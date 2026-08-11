# frozen_string_literal: true

require "test_helper"
require_relative "../../support/differential_harness"

class DifferentialHarnessTest < Minitest::Test
  CASES = [
    { name: "match", pattern: "a", options: nil, input: "cat" },
    { name: "no match", pattern: "z", options: nil, input: "cat" },
    { name: "invalid pattern", pattern: "[", options: nil, input: "cat" },
    { name: "invalid input", pattern: "a", options: nil, input: 1 },
    { name: "invalid options", pattern: "a", options: ["bad"], input: "a" }
  ].freeze

  def test_harness_normalizes_results_and_explains_mismatches
    results = CASES.map { |fixture| DifferentialHarness.compare(fixture) }

    assert_equal true, equal_results?(results.take(2))
    mismatch = first_mismatch(results.drop(3))

    assert_mismatch(mismatch)
  end

  private

  def equal_results?(results)
    results.all? { |result| result.fetch(:equal) }
  end

  def first_mismatch(results)
    results.find { |result| !result.fetch(:equal) }
  end

  def assert_mismatch(mismatch)
    refute_nil mismatch
    assert_includes mismatch.fetch(:message), mismatch.fetch(:name)
    assert_kind_of Hash, mismatch.fetch(:mri)
    assert_kind_of Hash, mismatch.fetch(:onibi)
  end
end
