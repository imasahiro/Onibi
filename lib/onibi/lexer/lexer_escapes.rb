# frozen_string_literal: true

module Onibi
  # Dispatches escape sequences that have dedicated lexer tokenizers.
  module LexerEscapes
    private

    def character_escape_token(index, escaped)
      return hex_escape_token(index) if escaped == "x"
      return unicode_escape_token(index) if escaped == "u"
      return named_character_token(index) if escaped == "N"
      return control_escape_token(index, escaped) if %w[c C].include?(escaped)
      return meta_escape_token(index) if escaped == "M"

      nil
    end

    def named_character_token(index)
      ending = @source.index("}", index + 3)
      return [Lexer::Token.new(:literal, "N", index), index + 2] unless ending

      value = @source[(index + 1)..ending]
      [Lexer::Token.new(:literal, value, index), ending + 1]
    end

    def meta_escape_token(index)
      raise RegexpError, "invalid meta escape" unless @source[index + 2] == "-"

      character, ending = meta_escape_character(index + 3)
      raise RegexpError, "invalid meta escape" unless character

      value = [character.ord | 0x80].pack("C").force_encoding(@source.encoding)
      raise RegexpError, "invalid meta escape" unless value.valid_encoding?

      [Lexer::Token.new(:literal, value, index), ending]
    rescue EncodingError
      raise RegexpError, "invalid meta escape"
    end

    def meta_escape_character(index)
      return [@source[index], index + 1] unless @source[index] == "\\"

      escaped = @source[index + 1]
      return meta_control_character(index) if escaped == "C"
      return meta_hex_character(index) if escaped == "x"

      nil
    end

    def meta_control_character(index)
      return unless @source[index + 2] == "-" && @source[index + 3]

      [(@source[index + 3].ord & 0x1f).chr, index + 4]
    end

    def meta_hex_character(index)
      digits = @source[(index + 2), 2]
      return unless hex_sequence?(digits, 2)

      [digits.to_i(16).chr, index + 4]
    end

    def control_escape_token(index, escaped)
      character_index = escaped == "C" && @source[index + 2] == "-" ? index + 3 : index + 2
      character = @source[character_index]
      raise RegexpError, "invalid control escape" unless character && character.length == 1

      ending = character_index + 1
      [Lexer::Token.new(:literal, (character.ord & 0x1f).chr(@source.encoding), index), ending]
    end

    def hex_escape_token(index)
      cursor = index + 2
      digits = +""
      while digits.length < 2 && hex_digit?(@source[cursor])
        digits << @source[cursor]
        cursor += 1
      end
      raise RegexpError, "invalid hex escape" if digits.empty?

      codepoint = digits.to_i(16)
      [Lexer::Token.new(:literal, escaped_byte(codepoint), index), cursor]
    end

    def unicode_escape_token(index)
      return unicode_codepoint_token(index) if @source[index + 2] == "{"

      unicode_character_token(index)
    end

    def unicode_codepoint_token(index)
      ending = @source.index("}", index + 3)
      raise RegexpError, "invalid Unicode escape" unless ending

      values = @source[(index + 3)...ending].split.map { |digits| codepoint_character(unicode_codepoint(digits)) }
      raise RegexpError, "invalid Unicode escape" if values.empty?

      [Lexer::Token.new(:literal, values.join, index), ending + 1]
    end

    def unicode_character_token(index)
      digits = @source[(index + 2), 4]
      raise RegexpError, "invalid Unicode escape" unless hex_sequence?(digits, 4)

      [Lexer::Token.new(:literal, codepoint_character(digits.to_i(16)), index), index + 6]
    end

    def unicode_codepoint(digits)
      unless digits&.length&.between?(1, 6) && digits.each_char.all? { |digit| hex_digit?(digit) }
        raise RegexpError,
              "invalid Unicode escape"
      end

      digits.to_i(16)
    end

    def codepoint_character(codepoint)
      encoding = codepoint > 0x7f ? Encoding::UTF_8 : escape_encoding
      codepoint.chr(encoding)
    rescue RangeError, EncodingError
      raise RegexpError, "invalid Unicode escape"
    end

    def hex_digit?(character)
      character&.match?(/[0-9a-f]/i)
    end

    def hex_sequence?(digits, length)
      digits && digits.length == length && digits.each_char.all? { |digit| hex_digit?(digit) }
    end

    def escape_encoding
      @noencoding ? Encoding::ASCII_8BIT : @source.encoding
    end

    def escaped_byte(codepoint)
      encoding = escape_encoding
      encoding = Encoding::ASCII_8BIT if codepoint > 0x7f && encoding == Encoding::US_ASCII
      raise RegexpError, "invalid multibyte escape" if codepoint > 0x7f &&
                                                       [Encoding::UTF_8, Encoding::EUC_JP].include?(encoding)

      codepoint.chr(encoding)
    rescue RangeError, EncodingError
      raise RegexpError, "invalid multibyte escape"
    end

    def special_escape_token(index, escaped)
      return backreference_token(index) if digit_escape?(escaped) ||
                                           (escaped == "k" && @source[index + 2] == "<")
      return subexpression_token(index) if escaped == "g" && @source[index + 2] == "<"

      property_token(index) if %w[p P].include?(escaped) && @source[index + 2] == "{"
    end

    def escaped_type_token(type, escaped, index)
      token_type = type || :literal
      [Lexer::Token.new(token_type, escaped, index), index + 2]
    end
  end
end
