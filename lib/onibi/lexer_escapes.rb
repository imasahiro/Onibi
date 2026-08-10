# frozen_string_literal: true

module Onibi
  # Dispatches escape sequences that have dedicated lexer tokenizers.
  module LexerEscapes
    private

    def character_escape_token(index, escaped)
      return hex_escape_token(index) if escaped == "x"
      return unicode_escape_token(index) if escaped == "u"

      nil
    end

    def hex_escape_token(index)
      cursor = index + 2
      digits = +""
      while digits.length < 2 && hex_digit?(@source[cursor])
        digits << @source[cursor]
        cursor += 1
      end
      raise RegexpError, "invalid hex escape" if digits.empty?

      [Lexer::Token.new(:literal, codepoint_character(digits.to_i(16)), index), cursor]
    end

    def unicode_escape_token(index)
      if @source[index + 2] == "{"
        ending = @source.index("}", index + 3)
        raise RegexpError, "invalid Unicode escape" unless ending

        values = @source[(index + 3)...ending].split.map { |digits| codepoint_character(unicode_codepoint(digits)) }
        raise RegexpError, "invalid Unicode escape" if values.empty?

        return [Lexer::Token.new(:literal, values.join, index), ending + 1]
      end

      digits = @source[(index + 2), 4]
      raise RegexpError, "invalid Unicode escape" unless digits && digits.length == 4 && digits.each_char.all? { |digit| hex_digit?(digit) }

      [Lexer::Token.new(:literal, codepoint_character(digits.to_i(16)), index), index + 6]
    end

    def unicode_codepoint(digits)
      raise RegexpError, "invalid Unicode escape" if digits.empty? || digits.length > 6 || !digits.each_char.all? { |digit| hex_digit?(digit) }

      digits.to_i(16)
    end

    def codepoint_character(codepoint)
      codepoint.chr(@source.encoding)
    rescue RangeError, EncodingError
      raise RegexpError, "invalid Unicode escape"
    end

    def hex_digit?(character)
      character && (character >= "0" && character <= "9" || character >= "a" && character <= "f" || character >= "A" && character <= "F")
    end

    def special_escape_token(index, escaped)
      return backreference_token(index) if digit_escape?(escaped) || escaped == "k"
      return subexpression_token(index) if escaped == "g"

      property_token(index) if %w[p P].include?(escaped)
    end

    def escaped_type_token(type, escaped, index)
      token_type = type || :literal
      [Lexer::Token.new(token_type, escaped, index), index + 2]
    end
  end
end
