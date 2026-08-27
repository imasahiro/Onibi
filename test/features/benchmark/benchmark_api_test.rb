# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../benchmark/regex_redux"
require_relative "../../../benchmark/regexp_features"

class BenchmarkApiTest < Minitest::Test
  def test_regex_redux_matches_mri_output
    input = File.read(File.join(__dir__, "../../../benchmark/fasta-500.txt"))
    ruby = RegexRedux.new(StringIO.new(input), engine: :ruby).to_s
    onibi = RegexRedux.new(StringIO.new(input), engine: :onibi).to_s
    assert_equal ruby, onibi
  end

  def test_feature_corpus_has_mri_match_behavior
    RegexpFeatureBenchmark::Suite.load.cases.each do |benchmark_case|
      assert_equal benchmark_case.ruby_regexp.match?(benchmark_case.input),
                   benchmark_case.onibi_regexp.match?(benchmark_case.input),
                   benchmark_case.label
    end
  end
end
