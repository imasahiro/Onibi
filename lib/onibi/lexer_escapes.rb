# frozen_string_literal: true

module Onibi
  # Dispatches escape sequences that have dedicated lexer tokenizers.
  module LexerEscapes
    private

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
