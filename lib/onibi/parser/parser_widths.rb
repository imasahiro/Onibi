# frozen_string_literal: true

module Onibi
  # Calculates fixed widths for parser-level lookbehind validation.
  module ParserWidths
    WIDTH_METHODS = {
      AST::Literal => :literal_width,
      AST::CharacterClass => :unit_width,
      AST::Property => :unit_width,
      AST::Any => :unit_width,
      AST::Anchor => :zero_width,
      AST::Assertion => :zero_width,
      AST::Escape => :escape_width,
      AST::Sequence => :sequence_width_node,
      AST::Alternation => :alternation_width_node,
      AST::Group => :body_width,
      AST::AtomicGroup => :body_width,
      AST::Quantifier => :quantifier_width,
      AST::Conditional => :conditional_width
    }.freeze

    private

    def fixed_width?(node)
      !node_width(node).nil?
    end

    def node_width(node)
      matcher = WIDTH_METHODS[node.class]
      matcher ? send(matcher, node) : nil
    end

    def literal_width(node)
      node.value.chars.length
    end

    def unit_width(_node)
      1
    end

    def zero_width(_node)
      0
    end

    def escape_width(node)
      return nil if node.kind == :grapheme

      zero_width_escape?(node.kind) ? 0 : 1
    end

    def sequence_width_node(node)
      sequence_width(node.parts)
    end

    def alternation_width_node(node)
      alternation_width(node.branches)
    end

    def body_width(node)
      node_width(node.body)
    end

    def sequence_width(parts)
      widths = parts.map { |part| node_width(part) }
      widths.all? ? widths.sum : nil
    end

    def alternation_width(branches)
      widths = branches.map { |branch| node_width(branch) }
      widths.all? && widths.uniq.one? ? widths.first : nil
    end

    def quantifier_width(node)
      return unless node.kind == :bounded && node.minimum == node.maximum

      body_width = node_width(node.expression)
      body_width && body_width * node.minimum
    end

    def conditional_width(node)
      widths = [node_width(node.yes_branch), node_width(node.no_branch)]
      widths.all? && widths.uniq.one? ? widths.first : nil
    end

    def zero_width_escape?(kind)
      %i[word_boundary not_word_boundary start_match].include?(kind)
    end
  end
end
