# frozen_string_literal: true

require "test_helper"

class V2ParserQuantifiersTest < Minitest::Test
  def test_short_quantifiers_have_exact_bounds_and_modes
    expected = Onibi::AST::Sequence.new([
                                          quantifier(:"?", 0, 1, :greedy),
                                          quantifier(:+, 1, nil, :lazy),
                                          quantifier(:+, 1, nil, :possessive)
                                        ])

    assert_equal expected, Onibi::V2::Parser.parse("a?a+?a++").ast
  end

  def test_bounded_quantifiers_have_exact_bounds
    expected = Onibi::AST::Sequence.new([
                                          quantifier(:bounded, 2, 4, :greedy),
                                          quantifier(:bounded, 2, nil, :greedy),
                                          quantifier(:bounded, 2, 2, :greedy)
                                        ])

    assert_equal expected, Onibi::V2::Parser.parse("a{2,4}a{2,}a{2}").ast
  end

  private

  def quantifier(kind, minimum, maximum, mode)
    Onibi::AST::Quantifier.new(Onibi::AST::Literal.new("a"), kind, minimum, maximum, mode)
  end
end
