# frozen_string_literal: true

module Onibi
  # Matches scoped inline casefold groups against AST positions.
  module AstMatcherOptionGroups
    private

    def option_group_positions(node, characters, position)
      original = [@ignorecase, @multiline]
      @ignorecase = node.ignorecase unless node.ignorecase.nil?
      @multiline = node.multiline unless node.multiline.nil?
      match_positions(node.body, characters, position)
    ensure
      @ignorecase, @multiline = original
    end
  end

  # Matches scoped inline casefold groups while preserving captures.
  module CaptureMatcherOptionGroups
    private

    def option_group_results(node, characters, position, captures)
      original = [@ignorecase, @multiline]
      @ignorecase = node.ignorecase unless node.ignorecase.nil?
      @multiline = node.multiline unless node.multiline.nil?
      match_results(node.body, characters, position, captures)
    ensure
      @ignorecase, @multiline = original
    end
  end
end
