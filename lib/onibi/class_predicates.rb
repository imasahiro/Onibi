# frozen_string_literal: true

module Onibi
  # Evaluates character class source without delegating to another regexp engine.
  module ClassPredicates
    module_function

    def matches?(source, character, ignorecase: false, encoding: nil)
      return match_source(source, character, ignorecase, encoding) if non_utf8_encoding?(encoding)

      compiled(source, ignorecase: ignorecase).matches?(character)
    end

    def match_source(source, character, ignorecase, encoding = nil)
      negated = source.start_with?("^")
      body = negated ? source[1..] : source
      posix = POSIX_PROPERTIES[body]
      if posix
        result = posix_matches?(posix, character, ignorecase, encoding)
        return negated if result == :incompatible

        return negated ? !result : result
      end

      intersection = split_intersection(body)
      if intersection
        result = intersection_matches?(intersection, character, ignorecase, encoding)
        return negated if result == :incompatible

        return negated ? !result : result
      end

      result = union_matches?(body, character, ignorecase, encoding)
      return negated if result == :incompatible

      negated ? !result : result
    end

    def posix_matches?(property, character, ignorecase, encoding)
      return :incompatible if incompatible_property?(property, character, encoding)

      return true if property == "Word" && encoding && encoding != Encoding::UTF_8 && encoding != Encoding::ASCII_8BIT && !character.ascii_only?

      normalized_character = if property == "Word" && encoding && encoding != Encoding::UTF_8 &&
                                encoding != Encoding::ASCII_8BIT
                               character.encode(Encoding::UTF_8)
                             else
                               character
                             end
      return true if UnicodeProperties.matches_normalized?(property, normalized_character)
      return false unless ignorecase && %w[Lower Upper].include?(property)

      UnicodeProperties.casefold_matches?(property, normalized_character)
    rescue EncodingError
      false
    end

    def intersection_matches?(intersection, character, ignorecase, encoding)
      left = matches?(intersection[0], character, ignorecase: ignorecase, encoding: encoding)
      right = matches?(intersection[1], character, ignorecase: ignorecase, encoding: encoding)
      return :incompatible if left == :incompatible || right == :incompatible

      left && right
    end

    def split_intersection(source)
      depth = 0
      escaped = false
      source.each_char.with_index do |character, index|
        return [source[0...index], source[(index + 2)..]] if intersection_marker?(source, character, index, depth, escaped)

        depth, escaped = intersection_state(character, depth, escaped)
      end

      nil
    end

    def union_matches?(source, character, ignorecase, encoding)
      index = 0
      incompatible = false
      while index < source.length
        first, index = atom(source, index)
        return true if range_matches?(source, index, first, character, ignorecase: ignorecase)

        result = atom_matches?(first, character, ignorecase, encoding)
        return true if result == true

        incompatible = true if result == :incompatible

        index = range_end(source, index, first)
      end

      incompatible ? :incompatible : false
    end

    def atom(source, index)
      return nested_atom(source, index) if source[index] == "["
      return escaped_atom(source, index) if source[index] == "\\"

      literal_atom(source, index)
    end

    def nested_atom(source, index)
      ending = nested_end(source, index)
      value = source[(index + 1)...ending]
      value = "[#{value}]" if source[index, 2] == "[:"
      [[:nested, value], ending + 1]
    end

    def escaped_atom(source, index)
      property, ending = property_escape(source, index)
      return [property, ending] if property

      decoded, ending = literal_escape(source, index)
      return [[:literal, decoded], ending] if decoded

      [[:escaped, source[index + 1]], index + 2]
    end

    def literal_atom(source, index)
      [[:literal, source[index]], index + 1]
    end

    def nested_end(source, index)
      if source[index, 2] == "[:"
        closing = source.index(":]", index + 2)
        return closing + 1 if closing
      end

      depth = 1
      cursor = index + 1
      loop do
        depth, cursor = nested_state(source[cursor], depth, cursor)
        break unless depth.positive?
      end
      cursor - 1
    end

    def intersection_marker?(source, character, index, depth, escaped)
      !escaped && depth.zero? && character == "&" && source[index, 2] == "&&"
    end

    def intersection_state(character, depth, escaped)
      return [depth, false] if escaped
      return [depth, true] if character == "\\"
      return [depth + 1, false] if character == "["
      return [depth - 1, false] if character == "]"

      [depth, false]
    end

    def range_matches?(source, index, first, character, ignorecase: false)
      return false unless source[index] == "-" && index + 1 < source.length

      last, = atom(source, index + 1)
      return false unless literal?(first) && literal?(last)

      return true if character.between?(first[1], last[1])
      return false unless ignorecase

      folded = character.downcase(:fold)
      return false unless folded.each_char.one?

      folded.between?(first[1].downcase(:fold), last[1].downcase(:fold))
    end

    def range_end(source, index, first)
      return index unless source[index] == "-" && index + 1 < source.length

      _last, after_last = atom(source, index + 1)
      literal?(first) ? after_last : index
    end

    def nested_state(character, depth, cursor)
      return [depth, cursor + 2] if character == "\\"
      return [depth + 1, cursor + 1] if character == "["
      return [depth - 1, cursor + 1] if character == "]"

      [depth, cursor + 1]
    end

    def atom_matches?(atom, character, ignorecase, encoding)
      kind, value = atom
      return ignorecase ? value.casecmp?(character) : value == character if kind == :literal
      return matches?(value, character, ignorecase: ignorecase, encoding: encoding) if kind == :nested

      if kind == :property
        name, negated = value
        return true if ignorecase && negated && %w[Lower Upper Ll Lu Lt].include?(name)

        return property_matches?(value, character, ignorecase: ignorecase, encoding: encoding)
      end

      escaped_matches?(value, character)
    end

    def property_matches?(property, character, ignorecase: false, encoding: nil)
      name, negated = property
      name = UnicodeProperties.normalize_name(name)
      if incompatible_property?(name, character, encoding)
        return negated ? true : :incompatible
      end

      matched = UnicodeProperties.matches_normalized?(name, character)
      matched = casefold_property_match?(name, character) if ignorecase && !negated && !matched
      negated ? !matched : matched
    end

    def casefold_property_match?(name, character)
      UnicodeProperties.casefold_matches?(name, character)
    end

    def incompatible_property?(name, character, encoding)
      non_utf8_encoding?(encoding) &&
        (%w[ASCII Alpha Alnum Digit Lower Upper Space XDigit Blank Cntrl Graph Print Punct].include?(name) ||
         (name == "Word" && encoding == Encoding::ASCII_8BIT)) &&
        !character.ascii_only?
    end

    def non_utf8_encoding?(encoding)
      [Encoding::ASCII_8BIT, Encoding::EUC_JP, Encoding::Windows_31J].include?(encoding)
    end

    def property_escape(source, index)
      kind = source[index + 1]
      return [nil, nil] unless %w[p P].include?(kind) && source[index + 2] == "{"

      ending = source.index("}", index + 3)
      raise RegexpError, "invalid Unicode property" unless ending

      name = source[(index + 3)...ending]
      name, negated = property_name_and_polarity(name, kind)
      UnicodeProperties.validate!(name)
      [[:property, [name, negated]], ending + 1]
    end

    def property_name_and_polarity(name, kind)
      negated = kind == "P"
      return [name, negated] unless name.start_with?("^")

      [name[1..], !negated]
    end

    def escaped_matches?(value, character)
      return value == character unless %w[d D s S w W h H].include?(value)

      CharacterPredicates.escape_matches?(escape_kind(value), character)
    end

    def literal_escape(source, index)
      escaped = source[index + 1]
      return named_character_escape(source, index) if escaped == "N"

      simple = { "a" => "\a", "e" => "\e", "f" => "\f", "n" => "\n", "r" => "\r", "t" => "\t", "v" => "\v" }[escaped]
      return [simple, index + 2] if simple
      return decode_control_escape(source, index) if %w[c C].include?(escaped)
      return decode_meta_escape(source, index) if escaped == "M"
      return decode_hex_escape(source, index) if escaped == "x"
      return decode_unicode_escape(source, index) if escaped == "u"

      [nil, nil]
    end

    def named_character_escape(source, index)
      ending = source.index("}", index + 3)
      raise RegexpError, "invalid Unicode character name" unless ending

      [source[index + 1], index + 2]
    end

    def decode_control_escape(source, index)
      character_index = source[index + 1] == "C" && source[index + 2] == "-" ? index + 3 : index + 2
      character = source[character_index]
      raise RegexpError, "invalid control escape" unless character

      [(character.ord & 0x1f).chr(source.encoding), character_index + 1]
    end

    def decode_meta_escape(source, index)
      raise RegexpError, "invalid meta escape" unless source[index + 2] == "-"

      character, ending = meta_escape_character(source, index + 3)
      raise RegexpError, "invalid meta escape" unless character

      [(character.ord | 0x80).chr(source.encoding), ending]
    rescue EncodingError
      raise RegexpError, "invalid meta escape"
    end

    def meta_escape_character(source, index)
      return [source[index], index + 1] unless source[index] == "\\"

      escaped = source[index + 1]
      return meta_control_character(source, index) if escaped == "C"
      return meta_hex_character(source, index) if escaped == "x"

      [nil, nil]
    end

    def meta_control_character(source, index)
      character_index = source[index + 2] == "-" ? index + 3 : index + 2
      character = source[character_index]
      return [nil, nil] unless character

      [(character.ord & 0x1f).chr, character_index + 1]
    end

    def meta_hex_character(source, index)
      digits = source[(index + 2), 2]
      return [nil, nil] unless hex_sequence?(digits, 2)

      [digits.to_i(16).chr, index + 4]
    end

    def decode_hex_escape(source, index)
      cursor = index + 2
      digits = +""
      while digits.length < 2 && hex_digit?(source[cursor])
        digits << source[cursor]
        cursor += 1
      end
      raise RegexpError, "invalid hex escape" if digits.empty?

      [digits.to_i(16).chr(source.encoding), cursor]
    end

    def decode_unicode_escape(source, index)
      return unicode_codepoint_escape(source, index) if source[index + 2] == "{"

      unicode_character_escape(source, index)
    rescue RangeError, EncodingError
      raise RegexpError, "invalid Unicode escape"
    end

    def unicode_codepoint_escape(source, index)
      ending = source.index("}", index + 3)
      raise RegexpError, "invalid Unicode escape" unless ending

      values = source[(index + 3)...ending].split.map { |digits| unicode_codepoint(digits) }
      raise RegexpError, "invalid Unicode escape" if values.empty?

      [values.map { |value| value.chr(source.encoding) }.join, ending + 1]
    end

    def unicode_character_escape(source, index)
      digits = source[(index + 2), 4]
      raise RegexpError, "invalid Unicode escape" unless hex_sequence?(digits, 4)

      [digits.to_i(16).chr(source.encoding), index + 6]
    end

    def unicode_codepoint(digits)
      unless digits&.length&.between?(1, 6) && digits.each_char.all? { |digit| hex_digit?(digit) }
        raise RegexpError,
              "invalid Unicode escape"
      end

      digits.to_i(16)
    end

    def hex_digit?(character)
      character&.match?(/[0-9a-f]/i)
    end

    def hex_sequence?(digits, length)
      digits && digits.length == length && digits.each_char.all? { |digit| hex_digit?(digit) }
    end

    def escape_kind(value)
      {
        "d" => :digit, "D" => :not_digit, "s" => :space, "S" => :not_space,
        "w" => :word, "W" => :not_word, "h" => :horizontal_space, "H" => :not_horizontal_space
      }.fetch(value)
    end

    def literal?(atom)
      atom[0] == :literal
    end
  end
end
