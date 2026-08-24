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
      ASCII Any Bidi_Control Case_Ignorable Default_Ignorable_Code_Point Deprecated Diacritic Emoji Emoji_Component
      Emoji_Presentation Emoji_Modifier Join_Control Noncharacter_Code_Point Pattern_White_Space Quotation_Mark
      Cased Extender ID_Compat_Math_Continue ID_Compat_Math_Start Ideographic Math Prepended_Concatenation_Mark Regional_Indicator Sentence_Terminal Soft_Dotted
      Terminal_Punctuation Unified_Ideograph Variation_Selector
      Emoji_Modifier_Base Extended_Pictographic Han Hiragana Katakana Latin Greek Cyrillic Arabic
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
      "ASCII" => :ascii?, "Any" => :any?, "Emoji" => :emoji?,
      "Bidi_Control" => :bidi_control?,
      "Case_Ignorable" => :case_ignorable?,
      "Default_Ignorable_Code_Point" => :default_ignorable?,
      "Deprecated" => :deprecated?,
      "Diacritic" => :diacritic?,
      "Emoji_Component" => :emoji_component?,
      "Join_Control" => :join_control?,
      "Regional_Indicator" => :regional_indicator?,
      "Variation_Selector" => :variation_selector?,
      "Noncharacter_Code_Point" => :noncharacter_code_point?,
      "Pattern_White_Space" => :pattern_white_space?,
      "Quotation_Mark" => :quotation_mark?,
      "Terminal_Punctuation" => :terminal_punctuation?,
      "Soft_Dotted" => :soft_dotted?,
      "Extender" => :extender?,
      "Math" => :math?,
      "Cased" => :cased?,
      "Sentence_Terminal" => :sentence_terminal?,
      "Prepended_Concatenation_Mark" => :prepended_concatenation_mark?,
      "Ideographic" => :ideographic?,
      "Unified_Ideograph" => :unified_ideograph?,
      "ID_Compat_Math_Start" => :id_compat_math_start?,
      "ID_Compat_Math_Continue" => :id_compat_math_continue?,
      "Emoji_Presentation" => :emoji_presentation?, "Emoji_Modifier" => :emoji_modifier?,
      "Emoji_Modifier_Base" => :emoji_modifier_base?,
      "Extended_Pictographic" => :extended_pictographic?,
      "Han" => :han?, "Hiragana" => :hiragana?,
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

    # Onigmo expands these Unicode case folds while it compiles a property
    # operand. Keep the code points in generated-table form, then derive the
    # short immutable sequences only for properties used by a bytecode program.
    MULTI_CHAR_CASEFOLD_CODEPOINTS = [
      223, 304, 329, 496, 912, 944, 1415, 7830, 7831, 7832, 7833, 7834, 7838,
      8016, 8018, 8020, 8022, 8064, 8065, 8066, 8067, 8068, 8069, 8070, 8071,
      8072, 8073, 8074, 8075, 8076, 8077, 8078, 8079, 8080, 8081, 8082, 8083,
      8084, 8085, 8086, 8087, 8088, 8089, 8090, 8091, 8092, 8093, 8094, 8095,
      8096, 8097, 8098, 8099, 8100, 8101, 8102, 8103, 8104, 8105, 8106, 8107,
      8108, 8109, 8110, 8111, 8114, 8115, 8116, 8118, 8119, 8124, 8130, 8131,
      8132, 8134, 8135, 8140, 8146, 8147, 8150, 8151, 8162, 8163, 8164, 8166,
      8167, 8178, 8179, 8180, 8182, 8183, 8188, 64_256, 64_257, 64_258, 64_259,
      64_260, 64_261, 64_262, 64_275, 64_276, 64_277, 64_278, 64_279
    ].freeze

    # Unicode Simple_Case_Folding has one compatibility code point that is
    # not reached by String#upcase/downcase from its ASCII base character.
    # Keep it in compiler-owned Unicode data so range operands can close over
    # the same reverse fold as MRI.
    REVERSE_SIMPLE_CASEFOLDS = {
      "k" => ["K"], "K" => ["K"], "K" => %w[k K]
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

      matches_normalized?(normalized, character)
    end

    # Compiler operands contain normalized, validated property names. This
    # path is the VM equivalent of MRI's generated ctype identifier lookup.
    def matches_normalized?(normalized, character)
      return block?(normalized.delete_prefix("In"), character) if normalized.start_with?("In")

      send(PROPERTY_MATCHERS.fetch(normalized), character)
    end

    # MRI applies simple casefold closure before it evaluates Ll, Lu, and Lt.
    # Keep the closure here so every bytecode property operand uses one rule.
    def casefold_matches?(name, character)
      normalized = normalize_name(name)
      validate!(name)
      return true if matches_normalized?(normalized, character)

      variants = [character.downcase, character.upcase, character.capitalize]
      return true if variants.any? do |variant|
        variant.length == 1 && character.casecmp?(variant) && matches_normalized?(normalized, variant)
      end

      return false unless %w[Lower Upper Ll Lu Lt].include?(normalized)

      # These two Unicode mappings are multi-stage casefold closures in MRI.
      return true if normalized == "Ll" && character == "\u0345"
      return true if %w[Lu Upper].include?(normalized) && character == "\u00DF"

      false
    end

    def casefold_sequences(name)
      normalized = normalize_name(name)
      @casefold_sequences ||= {}
      return @casefold_sequences[normalized] if @casefold_sequences.key?(normalized)

      sequences = MULTI_CHAR_CASEFOLD_CODEPOINTS.filter_map do |codepoint|
        source = [codepoint].pack("U")
        folded = source.downcase(:fold)
        [source, folded] if matches?(normalized, source)
      end
      @casefold_sequences[normalized] = sequences.freeze
    end

    def casefold_codepoints
      MULTI_CHAR_CASEFOLD_CODEPOINTS
    end

    def reverse_casefold_variants(character)
      REVERSE_SIMPLE_CASEFOLDS.fetch(character, EMPTY_ARRAY)
    end

    EMPTY_ARRAY = [].freeze

    def boundary_word?(character)
      matches?("Word", character) || [0xb2, 0xb3, 0xb9, 0xbc, 0xbd, 0xbe].include?(character.codepoints.first)
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
