# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenMatchAdapterTest < Minitest::Test
  def test_generated_offsets_build_existing_match_data
    ast = Onibi::Parser.new("(a)(?<word>b)").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)
    result = program.search("ab", 0, capture: true)
    regexp = Onibi::Regexp.new("ab")
    match = Onibi::Codegen::MatchAdapter.build(result, "ab", regexp, "word" => 2)

    assert_equal "ab", match[0]
    assert_equal %w[a b], match.captures
    assert_equal [[0, 2], [0, 1], [1, 2]], [match.offset(0), match.offset(1), match.offset(2)]
  end
end
