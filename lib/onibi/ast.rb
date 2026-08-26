# frozen_string_literal: true

module Onibi
  module AST
    # Visit an AST node and all child nodes in source order.
    def self.walk(node, &block)
      return enum_for(:walk, node) unless block

      yield node
      node.each_pair do |_field, value|
        values = value.is_a?(Array) ? value : [value]
        values.each do |child|
          walk(child, &block) if child.respond_to?(:each_pair)
        end
      end
    end

    Literal = Struct.new(:value)
    CharacterClass = Struct.new(:value)
    Escape = Struct.new(:kind)
    Property = Struct.new(:name, :negated)
    Backreference = Struct.new(:identifier, :named)
    Assertion = Struct.new(:body, :kind)
    Any = Struct.new(:value)
    Anchor = Struct.new(:kind)
    Sequence = Struct.new(:parts)
    Alternation = Struct.new(:branches)
    Group = Struct.new(:body, :number, :capture, :name)
    OptionGroup = Struct.new(:body, :ignorecase, :multiline, :extended)
    AtomicGroup = Struct.new(:body)
    Conditional = Struct.new(:condition, :yes_branch, :no_branch)
    SubexpressionCall = Struct.new(:identifier, :named)
    Absence = Struct.new(:body)
    # `exact_bound` preserves `{n}` versus `{n,n}` for bytecode semantics.
    Quantifier = Struct.new(:expression, :kind, :minimum, :maximum, :mode, :exact_bound)
  end
end
