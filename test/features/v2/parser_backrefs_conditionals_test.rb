# frozen_string_literal: true

require "test_helper"

class V2ParserBackreferencesConditionalsTest < Minitest::Test
  def test_numbered_and_named_backreferences_have_exact_ast
    expected = Onibi::AST::Sequence.new([
                                          Onibi::AST::Group.new(
                                            Onibi::AST::Sequence.new([Onibi::AST::Literal.new("a")]), 1, true, nil
                                          ),
                                          Onibi::AST::Backreference.new(1, false),
                                          Onibi::AST::Group.new(
                                            Onibi::AST::Sequence.new([Onibi::AST::Literal.new("b")]), 2, true, "word"
                                          ),
                                          Onibi::AST::Backreference.new("word", true)
                                        ])

    assert_equal expected, Onibi::V2::Parser.parse("(a)\\1(?<word>b)\\k<word>").ast
  end

  def test_conditionals_have_exact_condition_and_branches
    body = Onibi::AST::Sequence.new([Onibi::AST::Literal.new("a")])
    condition = Onibi::AST::Conditional.new(
      ["letter", true],
      Onibi::AST::Sequence.new([Onibi::AST::Literal.new("b")]),
      Onibi::AST::Sequence.new([Onibi::AST::Literal.new("c")])
    )
    expected = Onibi::AST::Sequence.new([
                                          Onibi::AST::Group.new(body, 1, true, "letter"),
                                          condition
                                        ])

    assert_equal expected, Onibi::V2::Parser.parse("(?<letter>a)(?(<letter>)b|c)").ast
  end

  def test_subexpression_calls_have_exact_identifier_kind
    expected = Onibi::AST::Sequence.new([
                                          Onibi::AST::SubexpressionCall.new(1, false),
                                          Onibi::AST::SubexpressionCall.new("letter", true)
                                        ])

    assert_equal expected, Onibi::V2::Parser.parse("\\g1\\g<letter>").ast
  end
end
