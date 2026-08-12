# frozen_string_literal: true

require_relative "../../test_helper"

class ClassPrefilterBenchmarkTest < Minitest::Test
  def test_class_prefilter_and_baseline_produce_equivalent_fixture_output
    pattern = "[a-z]\\d+"
    input = ("--a2--" * 8).freeze
    optimized, baseline = programs(pattern)

    assert_equal baseline.search(input, 0, capture: true), optimized.search(input, 0, capture: true)
    assert_equal ::Regexp.new(pattern).match(input).to_s, Onibi::Regexp.new(pattern).match(input).to_s
  end

  private

  def programs(pattern)
    ast = Onibi::Parser.new(pattern).parse
    analysis = Onibi::Codegen::Analyzer.new([]).analyze(ast)
    optimized = Onibi::Codegen::GeneratedProgram.ast(ast)
    [optimized, Onibi::Codegen::GeneratedProgram.new(optimized.source, search_plan: baseline_plan(analysis, ast))]
  end

  def baseline_plan(analysis, ast)
    Onibi::Codegen::SearchPlan.new(
      anchor_start: false, anchor_end: false, minimum_width: analysis.widths.fetch(ast).minimum,
      first_set: nil, required_literal: nil, required_literals: nil, nullable_prefix: true,
      search_mode: :scan, regular_run: nil, class_prefilter: nil
    )
  end
end
