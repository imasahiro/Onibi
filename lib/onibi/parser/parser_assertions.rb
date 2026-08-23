# frozen_string_literal: true

module Onibi
  # Parses zero-width assertion group bodies.
  module ParserAssertions
    include ParserWidths

    private

    def parse_assertion(opening)
      body = parse_alternation
      expect(:close_group)
      validate_lookbehind!(opening, body)
      kind = assertion_kind(opening.type)
      AST::Assertion.new(body, kind)
    end

    def validate_lookbehind!(opening, body)
      return unless %i[open_positive_lookbehind open_negative_lookbehind].include?(opening.type)
      return if fixed_width?(body)

      raise RegexpError, "lookbehind must be fixed-width"
    end

    def assertion_kind(type)
      {
        open_positive_lookahead: :positive,
        open_negative_lookahead: :negative,
        open_positive_lookbehind: :positive_lookbehind,
        open_negative_lookbehind: :negative_lookbehind
      }.fetch(type)
    end
  end
end
