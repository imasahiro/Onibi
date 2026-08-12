# frozen_string_literal: true

require_relative "../../test_helper"

class FixedWidthSuffixLiteralBenchmarkTest < Minitest::Test
  def test_suffix_literal_candidates_match_baseline_and_mri
    pattern = ".[a-z]foo"
    input = "#{"xAbar\n" * 20}xyfoo"
    baseline, optimized = programs(pattern)

    assert_equal baseline.search(input, 0, capture: true), optimized.search(input, 0, capture: true)
    assert_equal ::Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    assert_equal [["foo", 2]], optimized.search_plan.required_literals
  end

  private

  def programs(pattern)
    ast = Onibi::Parser.new(pattern).parse
    optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
    baseline_plan = Onibi::Codegen::SearchPlan.new(
      **optimized.search_plan.to_h.merge(required_literals: nil, required_literal_source: nil, search_mode: :scan)
    )
    [Onibi::Codegen::GeneratedProgram.new(optimized.source, search_plan: baseline_plan), optimized]
  end
end
