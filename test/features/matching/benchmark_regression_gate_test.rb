# frozen_string_literal: true

require "json"
require "test_helper"
require_relative "../../../script/benchmark_report"

class BenchmarkRegressionGateTest < Minitest::Test
  def test_only_onibi_results_are_regression_gates
    before = {
      "literals/ascii/match/onibi" => { "ips" => 100.0 },
      "literals/ascii/match/ruby" => { "ips" => 100.0 }
    }
    after = {
      "literals/ascii/match/onibi" => { "ips" => 89.0 },
      "literals/ascii/match/ruby" => { "ips" => 1.0 }
    }

    failures = BenchmarkReport::RegressionChecker.new(before, after).regressions

    names = failures.map { |failure| failure.fetch(:name) }

    assert_equal ["literals/ascii/match/onibi"], names
  end

  def test_ten_percent_threshold_allows_exactly_ten_percent
    before = { "case/onibi" => { "ips" => 100.0 } }
    after = { "case/onibi" => { "ips" => 90.0 } }

    assert_empty BenchmarkReport::RegressionChecker.new(before, after).regressions
  end

  def test_threshold_rejects_more_than_ten_percent_regression
    before = { "case/onibi" => { "ips" => 100.0 } }
    after = { "case/onibi" => { "ips" => 89.9 } }

    assert_raises(RuntimeError) do
      BenchmarkReport::RegressionChecker.new(before, after).assert_clean!
    end
  end
end
