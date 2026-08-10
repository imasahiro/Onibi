# frozen_string_literal: true

module Onibi
  # Dispatches AST nodes and handles structural capture propagation.
  module CaptureMatcherDispatch
    NODE_MATCHERS = {
      AST::Sequence => :sequence_results,
      AST::Alternation => :alternation_results,
      AST::Group => :group_results,
      AST::OptionGroup => :option_group_results,
      AST::AtomicGroup => :atomic_group_results,
      AST::Conditional => :conditional_results,
      AST::Quantifier => :quantifier_results,
      AST::Literal => :literal_results,
      AST::CharacterClass => :class_results,
      AST::Escape => :escape_results,
      AST::Property => :property_results,
      AST::Backreference => :backreference_results,
      AST::SubexpressionCall => :subexpression_call_results,
      AST::Absence => :absence_results,
      AST::Assertion => :assertion_results,
      AST::Any => :any_results,
      AST::Anchor => :anchor_results
    }.freeze

    CAPTURE_COUNTS = {
      AST::Group => :group_capture_count,
      AST::AtomicGroup => :body_capture_count,
      AST::Sequence => :sequence_capture_count,
      AST::Alternation => :alternation_capture_count,
      AST::Quantifier => :expression_capture_count,
      AST::Conditional => :conditional_capture_count,
      AST::SubexpressionCall => :subexpression_capture_count,
      AST::Absence => :body_capture_count
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
        next [finish, state] unless node.capture

        updated = state.dup
        updated[node.number - 1] = [position, finish]
        [finish, updated]
      end
    end

    def expression_capture_count(node)
      capture_count(node.expression)
    end

    def body_capture_count(node)
      capture_count(node.body)
    end

    def conditional_results(node, characters, position, captures)
      branch = condition_captured?(node.condition, captures) ? node.yes_branch : node.no_branch
      match_results(branch, characters, position, captures)
    end

    def condition_captured?(condition, captures)
      identifier, named = condition
      index = named ? CaptureNameCollector.call(@ast)[identifier] : identifier
      index && captures[index - 1]
    end

    def conditional_capture_count(node)
      [capture_count(node.yes_branch), capture_count(node.no_branch)].max
    end

    def subexpression_capture_count(_node)
      0
    end
  end
end
