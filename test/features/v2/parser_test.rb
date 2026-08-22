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
end
