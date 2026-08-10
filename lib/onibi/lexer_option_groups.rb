# frozen_string_literal: true

module Onibi
  # Recognizes scoped inline casefold groups.
  module LexerOptionGroups
    private

    def option_group_start?(index)
      !scoped_option_spec(index).nil?
    end

    def option_group_token(index)
      specification, ending = scoped_option_spec(index)
      enabled, disabled = specification.split("-", -1)
      disabled ||= ""
      states = %w[i m x].map do |modifier|
        if enabled.include?(modifier)
          true
        elsif disabled.include?(modifier)
          false
        end
      end

      [Lexer::Token.new(:open_option_group, states, index), ending + 1]
    end

    def scoped_option_spec(index)
      return unless @source[index, 2] == "(?"

      ending = @source.index(":", index + 2)
      return unless ending

      specification = @source[(index + 2)...ending]
      enabled, disabled = specification.split("-", -1)
      enabled ||= ""
      disabled ||= ""
      return if enabled.empty? && disabled.empty?
      return unless (enabled + disabled).chars.all? { |modifier| %w[i m x].include?(modifier) }
      return unless (enabled.chars & disabled.chars).empty?

      [specification, ending]
    end
  end
end
