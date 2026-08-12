# frozen_string_literal: true

require_relative "../../test_helper"

class SearchOriginEliminationBenchmarkTest < Minitest::Test
  def test_origin_restriction_matches_baseline_and_mri
    pattern = "\\Gfoo"
    input = "#{"x" * 64}foo"
    baseline, optimized = programs(pattern)

    assert_equal baseline.search(input, 0, capture: true), optimized.search(input, 0, capture: true)
    assert_equal ::Regexp.new(pattern).match?(input, 0), Onibi::Regexp.new(pattern).match?(input, 0)
    assert optimized.search_plan.origin_start
  end

  private

  def programs(pattern)
    ast = Onibi::Parser.new(pattern).parse
    optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
    baseline_plan = Onibi::Codegen::SearchPlan.new(
      **optimized.search_plan.to_h.merge(origin_start: false, search_mode: :scan, candidate_source: nil)
    )
    [Onibi::Codegen::GeneratedProgram.new(optimized.source, search_plan: baseline_plan), optimized]
  end
end
