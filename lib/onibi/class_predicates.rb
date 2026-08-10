# frozen_string_literal: true

module Onibi
  # Evaluates character class source without delegating to another regexp engine.
  module ClassPredicates
    module_function

    def matches?(source, character, ignorecase: false)
      character = character.chr(source.encoding) if character.is_a?(Integer)
      posix = POSIX_PROPERTIES[source]
      return UnicodeProperties.matches?(posix, character) if posix

      intersection = split_intersection(source)
      return intersection_matches?(intersection, character, ignorecase) if intersection

      negated = source.start_with?("^")
      content = negated ? source[1..] : source
      result = union_matches?(content, character, ignorecase)
      negated ? !result : result
    end

    def intersection_matches?(intersection, character, ignorecase)
      left = matches?(intersection[0], character, ignorecase: ignorecase)
      right = matches?(intersection[1], character, ignorecase: ignorecase)
      left && right
    end

    def split_intersection(source)
      depth = 0
      escaped = false
      source.each_char.with_index do |character, index|
        if intersection_marker?(source, character, index, depth, escaped)
          return [source[0...index], source[(index + 2)..]]
        end

        depth, escaped = intersection_state(character, depth, escaped)
      end

      nil
    end

    def union_matches?(source, character, ignorecase)
      index = 0
      while index < source.length
        first, index = atom(source, index)
        return true if range_matches?(source, index, first, character)
        return true if atom_matches?(first, character, ignorecase)

        index = range_end(source, index, first)
      end

      false
    end

    def atom(source, index)
      if source[index] == "["
        ending = nested_end(source, index)
        return [[:nested, source[(index + 1)...ending]], ending + 1]
      end
      if source[index] == "\\"
        decoded, ending = literal_escape(source, index)
        return [[:literal, decoded], ending] if decoded

        return [[:escaped, source[index + 1]], index + 2]
      end

      [[:literal, source[index]], index + 1]
    end

    def nested_end(source, index)
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

    def range_matches?(source, index, first, character)
      return false unless source[index] == "-" && index + 1 < source.length

      last, = atom(source, index + 1)
      literal?(first) && literal?(last) && character.between?(first[1], last[1])
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

    def atom_matches?(atom, character, ignorecase)
      kind, value = atom
      return ignorecase ? value.casecmp?(character) : value == character if kind == :literal
      return matches?(value, character, ignorecase: ignorecase) if kind == :nested

      escaped_matches?(value, character)
    end

    def escaped_matches?(value, character)
      return value == character unless %w[d D s S w W h H].include?(value)

      CharacterPredicates.escape_matches?(escape_kind(value), character)
    end

    def literal_escape(source, index)
      escaped = source[index + 1]
      simple = {"a" => "\a", "e" => "\e", "f" => "\f", "n" => "\n", "r" => "\r", "t" => "\t", "v" => "\v"}[escaped]
      return [simple, index + 2] if simple
      return decode_hex_escape(source, index) if escaped == "x"
      return decode_unicode_escape(source, index) if escaped == "u"

      [nil, nil]
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
      if source[index + 2] == "{"
        ending = source.index("}", index + 3)
        raise RegexpError, "invalid Unicode escape" unless ending

        values = source[(index + 3)...ending].split.map { |digits| unicode_codepoint(digits) }
        raise RegexpError, "invalid Unicode escape" if values.empty?

        return [values.map { |value| value.chr(source.encoding) }.join, ending + 1]
      end

      digits = source[(index + 2), 4]
      raise RegexpError, "invalid Unicode escape" unless digits && digits.length == 4 && digits.each_char.all? { |digit| hex_digit?(digit) }

      [digits.to_i(16).chr(source.encoding), index + 6]
    rescue RangeError, EncodingError
      raise RegexpError, "invalid Unicode escape"
    end

    def unicode_codepoint(digits)
      raise RegexpError, "invalid Unicode escape" if digits.empty? || digits.length > 6 || !digits.each_char.all? { |digit| hex_digit?(digit) }

      digits.to_i(16)
    end

    def hex_digit?(character)
      character && (character >= "0" && character <= "9" || character >= "a" && character <= "f" || character >= "A" && character <= "F")
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
