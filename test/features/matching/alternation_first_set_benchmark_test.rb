# frozen_string_literal: true

require_relative "../../test_helper"

class AlternationFirstSetBenchmarkTest < Minitest::Test
  def test_first_set_prefilter_matches_baseline_and_mri
    pattern = "a|[b]|c"
    input = "#{"x" * 64}b"
    baseline, optimized = programs(pattern)

    assert_equal baseline.search(input, 0, capture: true), optimized.search(input, 0, capture: true)
    assert_mri_match(pattern, input, optimized)
  end

  private

  def programs(pattern)
    ast = Onibi::Parser.new(pattern).parse
    optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
    plan = optimized.search_plan
    baseline_plan = Onibi::Codegen::SearchPlan.new(
      **plan.to_h.merge(class_prefilter: nil, candidate_source: nil, search_mode: :scan)
    )
    [Onibi::Codegen::GeneratedProgram.new(optimized.source, search_plan: baseline_plan), optimized]
  end

  def assert_mri_match(pattern, input, program)
    expected = ::Regexp.new(pattern).match(input)
    result = program.search(input, 0, capture: true)
    actual = [input[result[0]...result[1]], [result[0], result[1]]]

    assert_equal [expected[0], expected.offset(0)], actual
  end
end
