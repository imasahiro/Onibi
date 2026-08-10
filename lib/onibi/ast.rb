# frozen_string_literal: true

module Onibi
  module AST
    Literal = Struct.new(:value)
    CharacterClass = Struct.new(:value)
    Escape = Struct.new(:kind)
    Property = Struct.new(:name, :negated)
    Backreference = Struct.new(:identifier, :named)
    Any = Struct.new(:value)
    Anchor = Struct.new(:kind)
    Sequence = Struct.new(:parts)
    Alternation = Struct.new(:branches)
    Group = Struct.new(:body, :number, :capture, :name)
    Quantifier = Struct.new(:expression, :kind, :minimum, :maximum, :mode)
  end
end
