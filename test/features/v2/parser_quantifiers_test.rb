# frozen_string_literal: true

require "test_helper"

class V2ParserQuantifiersTest < Minitest::Test
  def test_short_quantifiers_have_exact_bounds_and_modes
    expected = Onibi::AST::Sequence.new([
                                          quantifier("a", :"?", 0, 1, :greedy),
                                          quantifier("a", :+, 1, nil, :lazy),
                                          quantifier("a", :+, 1, nil, :possessive)
                                        ])

    assert_equal expected, Onibi::Parser.parse("a?a+?a++").ast
  end

  def test_bounded_quantifiers_have_exact_bounds
    expected = Onibi::AST::Sequence.new([
                                          quantifier("a", :bounded, 2, 4, :greedy),
                                          quantifier("a", :bounded, 2, nil, :greedy),
                                          quantifier("a", :bounded, 2, 2, :greedy, true)
                                        ])

    assert_equal expected, Onibi::Parser.parse("a{2,4}a{2,}a{2}").ast
  end

  private

  def quantifier(value, kind, minimum, maximum, mode, exact_bound = nil)
    expression = Onibi::AST::Literal.new(value)
    Onibi::AST::Quantifier.new(expression, kind, minimum, maximum, mode, exact_bound)
  end
end
