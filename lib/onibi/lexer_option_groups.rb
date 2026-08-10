# frozen_string_literal: true

module Onibi
  # Recognizes scoped inline casefold groups.
  module LexerOptionGroups
    private

    def option_group_start?(index)
      @source[index, 4] == "(?i:" || @source[index, 5] == "(?-i:"
    end

    def option_group_token(index)
      return [Lexer::Token.new(:open_option_group, true, index), index + 4] if @source[index, 4] == "(?i:"

      [Lexer::Token.new(:open_option_group, false, index), index + 5]
    end
  end
end
