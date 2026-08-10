# frozen_string_literal: true

module Onibi
  # Correctness fallback for ASTs that cannot complete through bytecode dispatch.
  class AstMatcher
    include AstMatcherDispatch
    include AstMatcherOptionGroups

    def initialize(ast, options = [])
      @ast = ast
      @ignorecase = options.include?("ignorecase")
      @multiline = options.include?("multiline")
    end

    def match?(input, start_position = 0)
      !match_span(input, start_position).nil?
    end

    def match_span(input, start_position = 0)
      characters = input.chars

      (start_position..characters.length).each do |start|
        finish = match_positions(@ast, characters, start).max
        return [start, finish] if finish
      end

      nil
    end

    private

    def match_positions(node, characters, position)
      matcher = NODE_MATCHERS[node.class]
      return [] unless matcher

      send(matcher, node, characters, position)
    end

    def sequence_positions(parts, characters, position)
      parts.reduce([position]) do |positions, part|
        positions.flat_map { |current| match_positions(part, characters, current) }
      end
    end

    def quantifier_positions(node, characters, position)
      positions = [position]
      maximum = node.maximum || characters.length + 1
      maximum.times do
        next_positions = quantifier_step(node, characters, positions)
        break if next_positions.empty? || next_positions == positions

        positions.concat(next_positions).uniq!
      end
      results = positions.select { |current| current >= position + node.minimum }
      node.mode == :possessive ? [results.max].compact : results
    end

    def quantifier_step(node, characters, positions)
      positions.flat_map { |current| match_positions(node.expression, characters, current) }.uniq
    end

    def literal_positions(node, characters, position)
      value = node.value.chars

      expected = @ignorecase ? value.map(&:downcase) : value
      actual = characters[position, value.length]
      actual = actual.map(&:downcase) if @ignorecase

      actual == expected ? [position + value.length] : []
    end

    def class_positions(node, characters, position)
      return [] unless position < characters.length
      return [] unless class_matches?(node.value, characters[position])

      [position + 1]
    end

    def class_matches?(source, character)
      ClassPredicates.matches?(source, character)
    end

    def escape_positions(node, characters, position)
      return zero_width_positions(node.kind, characters, position) if zero_width_escape?(node.kind)
      return linebreak_positions(characters, position) if node.kind == :linebreak
      return [] unless position < characters.length
      return [] unless escape_matches?(node.kind, characters[position])

      [position + 1]
    end

    def property_positions(node, characters, position)
      return [] unless position < characters.length

      character = characters[position].encode(Encoding::UTF_8)
      matched = UnicodeProperties.matches?(node.name, character) ^ node.negated
      matched ? [position + 1] : []
    end

    def escape_matches?(kind, character)
      CharacterPredicates.escape_matches?(kind, character)
    end

    def zero_width_escape?(kind)
      %i[word_boundary not_word_boundary start_match].include?(kind)
    end

    def zero_width_positions(kind, characters, position)
      matches = CharacterPredicates.word_boundary?(characters, position)
      matches = !matches if kind == :not_word_boundary
      matches = position.zero? if kind == :start_match
      matches ? [position] : []
    end

    def linebreak_positions(characters, position)
      return [] unless position < characters.length && CharacterPredicates.linebreak?(characters[position])
      return [position + 2] if characters[position, 2] == ["\r", "\n"]

      [position + 1]
    end

    def anchor_positions(node, characters, position)
      at_start = node.kind == :anchor_start && line_start?(characters, position)
      at_end = node.kind == :anchor_end && line_end?(characters, position)

      at_start || at_end ? [position] : []
    end

    def line_start?(characters, position)
      position.zero? || characters[position - 1] == "\n"
    end

    def line_end?(characters, position)
      position == characters.length || characters[position] == "\n"
    end
  end
end
