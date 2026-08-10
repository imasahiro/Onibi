# frozen_string_literal: true

module Onibi
  # Dispatches lexer input after applying extended-mode skips.
  module LexerDispatch
    private

    def next_token(index)
      extended_skip_token(index) || regular_token(index)
    end

    def extended_skip_token(index)
      skip_index = extended_skip_index(index)
      skip_index == index ? nil : [nil, skip_index]
    end

    def regular_token(index)
      character = @source[index]
      return literal_token(character, index) unless special_character?(character)
      return escaped_token(index) if character == "\\"
      return class_token(index) if character == "["
      return group_token(index) if character == "("
      return simple_token(character, index) if Lexer::SIMPLE_TOKENS.key?(character)
      return quantifier_token(index) if "*+?{".include?(character)

      raise RegexpError, "unexpected character class terminator"
    end
  end
end
