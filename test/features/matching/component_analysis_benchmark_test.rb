# frozen_string_literal: true

require "test_helper"
require_relative "../../../benchmark/component_analysis"

class ComponentAnalysisBenchmarkTest < Minitest::Test
  def test_component_fixture_outputs_match_mri
    ComponentAnalysisBenchmark::CASES.each do |name, (pattern, input)|
      expected = Regexp.new(pattern).match?(input)
      actual = Onibi::Regexp.new(pattern).match?(input)

      assert_equal expected, actual, name
    end
  end

  def test_benchmark_has_explicit_operations
    assert_equal %w[compile match], ComponentAnalysisBenchmark::OPERATIONS
  end
end
