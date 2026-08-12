# frozen_string_literal: true

require "test_helper"

class BenchmarkWorkflowTest < Minitest::Test
  def test_benchmark_workflow_only_runs_for_library_changes
    workflow = File.read(File.join(PROJECT_ROOT, ".github/workflows/benchmark.yml"))

    assert_match(%r{pull_request:\n\s+paths:\n\s+- lib/\*\*}, workflow)
  end
end
