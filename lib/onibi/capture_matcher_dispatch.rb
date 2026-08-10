# frozen_string_literal: true

module Onibi
  # Dispatches AST nodes and handles structural capture propagation.
  module CaptureMatcherDispatch
    NODE_MATCHERS = {
      AST::Sequence => :sequence_results,
      AST::Alternation => :alternation_results,
      AST::Group => :group_results,
      AST::Quantifier => :quantifier_results,
      AST::Literal => :literal_results,
      AST::CharacterClass => :class_results,
      AST::Escape => :escape_results,
      AST::Property => :property_results,
      AST::Any => :any_results,
      AST::Anchor => :anchor_results
    }.freeze

    CAPTURE_COUNTS = {
      AST::Group => :group_capture_count,
      AST::Sequence => :sequence_capture_count,
      AST::Alternation => :alternation_capture_count,
      AST::Quantifier => :expression_capture_count
    }.freeze

    private

    def match_results(node, characters, position, captures)
      matcher = NODE_MATCHERS[node.class]
      matcher ? send(matcher, node, characters, position, captures) : []
    end

    def sequence_results(node, characters, position, captures)
      node.parts.reduce([[position, captures]]) do |results, part|
        results.flat_map { |current, state| match_results(part, characters, current, state) }
      end
    end

    def alternation_results(node, characters, position, captures)
      node.branches.flat_map do |branch|
        match_results(branch, characters, position, captures.dup)
      end
    end

    def group_results(node, characters, position, captures)
      match_results(node.body, characters, position, captures).map do |finish, state|
        updated = state.dup
        updated[node.number - 1] = [position, finish]
        [finish, updated]
      end
    end

    def expression_capture_count(node)
      capture_count(node.expression)
    end
  end
end
