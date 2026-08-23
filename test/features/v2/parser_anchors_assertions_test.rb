# frozen_string_literal: true

require "test_helper"

class V2ParserAnchorsAssertionsTest < Minitest::Test
  def test_anchor_nodes_have_exact_kinds
    expected = Onibi::AST::Sequence.new([
                                          Onibi::AST::Anchor.new(:anchor_start),
                                          Onibi::AST::Anchor.new(:anchor_absolute_start),
                                          Onibi::AST::Anchor.new(:anchor_end),
                                          Onibi::AST::Anchor.new(:anchor_absolute_end),
                                          Onibi::AST::Anchor.new(:anchor_before_final_newline)
                                        ])

    assert_equal expected, Onibi::Parser.parse("^\\A$\\z\\Z").ast
  end

  def test_lookaround_nodes_have_exact_body_and_kind
    expected = Onibi::AST::Sequence.new([
                                          assertion(:positive, "a"),
                                          assertion(:negative, "b"),
                                          assertion(:positive_lookbehind, "c"),
                                          assertion(:negative_lookbehind, "d")
                                        ])

    assert_equal expected, Onibi::Parser.parse("(?=a)(?!b)(?<=c)(?<!d)").ast
  end

  private

  def assertion(kind, value)
    body = Onibi::AST::Sequence.new([Onibi::AST::Literal.new(value)])
    Onibi::AST::Assertion.new(body, kind)
  end
end
