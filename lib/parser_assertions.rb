# frozen_string_literal: true

module Onibi
  # Parses zero-width assertion group bodies.
  module ParserAssertions
    private

    def parse_assertion(opening)
      body = parse_alternation
      expect(:close_group)
      kind = assertion_kind(opening.type)
      AST::Assertion.new(body, kind)
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
