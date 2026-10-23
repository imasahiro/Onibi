# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../benchmark/regexp_features"

class BenchmarkApiTest < Minitest::Test
  def test_feature_corpus_has_mri_match_behavior
    RegexpFeatureBenchmark::Suite.load.cases.each do |benchmark_case|
      assert_equal benchmark_case.ruby_regexp.match?(benchmark_case.input),
                   benchmark_case.onibi_regexp.match?(benchmark_case.input),
                   benchmark_case.label
    end
  end

  def test_ascii_pattern_in_non_utf8_encoding_is_not_implicitly_fixed
    regexp = Onibi::Regexp.new("[a-z]".encode(Encoding::EUC_JP))
    refute regexp.fixed_encoding?
    refute regexp.match?("あ")
  end
end
