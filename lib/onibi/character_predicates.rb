# frozen_string_literal: true

module Onibi
  # Matches Core MVP character classes without delegating to MRI Regexp.
  module CharacterPredicates
    ASCII_WHITESPACE = [9, 10, 11, 12, 13, 32].freeze

    module_function

    def whitespace?(character)
      ASCII_WHITESPACE.include?(codepoint(character))
    end

    def word?(character)
      value = codepoint(character)
      value == 95 || value.between?(48, 57) || value.between?(65, 90) || value.between?(97, 122)
    end

    def codepoint(character)
      character.is_a?(Integer) ? character : character.codepoints.first
    end
  end
end
