# frozen_string_literal: true

module Onibi
  # Converts the Core MVP pattern syntax into parser-ready tokens.
  class Lexer
    include LexerClasses
    Token = Struct.new(:type, :value, :position)

    ESCAPED_LITERALS = ".^$*+?{}[]()|\\".chars.freeze
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
      return literal_token(character, index) unless special_character?(character)
      return escaped_token(index) if character == "\\"
      return class_token(index) if character == "["
      return simple_token(character, index) if SIMPLE_TOKENS.key?(character)
      return quantifier_token(index) if "*+?{".include?(character)

      raise RegexpError, "unexpected character class terminator"
    end

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
      [Token.new(:quantifier, quantifier_value(index), index), quantifier_end(index)]
    end

    def escaped_token(index)
      escaped = @source[index + 1]
      raise RegexpError, "trailing escape" if escaped.nil?
      return property_token(index) if %w[p P].include?(escaped)

      type = ESCAPED_TYPES[escaped]
      return [Token.new(type, escaped, index), index + 2] if type
      return [Token.new(:literal, escaped, index), index + 2] if ESCAPED_LITERALS.include?(escaped)

      raise RegexpError, "unknown escape \\#{escaped}"
    end

    def class_token(index)
      ending = class_ending(index)
      raise RegexpError, "unterminated character class" unless ending

      [Token.new(:class, @source[(index + 1)...(ending - 1)], index), ending]
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
