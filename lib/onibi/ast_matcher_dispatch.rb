# frozen_string_literal: true

module Onibi
  # Holds AST dispatch helpers separate from the matching algorithms.
  module AstMatcherDispatch
    NODE_MATCHERS = {
      AST::Sequence => :sequence_node_positions,
      AST::Alternation => :alternation_positions,
      AST::Group => :group_positions,
      AST::Assertion => :assertion_positions,
      AST::Quantifier => :quantifier_positions,
      AST::Literal => :literal_positions,
      AST::CharacterClass => :class_positions,
      AST::Escape => :escape_positions,
      AST::Property => :property_positions,
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

    def assertion_positions(node, characters, position)
      matched = assertion_matches?(node, characters, position)
      matched = !matched if %i[negative negative_lookbehind].include?(node.kind)
      matched ? [position] : []
    end

    def assertion_matches?(node, characters, position)
      return !match_positions(node.body, characters, position).empty? unless lookbehind?(node)

      (0..position).any? do |start|
        match_positions(node.body, characters, start).include?(position)
      end
    end

    def lookbehind?(node)
      %i[positive_lookbehind negative_lookbehind].include?(node.kind)
    end

    def any_positions(_node, characters, position)
      return [] unless position < characters.length
      return [] if !@multiline && characters[position] == "\n"

      [position + 1]
    end
  end
end
