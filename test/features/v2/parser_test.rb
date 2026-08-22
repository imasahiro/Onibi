# frozen_string_literal: true

require "test_helper"

class V2ParserTest < Minitest::Test
  def test_parse_returns_ast_with_source_options
    result = Onibi::V2::Parser.parse("ab|c", options: [])

    expected = Onibi::AST::Alternation.new([
                                             Onibi::AST::Sequence.new([Onibi::AST::Literal.new("a"), Onibi::AST::Literal.new("b")]),
                                             Onibi::AST::Sequence.new([Onibi::AST::Literal.new("c")])
                                           ])

    assert_equal expected, result.ast
    assert_equal "ab|c", result.source
    assert_equal [], result.options
  end

  def test_parse_normalizes_public_option_forms
    assert_equal ["ignorecase"], Onibi::V2::Parser.parse("a", options: true).options
    assert_equal %w[ignorecase multiline], Onibi::V2::Parser.parse("a", options: "im").options
    assert_equal ["ignorecase"], Onibi::V2::Parser.parse("a", options: Onibi::Regexp::IGNORECASE).options
  end
end
