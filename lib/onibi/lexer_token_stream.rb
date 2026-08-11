# frozen_string_literal: true

module Onibi
  # Builds the lexer token stream while dropping ignored tokens.
  module LexerTokenStream
    PATTERN_NESTING_LIMIT = 256
    GROUP_OPEN_TOKEN_TYPES = %i[
      open_group open_non_capture open_named_group open_atomic open_conditional open_absence
      open_option_group open_positive_lookahead open_negative_lookahead
      open_positive_lookbehind open_negative_lookbehind
    ].freeze

    def tokens
      result = []
      index = 0
      nesting = 0

      while index < @source.length
        token, index = next_token(index)
        next unless token
        next if token.type == :comment

        nesting = update_nesting(token, nesting)

        result << token
      end

      result
    end

    private

    def update_nesting(token, nesting)
      if GROUP_OPEN_TOKEN_TYPES.include?(token.type)
        nesting += 1
        raise RegexpError, "regexp compilation limit exceeded: pattern_nesting" if nesting > PATTERN_NESTING_LIMIT
      elsif token.type == :close_group
        nesting -= 1 if nesting.positive?
      end
      nesting
    end
  end
end
