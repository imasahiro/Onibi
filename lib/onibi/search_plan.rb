# frozen_string_literal: true

module Onibi
  module Codegen
    # Conservative candidate-start facts consumed by GeneratedProgram#search.
    SearchPlan = Struct.new(
      :anchor_start, :anchor_end, :minimum_width, :first_set, :required_literal,
      :nullable_prefix, :search_mode,
      keyword_init: true
    ) do
      def self.from(ast, analysis)
        new(**SearchPlanFacts.new(ast, analysis).call)
      end

      def candidate_positions(input, position)
        positions = []
        each_candidate(input, position) { |candidate| positions << candidate }
        positions
      end

      def each_candidate(input, position, &block)
        return enum_for(__method__, input, position) unless block
        return unless valid_position?(input, position)

        maximum = input.length - minimum_width
        return if maximum < position
        return anchored_candidates(position, &block) if anchor_start
        return literal_candidates(input, position, maximum, &block) if required_literal

        position.upto(maximum, &block)
      end

      private

      def valid_position?(input, position)
        position >= 0 && position <= input.length
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
        minimum_width = @analysis.widths.fetch(@ast).minimum
        {
          anchor_start: anchor_start,
          anchor_end: false,
          minimum_width: minimum_width,
          first_set: literal ? [literal[0]].freeze : nil,
          required_literal: literal&.dup&.freeze,
          nullable_prefix: !anchor_start && first.nil?,
          search_mode: search_mode(anchor_start, literal)
        }
      end

      private

      def literal_value(node)
        return unless node.is_a?(AST::Literal)
        return if @analysis.options.include?("ignorecase") || node.value.empty?

        node.value
      end

      def search_mode(anchor_start, literal)
        return :anchored if anchor_start
        return :literal_skip if literal

        :scan
      end

      def leading_node(node)
        case node
        when AST::Sequence then leading_sequence(node.parts)
        when AST::Anchor then [node.kind == :anchor_absolute_start, nil]
        when AST::Literal then [false, node]
        else [false, nil]
        end
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
  end
end
