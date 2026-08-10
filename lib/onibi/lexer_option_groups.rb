# frozen_string_literal: true

module Onibi
  # Recognizes scoped inline casefold groups.
  module LexerOptionGroups
    private

    def option_group_start?(index)
      @source[index, 4] == "(?i:" || @source[index, 5] == "(?-i:" ||
        @source[index, 4] == "(?m:" || @source[index, 5] == "(?-m:" ||
        @source[index, 5] == "(?-x:"
    end

    def option_group_token(index)
      return [Lexer::Token.new(:open_option_group, [true, nil], index), index + 4] if @source[index, 4] == "(?i:"
      return [Lexer::Token.new(:open_option_group, [false, nil], index), index + 5] if @source[index, 5] == "(?-i:"
      return [Lexer::Token.new(:open_option_group, [nil, true], index), index + 4] if @source[index, 4] == "(?m:"
      return [Lexer::Token.new(:open_option_group, [nil, nil, false], index), index + 5] if @source[index, 5] == "(?-x:"

      [Lexer::Token.new(:open_option_group, [nil, false], index), index + 5]
    end
  end
end
