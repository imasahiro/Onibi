# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../benchmark/swar_multi_literal"

class SwarMultiLiteralBenchmarkTest < Minitest::Test
  def test_swar_and_baseline_benchmark_outputs_are_equivalent
    assert_equal [true], SwarMultiLiteralBenchmark.results.values.uniq
  end
end
