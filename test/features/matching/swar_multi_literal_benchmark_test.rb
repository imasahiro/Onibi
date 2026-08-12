# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../benchmark/swar_multi_literal"

class SwarMultiLiteralBenchmarkTest < Minitest::Test
  def test_suite_includes_regular_literal_early_and_late_matches
    assert_includes SwarMultiLiteralBenchmark::CASES, :regular_early
    assert_includes SwarMultiLiteralBenchmark::CASES, :regular_late
    assert_includes SwarMultiLiteralBenchmark::CASES, :regular_no_match
    assert_includes SwarMultiLiteralBenchmark::CASES, :one_character_no_match
    assert_includes SwarMultiLiteralBenchmark::CASES, :word_width_no_match
  end

  def test_swar_and_baseline_benchmark_outputs_are_equivalent
    SwarMultiLiteralBenchmark.results.each do |name, variants|
      assert_equal [SwarMultiLiteralBenchmark::CASES.fetch(name).expected], variants.values.uniq, name
    end
  end

  def test_every_benchmark_case_exercises_the_swar_path
    SwarMultiLiteralBenchmark::CASES.each do |name, benchmark_case|
      swar = SwarMultiLiteralBenchmark.programs(benchmark_case).fetch("codegen with SWAR")

      assert swar.swar?, name
    end
  end
end
