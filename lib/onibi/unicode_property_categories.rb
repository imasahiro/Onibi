# frozen_string_literal: true

module Onibi
  # Matches Unicode general categories and POSIX-compatible categories.
  module UnicodePropertyCategories
    UNCASED_LETTER_RANGES = [
      (0x3040..0x30FF), # Hiragana and Katakana
      (0x3400..0x4DBF), # CJK Unified Ideographs Extension A
      (0x4E00..0x9FFF), # CJK Unified Ideographs
      (0xAC00..0xD7AF)  # Hangul syllables
    ].freeze

    def letter?(character)
      character.downcase != character.upcase || uncased_letter?(character)
    end

    def uncased_letter?(character)
      UNCASED_LETTER_RANGES.any? { |range| range.cover?(character.codepoints.first) }
    end

    def digit?(character)
      codepoint = character.codepoints.first
      CharacterPredicates.escape_matches?(:digit, character) || codepoint.between?(0x660, 0x669)
    end

    def xdigit?(character)
      codepoint = character.downcase.codepoints.first
      digit?(character) || codepoint.between?("a".ord, "f".ord)
    end

    def alnum?(character)
      letter?(character) || digit?(character)
    end

    def lower?(character)
      caseable_letter?(character) && character == character.downcase
    end

    def upper?(character)
      caseable_letter?(character) && character == character.upcase
    end

    def caseable_letter?(character)
      letter?(character) && character.downcase != character.upcase
    end

    def space?(character)
      CharacterPredicates.whitespace?(character)
    end

    def word?(character)
      CharacterPredicates.word?(character) || letter?(character)
    end

    def blank?(character)
      CharacterPredicates.horizontal_whitespace?(character)
    end

    def cntrl?(character)
      character.codepoints.first < 32 || character.codepoints.first == 127
    end

    def graph?(character)
      !space?(character) && !cntrl?(character)
    end

    def print?(character)
      !cntrl?(character)
    end

    def punct?(character)
      codepoint = character.codepoints.first
      codepoint.between?(33, 47) || codepoint.between?(58, 64) ||
        codepoint.between?(91, 96) || codepoint.between?(123, 126)
    end
  end
end
