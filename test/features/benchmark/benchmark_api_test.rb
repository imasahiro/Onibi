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

  def test_rseq_vm_matches_mri_for_dispatched_cases
    RegexpFeatureBenchmark::Suite.load.cases.each do |benchmark_case|
      regexp = benchmark_case.onibi_regexp
      next unless regexp.pipeline[:vm] == :RSEQ

      assert_equal benchmark_case.ruby_regexp.match?(benchmark_case.input),
                   regexp.vm_match?(benchmark_case.input),
                   "RSeq #{benchmark_case.label}"
    end
  end

  def test_literal_pipeline_exposes_compiler_stages
    pipeline = Onibi::Regexp.new("abc").pipeline
    assert_equal(%i[literal literal literal], pipeline[:tokens].map { |token| token[:kind] })
    assert_equal([97, 98, 99], pipeline[:rseq].map { |op| op[:arg][:byte] })
    assert_equal :sequence, pipeline[:ast][:type]
    assert_equal :RSEQ, pipeline[:vm]
  end

  def test_literal_rseq_vm_matches_substring
    regexp = Onibi::Regexp.new("abc")
    assert regexp.vm_match?("xxabcxx")
    refute regexp.vm_match?("xxabxx")
  end

  def test_tokenizer_marks_classes_and_alternation
    kinds = Onibi::Regexp.new("[ab]|cd").pipeline[:tokens].map { |token| token[:kind] }
    assert_equal %i[class_start literal literal class_end alternation literal literal], kinds
  end

  def test_single_character_alternation_rseq_vm
    regexp = Onibi::Regexp.new("a|b")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.vm_match?("xxbxx")
    refute regexp.vm_match?("xxcxx")
  end

  def test_multi_character_alternation_rseq_vm
    regexp = Onibi::Regexp.new("foo|bar")
    assert regexp.vm_match?("xxbarxx")
    refute regexp.vm_match?("xxbazxx")
    assert_equal :alternation, regexp.pipeline[:ast][:type]
  end

  def test_rseq_class_sequence_public_match
    regexp = Onibi::Regexp.new("[a]b")
    assert_equal :MRI, regexp.pipeline[:vm]
    assert regexp.match?("xxabxx")
    refute regexp.match?("xxacxx")
  end

  def test_quantifier_ast_and_repeat_opcode
    pipeline = Onibi::Regexp.new("a{2,3}").pipeline
    assert_equal :quantifier, pipeline[:ast][:type]
    assert_includes pipeline[:rseq].map { |op| op[:op] }, :REPEAT
  end

  def test_class_and_anchor_ast_types
    assert_equal :character_class, Onibi::Regexp.new("[ab]").pipeline[:ast][:type]
    assert_equal :anchor, Onibi::Regexp.new("^abc$").pipeline[:ast][:type]
  end

  def test_literal_wildcard_sequence_rseq_vm
    regexp = Onibi::Regexp.new("a.c")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.vm_match?("xxabcxx")
    refute regexp.vm_match?("xxacxx")
  end
end
