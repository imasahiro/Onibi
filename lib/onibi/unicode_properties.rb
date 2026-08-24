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
    ASCII_ENCODING_PROPERTIES = %w[
      ASCII Alpha Alnum Digit Lower Upper Space Word XDigit Blank Cntrl Graph Print Punct
    ].freeze
    NON_UTF8_ENCODING_PROPERTIES = %w[
      ASCII Han Hiragana Katakana Latin Greek Cyrillic Alpha Alnum Digit Lower Upper Space Word XDigit Blank
      Cntrl Graph Print Punct
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
      "L" => :letter?, "Lu" => :uppercase?, "Ll" => :lowercase?, "Lt" => :titlecase?,
      "Lm" => :modifier_letter?, "Lo" => :other_letter?, "M" => :mark?, "Mark" => :mark?,
      "N" => :number?, "P" => :punct?, "S" => :symbol?, "Symbol" => :symbol?,
      "Z" => :separator?, "Separator" => :separator?, "C" => :other?, "Cn" => :unassigned?,
      "Other" => :other?
    }.freeze

    def validate!(name)
      normalized = normalize_name(name)
      return if SUPPORTED.include?(normalized) ||
                (normalized.start_with?("In") && BLOCK_LOOKUP.key?(normalized.delete_prefix("In")))

      raise RegexpError, "unknown Unicode property #{name}"
    end

    def valid_for_encoding?(name, encoding)
      normalized = normalize_name(name)
      return ASCII_ENCODING_PROPERTIES.include?(normalized) if encoding == Encoding::US_ASCII
      return NON_UTF8_ENCODING_PROPERTIES.include?(normalized) if [Encoding::EUC_JP, Encoding::Windows_31J].include?(encoding)

      true
    end

    def matches?(name, character)
      normalized = normalize_name(name)
      validate!(name)

      return block?(normalized.delete_prefix("In"), character) if normalized.start_with?("In")

      send(PROPERTY_MATCHERS.fetch(normalized), character)
    end

    # MRI applies simple casefold closure before it evaluates Ll, Lu, and Lt.
    # Keep the closure here so every bytecode property operand uses one rule.
    def casefold_matches?(name, character)
      return true if matches?(name, character)

      variants = [character.downcase, character.upcase, character.capitalize]
      return true if variants.any? do |variant|
        variant.length == 1 && character.casecmp?(variant) && matches?(name, variant)
      end

      return false unless %w[Lower Upper Ll Lu Lt].include?(name)

      # These two Unicode mappings are multi-stage casefold closures in MRI.
      return true if name == "Ll" && character == "\u0345"
      return true if %w[Lu Upper].include?(name) && character == "\u00DF"

      false
    end

    def normalize_name(name)
      normalized = name.sub("^", "")
      return normalized if normalized.start_with?("In") && BLOCK_LOOKUP.key?(normalized.delete_prefix("In"))

      normalized
    end

    # MRI maps normalized property names to generated ctype entries.
    # The range table is the single source for block names in this VM.
    BLOCK_LOOKUP = UNICODE_BLOCK_RANGES.each_key.to_h { |name| [name, true] }.freeze
  end
end
