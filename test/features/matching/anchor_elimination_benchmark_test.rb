# frozen_string_literal: true

require_relative "../../test_helper"

class AnchorEliminationBenchmarkTest < Minitest::Test
  def test_end_anchor_plan_and_baseline_have_identical_output # rubocop:disable Metrics/AbcSize
    pattern = "elementary\\z"
    input = "#{"x" * 40}elementary".freeze
    ast = Onibi::Parser.new(pattern).parse
    optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
    analysis = Onibi::Codegen::Analyzer.new([]).analyze(ast)
    baseline = Onibi::Codegen::GeneratedProgram.new(
      optimized.source,
      search_plan: Onibi::Codegen::SearchPlan.new(
        anchor_start: false, anchor_end: false, minimum_width: analysis.widths.fetch(ast).minimum,
        first_set: nil, required_literal: "elementary", required_literals: nil,
        nullable_prefix: false, search_mode: :literal_skip, regular_run: nil, class_prefilter: nil
      )
    )

    assert_equal baseline.search(input, 0, capture: true), optimized.search(input, 0, capture: true)
    assert optimized.search_plan.anchor_end
  end
end
