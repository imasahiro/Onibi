# frozen_string_literal: true

module Onibi
  # Correctness fallback for ASTs that cannot complete through bytecode dispatch.
  class AstMatcher
    def initialize(ast)
      @ast = ast
    end

    def match?(input)
      characters = input.chars

      (0..characters.length).any? do |start|
        !match_positions(@ast, characters, start).empty?
      end
    end

    private

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    def match_positions(node, characters, position)
      case node
      when AST::Sequence then sequence_positions(node.parts, characters, position)
      when AST::Alternation then node.branches.flat_map { |branch| match_positions(branch, characters, position) }
      when AST::Group then match_positions(node.body, characters, position)
      when AST::Quantifier then quantifier_positions(node, characters, position)
      when AST::Literal then literal_positions(node, characters, position)
      when AST::CharacterClass then class_positions(node, characters, position)
      when AST::Escape then escape_positions(node, characters, position)
      when AST::Any then position < characters.length ? [position + 1] : []
      when AST::Anchor then anchor_positions(node, characters, position)
      else []
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

    def sequence_positions(parts, characters, position)
      parts.reduce([position]) do |positions, part|
        positions.flat_map { |current| match_positions(part, characters, current) }
      end
    end

    def quantifier_positions(node, characters, position)
      positions = [position]
      maximum = node.maximum || characters.length + 1
      maximum.times do
        next_positions = positions.flat_map { |current| match_positions(node.expression, characters, current) }.uniq
        break if next_positions.empty? || next_positions == positions

        positions.concat(next_positions).uniq!
      end
      positions.select { |current| current >= position + node.minimum }
    end

    def literal_positions(node, characters, position)
      value = node.value.chars

      characters[position, value.length] == value ? [position + value.length] : []
    end

    def class_positions(node, characters, position)
      return [] unless position < characters.length
      return [] unless class_matches?(node.value, characters[position])

      [position + 1]
    end

    def class_matches?(source, character)
      negated = source.start_with?("^")
      content = source[(negated ? 1 : 0)..-1]
      matched = content.include?(character)
      matched ||= content.each_char.each_cons(3).any? do |first, hyphen, last|
        hyphen == "-" && character >= first && character <= last
      end

      negated ? !matched : matched
    end

    def escape_positions(node, characters, position)
      return [] unless position < characters.length
      return [] unless escape_matches?(node.kind, characters[position])

      [position + 1]
    end

    def escape_matches?(kind, character)
      case kind
      when :digit then character >= "0" && character <= "9"
      when :space then character =~ /\s/
      when :word then character =~ /[A-Za-z0-9_]/
      end
    end

    def anchor_positions(node, characters, position)
      at_start = node.kind == :anchor_start && position.zero?
      at_end = node.kind == :anchor_end && position == characters.length

      at_start || at_end ? [position] : []
    end
  end
end
