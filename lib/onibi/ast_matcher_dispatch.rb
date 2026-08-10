# frozen_string_literal: true

module Onibi
  module AstMatcherDispatch
    NODE_MATCHERS = {
      AST::Sequence => :sequence_node_positions,
      AST::Alternation => :alternation_positions,
      AST::Group => :group_positions,
      AST::Quantifier => :quantifier_positions,
      AST::Literal => :literal_positions,
      AST::CharacterClass => :class_positions,
      AST::Escape => :escape_positions,
      AST::Any => :any_positions,
      AST::Anchor => :anchor_positions
    }.freeze

    private

    def alternation_positions(node, characters, position)
      node.branches.flat_map { |branch| match_positions(branch, characters, position) }
    end

    def sequence_node_positions(node, characters, position)
      sequence_positions(node.parts, characters, position)
    end

    def group_positions(node, characters, position)
      match_positions(node.body, characters, position)
    end

    def any_positions(_node, characters, position)
      position < characters.length ? [position + 1] : []
    end
  end
end
