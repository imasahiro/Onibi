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

    DECIMAL_DIGIT_RANGES = [
      (0x660..0x669), (0x6F0..0x6F9), (0x966..0x96F), (0x9E6..0x9EF),
      (0xA66..0xA6F), (0xAE6..0xAEF), (0xB66..0xB6F), (0xBE6..0xBEF),
      (0xC66..0xC6F), (0xCE6..0xCEF), (0xD66..0xD6F), (0xDE6..0xDEF),
      (0xE50..0xE59), (0xED0..0xED9), (0xF20..0xF29), (0x1040..0x1049),
      (0x1090..0x1099), (0x17E0..0x17E9), (0x1810..0x1819), (0xFF10..0xFF19)
    ].freeze

    def letter?(character)
      !numeric_symbol?(character) && (character.downcase != character.upcase || uncased_letter?(character))
    end

    def uncased_letter?(character)
      UNCASED_LETTER_RANGES.any? { |range| range.cover?(character.codepoints.first) }
    end

    def digit?(character)
      codepoint = character.codepoints.first
      CharacterPredicates.escape_matches?(:digit, character) || DECIMAL_DIGIT_RANGES.any? { |range| range.cover?(codepoint) }
    end

    def xdigit?(character)
      codepoint = character.downcase.codepoints.first
      codepoint.between?("0".ord, "9".ord) || codepoint.between?("a".ord, "f".ord) ||
        codepoint.between?("A".ord, "F".ord)
    end

    def alnum?(character)
      letter?(character) || digit?(character) || numeric_symbol?(character)
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
      CharacterPredicates.word?(character) || letter?(character) || digit?(character) ||
        (0x300..0x36F).cover?(character.codepoints.first)
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
      !cntrl?(character) && (!space?(character) || character.codepoints.first == 32)
    end

    def punct?(character)
      codepoint = character.codepoints.first
      codepoint == 0xB7 || codepoint.between?(33, 47) || codepoint.between?(58, 64) ||
        codepoint.between?(91, 96) || codepoint.between?(123, 126) ||
        codepoint == 0x66A || codepoint.between?(0x2010, 0x2027) ||
        codepoint.between?(0x2030, 0x2043) || codepoint.between?(0x3001, 0x303F) ||
        codepoint.between?(0xFF01, 0xFF65)
    end

    def mark?(character)
      codepoint = character.codepoints.first
      (0x300..0x36F).cover?(codepoint) || (0x1AB0..0x1AFF).cover?(codepoint) ||
        (0x1DC0..0x1DFF).cover?(codepoint) || (0x20D0..0x20FF).cover?(codepoint) ||
        (0xFE20..0xFE2F).cover?(codepoint)
    end

    def symbol?(character)
      codepoint = character.codepoints.first
      [0xA9, 0xAE, 0x2116, 0x2122].include?(codepoint) ||
        (0x20A0..0x20CF).cover?(codepoint) || (0x2100..0x214F).cover?(codepoint) ||
        (0x2190..0x21FF).cover?(codepoint) || (0x2200..0x22FF).cover?(codepoint) ||
        (0x2300..0x23FF).cover?(codepoint) || (0x25A0..0x25FF).cover?(codepoint) ||
        (0x2600..0x27BF).cover?(codepoint) || (0x1F300..0x1FAFF).cover?(codepoint)
    end

    def separator?(character)
      space?(character)
    end

    def other?(character)
      !letter?(character) && !digit?(character) && !numeric_symbol?(character) && !mark?(character) && !space?(character) &&
        !punct?(character) && !symbol?(character)
    end

    def numeric_symbol?(character)
      codepoint = character.codepoints.first
      codepoint.between?(0xB2, 0xB3) || codepoint == 0xB9 || codepoint.between?(0xBC, 0xBD) ||
        codepoint.between?(0xBF0, 0xBF2) || codepoint.between?(0x2070, 0x2079) ||
        codepoint.between?(0x2080, 0x2089) || codepoint.between?(0x2150, 0x2182) ||
        codepoint.between?(0x2460, 0x249B) || codepoint.between?(0x2776, 0x2793)
    end

    def number?(character)
      digit?(character) || numeric_symbol?(character)
    end

    def titlecase?(character)
      [0x1C5, 0x1F2, 0x1F9, 0x01F2].include?(character.codepoints.first)
    end

    def modifier_letter?(character)
      codepoint = character.codepoints.first
      (0x2B0..0x2FF).cover?(codepoint) || (0xA700..0xA71F).cover?(codepoint)
    end

    def other_letter?(character)
      uncased_letter?(character)
    end
  end
end
