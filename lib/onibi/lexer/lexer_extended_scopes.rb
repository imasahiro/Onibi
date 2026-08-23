# frozen_string_literal: true

module Onibi
  # Tracks extended-mode state while lexing scoped option groups.
  module LexerExtendedScopes
    private

    def extended_scope_opened(token)
      @extended_scopes << @extended
      return unless token.type == :open_option_group

      scoped_extended = token.value[2]
      @extended = scoped_extended unless scoped_extended.nil?
    end

    def extended_scope_closed
      @extended = @extended_scopes.pop unless @extended_scopes.empty?
    end
  end
end
