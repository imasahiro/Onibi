# frozen_string_literal: true

require "test_helper"
require_relative "../../../benchmark/regexp_features"

class RegexpFeatureBenchmarkTest < Minitest::Test
  EXPECTED_FEATURES = %w[
    absence_operator alternation anchors atomic_group backreference boundaries
    captures character_classes conditional dot greedy_quantifier lazy_quantifier
    literals match_reset named_captures options possessive_quantifier posix_classes
    shorthand_classes subexpression_call unicode_properties lookahead lookbehind
  ].freeze

  def setup
    @suite = RegexpFeatureBenchmark::Suite.load
  end

  def test_suite_covers_supported_regexp_features
    assert_equal EXPECTED_FEATURES.sort, @suite.cases.map(&:feature).uniq.sort
    assert_equal %w[ascii utf8], @suite.cases.map(&:encoding).uniq.sort
    assert_operator @suite.cases.length, :>=, 30
  end

  def test_case_names_are_unique_and_inputs_use_the_declared_encoding
    labels = @suite.cases.map(&:label)

    assert_equal labels.uniq, labels
    @suite.cases.each do |benchmark_case|
      assert_equal benchmark_case.ruby_encoding, benchmark_case.pattern.encoding, benchmark_case.label
      assert_equal benchmark_case.ruby_encoding, benchmark_case.input.encoding, benchmark_case.label
    end
  end

  def test_ruby_and_onibi_produce_the_same_result_for_every_case
    @suite.cases.each do |benchmark_case|
      assert_equal benchmark_case.ruby_regexp.match?(benchmark_case.input),
                   benchmark_case.onibi_regexp.match?(benchmark_case.input), benchmark_case.label
    end
  end

  def test_filters_select_feature_and_encoding
    cases = @suite.select(feature: "literals", encoding: "utf8")

    assert_equal 1, cases.length
    assert_equal "literals/utf8/unicode-literal", cases.first.label
  end

  def test_runner_separates_compile_first_match_and_warm_match_costs
    assert_equal %w[compile first_match match], RegexpFeatureBenchmark::Runner::OPERATIONS
  end
end
