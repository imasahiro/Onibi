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

  def test_parse_accepts_global_inline_option_groups
    result = Onibi::V2::Parser.parse("(?imx)cat")

    assert_equal Onibi::AST::Sequence.new(%w[c a t].map { |value| Onibi::AST::Literal.new(value) }), result.ast
    assert_equal %w[ignorecase multiline extended], result.options
  end

  def test_parse_accepts_global_disabled_inline_options
    result = Onibi::V2::Parser.parse("(?-imx)cat", options: %w[ignorecase multiline extended])

    assert_equal Onibi::AST::Sequence.new(%w[c a t].map { |value| Onibi::AST::Literal.new(value) }), result.ast
    assert_equal [], result.options
  end

  def test_literal_concatenation_and_alternation_have_exact_ast_shape
    expected = Onibi::AST::Alternation.new([
                                             Onibi::AST::Sequence.new(%w[c a t].map { |value| Onibi::AST::Literal.new(value) }),
                                             Onibi::AST::Sequence.new(%w[d o g].map { |value| Onibi::AST::Literal.new(value) })
                                           ])

    assert_equal expected, Onibi::V2::Parser.parse("cat|dog").ast
  end
end
