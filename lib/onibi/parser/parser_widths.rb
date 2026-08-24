# frozen_string_literal: true

module Onibi
  # Computes all finite input widths for a syntax node.
  # The compiler stores this set in assertion operands for bounded lookbehind.
  module WidthAnalysis
    module_function

    def widths(node)
      case node
      when AST::Literal then [node.value.chars.length]
      when AST::CharacterClass, AST::Property, AST::Any then [1]
      when AST::Anchor, AST::Assertion then [0]
      when AST::Escape
        next_width = zero_width_escape?(node.kind) ? 0 : 1
        node.kind == :grapheme ? nil : [next_width]
      when AST::Sequence then combine(node.parts)
      when AST::Alternation
        branch_widths = node.branches.map { |branch| widths(branch) }
        return nil if branch_widths.any?(&:nil?)

        branch_widths.flatten.uniq.sort
      when AST::Group, AST::AtomicGroup, AST::OptionGroup then widths(node.body)
      when AST::Quantifier
        return unless node.kind == :bounded && node.minimum == node.maximum

        widths(node.expression)&.map { |width| width * node.minimum }
      when AST::Conditional
        return unless node.yes_branch && node.no_branch

        (widths(node.yes_branch) || []).concat(widths(node.no_branch) || []).uniq.sort
      end
    end

    def combine(parts)
      parts.reduce([0]) do |prefixes, part|
        part_widths = widths(part)
        return nil unless part_widths

        prefixes.product(part_widths).map { |left, right| left + right }.uniq.sort
      end
    end

    def zero_width_escape?(kind)
      %i[word_boundary not_word_boundary start_match].include?(kind)
    end
  end

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
      widths = WidthAnalysis.widths(node)
      widths&.one? ? widths.first : nil
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
