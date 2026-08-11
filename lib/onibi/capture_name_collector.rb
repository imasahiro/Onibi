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

    def self.indices(node)
      new.collect_indices(node)
    end

    def collect(node)
      collector = NODE_COLLECTORS[node.class]
      collector ? send(collector, node) : {}
    end

    def collect_indices(node)
      collector = NODE_COLLECTORS[node.class]
      collector ? send(collector, node, :indices) : {}
    end

    private

    def group_names(node, mode = :single)
      names = mode == :indices ? collect_indices(node.body) : collect(node.body)
      names[node.name] = mode == :indices ? [node.number] : node.number if node.name
      names.sort_by { |_name, index| Array(index).first }.to_h
    end

    def sequence_names(node, mode = :single)
      return merge_indices(node.parts) if mode == :indices

      merge_names(node.parts)
    end

    def alternation_names(node, mode = :single)
      return merge_indices(node.branches) if mode == :indices

      merge_names(node.branches)
    end

    def quantifier_names(node, mode = :single)
      return collect_indices(node.expression) if mode == :indices

      collect(node.expression)
    end

    def merge_names(nodes)
      nodes.each_with_object({}) do |child, names|
        collect(child).each { |name, index| names[name] ||= index }
      end
    end

    def merge_indices(nodes)
      nodes.each_with_object({}) do |child, names|
        collect_indices(child).each do |name, indices|
          names[name] = (names[name] || []) + indices
        end
      end
    end
  end
end
