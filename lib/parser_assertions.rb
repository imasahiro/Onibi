# frozen_string_literal: true

module Onibi
  # Parses zero-width assertion group bodies.
  module ParserAssertions
    private

    def parse_assertion(opening)
      body = parse_alternation
      expect(:close_group)
      kind = opening.type == :open_positive_lookahead ? :positive : :negative
      AST::Assertion.new(body, kind)
    end
  end
end
