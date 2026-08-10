# frozen_string_literal: true

module Onibi
  module ParserOptionGroups
    private

    def parse_option_group(opening)
      body = parse_alternation
      expect(:close_group)
      AST::OptionGroup.new(body, opening.value)
    end
  end
end
