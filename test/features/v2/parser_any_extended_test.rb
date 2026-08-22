# frozen_string_literal: true

require "test_helper"

class V2ParserAnyExtendedTest < Minitest::Test
  def test_any_node_has_exact_value
    assert_equal Onibi::AST::Sequence.new([Onibi::AST::Any.new(".")]), Onibi::V2::Parser.parse(".").ast
  end

  def test_extended_scoped_group_removes_comments_and_space
    body = Onibi::AST::Sequence.new([Onibi::AST::Literal.new("a"), Onibi::AST::Literal.new("b")])
    expected = Onibi::AST::Sequence.new([Onibi::AST::OptionGroup.new(body, nil, nil, true)])

    assert_equal expected, Onibi::V2::Parser.parse("(?x: a # comment\n b )").ast
  end

  def test_extended_mode_keeps_escaped_space_as_literal
    expected = Onibi::AST::Sequence.new([
                                          Onibi::AST::Literal.new("a"), Onibi::AST::Literal.new(" "), Onibi::AST::Literal.new("b")
                                        ])

    assert_equal expected, Onibi::V2::Parser.parse("a\\ b", options: ["extended"]).ast
  end
end
