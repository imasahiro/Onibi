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
      XDigit Blank Cntrl Graph Print Punct L Lu Ll Lt Lm Lo M N P S Z C Mark
      Symbol Separator Other
    ].freeze
    PROPERTY_MATCHERS = {
      "ASCII" => :ascii?, "Any" => :any?, "Han" => :han?, "Hiragana" => :hiragana?,
      "Katakana" => :katakana?, "Latin" => :latin?, "Greek" => :greek?,
      "Cyrillic" => :cyrillic?, "Arabic" => :arabic?, "Alpha" => :letter?,
      "Letter" => :letter?, "Alnum" => :alnum?, "Digit" => :digit?, "Nd" => :digit?,
      "Number" => :number?, "Lower" => :lower?, "Upper" => :upper?, "Space" => :space?,
      "Word" => :word?, "XDigit" => :xdigit?, "Blank" => :blank?, "Cntrl" => :cntrl?,
      "Graph" => :graph?, "Print" => :print?, "Punct" => :punct?,
      "L" => :letter?, "Lu" => :upper?, "Ll" => :lower?, "Lt" => :titlecase?,
      "Lm" => :modifier_letter?, "Lo" => :other_letter?, "M" => :mark?, "Mark" => :mark?,
      "N" => :number?, "P" => :punct?, "S" => :symbol?, "Symbol" => :symbol?,
      "Z" => :separator?, "Separator" => :separator?, "C" => :other?, "Other" => :other?
    }.freeze

    def validate!(name)
      normalized = name.sub("Is", "").sub("^", "")
      raise RegexpError, "unknown Unicode property #{name}" unless SUPPORTED.include?(normalized)
    end

    def matches?(name, character)
      normalized = name.sub("Is", "").sub("^", "")
      validate!(name)

      send(PROPERTY_MATCHERS.fetch(normalized), character)
    end
  end
end
