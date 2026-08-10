# frozen_string_literal: true

module Onibi
  # Resolves subexpression calls against the parsed group tree.
  module CaptureMatcherSubexpressions
    private

    def subexpression_call_results(node, characters, position, captures)
      group = find_group(@ast, node.identifier, node.named)
      group ? match_results(group, characters, position, captures) : []
    end

    def find_group(node, identifier, named)
      return node if node.is_a?(AST::Group) && group_matches?(node, identifier, named)

      group_children(node).each do |child|
        found = find_group(child, identifier, named)
        return found if found
      end
      nil
    end

    def group_matches?(node, identifier, named)
      named ? node.name == identifier : node.number == identifier
    end

    def group_children(node)
      case node
      when AST::Sequence then node.parts
      when AST::Alternation then node.branches
      when AST::Group, AST::AtomicGroup, AST::Assertion then [node.body]
      when AST::Quantifier then [node.expression]
      when AST::Conditional then [node.yes_branch, node.no_branch]
      else []
      end
    end
  end
end
