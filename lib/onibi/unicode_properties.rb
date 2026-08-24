# frozen_string_literal: true

module Onibi
  # Implements the common Ruby Unicode and POSIX property names used by Onibi.
  module UnicodeProperties
    include UnicodePropertyScripts
    include UnicodePropertyCategories
    extend UnicodePropertyScripts
    extend UnicodePropertyCategories

    module_function

    SUPPORTED = %w[
      ASCII Any Han Hiragana Katakana Latin Greek Cyrillic Arabic
      Alpha Letter Alnum Digit Nd Number Lower Upper Space Word
      XDigit Hex_Digit Dash ASCII_Hex_Digit Assigned White_Space Blank Cntrl Graph Print Punct
      L Lu Ll Lt Lm Lo M N P S Z C Cn Mark
      Symbol Separator Other
    ].freeze
    PROPERTY_MATCHERS = {
      "ASCII" => :ascii?, "Any" => :any?, "Han" => :han?, "Hiragana" => :hiragana?,
      "Katakana" => :katakana?, "Latin" => :latin?, "Greek" => :greek?,
      "Cyrillic" => :cyrillic?, "Arabic" => :arabic?, "Alpha" => :alpha?,
      "Letter" => :letter?, "Alnum" => :alnum?, "Digit" => :digit?, "Nd" => :digit?,
      "Number" => :number?, "Lower" => :lower?, "Upper" => :upper?, "Space" => :space?,
      "Word" => :word?, "XDigit" => :xdigit?, "Blank" => :blank?, "Cntrl" => :cntrl?,
      "ASCII_Hex_Digit" => :xdigit?, "Hex_Digit" => :hex_digit?, "Dash" => :dash?,
      "Assigned" => :assigned?, "White_Space" => :space?,
      "Graph" => :graph?, "Print" => :print?, "Punct" => :punct?,
      "L" => :letter?, "Lu" => :upper?, "Ll" => :lower?, "Lt" => :titlecase?,
      "Lm" => :modifier_letter?, "Lo" => :other_letter?, "M" => :mark?, "Mark" => :mark?,
      "N" => :number?, "P" => :punct?, "S" => :symbol?, "Symbol" => :symbol?,
      "Z" => :separator?, "Separator" => :separator?, "C" => :other?, "Cn" => :unassigned?,
      "Other" => :other?
    }.freeze

    def validate!(name)
      normalized = normalize_name(name)
      return if SUPPORTED.include?(normalized) ||
                (normalized.start_with?("In") && BLOCKS.include?(normalized.delete_prefix("In")))

      raise RegexpError, "unknown Unicode property #{name}"
    end

    def matches?(name, character)
      normalized = normalize_name(name)
      validate!(name)

      return block?(normalized.delete_prefix("In"), character) if normalized.start_with?("In")

      send(PROPERTY_MATCHERS.fetch(normalized), character)
    end

    def normalize_name(name)
      normalized = name.sub("^", "")
      return normalized if normalized.start_with?("In") && BLOCKS.include?(normalized.delete_prefix("In"))

      normalized
    end

    BLOCKS = %w[
      Basic_Latin Latin_1_Supplement Latin_Extended_A Latin_Extended_B IPA_Extensions
      Spacing_Modifier_Letters Combining_Diacritical_Marks Greek_and_Coptic Cyrillic
      Armenian Hebrew Arabic Syriac Arabic_Supplement Devanagari Bengali Gurmukhi Gujarati
      Oriya Tamil Telugu Kannada Malayalam Thai Lao Tibetan Myanmar Georgian Hangul_Jamo
      Ethiopic Cherokee Canadian_Aboriginal Ogham Runic Khmer Mongolian Hiragana Katakana
      Bopomofo CJK_Unified_Ideographs Yi Hangul_Syllables CJK_Compatibility
      CJK_Compatibility_Forms Halfwidth_and_Fullwidth_Forms Emoticons Miscellaneous_Symbols Dingbats
      Mathematical_Operators Geometric_Shapes Letterlike_Symbols Currency_Symbols
      General_Punctuation CJK_Symbols_and_Punctuation Greek_Extended Latin_Extended_Additional
      Supplemental_Arrows_A
      Supplemental_Mathematical_Operators
      Transport_and_Map_Symbols
      Enclosed_Alphanumerics
      Enclosed_Alphanumeric_Supplement
      Mathematical_Alphanumeric_Symbols
      CJK_Compatibility_Ideographs
      CJK_Strokes
      Ideographic_Description_Characters
      CJK_Radicals_Supplement
      Katakana_Phonetic_Extensions
      Kana_Supplement
      CJK_Unified_Ideographs_Extension_A
      CJK_Unified_Ideographs_Extension_B
      CJK_Unified_Ideographs_Extension_C
      Arabic_Presentation_Forms_A
      Arabic_Presentation_Forms_B
    ].freeze
  end
end
