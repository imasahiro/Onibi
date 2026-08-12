# frozen_string_literal: true

require_relative "../../test_helper"

class PredicateTableRegistryBenchmarkTest < Minitest::Test
  def test_generated_table_identity_preserves_matching_result
    ast = Onibi::Parser.new("[a-z]+[0-9]").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)
    expected = ::Regexp.new("[a-z]+[0-9]").match("abc123")&.[](0)
    result = program.search("abc123", 0, capture: true)
    actual = result && "abc123"[result[0]...result[1]]

    assert_equal expected, actual
  end
end
