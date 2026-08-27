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

  def test_literal_pipeline_exposes_compiler_stages
    pipeline = Onibi::Regexp.new("abc").pipeline
    assert_equal(%i[literal literal literal], pipeline[:tokens].map { |token| token[:kind] })
    assert_equal([97, 98, 99], pipeline[:rseq].map { |token| token[:byte] })
    assert_equal :MRI, pipeline[:vm]
  end

  def test_literal_rseq_vm_matches_substring
    regexp = Onibi::Regexp.new("abc")
    assert regexp.vm_match?("xxabcxx")
    refute regexp.vm_match?("xxabxx")
  end
end
