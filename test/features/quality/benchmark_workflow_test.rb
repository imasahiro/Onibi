# frozen_string_literal: true

require "test_helper"

class BenchmarkWorkflowTest < Minitest::Test
  def test_benchmark_workflow_only_runs_for_library_changes
    workflow = File.read(File.join(PROJECT_ROOT, ".github/workflows/benchmark.yml"))

    assert_match(%r{pull_request:\n\s+paths:\n\s+- lib/\*\*}, workflow)
  end

  def test_ci_benchmark_report_runs_only_onibi
    report = File.read(File.join(PROJECT_ROOT, "script/benchmark_report.rb"))

    assert_equal 2, report.scan(/benchmark\.report\("onibi"\)/).length
    refute_match(/benchmark\.report\("ruby"\)/, report)
    refute_match(/%i\[ruby onibi\]/, report)
  end
end
