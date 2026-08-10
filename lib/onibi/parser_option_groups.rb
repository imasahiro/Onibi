# frozen_string_literal: true

module Onibi
  # Parses scoped inline casefold groups.
  module ParserOptionGroups
    private

    def parse_option_group(opening)
      body = parse_alternation
      expect(:close_group)
      ignorecase, multiline, extended = opening.value
      AST::OptionGroup.new(body, ignorecase, multiline, extended)
    end
  end
end
