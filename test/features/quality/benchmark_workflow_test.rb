# frozen_string_literal: true

require "test_helper"

class BenchmarkWorkflowTest < Minitest::Test
  def test_benchmark_workflow_uses_short_measurement_window
    workflow = File.read(File.join(PROJECT_ROOT, ".github/workflows/benchmark.yml"))

    assert_equal 2, workflow.scan(%r{script/benchmark_report\.rb --time 0\.5}).length
    assert_equal 2, workflow.scan(/--warmup 0\.25/).length
  end
end
