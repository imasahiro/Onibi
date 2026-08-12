# frozen_string_literal: true

require_relative "../../test_helper"

class NullablePrefixBenchmarkTest < Minitest::Test
  def test_nullable_prefix_prefilter_matches_mri_and_baseline
    pattern = "[a-z]*foo"
    inputs = ["--afoo--foo", "x" * 128, "foo", "afo"]
    optimized, baseline = programs(pattern)

    inputs.each do |input|
      assert_fixture(pattern, input, optimized, baseline)
    end
  end

  private

  def programs(pattern)
    ast = Onibi::Parser.new(pattern).parse
    optimized = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
    analysis = Onibi::Codegen::Analyzer.new([]).analyze(ast)
    [optimized, baseline_program(optimized, analysis, ast)]
  end

  def baseline_program(optimized, analysis, ast)
    plan = Onibi::Codegen::SearchPlan.new(
      anchor_start: false, anchor_end: false, minimum_width: analysis.widths.fetch(ast).minimum,
      first_set: nil, required_literal: nil, required_literals: nil, nullable_prefix: true,
      search_mode: :scan, regular_run: nil, class_prefilter: nil
    )
    Onibi::Codegen::GeneratedProgram.new(optimized.source, search_plan: plan)
  end

  def assert_fixture(pattern, input, optimized, baseline)
    expected = ::Regexp.new(pattern).match?(input)
    actual = optimized.search(input, 0, capture: false)
    assert_equal expected, actual, input
    assert_equal baseline.search(input, 0, capture: false), actual, input
  end
end
