# frozen_string_literal: true

require_relative "../../test_helper"

class LineAnchorEliminationBenchmarkTest < Minitest::Test
  def test_line_anchor_candidates_match_baseline_and_mri
    pattern = "^foo"
    input = "#{"x" * 64}bar\nfoo"
    baseline, optimized = programs(pattern)

    assert_equal baseline.search(input, 0, capture: true), optimized.search(input, 0, capture: true)
    assert_equal ::Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    assert optimized.search_plan.line_anchor
  end

  private

  def programs(pattern)
    ast = Onibi::Parser.new(pattern).parse
    optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
    baseline_plan = Onibi::Codegen::SearchPlan.new(
      **optimized.search_plan.to_h.merge(line_anchor: false, class_prefilter: nil, candidate_source: nil,
                                         search_mode: :scan)
    )
    [Onibi::Codegen::GeneratedProgram.new(optimized.source, search_plan: baseline_plan), optimized]
  end
end
