# frozen_string_literal: true

module Onibi
  # Matches Core MVP character classes without delegating to MRI Regexp.
  module CharacterPredicates
    UNICODE_WHITESPACE = [9, 10, 11, 12, 13, 32, 0x85, 0xA0, 0x1680, 0x2028,
                          0x2029, 0x202F, 0x205F, 0x3000].freeze
    ESCAPE_PREDICATES = {
      digit: ->(character) { codepoint(character).between?(48, 57) },
      not_digit: ->(character) { !codepoint(character).between?(48, 57) },
      space: ->(character) { whitespace?(character) },
      not_space: ->(character) { !whitespace?(character) },
      word: ->(character) { word?(character) },
      not_word: ->(character) { !word?(character) },
      horizontal_space: ->(character) { hex_digit?(character) },
      not_horizontal_space: ->(character) { !hex_digit?(character) }
    }.freeze

    module_function

    def whitespace?(character)
      value = codepoint(character)
      UNICODE_WHITESPACE.include?(value) || value.between?(0x2000, 0x200A)
    end

    def word?(character)
      value = codepoint(character)
      value == 95 || value.between?(48, 57) || value.between?(65, 90) || value.between?(97, 122)
    end

    def horizontal_whitespace?(character)
      value = codepoint(character)
      value == 9 || value == 32 || value == 0xA0 || value == 0x1680 ||
        value.between?(0x2000, 0x200A) || value == 0x202F || value == 0x205F || value == 0x3000
    end

    def hex_digit?(character)
      value = codepoint(character)
      value.between?(48, 57) || value.between?(65, 70) || value.between?(97, 102)
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

    def escape_matches?(kind, character, encoding: nil)
      return false if encoding == Encoding::ASCII_8BIT && !character.ascii_only? && kind == :space

      ESCAPE_PREDICATES.fetch(kind).call(character)
    end
  end
end
