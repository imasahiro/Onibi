# frozen_string_literal: true

module Onibi
  # Collects named capture numbers from the parsed AST.
  class CaptureNameCollector
    NODE_COLLECTORS = {
      AST::Group => :group_names,
      AST::Sequence => :sequence_names,
      AST::Alternation => :alternation_names,
      AST::Quantifier => :quantifier_names
    }.freeze

    def self.call(node)
      new.collect(node)
    end

    def collect(node)
      collector = NODE_COLLECTORS[node.class]
      collector ? send(collector, node) : {}
    end

    private

    def group_names(node)
      node.name ? { node.name => node.number } : collect(node.body)
    end

    def sequence_names(node)
      merge_names(node.parts)
    end

    def alternation_names(node)
      merge_names(node.branches)
    end

    def quantifier_names(node)
      collect(node.expression)
    end

    def merge_names(nodes)
      nodes.reduce({}) { |names, child| names.merge(collect(child)) }
    end
  end
end
