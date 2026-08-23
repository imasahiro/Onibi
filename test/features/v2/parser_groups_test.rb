# frozen_string_literal: true

require "test_helper"

class V2ParserGroupsTest < Minitest::Test
  def test_numbered_and_non_capturing_groups_have_exact_ast
    expected = Onibi::AST::Sequence.new([
                                          Onibi::AST::Group.new(
                                            Onibi::AST::Sequence.new([Onibi::AST::Literal.new("a"), Onibi::AST::Literal.new("b")]), 1, true, nil
                                          ),
                                          Onibi::AST::Group.new(
                                            Onibi::AST::Sequence.new([Onibi::AST::Literal.new("c"), Onibi::AST::Literal.new("d")]), nil, false, nil
                                          )
                                        ])

    assert_equal expected, Onibi::Parser.parse("(ab)(?:cd)").ast
  end

  def test_named_group_has_name_and_capture_number
    body = Onibi::AST::Sequence.new([Onibi::AST::Literal.new("a")])
    expected = Onibi::AST::Sequence.new([Onibi::AST::Group.new(body, 1, true, "word")])

    assert_equal expected, Onibi::Parser.parse("(?<word>a)").ast
  end
end
