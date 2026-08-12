# frozen_string_literal: true

require_relative "../../test_helper"

class CandidateIntersectionBenchmarkTest < Minitest::Test
  def test_opt_in_intersection_matches_mri_fixture # rubocop:disable Metrics/AbcSize
    pattern = "alpha|beta|gamma|delta"
    input = "#{"x" * 32}gamma"
    ast = Onibi::Parser.new(pattern).parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: %i[swar candidate_intersection])

    expected = ::Regexp.new(pattern).match(input)
    actual = Onibi::Regexp.new(pattern).match(input)
    assert_equal [expected[0], expected.offset(0)], [actual[0], actual.offset(0)]
    result = program.search(input, 0, capture: true)
    assert_equal actual[0], input[result[0]...result[1]]
  end
end
