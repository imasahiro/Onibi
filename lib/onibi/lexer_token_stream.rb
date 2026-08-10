# frozen_string_literal: true

module Onibi
  # Builds the lexer token stream while dropping ignored tokens.
  module LexerTokenStream
    def tokens
      result = []
      index = 0

      while index < @source.length
        token, index = next_token(index)
        result << token if token && token.type != :comment
      end

      result
    end
  end
end
