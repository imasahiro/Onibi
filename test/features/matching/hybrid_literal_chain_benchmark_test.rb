# frozen_string_literal: true

require "test_helper"
require_relative "../../../benchmark/hybrid_literal_chain"

class HybridLiteralChainBenchmarkTest < Minitest::Test
  def test_benchmark_fixture_matches_baseline_and_mri
    HybridLiteralChainBenchmark::CASES.each_value do |pattern, input|
      baseline, hybrid = HybridLiteralChainBenchmark.programs(pattern)

      assert_equal baseline.search(input, 0, capture: false), hybrid.search(input, 0, capture: false)
      assert_equal Regexp.new(pattern).match?(input), hybrid.search(input, 0, capture: false)
    end
  end

  def test_benchmark_separates_match_lifecycle_operations
    assert_equal %w[compile first_match match_question match scan gsub],
                 HybridLiteralChainBenchmark::OPERATIONS
  end
end
