# frozen_string_literal: true

module Onibi
  # Converts the Core MVP pattern syntax into parser-ready tokens.
  class Lexer
    Token = Struct.new(:type, :value, :position)

    ESCAPED_LITERALS = ".^$*+?{}[]()|\\".chars.freeze

    def initialize(source)
      @source = source
    end

    def tokens
      result = []
      index = 0

      while index < @source.length
        token, index = next_token(index)
        result << token
      end

      result
    end

    private

    def next_token(index)
      character = @source[index]
      return [Token.new(:literal, character, index), index + 1] unless "\\()|*+?{}[].^$".include?(character)

      case character
      when "\\" then escaped_token(index)
      when "[" then class_token(index)
      when "(" then [Token.new(:open_group, character, index), index + 1]
      when ")" then [Token.new(:close_group, character, index), index + 1]
      when "|" then [Token.new(:alternation, character, index), index + 1]
      when "*", "+", "?", "{" then [Token.new(:quantifier, quantifier_value(index)), quantifier_end(index)]
      when "]" then raise RegexpError, "unexpected character class terminator"
      when "." then [Token.new(:dot, character, index), index + 1]
      when "^" then [Token.new(:anchor_start, character, index), index + 1]
      when "$" then [Token.new(:anchor_end, character, index), index + 1]
      end
    end

    def escaped_token(index)
      escaped = @source[index + 1]
      raise RegexpError, "trailing escape" if escaped.nil?

      type = { "d" => :digit, "s" => :space, "w" => :word }[escaped]
      return [Token.new(type, escaped, index), index + 2] if type
      return [Token.new(:literal, escaped, index), index + 2] if ESCAPED_LITERALS.include?(escaped)

      raise RegexpError, "unknown escape \\#{escaped}"
    end

    def class_token(index)
      ending = index + 1
      ending += 1 while ending < @source.length && @source[ending] != "]"
      raise RegexpError, "unterminated character class" if ending == @source.length

      [Token.new(:class, @source[(index + 1)...ending], index), ending + 1]
    end

    def quantifier_value(index)
      return @source[index] unless @source[index] == "{"

      ending = @source.index("}", index)
      raise RegexpError, "unterminated quantifier" unless ending

      @source[index..ending]
    end

    def quantifier_end(index)
      return index + 1 unless @source[index] == "{"

      ending = @source.index("}", index)
      raise RegexpError, "unterminated quantifier" unless ending

      ending + 1
    end
  end
end
