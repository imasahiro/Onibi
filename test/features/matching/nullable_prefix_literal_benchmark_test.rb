# frozen_string_literal: true

require_relative "../../test_helper"

class NullablePrefixLiteralBenchmarkTest < Minitest::Test
  def test_nullable_literal_prefix_matches_baseline_and_mri
    pattern = "a?foo"
    input = "#{"x" * 64}foo"
    baseline, optimized = programs(pattern)

    assert_equal baseline.search(input, 0, capture: true), optimized.search(input, 0, capture: true)
    assert_equal ::Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    assert_equal :first_set, optimized.search_plan.search_mode
  end

  private

  def programs(pattern)
    ast = Onibi::Parser.new(pattern).parse
    optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
    baseline_plan = Onibi::Codegen::SearchPlan.new(
      **optimized.search_plan.to_h.merge(class_prefilter: nil, candidate_source: nil, search_mode: :scan)
    )
    [Onibi::Codegen::GeneratedProgram.new(optimized.source, search_plan: baseline_plan), optimized]
  end
end
