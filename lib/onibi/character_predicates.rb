# frozen_string_literal: true

module Onibi
  # Matches Core MVP character classes without delegating to MRI Regexp.
  module CharacterPredicates
    ASCII_WHITESPACE = [9, 10, 11, 12, 13, 32].freeze
    ESCAPE_PREDICATES = {
      digit: ->(character) { character >= "0" && character <= "9" },
      not_digit: ->(character) { character < "0" || character > "9" },
      space: ->(character) { whitespace?(character) },
      not_space: ->(character) { !whitespace?(character) },
      word: ->(character) { word?(character) },
      not_word: ->(character) { !word?(character) },
      horizontal_space: ->(character) { horizontal_whitespace?(character) },
      not_horizontal_space: ->(character) { !horizontal_whitespace?(character) }
    }.freeze

    module_function

    def whitespace?(character)
      ASCII_WHITESPACE.include?(codepoint(character))
    end

    def word?(character)
      value = codepoint(character)
      value == 95 || value.between?(48, 57) || value.between?(65, 90) || value.between?(97, 122)
    end

    def horizontal_whitespace?(character)
      [9, 32].include?(codepoint(character))
    end

    def linebreak?(character)
      [10, 11, 12, 13, 133, 8232, 8233].include?(codepoint(character))
    end

    def word_boundary?(characters, position)
      before = position.positive? && word?(characters[position - 1])
      after = position < characters.length && word?(characters[position])
      before != after
    end

    def codepoint(character)
      character.is_a?(Integer) ? character : character.codepoints.first
    end

    def escape_matches?(kind, character)
      ESCAPE_PREDICATES.fetch(kind).call(character)
    end
  end
end
