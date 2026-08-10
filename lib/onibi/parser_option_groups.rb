# frozen_string_literal: true

module Onibi
  # Parses scoped inline casefold groups.
  module ParserOptionGroups
    private

    def parse_option_group(opening)
      body = parse_alternation
      expect(:close_group)
      ignorecase, multiline = opening.value
      AST::OptionGroup.new(body, ignorecase, multiline)
    end
  end
end
