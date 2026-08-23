# frozen_string_literal: true

require "test_helper"

class V2ParserCommentsTest < Minitest::Test
  def test_pattern_comment_is_removed_without_changing_ast
    expected = Onibi::AST::Sequence.new([
                                          Onibi::AST::Literal.new("c"),
                                          Onibi::AST::Literal.new("a"),
                                          Onibi::AST::Literal.new("t")
                                        ])

    assert_equal expected, Onibi::Parser.parse("(?# greeting)cat").ast
  end
end
