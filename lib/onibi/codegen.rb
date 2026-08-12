# frozen_string_literal: true

module Onibi
  # Raised when generated Ruby cannot be compiled or violates the codegen boundary.
  class CodegenError < StandardError
  end

  module Codegen
    # Computes Ruby-compatible simple and full-fold literal candidates.
    module Casefold
      module_function

      def literal_candidates(input, position, value)
        maximum = [value.length * 2, value.length].max
        (value.length..maximum).filter_map do |length|
          candidate = input[position, length]
          next unless candidate
          next unless candidate.downcase == value.downcase || candidate.upcase == value.upcase

          position + length
        end
      end

      def class_candidates(input, position, source, ignorecase)
        predicate = compiled_predicate(source, ignorecase)
        return byte_class_candidate(input, position, predicate) if !ignorecase && byte_input?(input)

        character_class_candidate(input, position, predicate, ignorecase)
      end

      def compiled_predicate(source, ignorecase)
        return source if source.is_a?(ClassPredicates::Compiled)

        ClassPredicates.compiled(source, ignorecase: ignorecase)
      end

      def byte_class_candidate(input, position, predicate)
        byte = input.getbyte(position)
        return position + 1 if byte && predicate.matches_byte?(byte)

        nil
      end

      def character_class_candidate(input, position, predicate, ignorecase)
        character = input[position]
        return position + 1 if character && predicate.matches?(character)

        if ignorecase && predicate.source.include?("ß")
          folded = input[position, 2]
          return position + 2 if folded && folded.upcase == "SS"
        end
        nil
      end

      def byte_input?(input)
        input.is_a?(String) && (input.ascii_only? || input.encoding == Encoding::ASCII_8BIT)
      end
    end

    Width = Struct.new(:minimum, :maximum, :finite, :nullable, keyword_init: true) do
      def initialize(**kwargs)
        super
        freeze
      end
    end

    LiteralAtom = Struct.new(:value, :ascii, :fixed_width, :casefold, keyword_init: true) do
      def ascii? = ascii
      def fixed_width? = fixed_width
      def casefold? = casefold
    end

    LiteralRun = Struct.new(:value, :node, keyword_init: true)
    RequiredLiteral = Struct.new(:value, :node, keyword_init: true)
    PrefixLiteral = Struct.new(:value, :node, keyword_init: true)
    SuffixLiteral = Struct.new(:value, :node, keyword_init: true)
    FirstSet = Struct.new(:characters, :node, keyword_init: true) do
      def values = characters
    end
    AnchorFacts = Struct.new(:kind, :node, keyword_init: true)
    ComponentPlan = Struct.new(:kind, :region, :matcher, :activation, :preserves_order, keyword_init: true)
    ANALYZER_NODE_TYPES = [
      AST::Literal, AST::CharacterClass, AST::Escape, AST::Property, AST::Backreference,
      AST::Assertion, AST::Any, AST::Anchor, AST::Sequence, AST::Alternation, AST::Group,
      AST::OptionGroup, AST::AtomicGroup, AST::Conditional, AST::SubexpressionCall,
      AST::Absence, AST::Quantifier
    ].freeze

    Analysis = Struct.new(
      :captures, :named_captures, :subexpression_calls, :widths, :labels, :options, :encoding,
      :literal_atoms, :literal_runs, :required_literals, :prefix_literals, :suffix_literals,
      :first_sets, :anchor_facts, :component_plans,
      keyword_init: true
    )

    # Recursively freezes compiler metadata before publication.
    module DeepFreezer
      private

      def deep_freeze(value)
        case value
        when Struct then value.each { |item| deep_freeze(item) }
        when Hash
          value.each do |key, item|
            deep_freeze(key)
            deep_freeze(item)
          end
        when Array then value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end

    # Extracts conservative literal components without changing execution.
    module ComponentExtraction
      private

      def initialize_component_metadata
        @literal_atoms = []
        @literal_runs = []
        @required_literals = []
        @prefix_literals = []
        @suffix_literals = []
        @first_sets = []
        @anchor_facts = []
        @component_plans = []
      end

      def component_metadata
        {
          literal_atoms: @literal_atoms, literal_runs: @literal_runs,
          required_literals: @required_literals, prefix_literals: @prefix_literals,
          suffix_literals: @suffix_literals, first_sets: @first_sets,
          anchor_facts: @anchor_facts, component_plans: @component_plans
        }
      end

      def extract_components(node)
        case node
        when AST::Alternation
          node.branches.each { |branch| extract_branch_literals(branch, :literal_alternation) }
        when AST::Sequence
          extract_sequence_components(node)
        else
          node_children(node).each { |child| extract_components(child) }
        end
      end

      def extract_branch_literals(branch, kind)
        value = literal_sequence_value(branch)
        return unless value

        record_atom_metadata(value)
        run = record_literal_run(value, branch)
        return unless component_eligible?(value)

        record_prefix(run)
        record_suffix(run)
        record_first_set(value, branch)
        @component_plans << ComponentPlan.new(
          kind: kind, region: branch, matcher: :literal, activation: :candidate_start,
          preserves_order: true
        )
      end

      def extract_sequence_components(node)
        literal_parts = []
        literal_start = nil
        node.parts.each_with_index do |part, index|
          literal_start, literal_parts = process_sequence_part(
            node, part, index, literal_parts, literal_start
          )
        end
        record_sequence_run(literal_parts, node, literal_start, node.parts.length) unless literal_parts.empty?
        record_sequence_requirements(node)
      end

      def process_sequence_part(node, part, index, literal_parts, literal_start)
        return [literal_start || index, literal_parts + [part]] if part.is_a?(AST::Literal)

        record_sequence_run(literal_parts, node, literal_start, index) unless literal_parts.empty?
        record_anchor(part) if part.is_a?(AST::Anchor)
        extract_components(part)
        [nil, []]
      end

      def record_anchor(node)
        @anchor_facts << AnchorFacts.new(kind: node.kind, node: node)
      end

      def record_sequence_run(parts, sequence, start_index, end_index)
        value = parts.map(&:value).join
        run = record_literal_run(value, parts.first)
        record_atom_metadata(value)
        return unless component_eligible?(value)

        at_start, at_end = sequence_run_boundaries(sequence, start_index, end_index)
        record_prefix(run) if at_start
        record_suffix(run) if at_end
        record_first_set(value, parts.first) if at_start
        @component_plans << ComponentPlan.new(
          kind: sequence_component_kind(at_start, at_end), region: sequence, matcher: :literal,
          activation: at_start ? :candidate_start : :component_progress, preserves_order: true
        )
      end

      def sequence_run_boundaries(sequence, start_index, end_index)
        [
          sequence.parts.take(start_index).none? { |part| part.is_a?(AST::Literal) },
          sequence.parts.drop(end_index).none? { |part| part.is_a?(AST::Literal) }
        ]
      end

      def sequence_component_kind(at_start, at_end)
        return :anchored_literal if at_start && at_end
        return :prefix_literal if at_start
        return :suffix_literal if at_end

        :literal_run
      end

      def record_sequence_requirements(sequence)
        literal_parts = []
        sequence.parts.each do |part|
          if part.is_a?(AST::Literal)
            literal_parts << part
            next
          end

          record_required_literal(literal_parts) unless literal_parts.empty?
          literal_parts = []
        end
        record_required_literal(literal_parts) unless literal_parts.empty?
      end

      def record_required_literal(parts)
        value = parts.map(&:value).join
        return unless component_eligible?(value)

        @required_literals << RequiredLiteral.new(value: value, node: parts.first)
      end

      def record_literal_run(value, node)
        run = LiteralRun.new(value: value, node: node)
        @literal_runs << run
        run
      end

      def record_atom_metadata(value)
        value.each_char do |character|
          @literal_atoms << LiteralAtom.new(
            value: character,
            ascii: character.ascii_only?,
            fixed_width: true,
            casefold: @options.include?("ignorecase")
          )
        end
      end

      def record_prefix(run)
        @prefix_literals << PrefixLiteral.new(value: run.value, node: run.node)
      end

      def record_suffix(run)
        @suffix_literals << SuffixLiteral.new(value: run.value, node: run.node)
      end

      def record_first_set(value, node)
        @first_sets << FirstSet.new(characters: [value[0]], node: node)
      end

      def component_eligible?(value)
        !@options.include?("ignorecase") && value.ascii_only?
      end

      def literal_sequence_value(node)
        return node.value if node.is_a?(AST::Literal)
        return unless node.is_a?(AST::Sequence)
        return unless node.parts.all? { |part| part.is_a?(AST::Literal) }

        node.parts.map(&:value).join
      end

      def node_children(node)
        return [] unless node.is_a?(Struct)

        node.each_with_object([]) do |child, children|
          children << child if child.is_a?(Struct)
          children.concat(child.select { |item| item.is_a?(Struct) }) if child.is_a?(Array)
        end
      end
    end

    # Computes immutable facts consumed by source emitters.
    class Analyzer
      include DeepFreezer
      include ComponentExtraction

      def initialize(options = [], encoding = Encoding::UTF_8)
        @options = options.dup.freeze
        @encoding = encoding
        @captures = []
        @named_captures = {}
        @calls = []
        @widths = {}.compare_by_identity
        @labels = {}.compare_by_identity
        @next_label = 0
        initialize_component_metadata
      end

      def analyze(ast)
        visit(ast)
        extract_components(ast)
        result = Analysis.new(
          captures: @captures,
          named_captures: @named_captures,
          subexpression_calls: @calls,
          widths: @widths,
          labels: @labels,
          options: @options,
          encoding: @encoding,
          **component_metadata
        )
        deep_freeze(result)
      end

      private

      def visit(node)
        handler = "visit_#{node_type_name(node).downcase}"
        raise CodegenError, "unsupported AST node #{node.class}" unless ANALYZER_NODE_TYPES.include?(node.class)

        assign_label(node)
        width = send(handler, node)
        @widths[node] = width
        width
      end

      def node_type_name(node)
        node.class.name.to_s.split("::").last.to_s
      end

      def assign_label(node)
        @labels[node] = @next_label
        @next_label += 1
      end

      def visit_literal(node)
        scalar_width(node.value.length)
      end

      def visit_characterclass(_node) = scalar_width(1)

      def visit_escape(node)
        return zero_width if %i[word_boundary not_word_boundary start_match match_reset].include?(node.kind)

        scalar_width(1)
      end

      def visit_property(_node) = scalar_width(1)
      def visit_backreference(_node) = variable_width
      def visit_any(_node) = scalar_width(1)
      def visit_anchor(_node) = zero_width

      def visit_subexpressioncall(node)
        @calls << node
        variable_width
      end

      def visit_assertion(node)
        visit(node.body)
        zero_width
      end

      def visit_group(node)
        @captures << node.number if node.capture
        @named_captures[node.name] = node.number if node.name
        visit(node.body)
      end

      def visit_atomicgroup(node) = visit(node.body)
      def visit_absence(node) = visit(node.body) && zero_width

      def visit_optiongroup(node)
        visit(node.body)
      end

      def visit_conditional(node)
        yes = visit(node.yes_branch)
        no = visit(node.no_branch)
        merge(yes, no)
      end

      def visit_sequence(node)
        widths = node.parts.map { |part| visit(part) }
        sequence_width(widths)
      end

      def sequence_width(widths)
        finite = finite_sequence_width(widths)
        maximum = unbounded_width?(widths) ? nil : widths.sum(&:maximum)
        Width.new(minimum: widths.sum(&:minimum), maximum: maximum, finite: finite, nullable: widths.all?(&:nullable))
      end

      def finite_sequence_width(widths)
        return nil unless widths.all?(&:finite)

        widths.flat_map { |width| width.finite || [width.minimum] }.uniq
      end

      def unbounded_width?(widths)
        widths.any? { |width| width.maximum.nil? }
      end

      def visit_alternation(node)
        widths = node.branches.map { |branch| visit(branch) }
        merge(*widths)
      end

      def visit_quantifier(node)
        body = visit(node.expression)
        minimum = body.minimum * node.minimum
        maximum = node.maximum.nil? || body.maximum.nil? ? nil : body.maximum * node.maximum
        Width.new(minimum: minimum, maximum: maximum, finite: nil, nullable: node.minimum.zero? || body.nullable)
      end

      def scalar_width(value)
        Width.new(minimum: value, maximum: value, finite: [value], nullable: value.zero?)
      end

      def zero_width
        scalar_width(0)
      end

      def variable_width
        Width.new(minimum: 0, maximum: nil, finite: nil, nullable: true)
      end

      def merge(*widths)
        Width.new(
          minimum: widths.map(&:minimum).min,
          maximum: widths.any? { |width| width.maximum.nil? } ? nil : widths.map(&:maximum).max,
          finite: widths.all?(&:finite) ? widths.flat_map(&:finite).uniq.sort : nil,
          nullable: widths.any?(&:nullable)
        )
      end
    end

    # Compiles generated Ruby source without depending on CRuby instruction sequences.
    class SourceCompiler
      ENTRYPOINT = :__onibi_search

      def self.available?
        module_object = Module.new
        module_object.module_eval("def self.__onibi_probe; true; end", __FILE__, __LINE__)
        module_object.__send__(:__onibi_probe) == true
      rescue StandardError, SyntaxError
        false
      end

      def self.production_requires_rubyvm?
        false
      end

      def compile(source, filename: "(onibi-generated)")
        raise TypeError, "generated source must be a String" unless source.is_a?(String)

        Security.validate_source!(source)

        module_object = Module.new
        module_object.module_eval(source, filename, 1)
        return module_object if module_object.respond_to?(SourceCompiler::ENTRYPOINT)

        raise CodegenError, "generated source does not define #{SourceCompiler::ENTRYPOINT}"
      rescue CodegenError
        raise
      rescue StandardError, SyntaxError => e
        raise CodegenError, "generated Ruby compilation failed: #{e.class}: #{e.message}"
      end
    end

    # Emits the smallest typed source fragment used to validate the codegen boundary.
    class RubyEmitter
      def self.literal(value)
        raise TypeError, "literal value must be a String" unless value.is_a?(String)

        escaped_value = value.dump
        length = value.length
        <<~RUBY
          def self.__onibi_search(input, position, capture, search_origin = position)
            return false unless input.is_a?(String)
            return false unless input[position, #{length}] == #{escaped_value}

            capture ? [position, position + #{length}, []] : true
          end
        RUBY
      end
    end

    # Coordinates typed emitters; later AST emitters will be added here.
    class RubyGenerator
      def self.literal(value)
        RubyEmitter.literal(value)
      end

      def self.ast(ast, options: [])
        AstEmitter.new(options).emit(ast)
      end
    end

    # Deduplicates repeated case-sensitive literal values in generated source.
    class LiteralRegistry
      attr_reader :entries

      def initialize
        @counts = Hash.new(0)
        @entries = []
        @indices = {}
      end

      def count(value)
        @counts[value] += 1
      end

      def register(value)
        return unless @counts[value] > 1 && value.bytesize >= 16
        return @indices[value] if @indices.key?(value)

        index = @entries.length
        normalized = value.dup.freeze
        @indices[normalized] = index
        @entries << normalized
        index
      end
    end

    # Emits capture group begin/end operations.
    module GroupEmitter
      private

      def emit_group(node, cursor)
        return emit_node(node.body, cursor) unless node.capture

        tracked_group(node, cursor)
      end

      def tracked_group(node, cursor)
        result = fresh_cursor
        previous_capture = fresh_cursor
        <<~EXPRESSION.strip
          (begin #{previous_capture} = captures && captures[#{node.number - 1}]; captures && (captures[#{node.number - 1}] = [#{cursor}, nil]); #{result} = #{emit_node(node.body, cursor)}; #{result}.nil? ? (captures && (captures[#{node.number - 1}] = #{previous_capture}); nil) : (captures && (captures[#{node.number - 1}][1] = #{result}); #{result}); end)
        EXPRESSION
      end
    end

    # Emits lookahead and fixed-width lookbehind assertions.
    module AssertionEmitter
      private

      def emit_assertion(node, cursor)
        if %i[positive negative].include?(node.kind)
          body = emit_node(node.body, cursor)
          matched = node.kind == :positive ? "!#{body}.nil?" : "#{body}.nil?"
          return "(#{matched} ? #{cursor} : nil)"
        end

        width = fixed_width(node.body)
        start = "#{cursor} - #{width}"
        body = emit_node(node.body, start)
        matched = "#{start} >= 0 && #{body} == #{cursor}"
        matched = "!(#{matched})" if node.kind == :negative_lookbehind
        "(#{matched} ? #{cursor} : nil)"
      end

      def fixed_width(node)
        case node
        when AST::Literal then node.value.length
        when AST::Sequence then node.parts.sum { |part| fixed_width(part) }
        else raise CodegenError, "lookbehind requires fixed-width generated body"
        end
      end
    end

    # Emits counter-driven quantifier loops.
    module QuantifierEmitter
      private

      def emit_quantifier_with_remainder(node, remainder, cursor)
        return emit_capture_free_quantifier_with_remainder(node, remainder, cursor) if
          capture_count.zero? || !capture_writes?(node.expression) && remainder.none? { |part| capture_writes?(part) }

        emit_captureful_quantifier_with_remainder(node, remainder, cursor)
      end

      def capture_writes?(node)
        return true if node.is_a?(AST::SubexpressionCall)
        return node.capture || capture_writes?(node.body) if node.is_a?(AST::Group)
        return node.any? { |child| capture_writes?(child) } if node.is_a?(Array)
        return node.any? { |child| capture_writes?(child) } if node.is_a?(Struct)

        false
      end

      def emit_captureful_quantifier_with_remainder(node, remainder, cursor)
        variables = Array.new(7) { fresh_cursor }
        counter, result, previous, candidates, candidate, final, original = variables
        body = emit_node(node.expression, result)
        suffix = emit_sequence_parts(remainder, "#{candidate}[0]")
        candidate_order = node.mode == :lazy ? candidates : "#{candidates}.reverse_each"
        snapshot = "captures ? captures.map { |item| item&.dup } : nil"
        restore = "captures&.replace"
        <<~EXPRESSION.strip
          (begin #{original} = #{snapshot}; #{result} = #{cursor}; #{counter} = 0; #{candidates} = []; #{candidates} << [#{result}, #{snapshot}] if #{counter} >= #{node.minimum}; while #{counter} < #{quantifier_maximum(node)}; #{previous} = #{result}; #{result} = #{body}; break if #{result}.nil?; #{counter} += 1; #{candidates} << [#{result}, #{snapshot}] if #{counter} >= #{node.minimum}; break if #{result} == #{previous}; end; #{final} = nil; #{candidate_order}.each do |#{candidate}| #{restore}(#{candidate}[1]); #{final} = #{suffix}; break unless #{final}.nil?; end; #{restore}(#{original}) if #{final}.nil?; #{final}; end)
        EXPRESSION
      end

      def emit_capture_free_quantifier_with_remainder(node, remainder, cursor)
        variables = Array.new(6) { fresh_cursor }
        counter, result, previous, candidates, candidate, final = variables
        body = emit_node(node.expression, result)
        suffix = emit_sequence_parts(remainder, candidate)
        candidate_order = node.mode == :lazy ? candidates : "#{candidates}.reverse_each"
        <<~EXPRESSION.strip
          (begin #{result} = #{cursor}; #{counter} = 0; #{candidates} = []; #{candidates} << #{result} if #{counter} >= #{node.minimum}; while #{counter} < #{quantifier_maximum(node)}; #{previous} = #{result}; #{result} = #{body}; break if #{result}.nil?; #{counter} += 1; #{candidates} << #{result} if #{counter} >= #{node.minimum}; break if #{result} == #{previous}; end; #{final} = nil; #{candidate_order}.each do |#{candidate}| #{final} = #{suffix}; break unless #{final}.nil?; end; #{final}; end)
        EXPRESSION
      end

      def emit_quantifier(node, cursor)
        counter = fresh_cursor
        result = fresh_cursor
        previous = fresh_cursor
        maximum = quantifier_maximum(node)
        body = emit_node(node.expression, result)
        greedy_exit = node.mode == :lazy ? "break if #{counter} >= #{node.minimum}" : ""
        <<~EXPRESSION.strip
          (begin #{result} = #{cursor}; #{counter} = 0; while #{counter} < #{maximum}; #{previous} = #{result}; #{result} = #{body}; if #{result}.nil?; #{result} = #{previous}; break; end; #{counter} += 1; break if #{result} == #{previous}; #{greedy_exit}; end; #{counter} >= #{node.minimum} ? #{result} : nil; end)
        EXPRESSION
      end

      def quantifier_maximum(node)
        if %i[possessive possessive_bounded].include?(node.mode) && node.maximum
          return [node.maximum - 1, node.minimum].max
        end

        node.maximum || "input.length + 1"
      end
    end

    # Emits backreferences, conditionals, calls, and absence regions.
    module NonRegularEmitter
      private

      def emit_backreference(node, cursor)
        index = node.identifier.to_i - 1
        length = "captures[#{index}][1] - captures[#{index}][0]"
        source = "input[captures[#{index}][0], #{length}]"
        target = "input[#{cursor}, #{length}]"
        "(captures[#{index}] ? (#{target} == #{source} ? #{cursor} + #{length} : nil) : nil)"
      end

      def emit_conditional(node, cursor)
        condition = Array(node.condition).first.to_i - 1
        yes_branch = emit_node(node.yes_branch, cursor)
        no_branch = emit_node(node.no_branch, cursor)
        "(captures[#{condition}] ? #{yes_branch} : #{no_branch})"
      end

      def emit_subexpression_call(node, cursor)
        group = @groups[node.identifier]
        raise CodegenError, "unresolved subexpression call #{node.identifier}" unless group

        emit_node(group.body, cursor)
      end

      def emit_absence(node, cursor)
        probe = fresh_cursor
        occurrence = fresh_cursor
        body = emit_node(node.body, probe)
        <<~EXPRESSION.strip
          (begin #{probe} = 0; #{occurrence} = nil; seen = false; while #{probe} < input.length; candidate = #{body}; if candidate; seen = true; if candidate > #{cursor}; #{occurrence} = #{probe} >= #{cursor} ? candidate - 1 : candidate; break; end; end; #{probe} += 1; end; #{occurrence} || (seen ? #{cursor} : input.length); end)
        EXPRESSION
      end
    end

    # Emits anchors and line-boundary predicates.
    module AnchorEmitter
      private

      def emit_anchor(node, cursor)
        predicate = case node.kind
                    when :anchor_absolute_start then "#{cursor} == 0"
                    when :anchor_absolute_end then "#{cursor} == input.length"
                    when :anchor_start then line_start_predicate(cursor)
                    when :anchor_end then line_end_predicate(cursor)
                    when :anchor_before_final_newline
                      "#{cursor} == input.length || (#{cursor} == input.length - 1 && " \
                        "input[#{cursor}] == \"\\n\")"
                    else "false"
                    end
        "(#{predicate} ? #{cursor} : nil)"
      end

      def line_start_predicate(cursor)
        "#{cursor} == 0 || input[#{cursor} - 1] == \"\\n\""
      end

      def line_end_predicate(cursor)
        "#{cursor} == input.length || input[#{cursor}] == \"\\n\""
      end
    end

    # Emits character class and Unicode property predicates.
    module PredicateEmitter
      private

      def emit_class(node, cursor)
        ignorecase = @options.include?("ignorecase")
        key = [node.value, ignorecase]
        index = @predicate_registry.register(key)
        predicate = "ONIBI_CLASS_PREDICATES.fetch(#{index})"
        "Onibi::Codegen::Casefold.class_candidates(input, #{cursor}, #{predicate}, #{ignorecase})"
      end

      def emit_property(node, cursor)
        predicate = "Onibi::UnicodeProperties.matches?(#{node.name.dump}, input[#{cursor}].encode(Encoding::UTF_8))"
        predicate = "!(#{predicate})" if node.negated
        "(#{cursor} < input.length && #{predicate} ? #{cursor} + 1 : nil)"
      end
    end

    # Emits escape predicates and variable-width linebreaks.
    module EscapeEmitter
      private

      def emit_escape(node, cursor)
        if %i[word_boundary not_word_boundary].include?(node.kind)
          predicate = "Onibi::CharacterPredicates.word_boundary?(input.chars, #{cursor})"
          predicate = "!(#{predicate})" if node.kind == :not_word_boundary
          return "(#{predicate} ? #{cursor} : nil)"
        end
        return "(#{cursor} == search_origin ? #{cursor} : nil)" if node.kind == :start_match
        return "(match_start = #{cursor})" if node.kind == :match_reset
        return emit_character_escape(node, cursor) if character_escape?(node.kind)
        return emit_linebreak(cursor) if node.kind == :linebreak

        "(#{cursor} < input.length ? #{cursor} + 1 : nil)"
      end

      def character_escape?(kind)
        %i[digit not_digit space not_space word not_word horizontal_space not_horizontal_space].include?(kind)
      end

      def emit_character_escape(node, cursor)
        predicate = "Onibi::CharacterPredicates.escape_matches?(#{node.kind.inspect}, input[#{cursor}])"
        "(#{cursor} < input.length && #{predicate} ? #{cursor} + 1 : nil)"
      end

      def emit_linebreak(cursor)
        predicate = "Onibi::CharacterPredicates.linebreak?(input[#{cursor}])"
        prefix = "(input[#{cursor}, 2] == \"\\r\\n\" ? #{cursor} + 2 : ("
        suffix = "#{cursor} < input.length && #{predicate} ? #{cursor} + 1 : nil))"
        "#{prefix}#{suffix}"
      end
    end

    # Deduplicates generated predicate keys with constant-time lookup.
    class PredicateRegistry
      attr_reader :entries

      def initialize
        @entries = []
        @indices = {}
      end

      def register(key)
        return @indices[key] if @indices.key?(key)

        index = @entries.length
        normalized = [key.fetch(0).dup.freeze, key.fetch(1) == true].freeze
        @indices[normalized] = index
        @entries << normalized
        index
      end
    end

    # Determines whether generated boolean execution needs capture state.
    module CaptureLiveness
      module_function

      def required?(value)
        return value.any? { |child| required?(child) } if value.is_a?(Array)
        return true if [AST::Backreference, AST::Conditional, AST::SubexpressionCall].include?(value.class)
        return false unless value.is_a?(Struct)

        value.any? { |child| required?(child) }
      end
    end

    # Emits one immutable compiled predicate table per generated module.
    module PredicateTableSetup
      private

      def predicate_setup
        return if @predicate_registry.entries.empty?

        entries = @predicate_registry.entries.map do |source, ignorecase|
          index = Onibi::ClassPredicates::TableRegistry.register(source, ignorecase: ignorecase)
          "Onibi::ClassPredicates::TableRegistry.fetch(#{index})"
        end
        "ONIBI_CLASS_PREDICATES = [#{entries.join(", ")}].freeze"
      end
    end

    # Emits the shared literal constant used by generated source.
    module LiteralTableSetup
      private

      def literal_setup
        return if @literal_registry.entries.empty?

        values = @literal_registry.entries.map do |value|
          dumped = value.dump
          dumped = "#{dumped}.b" if value.encoding == Encoding::ASCII_8BIT
          dumped
        end
        return "ONIBI_LITERAL_VALUES = #{values.first}" if values.one?

        "ONIBI_LITERAL_VALUES = [#{values.join(", ")}].freeze"
      end
    end

    # Supplies deterministic cursor names to generated expressions.
    module CursorFactory
      private

      def fresh_cursor
        @counter += 1
        "cursor_#{@counter}"
      end
    end

    # Emits literal leaves and coalesced straight-line literal runs.
    module LiteralRunEmitter
      private

      def emit_literal(node, cursor)
        value = node.is_a?(Array) ? node.map(&:value).join : node.value
        comparison = literal_comparison(value, cursor)
        return "(#{comparison} || nil)" if @options.include?("ignorecase")

        "(#{comparison} ? #{cursor} + #{value.length} : nil)"
      end

      def literal_comparison(value, cursor)
        dumped = value.dump
        dumped = "#{dumped}.b" if value.encoding == Encoding::ASCII_8BIT
        if @options.include?("ignorecase")
          return "Onibi::Codegen::Casefold.literal_candidates(input, #{cursor}, #{dumped}).first"
        end

        "input[#{cursor}, #{value.length}] == #{literal_reference(value, dumped)}"
      end

      def literal_reference(value, dumped)
        index = @literal_registry.register(value)
        return dumped unless index
        return "ONIBI_LITERAL_VALUES" if @literal_registry.entries.length == 1

        "ONIBI_LITERAL_VALUES.fetch(#{index})"
      end

      def literal_run?(parts)
        parts.length > 1 && parts.all? { |part| part.is_a?(AST::Literal) }
      end
    end

    # Collects repeated literal runs before source emission.
    module LiteralRegistryCollector
      private

      def collect_literals(value)
        case value
        when Array then value.each { |item| collect_literals(item) }
        when AST::Sequence then collect_sequence_literals(value.parts)
        when AST::Literal then @literal_registry.count(value.value)
        when Struct then value.each { |child| collect_literals(child) }
        end
      end

      def collect_sequence_literals(parts)
        index = 0
        while index < parts.length
          unless parts[index].is_a?(AST::Literal)
            collect_literals(parts[index])
            index += 1
            next
          end

          ending = index
          ending += 1 while ending < parts.length && parts[ending].is_a?(AST::Literal)
          @literal_registry.count(parts[index...ending].map(&:value).join) if ending - index > 1
          index = ending
        end
      end
    end

    # Emits literal prefixes before the remaining sequence body.
    module SequenceEmitter
      private

      def emit_sequence(node, cursor)
        emit_sequence_parts(node.parts, cursor)
      end

      def emit_sequence_parts(parts, cursor)
        return cursor if parts.empty?
        return emit_quantifier_with_remainder(parts.first, parts.drop(1), cursor) if backtracking_quantifier?(parts)

        prefix = literal_prefix(parts)
        return emit_literal(prefix, cursor) if prefix.length == parts.length && literal_run?(parts)
        return emit_literal_prefix(prefix, parts.drop(prefix.length), cursor) unless prefix.empty?

        emit_sequence_remainder(parts, cursor)
      end

      def emit_sequence_remainder(parts, cursor)
        next_cursor = fresh_cursor
        expression = emit_node(parts.first, cursor)
        remainder = emit_sequence_parts(parts.drop(1), next_cursor)
        "(#{next_cursor} = #{expression}; #{next_cursor}.nil? ? nil : #{remainder})"
      end

      def literal_prefix(parts)
        parts.take_while { |part| part.is_a?(AST::Literal) }
      end

      def emit_literal_prefix(prefix, remainder, cursor)
        next_cursor = fresh_cursor
        expression = emit_literal(prefix, cursor)
        rest = emit_sequence_parts(remainder, next_cursor)
        "(#{next_cursor} = #{expression}; #{next_cursor}.nil? ? nil : #{rest})"
      end

      def backtracking_quantifier?(parts)
        parts.length > 1 && parts.first.is_a?(AST::Quantifier) &&
          !%i[possessive possessive_bounded].include?(parts.first.mode)
      end
    end

    # Emits direct Ruby control flow for regular consuming AST nodes.
    class AstEmitter
      include GroupEmitter
      include AssertionEmitter
      include QuantifierEmitter
      include NonRegularEmitter
      include AnchorEmitter
      include PredicateEmitter
      include EscapeEmitter
      include PredicateTableSetup
      include LiteralTableSetup
      include CursorFactory
      include LiteralRunEmitter
      include LiteralRegistryCollector
      include SequenceEmitter
      NODE_EMITTERS = {
        AST::Literal => :emit_literal,
        AST::Sequence => :emit_sequence,
        AST::Alternation => :emit_alternation,
        AST::Any => :emit_any,
        AST::CharacterClass => :emit_class,
        AST::Property => :emit_property,
        AST::Escape => :emit_escape,
        AST::Anchor => :emit_anchor,
        AST::OptionGroup => :emit_option_group,
        AST::Quantifier => :emit_quantifier,
        AST::Group => :emit_group,
        AST::AtomicGroup => :emit_atomic_group,
        AST::Assertion => :emit_assertion,
        AST::Backreference => :emit_backreference,
        AST::Conditional => :emit_conditional,
        AST::SubexpressionCall => :emit_subexpression_call,
        AST::Absence => :emit_absence
      }.freeze
      def initialize(options, predicate_registry = nil, literal_registry = nil)
        @options = options
        @counter = 0
        @predicate_registry = predicate_registry || PredicateRegistry.new
        @literal_registry = literal_registry || LiteralRegistry.new
      end

      def emit(ast)
        @backreferences = CaptureLiveness.required?(ast)
        collect_groups(ast)
        collect_literals(ast)
        body = emit_node(ast, "position")
        captures = capture_setup
        setup = [predicate_setup, literal_setup].compact.join("\n")
        <<~RUBY
          #{setup}
          def self.__onibi_search(input, position, capture, search_origin = position)
            return false unless input.is_a?(String)
            #{captures}
            match_start = position
            result = #{body}
            result.nil? ? false : (capture ? [match_start, result, #{capture_result}] : true)
          end
        RUBY
      end

      private

      def capture_setup
        return "captures = nil" if capture_count.zero?

        @backreferences ? "captures=Array.new(#{capture_count})" : "captures=capture ?Array.new(#{capture_count}):nil"
      end

      def capture_result = capture_count.zero? ? "[]" : "captures"

      def collect_groups(value)
        return value.each { |item| collect_groups(item) } if value.is_a?(Array)
        return unless value.is_a?(Struct)

        @groups ||= {}
        if value.is_a?(AST::Group)
          @groups[value.number] = value if value.number
          @groups[value.name] = value if value.name
        end
        value.each { |child| collect_groups(child) }
      end

      def capture_count = @groups.keys.grep(Integer).max || 0

      def emit_node(node, cursor)
        handler = NODE_EMITTERS[node.class]
        raise CodegenError, "unsupported regular AST node #{node.class}" unless handler

        send(handler, node, cursor)
      end

      def emit_alternation(node, cursor)
        branches = node.branches.map do |branch|
          expression = emit_node(branch, cursor)
          "(branch = #{expression}; branch.nil? ? nil : branch)"
        end
        "(#{branches.join(" || ")})"
      end

      def emit_any(node, cursor)
        condition = node.value == "." && !@options.include?("multiline") ? "input[#{cursor}] != \"\\n\"" : "true"
        "(#{cursor} < input.length && #{condition} ? #{cursor} + 1 : nil)"
      end

      def emit_option_group(node, cursor)
        scoped_options = @options.dup
        scoped_options = toggle_option(scoped_options, "ignorecase", node.ignorecase)
        scoped_options = toggle_option(scoped_options, "multiline", node.multiline)
        scoped_options = toggle_option(scoped_options, "extended", node.extended)
        AstEmitter.new(scoped_options, @predicate_registry, @literal_registry).send(:emit_node, node.body, cursor)
      end

      def toggle_option(options, name, value)
        return options unless [true, false].include?(value)

        value ? (options | [name]) : (options - [name])
      end

      def emit_atomic_group(node, cursor)
        emit_node(node.body, cursor)
      end
    end

    # Removes duplicate whole-regexp literal branches while preserving order.
    module BranchPruner
      module_function

      def prune(ast, options)
        return ast unless eligible?(ast, options)

        branches = unique_branches(ast.branches)
        branches.length == ast.branches.length ? ast : AST::Alternation.new(branches)
      end

      def eligible?(ast, options)
        options.empty? && ast.is_a?(AST::Alternation) && ast.branches.all? { |branch| prunable_branch?(branch) }
      end

      def unique_branches(branches)
        seen = {}
        viable = branches.reject { |branch| impossible_branch?(branch) }
        return [branches.first] if viable.empty?

        viable.select do |branch|
          value = branch.parts.map(&:value).join
          seen[value] ? false : (seen[value] = true)
        end
      end

      def prunable_branch?(branch)
        literal_branch?(branch) || impossible_branch?(branch)
      end

      def impossible_branch?(branch)
        branch.is_a?(AST::Sequence) && branch.parts.any? do |part|
          part.is_a?(AST::Assertion) && part.kind == :negative &&
            part.body.is_a?(AST::Sequence) && part.body.parts.empty?
        end
      end

      def literal_branch?(branch)
        branch.is_a?(AST::Sequence) && branch.parts.all? { |part| part.is_a?(AST::Literal) }
      end
    end

    # Owns one immutable generated module for one regexp compilation.
    class GeneratedProgram
      attr_reader :compiled_module, :entrypoint, :source, :search_plan

      def self.literal(value)
        new(RubyEmitter.literal(value))
      end

      def self.ast(ast, options: [], optimizations: [:swar], analysis: nil)
        ast = BranchPruner.prune(ast, options) unless analysis
        analysis ||= Analyzer.new(options).analyze(ast)
        if optimizations.include?(:swar)
          prefilter = Experimental::Swar::LiteralAlternation.build(
            ast, options,
            allow_long_literals: optimizations.include?(:swar_long_literals),
            allow_single_character: optimizations.include?(:swar_single_character)
          )
        end
        search_plan = SearchPlan.from(ast, analysis)
        candidate_source = candidate_source_for(optimizations, prefilter, search_plan)
        search_plan = search_plan.with_candidate_source(candidate_source) if candidate_source
        new(RubyGenerator.ast(ast, options: options), prefilter: prefilter,
                                                      search_plan: search_plan)
      end

      def self.candidate_source_for(optimizations, prefilter, search_plan)
        return unless optimizations.include?(:candidate_intersection) && prefilter

        CandidateSource::Intersection.new([prefilter, search_plan])
      end

      def initialize(source, compiler: SourceCompiler.new, filename: "(onibi-generated)", prefilter: nil,
                     search_plan: SearchPlan.new(anchor_start: false, anchor_end: false, minimum_width: 0,
                                                 first_set: nil, required_literal: nil, nullable_prefix: true,
                                                 search_mode: :scan, regular_run: nil))
        @source = source.dup.freeze
        @prefilter = prefilter
        @search_plan = search_plan.freeze
        @candidate_source = search_plan.candidate_source
        @compiled_module = compiler.compile(@source, filename: filename)
        @entrypoint = SourceCompiler::ENTRYPOINT
        freeze
      end

      def swar?
        !@prefilter.nil?
      end

      def prefilter_profitable?(input, position)
        @prefilter&.profitable?(input, position) == true
      end

      def search(input, position, capture:)
        if search_plan.regular_run
          result = search_plan.regular_run.search(input, position, capture: capture)
          return result unless result.nil?
        end

        if @candidate_source&.eligible?(input, position)
          return search_with_candidates(input, position, capture, @candidate_source)
        end
        return search_with_plan(input, position, capture) unless @prefilter&.eligible?(input, position)

        initial = execute(input, position, capture, position)
        return initial if initial

        candidates = @prefilter.candidate_positions(input, position + 1)
        search_candidates(input, position, capture, candidates)
      end

      # Lazily yields raw offset results without constructing MatchData.
      def each_match(input, position = 0, capture: true)
        return enum_for(__method__, input, position, capture: capture) unless block_given?

        cursor = position
        while cursor <= input.length
          result = search(input, cursor, capture: capture)
          break unless result

          yield result
          finish = capture ? result[1] : cursor + 1
          cursor = finish == cursor ? cursor + 1 : finish
        end
      end

      private

      def search_with_plan(input, position, capture)
        result = nil
        @search_plan.each_candidate(input, position) do |candidate|
          result = execute(input, candidate, capture, position)
          break if result
        end
        result || false
      end

      def search_with_candidates(input, position, capture, source)
        initial = execute(input, position, capture, position)
        return initial if initial

        search_candidates(input, position, capture, source.candidate_positions(input, position + 1))
      end

      def baseline_search(input, position, capture)
        candidate = position
        while candidate <= input.length
          result = execute(input, candidate, capture, position)
          return result if result

          candidate += 1
        end
        false
      end

      def search_candidates(input, position, capture, candidates)
        candidates.each do |candidate|
          result = execute(input, candidate, capture, position)
          return result if result
        end
        false
      end

      def execute(input, candidate, capture, search_origin)
        compiled_module.__send__(entrypoint, input, candidate, capture, search_origin)
      rescue ArgumentError => e
        raise unless e.message.include?("wrong number of arguments")

        compiled_module.__send__(entrypoint, input, candidate, capture)
      end
    end

    # Converts generated offsets into the existing public MatchData shape.
    class MatchAdapter
      def self.build(result, input, regexp, names = {})
        return nil unless result

        new(result, input, regexp, names).build
      end

      def initialize(result, input, regexp, names)
        @start, @finish, @capture_offsets = result
        @input = input
        @regexp = regexp
        @names = names
      end

      def build
        full_match = slice(@start, @finish)
        captures = @capture_offsets.map { |offset| offset && slice(offset[0], offset[1]) }
        offsets = [[@start, @finish]] + @capture_offsets
        names = normalized_names
        MatchData.new(full_match, captures, offsets, names, MatchData::Context.new(@input, @regexp))
      end

      private

      def slice(start, finish)
        @input[start...finish]
      end

      def normalized_names
        @names.transform_values do |value|
          Array(value).reverse_each.find { |index| @capture_offsets[index - 1] } || Array(value).last
        end
      end
    end

    # Experimental boolean surface backed by the same generated program.
    class BooleanMatcher
      def initialize(ast, options: [])
        @program = GeneratedProgram.ast(ast, options: options)
      end

      def match?(input, position = 0)
        @program.search(input, position, capture: false) == true
      end
    end

    # Counts generated execution steps and raises deterministic timeout errors.
    class ExecutionBudget
      attr_reader :steps

      def initialize(limit: 1_000_000, deadline: nil)
        @limit = limit
        @deadline = deadline
        @steps = 0
      end

      def consume!(amount = 1)
        @steps += amount
        return true if @steps <= @limit && (!@deadline || Process.clock_gettime(Process::CLOCK_MONOTONIC) < @deadline)

        raise Regexp::TimeoutError, "regexp match timeout"
      end
    end

    # Validates generated source before it reaches the Ruby parser.
    module Security
      FORBIDDEN_SOURCE = /RubyVM|InstructionSequence|`|\beval\b|\bsystem\b/

      def self.validate_source!(source, max_bytes: 1_000_000)
        raise CodegenError, "generated source exceeds source_bytes limit" if source.bytesize > max_bytes
        raise CodegenError, "generated source contains forbidden operation" if source.match?(FORBIDDEN_SOURCE)

        source
      end
    end
  end
end
