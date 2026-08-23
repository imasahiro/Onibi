# frozen_string_literal: true

module Onibi
  # Tokenizes comments that are ignored inside regexp patterns.
  module LexerComments
    private

    def comment_group_start?(index)
      @source[index, 3] == "(?#"
    end

    def comment_token(index)
      ending = @source.index(")", index + 3)
      raise RegexpError, "unterminated pattern comment" unless ending

      [Lexer::Token.new(:comment, @source[(index + 3)...ending], index), ending + 1]
    end
  end
end
