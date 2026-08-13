# frozen_string_literal: true

module Onibi
  # Experimental single-engine hybrid automaton for captureless ASCII regexps.
  # String matching emits candidate events, a bit-parallel position NFA computes
  # cold transitions, and the resulting subset states populate a bounded DFA.
  module HybridAutomata
    class UnsupportedPattern < RegexpError; end
    class UnsupportedInput < Error; end

    Fragment = Data.define(:nullable, :first, :last)
    Automaton = Data.define(:first_mask, :accept_mask, :nullable, :reach_masks,
                            :span_masks, :prefix_literal, :exact_literal)
    BytecodeInstruction = Data.define(:opcode, :operand)
    MAX_STATES = 512
    MAX_BOUNDED_REPEAT = 64

    module_function

    def compile(pattern, dfa: true, string_matching: true, dfa_state_limit: 4096)
      raise TypeError, "pattern must be a String" unless pattern.is_a?(String)
      raise UnsupportedPattern, "the PoC accepts ASCII patterns only" unless pattern.ascii_only?

      ast = Parser.new(pattern).parse
      unit = Codegen::Optimization.compile_prepared(ast, [], Encoding::US_ASCII)
      compile_unit(unit, dfa: dfa, string_matching: string_matching, dfa_state_limit: dfa_state_limit)
    end

    def compile_unit(unit, dfa: true, string_matching: true, dfa_state_limit: 4096)
      unless unit.is_a?(Codegen::Optimization::CompilationUnit)
        raise TypeError, "expected an optimization compilation unit"
      end

      Compiler.new(dfa: dfa, string_matching: string_matching,
                   dfa_state_limit: dfa_state_limit).compile(unit)
    end

    def validate_cfg!(cfg)
      supported = %i[match_literal match_class match_escape match_property match_any epsilon
                     match_group match_quantifier]
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
        Array.new(256) do |byte|
          @state_tables.each_with_index.reduce(0) do |mask, (table, index)|
            table[byte] ? mask | (1 << index) : mask
          end
        end.freeze
      end

      def build_span_masks
        spans = Hash.new(0)
        @follow.each_with_index do |targets, source|
          each_bit(targets) { |target| spans[target - source] |= 1 << source }
        end
        spans.freeze
      end
    end

    # Derives literals used by the HFA candidate-event policy.
    module PatternFacts
      module_function

      def selective_prefix(node)
        prefix = leading_literal(node)
        prefix if prefix && prefix.bytesize >= 2
      end

      def leading_literal(node)
        return node.value if node.is_a?(AST::Literal)
        return unless node.is_a?(AST::Sequence)

        value = +""
        node.parts.each do |part|
          break unless part.is_a?(AST::Literal)

          value << part.value
        end
        value.empty? ? nil : value.freeze
      end

      def literal_value(node)
        return node.value if node.is_a?(AST::Literal)
        return unless node.is_a?(AST::Sequence) && node.parts.all? { |part| part.is_a?(AST::Literal) }

        node.parts.map(&:value).join.freeze
      end
    end

    # Immutable NFA topology builder. Quantifiers are expanded into position
    # states so the runtime can represent every active state in one Integer.
    class Compiler
      include GraphBuilder
      include PatternFacts

      NODE_VISITORS = {
        AST::Literal => :literal_node, AST::CharacterClass => :character_class_node,
        AST::Escape => :escape_node, AST::Any => :any_node,
        AST::Sequence => :sequence_node, AST::Alternation => :alternation_node,
        AST::Group => :group_node, AST::Quantifier => :quantifier_node
      }.freeze

      def initialize(dfa:, string_matching:, dfa_state_limit:)
        @dfa = dfa
        @string_matching = string_matching
        @dfa_state_limit = dfa_state_limit
        @state_tables = []
        @follow = []
      end

      def compile(unit)
        ast = unit.ast
        HybridAutomata.validate_cfg!(unit.cfg)
        prefix = @string_matching ? selective_prefix(ast) : nil
        exact_literal = literal_value(ast)
        fragment = visit(ast)
        reach_masks = build_reach_masks

        automaton = Automaton.new(fragment.first, fragment.last, fragment.nullable,
                                  reach_masks, build_span_masks, prefix, exact_literal)
        Program.new(automaton, dfa: @dfa, dfa_state_limit: @dfa_state_limit, input_ir: :cfg)
      end

      private

      def visit(node)
        visitor = NODE_VISITORS[node.class]
        return send(visitor, node) if visitor

        name = node.class.name.split("::").last
        raise UnsupportedPattern, "#{name} is outside the hybrid PoC subset"
      end

      def literal_node(node)
        node.value.bytes.reduce(empty_fragment) do |fragment, byte|
          concatenate(fragment, consuming_state { |candidate| candidate == byte })
        end
      end

      def character_class_node(node)
        predicate = ClassPredicates.compiled(node.value).ascii_table
        consuming_state { |byte| predicate[byte] }
      end

      def escape_node(node)
        consuming_state do |byte|
          CharacterPredicates.escape_matches?(node.kind, byte.chr(Encoding::ASCII_8BIT))
        rescue KeyError
          raise UnsupportedPattern, "escape #{node.kind.inspect} is outside the hybrid PoC subset"
        end
      end

      def any_node(_node)
        consuming_state { |byte| byte != 10 }
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
        raise UnsupportedPattern, "captures are outside the hybrid PoC subset" if node.capture

        visit(node.body)
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
        unless %i[greedy lazy].include?(node.mode)
          raise UnsupportedPattern, "possessive quantifiers are outside the hybrid PoC subset"
        end
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
        candidate = input.index(prefix, position)
        while candidate
          return true unless (active & @accept_mask).zero?

          return true if search_prefix_candidate(input, candidate + prefix_length, active)

          candidate = input.index(prefix, candidate + 1)
        end
        false
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

    # Builds a compact deterministic table for small single-span automata.
    module StaticDfaRuntime
      private

      def static_search(input, position)
        return unless @single_span && @dfa_enabled

        static = static_dfa_data
        static && static_match?(input, position, static)
      end

      def static_match?(input, position, static)
        rows, accepting = static
        limit = input.bytesize
        first_byte = static_first_byte
        if first_byte
          candidate = static_jump_candidate(input, position, first_byte)
          return false unless candidate

          return static_match_with_jumps(input, candidate, static, first_byte) if candidate != :dense
        end

        static_match_scan(input, position, limit, rows, accepting)
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

      def build_static_dfa
        masks = [0]
        ids = { 0 => 0 }
        rows = []
        masks.each_with_index do |mask, state|
          rows[state] = static_row(mask, ids, masks)
          return nil unless rows[state]
        end
        accepting = masks.map { |mask| (mask & @accept_mask) != 0 }.freeze
        [rows.freeze, accepting].freeze
      end

      def static_row(mask, ids, masks)
        row = Array.new(256)
        256.times do |byte|
          result = nfa_transition(mask, byte, true)
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

    # Executes one fused HFA with NFA and optional lazy-DFA state.
    class Program
      include SingleSpanRuntime
      include PrefixRuntime
      include StaticDfaRuntime
      attr_reader :prefix_literal, :input_ir

      def initialize(automaton, dfa:, dfa_state_limit:, input_ir: :cfg)
        @first_mask = automaton.first_mask
        @accept_mask = automaton.accept_mask
        @nullable = automaton.nullable
        @reach_masks = automaton.reach_masks
        @span_masks, @span_entries, @single_span = span_data(automaton.span_masks)
        @prefix_literal = automaton.prefix_literal
        @exact_literal = automaton.exact_literal
        initialize_runtime_options(dfa, dfa_state_limit, input_ir)
      end

      def engine_kind = :hybrid

      def components
        components = [:bit_parallel_nfa]
        components.unshift(:lazy_dfa) if @dfa_enabled
        components.unshift(:string_matching) if @prefix_literal
        components.freeze
      end

      def bytecode
        instructions = []
        instructions << BytecodeInstruction.new(:string_search, @prefix_literal) if @prefix_literal
        instructions << BytecodeInstruction.new(:dfa_lookup, @dfa_state_limit) if @dfa_enabled
        instructions << BytecodeInstruction.new(:nfa_transition, @span_masks)
        instructions << BytecodeInstruction.new(:accept, @accept_mask)
        instructions.freeze
      end

      def dfa_state_count = @dfa_rows.length

      def ruby_program = RubyProgram.from_program(self)

      def match?(input, position = 0)
        raise TypeError, "input must be a String" unless input.is_a?(String)
        raise UnsupportedInput, "the PoC accepts ASCII inputs only" unless input.ascii_only?

        fast = fast_literal_match(input, position)
        return fast unless fast.nil?

        position = normalize_position(input, position)
        match_from_position(input, position)
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
        @input_ir = input_ir
      end

      def match_from_position(input, position)
        return false if position.negative? || position > input.bytesize
        return true if @nullable
        return !input.index(@exact_literal, position).nil? if @exact_literal && @prefix_literal

        static = static_search(input, position)
        return static unless static.nil?

        @prefix_literal ? search_prefix_events(input, position) : search_unanchored(input, position)
      end

      def fast_literal_match(input, position)
        return unless position.zero? && @exact_literal && @prefix_literal

        input.include?(@exact_literal)
      end

      def normalize_position(input, position)
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

        active = 0
        while position < input.bytesize
          active = transition(active, input.getbyte(position), true)
          return true unless (active & @accept_mask).zero?

          position += 1
        end
        false
      end

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

        @span_entries.each do |span, sources|
          selected = active & sources
          candidates |= span.negative? ? selected >> -span : selected << span
        end
        candidates & @reach_masks[byte]
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

    # Direct Ruby lowering of the same hybrid state machine. This is deliberately
    # separate from the regular-expression Ruby emitter: it embeds HFA tables and
    # emits the string-search, NFA, DFA, and acceptance operations directly.
    class RubyProgram
      attr_reader :source

      def self.from_program(program)
        new(program)
      end

      def initialize(program)
        @program = program
        @source = SourceEmitter.emit(program).freeze
        @compiled_module = Codegen::SourceCompiler.new.compile(@source, filename: "(onibi-hfa-generated)")
        freeze
      end

      def engine_kind
        :hybrid_ruby
      end

      def components
        @program.components
      end

      def match?(input, position = 0)
        raise TypeError, "input must be a String" unless input.is_a?(String)
        raise UnsupportedInput, "the PoC accepts ASCII inputs only" unless input.ascii_only?

        position = position.to_int if position.respond_to?(:to_int)
        raise TypeError, "position must be an Integer" unless position.is_a?(Integer)

        @compiled_module.__onibi_search(input, position)
      end
    end

    # Emits the HFA state machine as standalone Ruby source.
    module SourceEmitter
      module_function

      SINGLE_SPAN_TEMPLATE = <<~'RUBY'
        def self.__onibi_search(input, position = 0)
          return false unless input.is_a?(String) && input.ascii_only?
          position = position.to_int if position.respond_to?(:to_int)
          return false unless position.is_a?(Integer)
          position += input.bytesize if position.negative?
          return false if position.negative? || position > input.bytesize
          return true if %<nullable>s
          return !input.index(%<exact>s, position).nil? if %<exact>s && %<prefix>s

          candidate = %<prefix>s ? input.index(%<prefix>s, position) : position
            while candidate && candidate <= input.bytesize
            active = 0
            cursor = candidate
            while cursor < input.bytesize
              candidates = (%<prefix>s ? cursor == candidate : true) ? %<first>s : 0
              selected = active & %<sources>s
              candidates |= %<negative>s ? selected >> %<shift>s : selected << %<span>s
              active = candidates & %<reach>s[input.getbyte(cursor)]
              return true unless (active & %<accept>s) == 0
              cursor += 1
            end
            break unless %<prefix>s
            candidate = input.index(%<prefix>s, candidate + 1)
          end
          false
        end
      RUBY

      STATIC_DFA_TEMPLATE = <<~'RUBY'
        STATIC_ROWS = %<rows>s
        STATIC_ACCEPTING = %<accepting>s

        def self.__onibi_static_scan(input, position)
          rows = STATIC_ROWS
          accepting = STATIC_ACCEPTING
          limit = input.bytesize
          state = 0
          while position < limit
            state = rows[state][input.getbyte(position)]
            return true if accepting[state]
            position += 1
          end
          false
        end

        def self.__onibi_static_jump(input, position, first_byte)
          rows = STATIC_ROWS
          accepting = STATIC_ACCEPTING
          limit = input.bytesize
          state = 0
          while position < limit
            state = rows[state][input.getbyte(position)]
            return true if accepting[state]
            position += 1
            next unless state.zero?

            candidate = input.index(first_byte, position)
            return false unless candidate
            next_candidate = input.index(first_byte, candidate + 1)
            return __onibi_static_scan(input, candidate) if next_candidate && next_candidate - candidate < 16
            position = candidate
          end
          false
        end

        def self.__onibi_search(input, position = 0)
          return false unless input.is_a?(String) && input.ascii_only?
          position = position.to_int if position.respond_to?(:to_int)
          return false unless position.is_a?(Integer)
          position += input.bytesize if position.negative?
          return false if position.negative? || position > input.bytesize
          return true if %<nullable>s

          first_byte = %<first_byte>s
          if first_byte
            candidate = input.index(first_byte, position)
            if candidate
              next_candidate = input.index(first_byte, candidate + 1)
              return __onibi_static_jump(input, candidate, first_byte) if next_candidate.nil? ||
                                                                          next_candidate - candidate >= 16
            end
          end
          __onibi_static_scan(input, position)
        end
      RUBY

      SEARCH_TEMPLATE = <<~'RUBY'
        def self.__onibi_search(input, position = 0)
          return false unless input.is_a?(String) && input.ascii_only?
          position = position.to_int if position.respond_to?(:to_int)
          return false unless position.is_a?(Integer)
          position += input.bytesize if position.negative?
          return false if position.negative? || position > input.bytesize
          return true if %<nullable>s
          return !input.index(%<exact>s, position).nil? if %<exact>s && %<prefix>s

          candidate = %<prefix>s ? input.index(%<prefix>s, position) : position
            while candidate && candidate <= input.bytesize
            active = %<prefix_active>s
            return true unless (active & %<accept>s) == 0
            inject_start = false
            cursor = candidate + %<prefix_length>s
            while cursor < input.bytesize
              active = __hfa_transition(active, input.getbyte(cursor), inject_start)
              return true unless (active & %<accept>s) == 0
              break if active == 0
              inject_start = false
              cursor += 1
            end
            break unless %<prefix>s
            candidate = input.index(%<prefix>s, candidate + 1)
          end
          false
        end
      RUBY

      UNANCHORED_TEMPLATE = <<~'RUBY'
        def self.__onibi_search(input, position = 0)
          return false unless input.is_a?(String) && input.ascii_only?
          position = position.to_int if position.respond_to?(:to_int)
          return false unless position.is_a?(Integer)
          position += input.bytesize if position.negative?
          return false if position.negative? || position > input.bytesize
          return true if %<nullable>s
          return !input.index(%<exact>s, position).nil? if %<exact>s

          active = 0
          while position < input.bytesize
            active = __hfa_transition(active, input.getbyte(position), true)
            return true unless (active & %<accept>s) == 0
            position += 1
          end
          false
        end
      RUBY

      TRANSITION_TEMPLATE = <<~'RUBY'
        def self.__hfa_transition(active, byte, inject_start)
          rows = %<rows>s
          key = (active << 1) | (inject_start ? 1 : 0)
          if rows
            row = rows[key]
            cached = row && row[byte]
            return cached unless cached.nil?
          end
          candidates = inject_start ? %<first>s : 0
          %<spans>s.each do |span, sources|
            selected = active & sources
            candidates |= span.negative? ? selected >> -span : selected << span
          end
          result = candidates & %<reach>s[byte]
          if rows
            if row
              row[byte] = result
            elsif rows.length < %<limit>s
              rows[key] = Array.new(256).tap { |new_row| new_row[byte] = result }
            end
          end
          result
        end
      RUBY

      def emit(program)
        raw = raw_program_data(program)
        data = program_data(program)
        static_source = static_source(program, raw, data)
        return static_source if static_source

        return format(UNANCHORED_TEMPLATE, data).concat(format(TRANSITION_TEMPLATE, data)) unless raw[:prefix]
        return format(SINGLE_SPAN_TEMPLATE, data.merge(single_span_values(raw))) if raw[:single_span]

        format(SEARCH_TEMPLATE, data).concat(format(TRANSITION_TEMPLATE, data))
      end

      def static_source(program, raw, data)
        return unless raw[:single_span] && raw[:dfa] && !raw[:exact]

        static = program.send(:static_dfa_data)
        return unless static

        rows, accepting = static
        first_byte = program.send(:static_first_byte)
        format(STATIC_DFA_TEMPLATE,
               data.merge(rows: rows.inspect, accepting: accepting.inspect, first_byte: first_byte.inspect))
      end

      def single_span_values(data)
        span, sources = data.fetch(:single_span)
        {
          span: span.inspect,
          sources: sources.inspect,
          negative: span.negative?.inspect,
          shift: (-span).inspect
        }
      end

      def program_data(program)
        data = raw_program_data(program)
        data.transform_values(&:inspect).merge(rows: data.fetch(:rows), limit: data.fetch(:limit).inspect,
                                               single_span: data.fetch(:single_span))
      end

      def raw_program_data(program)
        {
          first: program.instance_variable_get(:@first_mask),
          accept: program.instance_variable_get(:@accept_mask),
          nullable: program.instance_variable_get(:@nullable),
          reach: program.instance_variable_get(:@reach_masks),
          spans: program.instance_variable_get(:@span_masks),
          prefix: program.instance_variable_get(:@prefix_literal),
          prefix_active: program.instance_variable_get(:@prefix_literal) && program.send(:prefix_active),
          prefix_length: program.instance_variable_get(:@prefix_literal)&.bytesize,
          exact: program.instance_variable_get(:@exact_literal),
          rows: program.instance_variable_get(:@dfa_enabled) ? "(@__hfa_rows ||= {})" : "nil",
          limit: program.instance_variable_get(:@dfa_state_limit),
          single_span: program.instance_variable_get(:@single_span),
          dfa: program.instance_variable_get(:@dfa_enabled)
        }
      end
    end
  end
end
