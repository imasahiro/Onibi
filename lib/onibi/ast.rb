# frozen_string_literal: true

module Onibi
  module AST
    Literal = Struct.new(:value)
    CharacterClass = Struct.new(:value)
    Escape = Struct.new(:kind)
    Any = Struct.new(:value)
    Anchor = Struct.new(:kind)
    Sequence = Struct.new(:parts)
    Alternation = Struct.new(:branches)
    Group = Struct.new(:body, :number)
    Quantifier = Struct.new(:expression, :kind, :min, :max)
  end
end
