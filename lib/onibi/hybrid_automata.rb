# frozen_string_literal: true

module Onibi
  # Experimental single-engine hybrid automaton for match-only regular syntax.
  # String matching emits candidate events, a bit-parallel position NFA computes
  # cold transitions, and the resulting subset states populate a bounded DFA.
  module HybridAutomata
    class UnsupportedPattern < RegexpError; end
    class UnsupportedInput < Error; end

    Fragment = Data.define(:nullable, :first, :last)
    Automaton = Data.define(:first_mask, :accept_mask, :nullable, :reach_masks,
                            :span_masks, :prefix_literal, :required_literals, :trailing_literal,
                            :exact_literal,
                            :anchored_start, :anchored_end, :before_final_newline, :line_anchor_start, :line_anchor_end,
                            :start_match,
                            :positive_prefix, :positive_suffix, :negative_prefix, :negative_suffix,
                            :word_boundary_start, :word_boundary_end, :unicode_spec,
                            :backref_spec, :repeat_literal_spec, :dot_literal_spec,
                            :atomic_literal_spec, :star_literal_spec, :bounded_literal_spec,
                            :lazy_star_literal_spec, :anchored_class_spec,
                            :alternation_literal_spec, :repeated_alternation_literal_spec,
                            :class_run_literal_spec, :class_run_chain_spec,
                            :adjacent_class_run_spec, :class_run_triple_spec,
                            :literal_class_literal_spec, :ascii_run_spec, :single_byte_spec,
                            :linebreak_spec,
                            :possessive_literal_spec)
    BytecodeInstruction = Data.define(:opcode, :operand)
    UnicodeSpec = Data.define(:kind, :value, :minimum, :maximum)
    BackrefSpec = Data.define(:body, :separator)
    RepeatLiteralSpec = Data.define(:byte, :suffix)
    RequiredLiteralSpec = Data.define(:literal, :offset)
    PossessiveLiteralSpec = Data.define(:unit, :minimum, :maximum, :suffix)
    DotLiteralSpec = Data.define(:prefix, :suffix, :allow_newline)
    StarLiteralSpec = Data.define(:prefix, :suffix, :allow_newline)
    BoundedLiteralSpec = Data.define(:literal, :unit, :minimum, :maximum)
    LazyStarLiteralSpec = Data.define(:prefix, :suffix, :allow_newline)
    AnchoredClassSpec = Data.define(:table)
    AlternationLiteralSpec = Data.define(:branches)
    RepeatedAlternationLiteralSpec = Data.define(:branches, :suffix, :width)
    ClassRunLiteralSpec = Data.define(:prefix, :table, :minimum, :suffix)
    ClassRunChainSpec = Data.define(:left_table, :separator, :right_table)
    AdjacentClassRunSpec = Data.define(:left_table, :right_table)
    ClassRunTripleSpec = Data.define(:first_table, :middle_table, :last_table)
    LiteralClassLiteralSpec = Data.define(:prefix, :table, :suffix)
    AsciiRunSpec = Data.define(:table, :candidate_byte, :candidate_bytes, :character_set, :any_byte)
    SingleByteSpec = Data.define(:table, :candidate_byte)
    LinebreakSpec = Data.define(:ascii_only)
    AtomicLiteralSpec = Data.define(:branches, :suffix, :subsumed_literal, :candidate_bytes)
    MAX_STATES = 512
    MAX_BOUNDED_REPEAT = 64
    EMPTY_REACH_MASKS = Array.new(256, 0).freeze
    EMPTY_SPAN_MASKS = {}.freeze

    require_relative "hybrid_automata_support"

    module_function

    def normalize_ast(ast)
      return normalize_sequence(ast) if ast.is_a?(AST::Sequence)
      return AST::Alternation.new(ast.branches.map { |branch| normalize_ast(branch) }) if ast.is_a?(AST::Alternation)

      ast
    end

    def normalize_sequence(sequence)
      parts = sequence.parts.map { |part| normalize_ast(part) }
      coalesced = parts.each_with_object([]) do |part, result|
        if result.last.is_a?(AST::Literal) && part.is_a?(AST::Literal) &&
           result.last.value.encoding == part.value.encoding
          result[-1] = AST::Literal.new(result.last.value + part.value)
        else
          result << part
        end
      end
      AST::Sequence.new(coalesced)
    end

    def compile(pattern, options: [], dfa: true, string_matching: true, dfa_state_limit: 4096)
      raise TypeError, "pattern must be a String" unless pattern.is_a?(String)

      ast = normalize_ast(Parser.new(pattern, options).parse)
      compile_ast(ast, options: options, dfa: dfa, string_matching: string_matching,
                       dfa_state_limit: dfa_state_limit)
    end

    def compile_unit(unit, dfa: true, string_matching: true, dfa_state_limit: 4096)
      raise TypeError, "expected an AST compilation unit" unless unit.respond_to?(:ast) && unit.respond_to?(:options)

      Compiler.new(dfa: dfa, string_matching: string_matching,
                   dfa_state_limit: dfa_state_limit, options: unit.options).compile(normalize_ast(unit.ast))
    end

    def compile_ast(ast, options: [], dfa: true, string_matching: true, dfa_state_limit: 4096)
      raise TypeError, "expected an AST" unless ast && AST.constants.any? { |name| ast.is_a?(AST.const_get(name)) }

      Compiler.new(dfa: dfa, string_matching: string_matching,
                   dfa_state_limit: dfa_state_limit, options: options).compile(normalize_ast(ast))
    end

    def validate_cfg!(cfg)
      supported = %i[match_literal match_class match_escape match_property match_any epsilon
                     match_group match_quantifier match_assertion match_atomic_group
                     match_option_group
                     match_conditional match_subexpression_call match_absence
                     match_backreference test_anchor]
      return if cfg.operations.all? { |operation| supported.include?(operation.opcode) }

      raise UnsupportedPattern, "CFG contains stateful operation outside the hybrid PoC subset"
    end

    # Encodes Glushkov follow edges as reach masks and relative bit shifts.
    module GraphBuilder
      private

      def consuming_state(&predicate)
        raise UnsupportedPattern, "automaton exceeds #{MAX_STATES} states" if @state_tables.length >= MAX_STATES

        index = @state_tables.length
        @state_tables << Array.new(256) { |byte| predicate.call(byte) }.freeze
        @follow << 0
        bit = 1 << index
        Fragment.new(false, bit, bit)
      end

      def connect(from_mask, to_mask)
        each_bit(from_mask) { |index| @follow[index] |= to_mask }
      end

      def each_bit(mask)
        while mask != 0
          bit = mask & -mask
          yield bit.bit_length - 1
          mask ^= bit
        end
      end

      def build_reach_masks
        reach = Array.new(256, 0)
        @state_tables.each_with_index do |table, index|
          bit = 1 << index
          256.times do |byte|
            reach[byte] |= bit if table[byte]
          end
        end
        reach.freeze
      end

      def build_span_masks
        spans = Hash.new(0)
        @follow.each_with_index do |targets, source|
          each_bit(targets) { |target| spans[target - source] |= 1 << source }
        end
        spans.freeze
      end
    end

    # Immutable NFA topology builder. Quantifiers are expanded into position
    # states so the runtime can represent every active state in one Integer.
    class Compiler
      include GraphBuilder
      include PatternFacts
      include AnchorFacts
      include GuardFacts
      include BoundaryFacts
      include CompilerFacts

      NODE_VISITORS = {
        AST::Literal => :literal_node, AST::CharacterClass => :character_class_node,
        AST::Escape => :escape_node, AST::Property => :property_node, AST::Any => :any_node,
        AST::Sequence => :sequence_node, AST::Alternation => :alternation_node,
        AST::Group => :group_node, AST::OptionGroup => :option_group_node,
        AST::Quantifier => :quantifier_node
      }.freeze
      PreparedAst = Data.define(:ast, :backref, :positive_prefix, :positive_suffix,
                                :negative_prefix, :negative_suffix,
                                :word_boundary_start, :word_boundary_end,
                                :anchored_start, :anchored_end, :before_final_newline, :line_anchor_start, :line_anchor_end,
                                :start_match,
                                :atomic_literal_spec, :possessive_literal_spec)

      def initialize(dfa:, string_matching:, dfa_state_limit:, options:)
        @dfa = dfa
        @string_matching = string_matching
        @dfa_state_limit = dfa_state_limit
        @options = options
        @state_tables = []
        @follow = []
        @scoped_ignorecase = nil
        @scoped_multiline = nil
      end

      def compile(ast)
        prepared = prepare_ast(ast)
        build_program(prepared)
      end

      private

      def prepare_ast(ast)
        atomic_literal = atomic_literal_spec(ast)
        possessive_literal = possessive_literal_spec(ast)
        source_positive_prefix = positive_lookbehind_literal(ast)
        backref, ast = extract_backref(ast)
        ast = RegularNormalizer.normalize(ast)
        raise UnsupportedPattern, "pattern is always false" if ast.equal?(RegularNormalizer::NEVER)

        ast, positive_prefix, positive_suffix, negative_prefix, negative_suffix = extract_guards(ast)
        validate_literal_guards!(negative_prefix, negative_suffix)
        ast, positive_prefix = consume_positive_guard(ast, positive_prefix, :prefix)
        ast, positive_suffix = consume_positive_guard(ast, positive_suffix, :suffix)
        ast, word_boundary_start, word_boundary_end = extract_boundaries(ast)
        ast, start_match = extract_start_match(ast)
        ast, anchored_start, anchored_end, before_final_newline, line_anchor_start, line_anchor_end = extract_anchors(ast)
        positive_prefix ||= source_positive_prefix
        PreparedAst.new(ast, backref, positive_prefix, positive_suffix, negative_prefix, negative_suffix,
                        word_boundary_start, word_boundary_end, anchored_start, anchored_end, before_final_newline,
                        line_anchor_start, line_anchor_end, start_match,
                        atomic_literal, possessive_literal)
      end

      def positive_lookbehind_literal(ast)
        return unless ast.is_a?(AST::Sequence) && ast.parts.length >= 2

        assertion = ast.parts.first
        return unless assertion.is_a?(AST::Assertion) && assertion.kind == :positive_lookbehind

        literal_value(assertion.body)
      end

      def build_program(prepared)
        ast = prepared.ast
        atomic_exact = prepared.atomic_literal_spec&.subsumed_literal
        string_matching_enabled = @string_matching && !ignorecase? && !scoped_option_group?(ast)
        prefix = string_matching_enabled ? selective_prefix(ast) : nil
        prefix ||= atomic_exact if atomic_exact && string_matching_enabled
        prefix = nil if prefix && !prefix.ascii_only?
        required_literals = string_matching_enabled ? required_literal_specs(ast) : nil
        trailing = string_matching_enabled ? trailing_literal(ast) : nil
        exact_literal = literal_value(ast) || repeated_literal_value(ast) || atomic_exact
        if prepared.positive_prefix && exact_literal&.start_with?(prepared.positive_prefix)
          exact_literal = exact_literal.delete_prefix(prepared.positive_prefix)
        end
        repeat_literal_spec = repeat_literal_spec(ast) unless constrained_match?(prepared)
        dot_literal_spec = dot_literal_spec(ast) unless constrained_match?(prepared)
        star_literal_spec = star_literal_spec(ast) unless constrained_match?(prepared)
        bounded_literal_spec = bounded_literal_spec(ast) unless constrained_match?(prepared)
        lazy_star_literal_spec = lazy_star_literal_spec(ast) unless constrained_match?(prepared)
        anchored_class_spec = anchored_class_spec(ast, prepared)
        alternation_literal_spec = alternation_literal_spec(ast) unless constrained_match?(prepared) || ignorecase?
        repeated_alternation_literal_spec = repeated_alternation_literal_spec(ast) unless constrained_match?(prepared) || ignorecase?
        class_run_literal_spec = class_run_literal_spec(ast) unless constrained_match?(prepared)
        class_run_chain_spec = class_run_chain_spec(ast) unless constrained_match?(prepared)
        adjacent_class_run_spec = adjacent_class_run_spec(ast) unless constrained_match?(prepared)
        class_run_triple_spec = class_run_triple_spec(ast) unless constrained_match?(prepared)
        literal_class_literal_spec = literal_class_literal_spec(ast) unless constrained_match?(prepared)
        ascii_run_spec = ascii_run_spec(ast) unless constrained_match?(prepared)
        single_byte_spec = single_byte_spec(ast)
        linebreak_spec = linebreak_spec(ast)
        spec = unicode_spec(ast)
        specialized = specialized_runtime?(prefix, exact_literal, prepared,
                                           repeat_literal_spec, dot_literal_spec, star_literal_spec,
                                           bounded_literal_spec, lazy_star_literal_spec,
                                           anchored_class_spec, alternation_literal_spec,
                                           literal_class_literal_spec, ascii_run_spec) || linebreak_spec
        fragment = specialized ? Fragment.new(false, 0, 0) : visit(ast)
        reach_masks = specialized ? EMPTY_REACH_MASKS : build_reach_masks
        span_masks = specialized ? EMPTY_SPAN_MASKS : build_span_masks

        automaton = Automaton.new(fragment.first, fragment.last, fragment.nullable,
                                  reach_masks, span_masks, prefix, required_literals, trailing, exact_literal,
                                  prepared.anchored_start, prepared.anchored_end,
                                  prepared.before_final_newline, prepared.line_anchor_start, prepared.line_anchor_end,
                                  prepared.start_match,
                                  prepared.positive_prefix, prepared.positive_suffix,
                                  prepared.negative_prefix, prepared.negative_suffix,
                                  prepared.word_boundary_start, prepared.word_boundary_end,
                                  spec, prepared.backref, repeat_literal_spec, dot_literal_spec,
                                  prepared.atomic_literal_spec, star_literal_spec, bounded_literal_spec,
                                  lazy_star_literal_spec, anchored_class_spec, alternation_literal_spec,
                                  repeated_alternation_literal_spec, class_run_literal_spec,
                                  class_run_chain_spec, adjacent_class_run_spec, class_run_triple_spec,
                                  literal_class_literal_spec, ascii_run_spec, single_byte_spec, linebreak_spec,
                                  prepared.possessive_literal_spec)
        Program.new(automaton, dfa: @dfa, dfa_state_limit: @dfa_state_limit, input_ir: :cfg,
                               ignorecase: ignorecase?)
      end

      def specialized_runtime?(prefix, exact_literal, prepared, *specs)
        return true if exact_literal && prefix && !constrained_match?(prepared)

        specs.any?
      end

      def visit(node)
        visitor = NODE_VISITORS[node.class]
        return send(visitor, node) if visitor

        name = node.class.name.split("::").last
        raise UnsupportedPattern, "#{name} is outside the hybrid PoC subset"
      end

      def extract_backref(ast)
        parts = ast.is_a?(AST::Sequence) ? ast.parts.dup : [ast]
        index = parts.index { |part| part.is_a?(AST::Backreference) }
        return [nil, ast] unless index && index >= 1

        reference = parts[index]
        separator = parts[index - 1] if index >= 2
        group = separator ? parts[index - 2] : parts[index - 1]
        return [nil, ast] unless group.is_a?(AST::Group)
        return [nil, ast] if separator && !separator.is_a?(AST::Literal)
        return [nil, ast] unless reference.identifier.to_s == group.name.to_s ||
                                 reference.identifier.to_i == group.number
        return [nil, ast] if separator.nil? && literal_value(group.body).nil? &&
                             !variable_backref_body?(group.body)

        parts.delete_at(index)
        body = parts.length == 1 ? parts.first : AST::Sequence.new(parts)
        [BackrefSpec.new(group.body, separator&.value), body]
      end

      def variable_backref_body?(body)
        body = body.parts.first if body.is_a?(AST::Sequence) && body.parts.one?
        body.is_a?(AST::Quantifier) && %i[* +].include?(body.kind) &&
          body.expression.is_a?(AST::Literal) && body.expression.value.bytesize == 1
      end

      def consume_positive_guard(ast, guard, side)
        return [ast, guard] unless guard && !guard.is_a?(String)

        parts = ast.is_a?(AST::Sequence) ? ast.parts : [ast]
        guard_parts = guard.is_a?(AST::Sequence) ? guard.parts : [guard]
        combined = side == :prefix ? guard_parts + parts : parts + guard_parts
        [AST::Sequence.new(combined), nil]
      end

      def validate_literal_guards!(*guards)
        return if guards.all? { |guard| guard.nil? || guard.is_a?(String) }

        raise UnsupportedPattern, "non-literal negative lookaround is outside the hybrid PoC subset"
      end

      def literal_node(node)
        node.value.bytes.reduce(empty_fragment) do |fragment, byte|
          concatenate(fragment, consuming_state do |candidate|
            ignorecase? ? candidate.chr.casecmp?(byte.chr) : candidate == byte
          end)
        end
      end

      def character_class_node(node)
        predicate = ascii_class_table(node.value)
        consuming_state { |byte| predicate[byte] }
      end

      def ascii_class_table(source)
        predicate = ClassPredicates.compiled(source).ascii_table
        return predicate unless ignorecase?

        256.times.map do |byte|
          character = byte.chr(Encoding::ASCII_8BIT)
          predicate[byte] || predicate[character.downcase.getbyte(0)] ||
            predicate[character.upcase.getbyte(0)]
        end.freeze
      end

      def property_node(node)
        consuming_state do |byte|
          matched = UnicodeProperties.matches?(node.name, byte.chr(Encoding::ASCII_8BIT))
          node.negated ? !matched : matched
        end
      end

      def escape_node(node)
        consuming_state do |byte|
          CharacterPredicates.escape_matches?(node.kind, byte.chr(Encoding::ASCII_8BIT))
        rescue KeyError
          raise UnsupportedPattern, "escape #{node.kind.inspect} is outside the hybrid PoC subset"
        end
      end

      def any_node(_node)
        consuming_state { |byte| multiline? || byte != 10 }
      end

      def sequence_node(node)
        node.parts.reduce(empty_fragment) { |fragment, part| concatenate(fragment, visit(part)) }
      end

      def alternation_node(node)
        fragments = node.branches.map { |branch| visit(branch) }
        Fragment.new(fragments.any?(&:nullable),
                     fragments.reduce(0) { |mask, fragment| mask | fragment.first },
                     fragments.reduce(0) { |mask, fragment| mask | fragment.last })
      end

      def group_node(node)
        visit(node.body)
      end

      def option_group_node(node)
        previous = [@scoped_ignorecase, @scoped_multiline]
        @scoped_ignorecase = node.ignorecase.nil? ? previous[0] : node.ignorecase
        @scoped_multiline = node.multiline.nil? ? previous[1] : node.multiline
        visit(node.body)
      ensure
        @scoped_ignorecase, @scoped_multiline = previous
      end

      def ignorecase?
        return @scoped_ignorecase unless @scoped_ignorecase.nil?

        @options.include?("ignorecase")
      end

      def multiline?
        return @scoped_multiline unless @scoped_multiline.nil?

        @options.include?("multiline")
      end

      def quantifier_node(node)
        validate_quantifier!(node)
        fragment = visit(node.expression) unless node.kind == :bounded
        return optional(fragment) if node.kind == :"?"
        return star(fragment) if node.kind == :*
        return plus(fragment) if node.kind == :+

        repeated(node.expression, node.minimum, node.maximum)
      end

      def validate_quantifier!(node)
        raise UnsupportedPattern, "possessive quantifiers are outside the hybrid PoC subset" unless %i[greedy lazy].include?(node.mode)
        return unless node.maximum && node.maximum > MAX_BOUNDED_REPEAT

        raise UnsupportedPattern, "bounded repeat exceeds #{MAX_BOUNDED_REPEAT}"
      end

      def repeated(expression, minimum, maximum)
        fragment = empty_fragment
        minimum.times { fragment = concatenate(fragment, visit(expression)) }
        if maximum
          (maximum - minimum).times { fragment = concatenate(fragment, optional(visit(expression))) }
        else
          fragment = concatenate(fragment, star(visit(expression)))
        end
        fragment
      end

      def optional(fragment)
        Fragment.new(true, fragment.first, fragment.last)
      end

      def star(fragment)
        connect(fragment.last, fragment.first)
        Fragment.new(true, fragment.first, fragment.last)
      end

      def plus(fragment)
        connect(fragment.last, fragment.first)
        fragment
      end

      def concatenate(left, right)
        connect(left.last, right.first)
        Fragment.new(left.nullable && right.nullable,
                     left.first | (left.nullable ? right.first : 0),
                     right.last | (right.nullable ? left.last : 0))
      end

      def empty_fragment
        Fragment.new(true, 0, 0)
      end
    end

    # A single runtime whose state is an NFA subset. Cold state/byte pairs use
    # masked bit shifts; repeated pairs become direct lazy-DFA transitions.
    module SingleSpanRuntime
      private

      def search_unanchored_single_span(input, position)
        span, sources = @single_span
        active = 0
        while position < input.bytesize
          active = single_span_step(active, input.getbyte(position), span, sources)
          return true unless (active & @accept_mask).zero?

          position += 1
        end
        false
      end

      def single_span_step(active, byte, span, sources)
        candidates = @first_mask
        selected = active & sources
        candidates |= span.negative? ? selected >> -span : selected << span
        candidates & @reach_masks[byte]
      end
    end

    # Reuses string-matching prefix events as an already-consumed NFA state.
    module PrefixRuntime
      private

      def search_prefix_events(input, position)
        prefix = @prefix_literal
        prefix_length = prefix.bytesize
        active = prefix_active
        candidate = prefix_literal_candidate(input, position)
        while candidate
          return true unless (active & @accept_mask).zero?

          return true if search_prefix_candidate(input, candidate + prefix_length, active)

          candidate = prefix_literal_candidate(input, candidate + 1)
        end
        false
      end

      def prefix_literal_candidate(input, position)
        prefix = @prefix_literal
        first_byte = prefix.getbyte(0)
        candidate = input.index(first_byte.chr(Encoding::ASCII_8BIT), position)
        while candidate
          return candidate if input.byteslice(candidate, prefix.bytesize) == prefix

          candidate = input.index(first_byte.chr(Encoding::ASCII_8BIT), candidate + 1)
        end
        nil
      end

      def search_prefix_candidate(input, position, active)
        while position < input.bytesize
          active = transition(active, input.getbyte(position), false)
          return true unless (active & @accept_mask).zero?
          break if active.zero?

          position += 1
        end
        false
      end

      def prefix_active
        @prefix_active ||= begin
          active = 0
          @prefix_literal.bytes.each_with_index do |byte, index|
            active = nfa_transition(active, byte, index.zero?)
          end
          active
        end
      end
    end

    # Uses a first-byte event to avoid full literal scans on sparse misses.
    module LiteralRuntime
      private

      def literal_search(input, position)
        return !input.index(@exact_literal, position).nil? unless @exact_literal.ascii_only?
        return !input.index(@exact_literal, position).nil? if @exact_literal.bytesize < 4

        first_byte = @exact_first_byte
        candidate = input.index(first_byte, position)
        return false unless candidate

        return !input.index(@exact_literal, position).nil? if literal_candidate_dense?(input, candidate, first_byte)

        !input.index(@exact_literal, candidate).nil?
      end

      def literal_candidate_dense?(input, candidate, first_byte)
        first_code = first_byte.getbyte(0)
        return true if input.getbyte(candidate + 1) == first_code

        next_candidate = input.index(first_byte, candidate + 1)
        next_candidate && next_candidate - candidate < 16
      end
    end

    # Builds a compact deterministic table for small single-span automata.
    module StaticDfaRuntime
      private

      def static_search(input, position)
        return unless @dfa_enabled
        return unless input.ascii_only?

        return static_prefix_search(input, position) if @prefix_literal
        return unless static_eligible?

        static = static_dfa_data
        return unless static && static[0].length <= @dfa_state_limit

        @dfa_rows[:static] ||= Array.new(static[0].length) unless @single_span
        static_match?(input, position, static)
      end

      def static_eligible?
        @single_span || (@prefix_literal.nil? && @span_entries.length >= 8)
      end

      def static_prefix_eligible?
        @prefix_literal && @span_entries.length >= 8
      end

      def eager_static_dfa?
        @dfa_enabled && @prefix_literal.nil? && @span_entries.length >= 8
      end

      def materialize_eager_static_dfa
        @static_dfa_attempted = true
        static = build_static_dfa
        @static_dfa_data = static if static && static[0].length <= @dfa_state_limit
      end

      def static_match?(input, position, static)
        rows, accepting, accepting_state = static
        limit = input.bytesize
        first_byte = static_first_byte
        if first_byte
          candidate = static_jump_candidate(input, position, first_byte)
          return false unless candidate

          return static_match_with_jumps(input, candidate, static, first_byte) if candidate != :dense
        end

        return static_match_scan_single(input, position, limit, rows, accepting_state) if accepting_state && !first_byte

        static_match_scan(input, position, limit, rows, accepting)
      end

      def static_prefix_search(input, position)
        return unless static_prefix_eligible?

        prefix = @prefix_literal
        candidate, dense = prefix_density(input, position, prefix)
        return false unless candidate
        return unless dense

        static = static_prefix_dfa_data
        return unless static && static[0].length <= @dfa_state_limit

        return static_prefix_suffix_search(input, position, static) if @trailing_literal

        while candidate
          return true if static_prefix_match?(input, candidate + prefix.bytesize, static)

          candidate = input.index(prefix, candidate + 1)
        end
        false
      end

      def static_prefix_suffix_search(input, position, static)
        suffix = @trailing_literal
        prefix = @prefix_literal
        suffix_position = input.index(suffix, position)
        while suffix_position
          suffix_end = suffix_position + suffix.bytesize
          prefix_position = input.rindex(prefix, suffix_position - prefix.bytesize)
          while prefix_position && prefix_position >= position
            prefix_end = prefix_position + prefix.bytesize
            return true if static_prefix_match_ending?(input, prefix_end, suffix_end, static)

            prefix_position = input.rindex(prefix, prefix_position - 1)
          end
          suffix_position = input.index(suffix, suffix_position + 1)
        end
        false
      end

      def static_prefix_match_ending?(input, position, limit, static)
        rows, accepting, accepting_state, dead_state = static
        state = 0
        while position < limit
          state = rows[state][input.getbyte(position)]
          return false if state == dead_state

          position += 1
        end
        accepting_state ? state == accepting_state : accepting[state]
      end

      def prefix_density(input, position, prefix)
        candidate = input.index(prefix, position)
        return [nil, false] unless candidate

        next_candidate = input.index(prefix, candidate + 1)
        [candidate, next_candidate && next_candidate - candidate < 64]
      end

      def static_prefix_match?(input, position, static)
        rows, accepting, accepting_state, dead_state = static
        return true if accepting[0]
        return static_prefix_match_single?(input, position, rows, accepting_state, dead_state) if accepting_state

        state = 0
        while position < input.bytesize
          state = rows[state][input.getbyte(position)]
          return true if accepting[state]
          break if state == dead_state

          position += 1
        end
        false
      end

      def static_prefix_match_single?(input, position, rows, accepting_state, dead_state)
        state = 0
        while position < input.bytesize
          state = rows[state][input.getbyte(position)]
          return true if state == accepting_state
          break if state == dead_state

          position += 1
        end
        false
      end

      def static_match_scan_single(input, position, limit, rows, accepting_state)
        state = 0
        while position < limit
          state = rows[state][input.getbyte(position)]
          return true if state == accepting_state

          position += 1
        end
        false
      end

      def static_match_scan(input, position, limit, rows, accepting)
        state = 0
        while position < limit
          state = rows[state][input.getbyte(position)]
          return true if accepting[state]

          position += 1
        end
        false
      end

      def static_match_with_jumps(input, position, static, first_byte)
        rows, accepting = static
        limit = input.bytesize
        state = 0
        while position < limit
          state = rows[state][input.getbyte(position)]
          return true if accepting[state]

          position += 1
          next unless state.zero?

          candidate = static_jump_candidate(input, position, first_byte)
          return false unless candidate

          return static_match_scan(input, candidate, limit, rows, accepting) if candidate == :dense

          position = candidate
        end
        false
      end

      def static_first_byte
        return @static_first_byte if @static_first_byte_attempted

        @static_first_byte_attempted = true
        bytes = 256.times.reject { |byte| (@first_mask & @reach_masks[byte]).zero? }
        @static_first_byte = bytes.one? ? bytes.first.chr : nil
      end

      def static_first_bytes
        return @static_first_bytes if @static_first_bytes_attempted

        @static_first_bytes_attempted = true
        bytes = 256.times.select { |byte| (@first_mask & @reach_masks[byte]).positive? }
        @static_first_bytes = (bytes.map { |byte| byte.chr(Encoding::ASCII_8BIT) }.join if bytes.length.between?(2, 8))
      end

      def static_jump_candidate(input, position, first_byte)
        candidate = input.index(first_byte, position)
        return unless candidate

        next_candidate = input.index(first_byte, candidate + 1)
        return :dense if next_candidate && next_candidate - candidate < 16

        candidate
      end

      def static_dfa_data
        return @static_dfa_data if @static_dfa_attempted

        @static_dfa_attempted = true
        @static_dfa_data = build_static_dfa
      end

      def static_prefix_dfa_data
        return @static_prefix_dfa_data if @static_prefix_dfa_attempted

        @static_prefix_dfa_attempted = true
        @static_prefix_dfa_data = build_static_dfa(prefix_active, inject_start: false)
      end

      def build_static_dfa(initial_mask = 0, inject_start: true)
        masks = [initial_mask]
        ids = { initial_mask => 0 }
        rows = []
        masks.each_with_index do |mask, state|
          rows[state] = static_row(mask, ids, masks, inject_start)
          return nil unless rows[state]
        end
        accepting = masks.map { |mask| (mask & @accept_mask) != 0 }.freeze
        accepting_state = accepting.one? ? accepting.index(true) : nil
        [rows.freeze, accepting, accepting_state, ids[0]].freeze
      end

      def static_row(mask, ids, masks, inject_start)
        row = Array.new(256)
        256.times do |byte|
          result = nfa_transition(mask, byte, inject_start)
          id = ids[result] || add_static_state(ids, masks, result)
          break unless id

          row[byte] = id
        end
        return unless row.none?(&:nil?)

        row.freeze
      end

      def add_static_state(ids, masks, result)
        return if masks.length >= 1024

        id = masks.length
        ids[result] = id
        masks << result
        id
      end
    end

    # Shares the NFA transition kernel and bounded lazy-DFA cache.
    module TransitionRuntime
      private

      def transition(active, byte, inject_start)
        return nfa_transition(active, byte, inject_start) unless @dfa_enabled

        key = (active << 1) | (inject_start ? 1 : 0)
        row = @dfa_rows[key]
        cached = row&.[](byte)
        return cached unless cached.nil?

        result = nfa_transition(active, byte, inject_start)
        if row
          row[byte] = result
        elsif @dfa_rows.length < @dfa_state_limit
          @dfa_rows[key] = Array.new(256).tap { |new_row| new_row[byte] = result }
        end
        result
      end

      def nfa_transition(active, byte, inject_start)
        return @first_mask & @reach_masks[byte] if active.zero? && inject_start

        candidates = inject_start ? @first_mask : 0
        return single_span_transition(candidates, active, byte) if @single_span

        case @span_entries.length
        when 1
          span, sources = @span_entries[0]
          selected = active & sources
          candidates |= span.negative? ? selected >> -span : selected << span
        when 2
          span, sources = @span_entries[0]
          selected = active & sources
          candidates |= span.negative? ? selected >> -span : selected << span
          span, sources = @span_entries[1]
          selected = active & sources
          candidates |= span.negative? ? selected >> -span : selected << span
        when 3
          span, sources = @span_entries[0]
          selected = active & sources
          candidates |= span.negative? ? selected >> -span : selected << span
          span, sources = @span_entries[1]
          selected = active & sources
          candidates |= span.negative? ? selected >> -span : selected << span
          span, sources = @span_entries[2]
          selected = active & sources
          candidates |= span.negative? ? selected >> -span : selected << span
        else
          @span_entries.each do |span, sources|
            selected = active & sources
            candidates |= span.negative? ? selected >> -span : selected << span
          end
        end
        candidates & @reach_masks[byte]
      end

      def observe_specialized_dfa
        @dfa_rows[:specialized] ||= [] if @dfa_enabled
      end

      def span_data(spans)
        entries = spans.to_a.freeze
        [spans, entries, entries.one? ? entries.first : nil]
      end

      def single_span_transition(candidates, active, byte)
        span, sources = @single_span
        selected = active & sources
        candidates |= span.negative? ? selected >> -span : selected << span
        candidates & @reach_masks[byte]
      end
    end

    # Executes one fused HFA with NFA and optional lazy-DFA state.
    class Program
      include SingleSpanRuntime
      include PrefixRuntime
      include LiteralRuntime
      include StaticDfaRuntime
      include TransitionRuntime
      include BackrefRuntime
      include UnicodeRuntime
      include GuardedRuntime
      include RepeatLiteralRuntime
      include PossessiveLiteralRuntime
      include DotLiteralRuntime
      include StarLiteralRuntime
      include BoundedLiteralRuntime
      include LazyStarLiteralRuntime
      include AnchoredClassRuntime
      include AlternationLiteralRuntime
      include RepeatedAlternationLiteralRuntime
      include ClassRunLiteralRuntime
      include ClassRunChainRuntime
      include AdjacentClassRunRuntime
      include ClassRunTripleRuntime
      include LiteralClassLiteralRuntime
      include AsciiRunRuntime
      include AtomicLiteralRuntime
      attr_reader :prefix_literal, :input_ir, :repeated_alternation_literal_spec,
                  :class_run_literal_spec, :class_run_chain_spec, :adjacent_class_run_spec,
                  :class_run_triple_spec, :literal_class_literal_spec, :ascii_run_spec

      def initialize(automaton, dfa:, dfa_state_limit:, input_ir: :cfg, ignorecase: false)
        @first_mask = automaton.first_mask
        @accept_mask = automaton.accept_mask
        @nullable = automaton.nullable
        @reach_masks = automaton.reach_masks
        @span_masks, @span_entries, @single_span = span_data(automaton.span_masks)
        @prefix_literal = automaton.prefix_literal
        @required_literals = automaton.required_literals
        @trailing_literal = automaton.trailing_literal
        @exact_literal = automaton.exact_literal
        @exact_first_byte = @exact_literal&.byteslice(0, 1)
        @anchored_start = automaton.anchored_start
        @anchored_end = automaton.anchored_end
        @before_final_newline = automaton.before_final_newline
        @line_anchor_start = automaton.line_anchor_start
        @line_anchor_end = automaton.line_anchor_end
        @start_match = automaton.start_match
        @negative_prefix = automaton.negative_prefix
        @negative_suffix = automaton.negative_suffix
        @positive_prefix = automaton.positive_prefix
        @positive_suffix = automaton.positive_suffix
        @word_boundary_start = automaton.word_boundary_start
        @word_boundary_end = automaton.word_boundary_end
        @word_table = (Array.new(256) { |byte| CharacterPredicates.word?(byte.chr) }.freeze if @word_boundary_start || @word_boundary_end)
        @unicode_spec = automaton.unicode_spec
        initialize_unicode_runtime(@unicode_spec)
        @backref_spec = automaton.backref_spec
        @ignorecase = ignorecase
        @backref_ignorecase = ignorecase
        @casefold_literal = @exact_literal&.downcase if @ignorecase && @exact_literal&.ascii_only?
        @backref_predicate, @backref_separator, @backref_literal = backref_data(@backref_spec,
                                                                                ignorecase: ignorecase)
        backref_body = @backref_spec&.body
        backref_body = backref_body.parts.first if backref_body.is_a?(AST::Sequence) && backref_body.parts.one?
        @backref_empty_allowed = backref_body.is_a?(AST::Quantifier) && backref_body.kind == :*
        @backref_separator_length = @backref_separator&.bytesize
        @repeat_literal_spec = automaton.repeat_literal_spec
        @dot_literal_spec = automaton.dot_literal_spec
        @star_literal_spec = automaton.star_literal_spec
        @bounded_literal_spec = automaton.bounded_literal_spec
        @lazy_star_literal_spec = automaton.lazy_star_literal_spec
        @anchored_class_spec = automaton.anchored_class_spec
        @alternation_literal_spec = automaton.alternation_literal_spec
        @repeated_alternation_literal_spec = automaton.repeated_alternation_literal_spec
        @class_run_literal_spec = automaton.class_run_literal_spec
        @class_run_chain_spec = automaton.class_run_chain_spec
        @adjacent_class_run_spec = automaton.adjacent_class_run_spec
        @class_run_triple_spec = automaton.class_run_triple_spec
        @literal_class_literal_spec = automaton.literal_class_literal_spec
        @ascii_run_spec = automaton.ascii_run_spec
        @single_byte_spec = automaton.single_byte_spec
        @linebreak_spec = automaton.linebreak_spec
        @atomic_literal_spec = automaton.atomic_literal_spec
        @possessive_literal_spec = automaton.possessive_literal_spec
        initialize_runtime_options(dfa, dfa_state_limit, input_ir)
        @casefold_variants = ([@exact_first_byte.downcase, @exact_first_byte.upcase].uniq.freeze if @ignorecase && @exact_literal&.ascii_only?)
      end

      def engine_kind = :hybrid

      def components
        components = [:bit_parallel_nfa]
        components.unshift(:lazy_dfa) if @dfa_enabled
        components.unshift(:string_matching) if @prefix_literal || @required_literals
        components.freeze
      end

      def bytecode
        instructions = []
        instructions << BytecodeInstruction.new(:string_search, @prefix_literal) if @prefix_literal
        instructions << BytecodeInstruction.new(:required_literal_search, @required_literals) if @required_literals
        instructions << BytecodeInstruction.new(:dfa_lookup, @dfa_state_limit) if @dfa_enabled
        instructions << BytecodeInstruction.new(:nfa_transition, @span_masks)
        instructions << BytecodeInstruction.new(:accept, @accept_mask)
        instructions.freeze
      end

      def dfa_state_count = @dfa_rows.length

      def topology_state_count = @reach_masks.count(&:positive?)

      def specialized_match_question?
        @repeated_alternation_literal_spec || @literal_class_literal_spec
      end

      def match?(input, position = 0)
        raise TypeError, "input must be a String" unless input.is_a?(String)
        return false if @negative_suffix == ""

        if @exact_literal && @prefix_literal
          fast = fast_literal_match(input, position)
          return fast unless fast.nil?
        end

        if input.ascii_only?
          return class_run_chain_match?(input, position) if @class_run_chain_spec
          return adjacent_class_run_match?(input, position) if @adjacent_class_run_spec
          return class_run_triple_match?(input, position) if @class_run_triple_spec
          return class_run_literal_match?(input, position) if @class_run_literal_spec
          return ascii_run_match?(input, position) if @ascii_run_spec
          return star_literal_match?(input, position) if @star_literal_spec
          return lazy_star_literal_match?(input, position) if @lazy_star_literal_spec
          return bounded_literal_match?(input, position) if @bounded_literal_spec
        end

        if exact_literal_search?
          position = normalize_position(input, position)
          return false if position.negative? || position > input.bytesize

          return !input.index(@exact_literal, position).nil?
        end

        return unicode_match?(input, position) if @unicode_spec && !input.ascii_only?
        return linebreak_match?(input, position) if @linebreak_spec
        return !start_match_result(input, normalize_position(input, position)).nil? if @start_match
        return backref_match?(input, position) if @backref_spec
        return possessive_literal_match?(input, position) if @possessive_literal_spec
        return repeat_literal_match?(input, position) if @repeat_literal_spec
        return dot_literal_match?(input, position) if @dot_literal_spec
        return star_literal_match?(input, position) if @star_literal_spec
        return bounded_literal_match?(input, position) if @bounded_literal_spec
        return lazy_star_literal_match?(input, position) if @lazy_star_literal_spec
        return atomic_literal_match?(input, position) if @atomic_literal_spec

        return positive_prefix_literal_match?(input, position) if positive_prefix_literal_search?

        return negative_prefix_literal_match?(input, position) if negative_prefix_literal_search?

        return negative_suffix_literal_match?(input, position) if negative_suffix_literal_search?

        return word_boundary_literal_match?(input, position) if word_boundary_literal_search?

        return anchored_class_match?(input, position) if @anchored_class_spec
        return alternation_literal_match?(input, position) if @alternation_literal_spec
        return repeated_alternation_literal_match?(input, position) if @repeated_alternation_literal_spec
        return class_run_literal_match?(input, position) if @class_run_literal_spec
        return class_run_chain_match?(input, position) if @class_run_chain_spec
        return adjacent_class_run_match?(input, position) if @adjacent_class_run_spec
        return class_run_triple_match?(input, position) if @class_run_triple_spec
        return literal_class_literal_match?(input, position) if @literal_class_literal_spec
        return ascii_run_match?(input, position) if @ascii_run_spec

        position = normalize_position(input, position)
        return nullable_match?(input, position) if nullable_shortcut?(input, position)

        match_from_position(input, position)
      end

      def match_result(input, position = 0)
        position = normalize_position(input, position)
        return if position.negative? || position > input.bytesize
        return if @negative_suffix == ""
        return unicode_match_result(input, position) if @unicode_spec && !input.ascii_only?
        return linebreak_match_result(input, position) if @linebreak_spec
        return start_match_result(input, position) if @start_match

        if @exact_literal && !@exact_literal.ascii_only?
          start = input.b.index(@exact_literal.b, position)
          return start && [start, start + @exact_literal.bytesize, []]
        end

        return positive_prefix_literal_match_result(input, position) if positive_prefix_literal_search?

        return negative_prefix_literal_match_result(input, position) if negative_prefix_literal_search?

        return negative_suffix_literal_match_result(input, position) if negative_suffix_literal_search?

        return word_boundary_literal_match_result(input, position) if word_boundary_literal_search?

        return unless input.ascii_only?
        return backref_match_result(input, position) if @backref_spec

        return anchored_class_match_result(input, position) if @anchored_class_spec
        return anchored_match_result(input, position) if @anchored_start || @anchored_end || @before_final_newline
        return line_anchor_match_result(input, position) if @line_anchor_start || @line_anchor_end
        return alternation_match_result(input, position) if @alternation_literal_spec
        return repeated_alternation_match_result(input, position) if @repeated_alternation_literal_spec
        return repeat_literal_match_result(input, position) if @repeat_literal_spec
        return possessive_literal_match_result(input, position) if @possessive_literal_spec
        return class_run_chain_match_result(input, position) if @class_run_chain_spec
        return adjacent_class_run_match_result(input, position) if @adjacent_class_run_spec
        return class_run_triple_match_result(input, position) if @class_run_triple_spec
        return single_byte_match_result(input, position) if @single_byte_spec
        return bounded_match_result(input, position) if @bounded_literal_spec
        return class_run_literal_match_result(input, position) if @class_run_literal_spec
        return dot_literal_match_result(input, position) if @dot_literal_spec
        return ascii_run_match_result(input, position) if @ascii_run_spec
        return literal_class_literal_match_result(input, position) if @literal_class_literal_spec
        return star_literal_match_result(input, position) if @star_literal_spec
        return lazy_star_literal_match_result(input, position) if @lazy_star_literal_spec
        return repeated_exact_literal_match_result(input, position) if repeated_exact_literal_topology?
        return guarded_literal_match_result(input, position) if @exact_literal && guarded_search?
        return nfa_match_result(input, position) unless @exact_literal && @prefix_literal
        return unless @exact_literal.ascii_only?

        start = input.index(@exact_literal, position)
        start && [start, start + @exact_literal.bytesize, []]
      end

      def alternation_match_result(input, position)
        best = nil
        @alternation_literal_spec.branches.each do |branch|
          candidate = input.index(branch, position)
          next unless candidate
          next if best && candidate >= best[0]

          best = [candidate, candidate + branch.bytesize, []]
        end
        best
      end

      def anchored_class_match_result(input, position)
        return unless position.zero?
        return unless input.each_byte.all? { |byte| @anchored_class_spec.table[byte] }

        [0, input.bytesize, []]
      end

      def repeated_alternation_match_result(input, position)
        spec = @repeated_alternation_literal_spec
        candidate = repeated_alternation_candidate(input, position, spec)
        while candidate
          cursor = candidate
          cursor += spec.width while spec.branches.any? { |value| literal_bytes_at?(input, cursor, value) }
          suffix_position = input.rindex(spec.suffix, cursor)
          while suffix_position && suffix_position >= candidate + spec.width
            return [candidate, suffix_position + spec.suffix.bytesize, []] if (suffix_position - candidate).modulo(spec.width).zero?

            suffix_position = input.rindex(spec.suffix, suffix_position - 1)
          end

          candidate = repeated_alternation_candidate(input, candidate + 1, spec)
        end
        nil
      end

      def repeated_alternation_candidate(input, position, spec)
        spec.branches.filter_map { |branch| input.index(branch, position) }.min
      end

      def repeat_literal_match_result(input, position)
        spec = @repeat_literal_spec
        suffix_position = input.index(spec.suffix, position + 1)
        while suffix_position
          start = suffix_position
          start -= 1 while start > position && input.getbyte(start - 1) == spec.byte
          return [start, suffix_position + spec.suffix.bytesize, []] if start < suffix_position

          suffix_position = input.index(spec.suffix, suffix_position + 1)
        end
        nil
      end

      def class_run_chain_match_result(input, position)
        spec = @class_run_chain_spec
        separator = input.index(spec.separator, position)
        while separator
          left = separator
          left -= 1 while left > position && spec.left_table[input.getbyte(left - 1)]
          right = separator + spec.separator.bytesize
          right += 1 while right < input.bytesize && spec.right_table[input.getbyte(right)]
          return [left, right, []] if left < separator && right > separator + spec.separator.bytesize

          separator = input.index(spec.separator, separator + 1)
        end
        nil
      end

      def adjacent_class_run_match_result(input, position)
        spec = @adjacent_class_run_spec
        cursor = position + 1
        while cursor < input.bytesize
          if spec.right_table[input.getbyte(cursor)] && spec.left_table[input.getbyte(cursor - 1)]
            start = cursor - 1
            start -= 1 while start > position && spec.left_table[input.getbyte(start - 1)]
            finish = cursor + 1
            finish += 1 while finish < input.bytesize && spec.right_table[input.getbyte(finish)]
            return [start, finish, []]
          end

          cursor += 1
        end
        nil
      end

      def class_run_triple_match_result(input, position)
        spec = @class_run_triple_spec
        cursor = position + 1
        while cursor < input.bytesize
          if spec.last_table[input.getbyte(cursor)] && spec.middle_table[input.getbyte(cursor - 1)]
            middle_start = cursor - 1
            middle_start -= 1 while middle_start > position && spec.middle_table[input.getbyte(middle_start - 1)]
            if middle_start > position && spec.first_table[input.getbyte(middle_start - 1)]
              start = middle_start - 1
              start -= 1 while start > position && spec.first_table[input.getbyte(start - 1)]
              finish = cursor + 1
              finish += 1 while finish < input.bytesize && spec.last_table[input.getbyte(finish)]
              return [start, finish, []]
            end
          end

          cursor += 1
        end
        nil
      end

      def single_byte_match_result(input, position)
        table = @single_byte_spec.table
        if @single_byte_spec.candidate_byte
          candidate = input.index(@single_byte_spec.candidate_byte, position)
          return candidate && [candidate, candidate + 1, []]
        end

        candidate = position
        while candidate < input.bytesize
          return [candidate, candidate + 1, []] if table[input.getbyte(candidate)]

          candidate += 1
        end
        nil
      end

      def linebreak_match?(input, position)
        !linebreak_match_result(input, normalize_position(input, position)).nil?
      end

      def linebreak_match_result(input, position)
        return unicode_linebreak_match_result(input, position) unless input.ascii_only?

        candidate = position
        while candidate < input.bytesize
          byte = input.getbyte(candidate)
          finish = if byte == 13
                     input.getbyte(candidate + 1) == 10 ? candidate + 2 : candidate + 1
                   elsif [10, 11, 12].include?(byte)
                     candidate + 1
                   end
          return [candidate, finish, []] if finish

          candidate += 1
        end
        nil
      end

      def unicode_linebreak_match_result(input, position)
        cursor = position
        while cursor < input.bytesize
          character = input.byteslice(cursor, 4).each_char.first
          width = character.bytesize
          finish = if character == "\r"
                     next_character = input.byteslice(cursor + width, 4)&.each_char&.first
                     next_character == "\n" ? cursor + width + next_character.bytesize : cursor + width
                   elsif CharacterPredicates.linebreak?(character)
                     cursor + width
                   end
          return [cursor, finish, []] if finish

          cursor += width
        end
        nil
      end

      def bounded_match_result(input, position)
        spec = @bounded_literal_spec
        candidate = input.index(spec.unit, position)
        while candidate
          count = 0
          cursor = candidate
          while count < spec.maximum && input.byteslice(cursor, spec.unit.bytesize) == spec.unit
            count += 1
            cursor += spec.unit.bytesize
          end
          return [candidate, cursor, []] if count >= spec.minimum

          candidate = input.index(spec.unit, candidate + 1)
        end
        nil
      end

      def class_run_literal_match_result(input, position)
        spec = @class_run_literal_spec
        candidate = input.index(spec.prefix, position)
        while candidate
          run_start = candidate + spec.prefix.bytesize
          finish = run_start + spec.minimum
          if finish <= input.bytesize && class_run_bytes_match?(input, run_start, finish, spec.table) &&
             input.byteslice(finish, spec.suffix.bytesize) == spec.suffix
            return [candidate, finish + spec.suffix.bytesize, []]
          end

          candidate = input.index(spec.prefix, candidate + 1)
        end
        nil
      end

      def dot_literal_match_result(input, position)
        spec = @dot_literal_spec
        candidate = input.index(spec.prefix, position)
        while candidate
          finish = candidate + 3
          if finish <= input.bytesize && (spec.allow_newline || input.getbyte(candidate + 1) != 10) &&
             input.getbyte(candidate + 2) == spec.suffix.getbyte(0)
            return [candidate, finish, []]
          end

          candidate = input.index(spec.prefix, candidate + 1)
        end
        nil
      end

      def ascii_run_match_result(input, position)
        spec = @ascii_run_spec
        candidate = ascii_run_candidate(input, position, spec)
        while candidate && candidate < input.bytesize
          finish = candidate
          finish += 1 while finish < input.bytesize && spec.table[input.getbyte(finish)]
          return [candidate, finish, []] if finish > candidate

          candidate = ascii_run_candidate(input, candidate + 1, spec)
        end
        nil
      end

      def literal_class_literal_match_result(input, position)
        spec = @literal_class_literal_spec
        candidate = input.index(spec.prefix, position)
        while candidate
          run_start = candidate + spec.prefix.bytesize
          suffix_position = input.index(spec.suffix, run_start + 1)
          best = nil
          while suffix_position
            best = suffix_position if class_run_bytes_match?(input, run_start, suffix_position, spec.table)
            suffix_position = input.index(spec.suffix, suffix_position + 1)
          end
          return [candidate, best + spec.suffix.bytesize, []] if best

          candidate = input.index(spec.prefix, candidate + 1)
        end
        nil
      end

      def star_literal_match_result(input, position)
        spec = @star_literal_spec
        candidate = input.index(spec.prefix, position)
        while candidate
          suffix = input.index(spec.suffix, candidate + spec.prefix.bytesize)
          best = nil
          while suffix
            newline = input.index("\n", candidate + spec.prefix.bytesize)
            break if !spec.allow_newline && newline && newline < suffix

            best = suffix + spec.suffix.bytesize
            suffix = input.index(spec.suffix, suffix + 1)
          end
          return [candidate, best, []] if best

          candidate = input.index(spec.prefix, candidate + 1)
        end
        nil
      end

      def lazy_star_literal_match_result(input, position)
        spec = @lazy_star_literal_spec
        candidate = input.index(spec.prefix, position)
        while candidate
          suffix = input.index(spec.suffix, candidate + spec.prefix.bytesize)
          while suffix
            newline = input.index("\n", candidate + spec.prefix.bytesize)
            return [candidate, suffix + spec.suffix.bytesize, []] if
              spec.allow_newline || newline.nil? || newline >= suffix

            suffix = input.index(spec.suffix, suffix + 1)
          end
          candidate = input.index(spec.prefix, candidate + 1)
        end
        nil
      end

      def ascii_run_candidate(input, position, spec)
        return input.index(spec.candidate_byte, position) if spec.candidate_byte
        return position if spec.candidate_bytes.length > 16

        earliest = nil
        spec.candidate_bytes.each do |byte|
          candidate = input.index(byte.chr(Encoding::ASCII_8BIT), position)
          earliest = candidate if candidate && (earliest.nil? || candidate < earliest)
        end
        earliest
      end

      def nfa_match_result(input, position, candidate_input = nil)
        prefix = @prefix_literal
        exact_first_byte = @exact_first_byte
        required_literals = @required_literals
        first_bytes = static_first_bytes unless prefix || exact_first_byte || required_literals
        candidate = if prefix
                      input.index(prefix, position)
                    elsif exact_first_byte
                      input.index(exact_first_byte, position)
                    elsif required_literals
                      required_literal_candidate(input, position)
                    elsif first_bytes
                      first_byte_set_candidate(input, position, first_bytes)
                    elsif candidate_input
                      candidate_input.index("\0", position)
                    else
                      position
                    end
        while candidate
          active = 0
          cursor = candidate
          last_accept = nil
          while cursor < input.bytesize
            active = transition(active, input.getbyte(cursor), cursor == candidate)
            last_accept = cursor + 1 unless (active & @accept_mask).zero?
            break if active.zero?

            cursor += 1
          end
          return [candidate, last_accept, []] if last_accept

          candidate = if prefix
                        input.index(prefix, candidate + 1)
                      elsif exact_first_byte
                        input.index(exact_first_byte, candidate + 1)
                      elsif required_literals
                        required_literal_candidate(input, candidate + 1)
                      elsif first_bytes
                        first_byte_set_candidate(input, candidate + 1, first_bytes)
                      elsif candidate_input
                        candidate_input.index("\0", candidate + 1)
                      else
                        candidate + 1
                      end
          candidate = nil if candidate && candidate >= input.bytesize
        end
        nil
      end

      def candidate_search_input(input)
        return unless input.ascii_only?
        return if input.include?("\0")

        source = candidate_event_source
        source && input.tr(source, "\0")
      end

      def candidate_event_source
        return @candidate_event_source if defined?(@candidate_event_source)

        bytes = 256.times.select { |byte| (@first_mask & @reach_masks[byte]).positive? }
        @candidate_event_source = if bytes.length > 8 && bytes.length < 256
                                    bytes.pack("C*").force_encoding(Encoding::ASCII_8BIT).freeze
                                  else
                                    false
                                  end
      end

      def required_literal_candidate(input, position)
        best = nil
        @required_literals.each do |spec|
          literal_position = input.index(spec.literal, position + spec.offset)
          start = literal_position && literal_position - spec.offset
          next unless start && start >= position

          best = start if best.nil? || start < best
        end
        best
      end

      def each_match_result(input, position = 0, &block)
        return enum_for(__method__, input, position) unless block_given?

        if @linebreak_spec
          position = normalize_position(input, position)
          return if position.negative? || position > input.bytesize

          while (result = linebreak_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @start_match
          position = normalize_position(input, position)
          result = start_match_result(input, position)
          yield result if result
          return
        end

        if (@anchored_start || @anchored_end || @before_final_newline) && !@anchored_class_spec
          position = normalize_position(input, position)
          result = anchored_match_result(input, position)
          yield result if result
          return
        end
        if (@line_anchor_start || @line_anchor_end) && !@anchored_class_spec
          position = normalize_position(input, position)
          while (result = line_anchor_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        unless input.ascii_only?
          if @exact_literal && !@exact_literal.ascii_only?
            position = normalize_position(input, position)
            return if position.negative? || position > input.bytesize

            while (start = input.b.index(@exact_literal.b, position))
              finish = start + @exact_literal.bytesize
              yield [start, finish, []]
              position = finish
            end
            return
          end
          return unless @unicode_spec

          position = normalize_position(input, position)
          return if position.negative? || position > input.bytesize

          while (result = unicode_match_result(input, position))
            yield result
            position = unicode_character_position(input, result[1])
          end
          return
        end

        return unless
                      @anchored_class_spec || @alternation_literal_spec || @repeated_alternation_literal_spec ||
                      @repeat_literal_spec ||
                      @class_run_chain_spec ||
                      @adjacent_class_run_spec ||
                      @class_run_triple_spec ||
                      @linebreak_spec ||
                      @single_byte_spec || @bounded_literal_spec ||
                      @class_run_literal_spec ||
                      @dot_literal_spec ||
                      @star_literal_spec || @lazy_star_literal_spec ||
                      @literal_class_literal_spec ||
                      @ascii_run_spec ||
                      @exact_literal&.ascii_only? || @first_mask.positive?

        position = normalize_position(input, position)
        return if position.negative? || position > input.bytesize

        if word_boundary_literal_search?
          while (result = word_boundary_literal_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if negative_prefix_literal_search?
          while (result = negative_prefix_literal_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if negative_suffix_literal_search?
          while (result = negative_suffix_literal_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @backref_spec
          while (result = backref_match_result(input, position))
            yield result
            position = [result[1], position + 1].max
          end
          return
        end

        if @anchored_class_spec
          result = anchored_class_match_result(input, position)
          yield result if result
          return
        end

        return each_alternation_result(input, position, &block) if @alternation_literal_spec

        if @repeated_alternation_literal_spec
          while (result = repeated_alternation_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @repeat_literal_spec
          while (result = repeat_literal_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @class_run_chain_spec
          while (result = class_run_chain_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @adjacent_class_run_spec
          while (result = adjacent_class_run_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @class_run_triple_spec
          while (result = class_run_triple_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @linebreak_spec
          while (result = linebreak_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @single_byte_spec
          table = @single_byte_spec.table
          while (candidate = next_single_byte_candidate(input, position, table,
                                                        @single_byte_spec.candidate_byte))
            yield [candidate, candidate + 1, []]
            position = candidate + 1
          end
          return
        end

        if @star_literal_spec
          while (result = star_literal_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @lazy_star_literal_spec
          while (result = lazy_star_literal_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @bounded_literal_spec
          while (result = bounded_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @class_run_literal_spec
          while (result = class_run_literal_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @dot_literal_spec
          while (result = dot_literal_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @ascii_run_spec
          while (result = ascii_run_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @literal_class_literal_spec
          while (result = literal_class_literal_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if repeated_exact_literal_topology?
          while (result = repeated_exact_literal_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @exact_literal && guarded_search?
          while (result = guarded_literal_match_result(input, position))
            yield result
            position = result[1]
          end
          return
        end

        if @exact_literal && @exact_literal.empty?
          while position <= input.bytesize
            yield [position, position, []]
            position += 1
          end
          return
        end

        if @prefix_literal.nil?
          candidate_input = candidate_search_input(input)
          while (result = nfa_match_result(input, position, candidate_input))
            yield result
            position = result[1]
          end
          return
        end

        if @exact_literal.nil?
          candidate_input = candidate_search_input(input)
          while (result = nfa_match_result(input, position, candidate_input))
            yield result
            position = result[1]
          end
          return
        end

        while (start = input.index(@exact_literal, position))
          finish = start + @exact_literal.bytesize
          yield [start, finish, []]
          position = finish
        end
      end

      def each_alternation_result(input, position)
        while position <= input.bytesize
          result = alternation_match_result(input, position)
          break unless result

          yield result
          position = result[1]
        end
      end

      def repeated_exact_literal_topology?
        return false unless @exact_literal && @prefix_literal.nil?

        width = @exact_literal.bytesize
        width > 1 && @span_masks.length == 2 &&
          @span_masks[width - 1] == 1 && @span_masks[-(width - 1)] == (1 << (width - 1))
      end

      def repeated_exact_literal_match_result(input, position)
        candidate = input.index(@exact_literal, position)
        while candidate
          cursor = candidate
          cursor += @exact_literal.bytesize while input.byteslice(cursor, @exact_literal.bytesize) == @exact_literal
          return [candidate, cursor, []] if cursor > candidate

          candidate = input.index(@exact_literal, candidate + 1)
        end
        nil
      end

      def next_single_byte_candidate(input, position, table, candidate_byte)
        return input.index(candidate_byte, position) if candidate_byte

        while position < input.bytesize
          return position if table[input.getbyte(position)]

          position += 1
        end
        nil
      end

      private

      def initialize_runtime_options(dfa, dfa_state_limit, input_ir)
        @dfa_enabled = dfa
        @dfa_state_limit = dfa_state_limit
        @dfa_rows = {}
        @static_dfa_attempted = false
        @static_dfa_data = nil
        @static_first_byte_attempted = false
        @static_first_byte = nil
        @static_first_bytes_attempted = false
        @static_first_bytes = nil
        @input_ir = input_ir
        materialize_eager_static_dfa if eager_static_dfa?
      end

      def match_from_position(input, position)
        return false if position.negative? || position > input.bytesize
        return nullable_match?(input, position) if nullable_shortcut?(input, position)
        return !start_match_result(input, position).nil? if @start_match
        return search_absolute_anchors(input, position) if @anchored_start || @anchored_end || @before_final_newline
        return search_line_anchors(input, position) if @line_anchor_start || @line_anchor_end
        return search_guarded(input, position) if guarded_search?
        return casefold_literal_search(input, position) if @ignorecase && @exact_literal
        return !input.index(@exact_literal, position).nil? if @exact_literal && !@ignorecase
        return literal_search(input, position) if @exact_literal && @prefix_literal

        static = static_search(input, position)
        return static unless static.nil?

        @prefix_literal ? search_prefix_events(input, position) : search_unanchored(input, position)
      end

      def start_match_result(input, position)
        return if position.negative? || position > input.bytesize
        return [position, position, []] if @nullable && final_anchor_match?(input, position)

        active = 0
        cursor = position
        while cursor < input.bytesize
          active = nfa_transition(active, input.getbyte(cursor), cursor == position)
          return [position, cursor + 1, []] if (active & @accept_mask).positive? && final_anchor_match?(input, cursor + 1)
          break if active.zero?

          cursor += 1
        end
        nil
      end

      def anchored_match_result(input, position)
        return if position.negative? || position > input.bytesize
        return if @anchored_start && position != 0

        candidate = @anchored_start ? 0 : position
        while candidate < input.bytesize
          active = 0
          cursor = candidate
          while cursor < input.bytesize
            active = transition(active, input.getbyte(cursor), cursor == candidate)
            if (active & @accept_mask).positive?
              finish = cursor + 1
              return [candidate, finish, []] if final_anchor_match?(input, finish)
            end
            break if active.zero?

            cursor += 1
          end
          break if @anchored_start

          candidate += 1
        end
        return [position, position, []] if @nullable && final_anchor_match?(input, position)

        nil
      end

      def line_anchor_match_result(input, position)
        return if position.negative? || position > input.bytesize

        candidate = position
        candidate += 1 while @line_anchor_start && candidate.positive? &&
                             candidate < input.bytesize && input.getbyte(candidate - 1) != 10
        while candidate <= input.bytesize
          if !@line_anchor_start || candidate.zero? || input.getbyte(candidate - 1) == 10
            active = 0
            cursor = candidate
            while cursor < input.bytesize
              active = transition(active, input.getbyte(cursor), cursor == candidate)
              if (active & @accept_mask).positive?
                finish = cursor + 1
                line_end = finish == input.bytesize || input.getbyte(finish) == 10
                return [candidate, finish, []] unless @line_anchor_end && !line_end
              end
              break if active.zero?

              cursor += 1
            end
          end
          break unless @line_anchor_start

          newline = input.index("\n", candidate)
          break unless newline

          candidate = newline + 1
        end
        nil
      end

      def nullable_match?(input, position)
        return false if @anchored_start && position != 0
        return false unless final_anchor_match?(input, position)
        return false if @line_anchor_start && position.positive? && input.getbyte(position - 1) != 10
        return false if @line_anchor_end && position < input.bytesize && input.getbyte(position) != 10

        true
      end

      def nullable_shortcut?(input, position)
        @nullable && @negative_suffix != "" &&
          (@first_mask.zero? || final_anchor_match?(input, position))
      end

      def final_anchor_match?(input, finish)
        return true unless @anchored_end || @before_final_newline
        return true if @anchored_end && finish == input.bytesize
        return true if @before_final_newline && finish == input.bytesize

        @before_final_newline && finish == input.bytesize - 1 && input.getbyte(finish) == 10
      end

      def search_line_anchors(input, position)
        return false if position.negative? || position > input.bytesize

        candidate = position
        candidate += 1 while candidate < input.bytesize &&
                             @line_anchor_start && candidate.positive? && input.getbyte(candidate - 1) != 10
        while candidate <= input.bytesize
          if !@line_anchor_start || candidate.zero? || input.getbyte(candidate - 1) == 10
            active = 0
            cursor = candidate
            while cursor < input.bytesize
              active = transition(active, input.getbyte(cursor), cursor == candidate)
              return true if ((active & @accept_mask) != 0) && !(@line_anchor_end && cursor + 1 < input.bytesize && input.getbyte(cursor + 1) != 10)
              break if active.zero?

              cursor += 1
            end
          end
          break unless @line_anchor_start

          newline = input.index("\n", candidate)
          break unless newline

          candidate = newline + 1
        end
        false
      end

      def casefold_literal_search(input, position)
        return !input.downcase.index(@casefold_literal, position).nil? if @exact_literal.ascii_only? && input.ascii_only?

        return unicode_casefold_literal_search(input, position) if @exact_literal.ascii_only?

        return !input.downcase.index(@exact_literal.downcase, position).nil?

        variants = @casefold_variants
        variants.any? do |variant|
          candidate = input.index(variant, position)
          while candidate
            return true if input.byteslice(candidate, @exact_literal.bytesize).casecmp?(@exact_literal)

            candidate = input.index(variant, candidate + 1)
          end
          false
        end
      end

      def unicode_casefold_literal_search(input, position)
        if @exact_literal.length == 1
          offset = 0
          input.each_char do |character|
            return true if offset >= position && character.casecmp?(@exact_literal)

            offset += character.bytesize
          end
          return false
        end

        !input.downcase.index(@exact_literal.downcase, position).nil?
      end

      def search_absolute_anchors(input, position)
        return false if @anchored_start && position != 0

        active = 0
        cursor = position
        inject_start = true
        while cursor < input.bytesize
          active = transition(active, input.getbyte(cursor), inject_start)
          accepted = (active & @accept_mask) != 0
          return true if accepted && final_anchor_match?(input, cursor + 1)
          return false if @anchored_start && active.zero?

          inject_start = !@anchored_start
          cursor += 1
        end
        false
      end

      def fast_literal_match(input, position)
        return if @start_match || @backref_spec || @anchored_start || @anchored_end || @before_final_newline ||
                  @line_anchor_start || @line_anchor_end || guarded_search? || @ignorecase
        return unless position.is_a?(Integer) && position.zero? && @exact_literal && @prefix_literal

        literal_search(input, position)
      end

      def exact_literal_search?
        @exact_literal && @span_masks.length == 1 && !@ignorecase && !@start_match &&
          !@anchored_start && !@anchored_end && !@before_final_newline && !@line_anchor_start &&
          !@line_anchor_end && !guarded_search?
      end

      def word_boundary_literal_search?
        @exact_literal && @word_table && (@word_boundary_start || @word_boundary_end)
      end

      def positive_prefix_literal_search?
        @exact_literal && @positive_prefix && !@positive_suffix && !@negative_prefix &&
          !@negative_suffix && !@word_boundary_start && !@word_boundary_end
      end

      def positive_prefix_literal_match?(input, position)
        !positive_prefix_literal_match_result(input, position).nil?
      end

      def positive_prefix_literal_match_result(input, position)
        return unless input.ascii_only?

        candidate = input.index(@exact_literal, position)
        while candidate
          prefix_start = candidate - @positive_prefix.bytesize
          return [candidate, candidate + @exact_literal.bytesize, []] if prefix_start >= 0 &&
                                                                         input.byteslice(prefix_start,
                                                                                         @positive_prefix.bytesize) == @positive_prefix

          candidate = input.index(@exact_literal, candidate + 1)
        end
        nil
      end

      def negative_suffix_literal_search?
        @exact_literal && @negative_suffix && !@positive_prefix && !@positive_suffix && !@negative_prefix &&
          !@word_boundary_start && !@word_boundary_end
      end

      def negative_prefix_literal_search?
        @exact_literal && @negative_prefix && !@positive_prefix && !@positive_suffix && !@negative_suffix &&
          !@word_boundary_start && !@word_boundary_end
      end

      def negative_prefix_literal_match?(input, position)
        !negative_prefix_literal_match_result(input, position).nil?
      end

      def negative_prefix_literal_match_result(input, position)
        return unless input.ascii_only?

        candidate = input.index(@exact_literal, position)
        while candidate
          prefix_start = candidate - @negative_prefix.bytesize
          prefix = prefix_start >= 0 && input.byteslice(prefix_start, @negative_prefix.bytesize)
          return [candidate, candidate + @exact_literal.bytesize, []] unless prefix == @negative_prefix

          candidate = input.index(@exact_literal, candidate + 1)
        end
        nil
      end

      def negative_suffix_literal_match?(input, position)
        !negative_suffix_literal_match_result(input, position).nil?
      end

      def negative_suffix_literal_match_result(input, position)
        return unless input.ascii_only?

        candidate = input.index(@exact_literal, position)
        while candidate
          finish = candidate + @exact_literal.bytesize
          return [candidate, finish, []] if input.byteslice(finish, @negative_suffix.bytesize) != @negative_suffix

          candidate = input.index(@exact_literal, candidate + 1)
        end
        nil
      end

      def word_boundary_literal_match?(input, position)
        return false unless input.ascii_only?

        candidate = input.index(@exact_literal, position)
        while candidate
          finish = candidate + @exact_literal.bytesize
          return true if word_boundary_edges_match?(input, candidate, finish)

          candidate = input.index(@exact_literal, candidate + 1)
        end
        false
      end

      def word_boundary_literal_match_result(input, position)
        return unless input.ascii_only?

        candidate = input.index(@exact_literal, position)
        while candidate
          finish = candidate + @exact_literal.bytesize
          return [candidate, finish, []] if word_boundary_edges_match?(input, candidate, finish)

          candidate = input.index(@exact_literal, candidate + 1)
        end
        nil
      end

      def word_boundary_edges_match?(input, start, finish)
        if @word_boundary_start
          before = start.positive? && @word_table[input.getbyte(start - 1)]
          current = @word_table[input.getbyte(start)]
          return false unless before != current
        end
        if @word_boundary_end
          current = @word_table[input.getbyte(finish - 1)]
          after = finish < input.bytesize && @word_table[input.getbyte(finish)]
          return false unless current != after
        end
        true
      end

      def normalize_position(input, position)
        return 0 if position.is_a?(Integer) && position.zero?

        position = position.to_int if position.respond_to?(:to_int)
        raise TypeError, "position must be an Integer" unless position.is_a?(Integer)

        position.negative? ? position + input.bytesize : position
      end

      def search_anchored(input, position)
        active = 0
        inject_start = true
        while position < input.bytesize
          active = transition(active, input.getbyte(position), inject_start)
          return true unless (active & @accept_mask).zero?
          return false if active.zero?

          inject_start = false
          position += 1
        end
        false
      end

      def search_unanchored(input, position)
        return search_unanchored_single_span(input, position) if @single_span
        return search_required_literal_events(input, position) if @required_literals
        return search_first_byte_events(input, position) if input.ascii_only? && !@ignorecase && static_first_byte
        return search_first_byte_set_events(input, position) if input.ascii_only? && !@ignorecase && static_first_bytes

        active = 0
        while position < input.bytesize
          active = transition(active, input.getbyte(position), true)
          return true unless (active & @accept_mask).zero?

          position += 1
        end
        false
      end

      def search_first_byte_events(input, position)
        first_byte = static_first_byte
        candidate = input.index(first_byte, position)
        while candidate
          active = transition(0, input.getbyte(candidate), true)
          return true unless (active & @accept_mask).zero?

          cursor = candidate + 1
          while cursor < input.bytesize
            active = transition(active, input.getbyte(cursor), false)
            return true unless (active & @accept_mask).zero?
            break if active.zero?

            cursor += 1
          end
          candidate = input.index(first_byte, candidate + 1)
        end
        false
      end

      def search_required_literal_events(input, position)
        candidate = required_literal_candidate(input, position)
        while candidate
          active = transition(0, input.getbyte(candidate), true)
          return true unless (active & @accept_mask).zero?

          cursor = candidate + 1
          while cursor < input.bytesize
            active = transition(active, input.getbyte(cursor), false)
            return true unless (active & @accept_mask).zero?
            break if active.zero?

            cursor += 1
          end
          candidate = required_literal_candidate(input, candidate + 1)
        end
        false
      end

      def search_first_byte_set_events(input, position)
        first_bytes = static_first_bytes
        candidate = first_byte_set_candidate(input, position, first_bytes)
        while candidate
          active = transition(0, input.getbyte(candidate), true)
          return true unless (active & @accept_mask).zero?

          cursor = candidate + 1
          while cursor < input.bytesize
            active = transition(active, input.getbyte(cursor), false)
            return true unless (active & @accept_mask).zero?
            break if active.zero?

            cursor += 1
          end
          candidate = first_byte_set_candidate(input, candidate + 1, first_bytes)
        end
        false
      end

      def first_byte_set_candidate(input, position, first_bytes)
        best = nil
        first_bytes.each_byte do |byte|
          candidate = input.index(byte.chr(Encoding::ASCII_8BIT), position)
          best = candidate if candidate && (best.nil? || candidate < best)
        end
        best
      end
    end
  end
end
