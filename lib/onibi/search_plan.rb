# frozen_string_literal: true

module Onibi
  module Codegen
    # Conservative candidate-start facts consumed by GeneratedProgram#search.
    SearchPlan = Struct.new(
      :anchor_start, :anchor_end, :minimum_width, :first_set, :required_literal,
      :required_literals,
      :nullable_prefix, :search_mode, :regular_run, :class_prefilter,
      keyword_init: true
    ) do
      include CandidateSource

      def self.from(ast, analysis)
        new(**SearchPlanFacts.new(ast, analysis).call)
      end

      def candidate_positions(input, position)
        positions = []
        each_candidate(input, position) { |candidate| positions << candidate }
        positions
      end

      def eligible?(input, position)
        input.is_a?(String) && valid_position?(input, position)
      end

      def preserves_order?
        true
      end

      def each_candidate(input, position, &block)
        return enum_for(__method__, input, position) unless block
        return unless valid_position?(input, position)

        maximum = input.length - minimum_width
        return if maximum < position

        yield_candidates(input, position, maximum, &block)
      end

      private

      def valid_position?(input, position)
        position >= 0 && position <= input.length
      end

      def yield_candidates(input, position, maximum, &block)
        if anchor_start
          yield position if position.zero?
          return
        end
        return class_candidates(input, position, maximum, &block) if class_prefilter
        return literal_set_candidates(input, position, maximum, &block) if required_literals
        return literal_candidates(input, position, maximum, &block) if required_literal

        position.upto(maximum, &block)
      end

      def anchored_candidates(position)
        yield position if position.zero?
      end

      def literal_candidates(input, position, maximum)
        candidate = position
        while (found = input.index(required_literal, candidate))
          break if found > maximum

          yield found
          candidate = found + 1
        end
      end

      def class_candidates(input, position, maximum)
        candidates = class_candidate_positions(input, position)
        candidates.each do |candidate|
          yield candidate if candidate <= maximum
        end
      end

      def class_candidate_positions(input, position)
        return class_prefilter.each_candidate(input, position) if class_prefilter.respond_to?(:each_candidate)

        class_prefilter.candidate_positions(input, position)
      end

      def literal_set_candidates(input, position, maximum, &block)
        candidates = required_literals.flat_map do |literal, offset|
          candidate = position
          starts = []
          while (found = input.index(literal, candidate))
            break if found > maximum + offset

            start = found - offset
            starts << start if start >= position && start <= maximum
            candidate = found + 1
          end
          starts
        end
        candidates.uniq.sort.each { |candidate| block.call(candidate) }
      end
    end

    # Builds conservative ASCII character-class candidate sources.
    module ClassPrefilterFacts
      module_function

      def build(ast)
        node = leading_node(ast)
        return unless node && ascii_literal_class?(node.value)

        Experimental::Swar::ClassPrefilter.new(node.value)
      end

      def leading_node(ast)
        return ast if ast.is_a?(AST::CharacterClass)
        return unless ast.is_a?(AST::Sequence)
        return unless ast.parts.first.is_a?(AST::CharacterClass)
        return if ast.parts[1].is_a?(AST::Literal)

        ast.parts.first
      end

      def ascii_literal_class?(source)
        source.ascii_only? && !source.start_with?("^") && !source.include?("\\") &&
          !source.include?("&&") && !source.include?(":")
      end
    end

    # Extracts conservative facts from an analyzed AST.
    class SearchPlanFacts
      def initialize(ast, analysis)
        @ast = ast
        @analysis = analysis
      end

      def call
        anchor_start, first = leading_node(@ast)
        literal = literal_value(first)
        required_literals = candidate_literals
        class_prefilter = leading_class_prefilter
        build_facts(anchor_start, first, literal, required_literals, class_prefilter)
      end

      private

      def build_facts(anchor_start, first, literal, required_literals, class_prefilter)
        minimum_width = @analysis.widths.fetch(@ast).minimum
        {
          anchor_start: anchor_start,
          anchor_end: false,
          minimum_width: minimum_width,
          first_set: literal ? [literal[0]].freeze : nil,
          required_literal: literal&.dup&.freeze,
          required_literals: required_literals,
          nullable_prefix: !anchor_start && first.nil?,
          search_mode: search_mode(anchor_start, literal, required_literals, class_prefilter),
          regular_run: regular_run,
          class_prefilter: class_prefilter
        }
      end

      def literal_value(node)
        return unless node.is_a?(AST::Literal)
        return if @analysis.options.include?("ignorecase") || node.value.empty?

        node.value
      end

      def search_mode(anchor_start, literal, required_literals, class_prefilter)
        return :anchored if anchor_start
        return :class_prefilter if class_prefilter
        return :literal_set_skip if required_literals
        return :literal_skip if literal

        :scan
      end

      def leading_class_prefilter
        return if @analysis.options.include?("ignorecase")

        ClassPrefilterFacts.build(@ast)
      end

      def regular_run
        return unless regular_run_shape?

        sources = @ast.parts.map { |node| node.expression.value }
        RegularRun.new(sources) if sources.each_cons(2).all? { |left, right| disjoint_ascii_classes?(left, right) }
      end

      def regular_run_shape?
        @analysis.options.empty? && @ast.is_a?(AST::Sequence) && @ast.parts.length >= 2 &&
          @ast.parts.all? { |node| simple_plus_class?(node) }
      end

      def simple_plus_class?(node)
        node.is_a?(AST::Quantifier) && node.minimum == 1 && node.maximum.nil? &&
          node.mode == :greedy && node.expression.is_a?(AST::CharacterClass)
      end

      def disjoint_ascii_classes?(left, right)
        (0..127).none? do |codepoint|
          character = codepoint.chr(Encoding::ASCII)
          ClassPredicates.matches?(left, character) && ClassPredicates.matches?(right, character)
        end
      end

      def leading_node(node)
        case node
        when AST::Sequence then leading_sequence(node.parts)
        when AST::Anchor then [node.kind == :anchor_absolute_start, nil]
        when AST::Literal then [false, node]
        else [false, nil]
        end
      end

      def candidate_literals
        literals = @ast.is_a?(AST::Alternation) ? alternation_literals : class_literal_suffix
        return if literals.nil? || literals.empty?

        literals.uniq { |literal, offset| [literal, offset] }
                .map { |literal, offset| [literal.dup.freeze, offset].freeze }.freeze
      end

      def alternation_literals
        prefixes = @ast.branches.map { |branch| branch_literal_prefix(branch) }
        prefixes if prefixes.all?
      end

      def branch_literal_prefix(branch)
        parts = branch.is_a?(AST::Sequence) ? branch.parts : [branch]
        return unless parts.first.is_a?(AST::Literal)
        return if @analysis.options.include?("ignorecase")

        literal = literal_prefix(parts, 0)
        return if literal.value.empty?

        [literal.value, 0]
      end

      def class_literal_suffix
        return unless @analysis.options.empty? && @ast.is_a?(AST::Sequence) && @ast.parts.length >= 2
        return unless @ast.parts[0].is_a?(AST::CharacterClass) && @ast.parts[1].is_a?(AST::Literal)

        literal = literal_prefix(@ast.parts, 1).value
        return if literal.empty?

        [[literal, 1]]
      end

      def leading_sequence(parts)
        return [false, nil] if parts.empty?

        if parts.first.is_a?(AST::Anchor)
          anchor = parts.first.kind == :anchor_absolute_start
          return [anchor, literal_prefix(parts, 1)] if anchor && parts[1].is_a?(AST::Literal)

          return [anchor, nil]
        end

        return [false, literal_prefix(parts, 0)] if parts.first.is_a?(AST::Literal)

        [false, nil]
      end

      def literal_prefix(parts, index)
        value = String.new(encoding: parts[index].value.encoding)
        parts[index..].each do |part|
          break unless part.is_a?(AST::Literal)

          value << part.value
        end
        AST::Literal.new(value)
      end
    end

    # One-pass scanner for two disjoint greedy character-class runs.
    class RegularRun
      attr_reader :sources, :predicates

      def initialize(sources)
        @sources = sources.map(&:dup).map(&:freeze).freeze
        @predicates = @sources.map { |source| ClassPredicates.compiled(source) }.freeze
        freeze
      end

      def search(input, position, capture:)
        return unless input.ascii_only?

        start = position
        while start < input.length
          unless matches?(predicates.first, input[start])
            start += 1
            next
          end

          finish = match_sources(input, start)
          return result(start, finish, capture) if finish

          # With disjoint classes, every start inside this left run reaches the
          # same failed boundary. Jumping to the boundary removes suffix rescans.
          start = consume(predicates.first, input, start)
        end
        false
      end

      private

      def consume(predicate, input, cursor)
        cursor += 1 while cursor < input.length && matches?(predicate, input[cursor])
        cursor
      end

      def match_sources(input, start)
        finish = start
        matched = predicates.all? do |predicate|
          next false unless matches?(predicate, input[finish])

          finish = consume(predicate, input, finish)
          true
        end
        matched ? finish : nil
      end

      def matches?(predicate, character)
        character && predicate.matches?(character)
      end

      def result(start, finish, capture)
        capture ? [start, finish, []] : true
      end
    end
  end
end
