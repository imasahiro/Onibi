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
      states = option_group_states(enabled, disabled)

      [Lexer::Token.new(:open_option_group, states, index), ending + 1]
    end

    def option_group_states(enabled, disabled)
      %w[i m x].map { |modifier| option_state(modifier, enabled, disabled) }
    end

    def option_state(modifier, enabled, disabled)
      return true if enabled.include?(modifier)
      return false if disabled.include?(modifier)

      nil
    end

    def scoped_option_spec(index)
      return unless @source[index, 2] == "(?"

      ending = @source.index(":", index + 2)
      return unless ending

      specification = @source[(index + 2)...ending]
      return unless valid_scoped_option_spec?(specification)

      [specification, ending]
    end

    def valid_scoped_option_spec?(specification)
      enabled, disabled = specification.split("-", -1)
      enabled = enabled.to_s
      disabled = disabled.to_s
      return false if enabled.empty? && disabled.empty?
      return false unless (enabled + disabled).chars.all? { |modifier| %w[i m x].include?(modifier) }

      (enabled.chars & disabled.chars).empty?
    end
  end
end
