# frozen_string_literal: true

module Onibi
  # Matches leaf AST nodes while preserving capture state.
  module CaptureMatcherAtoms
    private

    def literal_results(node, characters, position, captures)
      value = node.value.chars
      expected = @ignorecase ? value.map(&:downcase) : value
      actual = characters[position, value.length]
      actual = actual.map(&:downcase) if @ignorecase && actual
      actual == expected ? [[position + value.length, captures]] : []
    end

    def class_results(node, characters, position, captures)
      return [] unless position < characters.length && class_matches?(node.value, characters[position])

      [[position + 1, captures]]
    end

    def class_matches?(source, character)
      negated = source.start_with?("^")
      content = source[(negated ? 1 : 0)..]
      matched = content.include?(character)
      matched ||= content.each_char.each_cons(3).any? do |first, hyphen, last|
        hyphen == "-" && character >= first && character <= last
      end

      negated ? !matched : matched
    end

    def escape_results(node, characters, position, captures)
      return [] unless position < characters.length && escape_matches?(node.kind, characters[position])

      [[position + 1, captures]]
    end

    def escape_matches?(kind, character)
      predicates = {
        digit: -> { character >= "0" && character <= "9" },
        space: -> { CharacterPredicates.whitespace?(character) },
        word: -> { CharacterPredicates.word?(character) }
      }
      predicates.fetch(kind).call
    end

    def any_results(_node, characters, position, captures)
      return [] unless position < characters.length
      return [] if !@multiline && characters[position] == "\n"

      [[position + 1, captures]]
    end

    def anchor_results(node, characters, position, captures)
      at_start = node.kind == :anchor_start && line_start?(characters, position)
      at_end = node.kind == :anchor_end && line_end?(characters, position)
      at_start || at_end ? [[position, captures]] : []
    end

    def line_start?(characters, position)
      position.zero? || (@multiline && characters[position - 1] == "\n")
    end

    def line_end?(characters, position)
      position == characters.length || (@multiline && characters[position] == "\n")
    end
  end
end
