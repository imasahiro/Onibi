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
                (normalized.start_with?("In") && BLOCK_LOOKUP.key?(normalized.delete_prefix("In")))

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
      return normalized if normalized.start_with?("In") && BLOCK_LOOKUP.key?(normalized.delete_prefix("In"))

      normalized
    end

    # MRI maps normalized property names to generated ctype entries.
    # The range table is the single source for block names in this VM.
    BLOCK_LOOKUP = UNICODE_BLOCK_RANGES.each_key.to_h { |name| [name, true] }.freeze
  end
end
