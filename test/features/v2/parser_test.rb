# frozen_string_literal: true

require "test_helper"

class V2ParserTest < Minitest::Test
  def test_parse_returns_ast_with_source_options
    result = Onibi::V2::Parser.parse("ab|c", options: [])

    assert_instance_of Onibi::AST::Alternation, result.ast
    assert_equal "ab", result.ast.branches.first.parts.map(&:value).join
    assert_equal "c", result.ast.branches.last.parts.first.value
    assert_equal "ab|c", result.source
    assert_equal [], result.options
  end

  def test_parse_normalizes_public_option_forms
    assert_equal ["ignorecase"], Onibi::V2::Parser.parse("a", options: true).options
    assert_equal %w[ignorecase multiline], Onibi::V2::Parser.parse("a", options: "im").options
    assert_equal ["ignorecase"], Onibi::V2::Parser.parse("a", options: Onibi::Regexp::IGNORECASE).options
  end
end
