# frozen_string_literal: true

module Onibi
  module AstMatcherOptionGroups
    private

    def option_group_positions(node, characters, position)
      original = @ignorecase
      @ignorecase = node.ignorecase
      match_positions(node.body, characters, position)
    ensure
      @ignorecase = original
    end
  end

  module CaptureMatcherOptionGroups
    private

    def option_group_results(node, characters, position, captures)
      original = @ignorecase
      @ignorecase = node.ignorecase
      match_results(node.body, characters, position, captures)
    ensure
      @ignorecase = original
    end
  end
end
