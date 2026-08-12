# frozen_string_literal: true

module Onibi
  module Codegen
    # Conservative candidate-start facts consumed by GeneratedProgram#search.
    SearchPlan = Struct.new(
      :anchor_start, :origin_start, :anchor_end, :minimum_width, :first_set, :required_literal,
      :required_literals, :required_literal_source,
      :nullable_prefix, :search_mode, :regular_run, :class_prefilter, :candidate_source,
      keyword_init: true
    ) do
      include CandidateSource

      def with_candidate_source(source)
        self.class.new(**to_h, candidate_source: source).freeze
      end

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
        return origin_candidate(input, position, &block) if origin_start
        return anchored_end_candidate(input, position, &block) if anchor_end

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
        if anchor_end
          candidate = input.length - minimum_width
          yield candidate if candidate >= position
          return
        end
        return yield_special_candidates(input, position, maximum, &block) if special_candidates?

        position.upto(maximum, &block)
      end

      def special_candidates?
        class_prefilter || required_literals || required_literal
      end

      def yield_special_candidates(input, position, maximum, &block)
        if class_prefilter
          return class_candidates(input, position, maximum, &block) if class_prefilter.eligible?(input, position)

          return position.upto(maximum, &block)
        end
        return literal_set_candidates(input, position, maximum, &block) if required_literal_source

        literal_candidates(input, position, maximum, &block)
      end

      def anchored_end_candidate(input, position)
        candidate = input.length - minimum_width
        yield candidate if candidate >= position
      end

      def origin_candidate(input, position)
        return if anchor_end && position + minimum_width != input.length

        yield position
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
        required_literal_source.candidate_positions(input, position).each do |candidate|
          block.call(candidate) if candidate <= maximum
        end
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

    # Builds a conservative first-byte source for simple ASCII alternation branches.
    module AlternationFirstSetFacts
      module_function

      def build(ast, options)
        return unless options.empty? && ast.is_a?(AST::Alternation)

        bytes = ast.branches.map { |branch| branch_bytes(branch) }
        return unless bytes.all?

        Experimental::Swar::ByteSetPrefilter.new(bytes.flatten)
      end

      def branch_bytes(branch)
        node = branch.is_a?(AST::Sequence) ? branch.parts.first : branch
        return literal_bytes(node) if node.is_a?(AST::Literal)
        return class_bytes(node) if node.is_a?(AST::CharacterClass)

        nil
      end

      def literal_bytes(node)
        return unless node.value.bytesize == 1 && node.value.ascii_only?

        [node.value.getbyte(0)]
      end

      def class_bytes(node)
        return unless node.value.ascii_only?

        metadata = ClassPredicates.compiled(node.value).metadata
        return unless metadata.ascii_applicable

        0.upto(255).select { |byte| ((metadata.ascii_bitmap >> byte) & 1) == 1 }
      end
    end

    # Builds a conservative first-set source for a nullable ASCII class prefix.
    module NullablePrefixFacts
      module_function

      def build(ast, options)
        return unless eligible?(ast, options)

        quantifier, literal = prefix_nodes(ast)
        predicate = ClassPredicates.compiled(quantifier.expression.value)
        bytes = (0..255).select do |byte|
          predicate.matches?(byte.chr(Encoding::ASCII_8BIT))
        end
        bytes << literal.value.getbyte(0)
        Experimental::Swar::ByteSetPrefilter.new(bytes)
      end

      def eligible?(ast, options)
        return false unless options.empty? && ast.is_a?(AST::Sequence)

        quantifier = ast.parts.first
        literal = ast.parts[1]
        nullable_class?(quantifier) && ascii_literal?(literal) &&
          ClassPrefilterFacts.ascii_literal_class?(quantifier.expression.value)
      end

      def nullable_class?(node)
        node.is_a?(AST::Quantifier) && node.minimum.zero? && node.maximum != 0 &&
          node.expression.is_a?(AST::CharacterClass)
      end

      def ascii_literal?(node)
        node.is_a?(AST::Literal) && node.value.ascii_only? && !node.value.empty?
      end

      def prefix_nodes(ast)
        [ast.parts.first, ast.parts[1]]
      end
    end

    # Selects the candidate search strategy from immutable analysis facts.
    module SearchModeFacts
      module_function

      def call(facts)
        return :anchored if facts[:anchor_start]
        return :origin_anchored if facts[:origin_start]
        return :first_set if facts[:nullable_prefilter]
        return :class_prefilter if facts[:class_prefilter]
        return :literal_set_skip if facts[:required_literals]
        return :literal_skip if facts[:literal]

        :scan
      end
    end

    # Detects a leading \G/search-origin assertion.
    module OriginStartFacts
      module_function

      def call(ast)
        node = ast.is_a?(AST::Sequence) ? ast.parts.first : ast
        node.is_a?(AST::Escape) && node.kind == :start_match
      end
    end

    # Builds an immutable union source for analyzed required literals.
    module RequiredLiteralSourceFacts
      module_function

      def build(literals)
        return unless literals

        CandidateSource::Union.new(
          literals.map { |value, offset| CandidateSource::Literal.new(value, offset: offset) }
        )
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
        origin_start = OriginStartFacts.call(@ast)
        literal = literal_value(first)
        required_literals = candidate_literals
        nullable_prefilter = NullablePrefixFacts.build(@ast, @analysis.options)
        first_set_prefilter = AlternationFirstSetFacts.build(@ast, @analysis.options)
        class_prefilter = leading_class_prefilter || first_set_prefilter || nullable_prefilter
        build_facts(
          anchor_start: anchor_start, origin_start: origin_start, literal: literal,
          required_literals: required_literals, class_prefilter: class_prefilter,
          nullable_prefilter: nullable_prefilter
        )
      end

      private

      def build_facts(facts)
        {
          anchor_start: facts[:anchor_start],
          origin_start: facts[:origin_start],
          anchor_end: trailing_anchor?,
          minimum_width: @analysis.widths.fetch(@ast).minimum,
          **search_metadata(facts)
        }
      end

      def search_metadata(facts)
        literal = facts[:literal]
        {
          first_set: literal ? [literal[0]].freeze : nil,
          required_literal: literal&.dup&.freeze,
          required_literals: facts[:required_literals],
          required_literal_source: RequiredLiteralSourceFacts.build(facts[:required_literals]),
          nullable_prefix: !facts[:anchor_start] && !literal,
          search_mode: SearchModeFacts.call(facts),
          regular_run: regular_run,
          class_prefilter: facts[:class_prefilter]
        }
      end

      def trailing_anchor?
        node = @ast.is_a?(AST::Sequence) ? @ast.parts.last : @ast
        width = @analysis.widths.fetch(@ast)
        node.is_a?(AST::Anchor) && node.kind == :anchor_absolute_end && width.maximum == width.minimum
      end

      def literal_value(node)
        return unless node.is_a?(AST::Literal)
        return if @analysis.options.include?("ignorecase") || node.value.empty?

        node.value
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
      attr_reader :sources, :predicates, :scanners

      def initialize(sources)
        @sources = sources.map(&:dup).map(&:freeze).freeze
        @scanners = @sources.map { |source| Experimental::Swar::ClassRun.new(source) }.freeze
        @predicates = @scanners.map(&:predicate).freeze
        freeze
      end

      def search(input, position, capture:)
        return unless input.ascii_only?

        start = position
        while start < input.length
          unless matches_at?(scanners.first, input, start)
            start += 1
            next
          end

          finish = match_sources(input, start)
          return result(start, finish, capture) if finish

          # With disjoint classes, every start inside this left run reaches the
          # same failed boundary. Jumping to the boundary removes suffix rescans.
          start = consume(scanners.first, input, start)
        end
        false
      end

      private

      def consume(scanner, input, cursor)
        scanner.scan_end(input, cursor)
      end

      def match_sources(input, start)
        finish = start
        matched = scanners.all? do |scanner|
          next false unless matches_at?(scanner, input, finish)

          finish = consume(scanner, input, finish)
          true
        end
        matched ? finish : nil
      end

      def matches_at?(scanner, input, cursor)
        scanner.matches_byte?(input.getbyte(cursor))
      end

      def result(start, finish, capture)
        capture ? [start, finish, []] : true
      end
    end
  end
end
