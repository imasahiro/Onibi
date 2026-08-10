# frozen_string_literal: true

require "test_helper"
require_relative "../support/differential_harness"

class DifferentialHarnessTest < Minitest::Test
  CASES = [
    { name: "match", pattern: "a", options: nil, input: "cat" },
    { name: "no match", pattern: "z", options: nil, input: "cat" },
    { name: "invalid pattern", pattern: "[", options: nil, input: "cat" },
    { name: "invalid input", pattern: "a", options: nil, input: 1 }
  ].freeze

  def test_harness_normalizes_results_and_explains_mismatches
    results = CASES.map { |fixture| DifferentialHarness.compare(fixture) }

    assert_equal true, equal_results?(results.take(2))
    mismatch = first_mismatch(results.drop(2))

    refute_nil mismatch
    assert_includes mismatch.fetch(:message), mismatch.fetch(:name)
    assert mismatch.fetch(:mri).is_a?(Hash)
    assert mismatch.fetch(:onibi).is_a?(Hash)
  end

  private

  def equal_results?(results)
    results.all? { |result| result.fetch(:equal) }
  end

  def first_mismatch(results)
    results.find { |result| !result.fetch(:equal) }
  end
end
