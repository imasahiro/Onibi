# frozen_string_literal: true

module Onibi
  # Tokenizes numbered and named backreference escapes.
  module LexerClasses
    private

    def backreference_token(index)
      escaped = @source[index + 1]
      return numbered_backreference_token(index) if escaped >= "0" && escaped <= "9"

      ending = @source.index(">", index + 3)
      raise RegexpError, "invalid named backreference" unless @source[index + 2] == "<" && ending

      name = @source[(index + 3)...ending]
      raise RegexpError, "invalid named backreference" if name.empty?

      [Lexer::Token.new(:backreference, name, index), ending + 1]
    end

    def numbered_backreference_token(index)
      ending = index + 2
      ending += 1 while @source[ending] && @source[ending] >= "0" && @source[ending] <= "9"

      [Lexer::Token.new(:backreference, @source[(index + 1)...ending].to_i, index), ending]
    end
  end
end
