# frozen_string_literal: true

module Onibi
  # Converts the Core MVP pattern syntax into parser-ready tokens.
  class Lexer
    include LexerClasses
    include LexerOptionGroups
    include LexerComments
    include LexerExtendedMode
    include LexerExtendedScopes
    include LexerDispatch
    include LexerTokenStream
    include LexerEscapes
    Token = Struct.new(:type, :value, :position)

    ESCAPED_LITERALS = ".^$*+?{}[]()|\\ #QE".chars.freeze
    ESCAPED_CHARACTERS = {
      "a" => "\a", "e" => "\e", "f" => "\f", "n" => "\n",
      "r" => "\r", "t" => "\t", "v" => "\v"
    }.freeze
    ESCAPED_TYPES = {
      "d" => :digit,
      "D" => :not_digit,
      "s" => :space,
      "S" => :not_space,
      "w" => :word,
      "W" => :not_word,
      "h" => :horizontal_space,
      "H" => :not_horizontal_space,
      "R" => :linebreak,
      "b" => :word_boundary,
      "B" => :not_word_boundary,
      "G" => :start_match,
      "K" => :match_reset,
      "X" => :grapheme,
      "A" => :anchor_absolute_start,
      "Z" => :anchor_before_final_newline,
      "z" => :anchor_absolute_end
    }.freeze
    SIMPLE_TOKENS = {
      "(" => :open_group,
      ")" => :close_group,
      "|" => :alternation,
      "." => :dot,
      "^" => :anchor_start,
      "$" => :anchor_end
    }.freeze

    def initialize(source, options = [])
      @source = LexerScopedExtended.normalize(source)
      @extended = options.include?("extended")
      @noencoding = options.include?("noencoding")
      @extended_scopes = []
    end

    private

    def special_character?(character)
      "\\()|*+?{}[].^$".include?(character)
    end

    def literal_token(character, index)
      [Token.new(:literal, character, index), index + 1]
    end

    def simple_token(character, index)
      [Token.new(SIMPLE_TOKENS.fetch(character), character, index), index + 1]
    end

    def quantifier_token(index)
      return literal_token("{", index) if @source[index] == "{" && !bounded_quantifier?(index)

      [Token.new(:quantifier, quantifier_value(index), index), quantifier_end(index)]
    end

    def bounded_quantifier?(index)
      ending = @source.index("}", index + 1)
      return false unless ending

      body = @source[(index + 1)...ending]
      body.match?(/\A(?:\d+|\d+,\d*|,\d+)\z/)
    end

    def escaped_token(index)
      escaped = @source[index + 1]
      raise RegexpError, "too short escape sequence: /#{@source}/" if escaped.nil?

      return octal_escape_token(index) if octal_escape?(index)
      return special_escape_token(index, escaped) if special_escape_token(index, escaped)
      return character_escape_token(index, escaped) if character_escape_token(index, escaped)

      escaped_literal_token(index, escaped)
    end

    def escaped_literal_token(index, escaped)
      character = ESCAPED_CHARACTERS[escaped]
      return [Token.new(:literal, character, index), index + 2] if character

      type = ESCAPED_TYPES[escaped]
      return escaped_type_token(type, escaped, index) if type || ESCAPED_LITERALS.include?(escaped)

      [Token.new(:literal, escaped, index), index + 2]
    end

    def digit_escape?(character)
      character && character >= "0" && character <= "9"
    end

    def octal_escape?(index)
      digits = @source[(index + 1), 3]
      return false unless digits

      return true if digits.length == 3 && digits.each_char.all? { |digit| digit >= "0" && digit <= "7" }

      @source[index + 1] == "0" && digits.match?(/\A[0-7]{1,3}/)
    end

    def octal_escape_token(index)
      digits = @source[(index + 1), 3]
      digits = digits[/\A[0-7]{1,3}/]
      codepoint = digits.to_i(8)
      raise RegexpError, "invalid escape code" if codepoint > 0xFF

      value = escaped_byte(codepoint)
      [Token.new(:literal, value, index), index + 1 + digits.length]
    rescue RangeError, EncodingError
      raise RegexpError, "invalid octal escape"
    end

    def class_token(index)
      ending = class_ending(index)
      raise RegexpError, "unterminated character class" unless ending

      [Token.new(:class, @source[(index + 1)...(ending - 1)], index), ending]
    end

    def quantifier_value(index)
      @source[index...quantifier_end(index)]
    end

    def quantifier_end(index)
      ending = index + 1
      if @source[index] == "{"
        ending = @source.index("}", index)
        raise RegexpError, "unterminated quantifier" unless ending

        ending += 1
      end

      ending += 1 if %w[? +].include?(@source[ending])

      ending
    end
  end
end
