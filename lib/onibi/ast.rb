# frozen_string_literal: true

module Onibi
  module AST
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
    AtomicGroup = Struct.new(:body)
    Conditional = Struct.new(:condition, :yes_branch, :no_branch)
    Quantifier = Struct.new(:expression, :kind, :minimum, :maximum, :mode)
  end
end
