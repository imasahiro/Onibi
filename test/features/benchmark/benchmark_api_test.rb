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
    assert_equal(%i[literal literal literal], pipeline[:ast][:children].map { |node| node[:type] })
    assert_equal :RSEQ, pipeline[:vm]
    assert_equal :REGULAR_FAST, pipeline[:interpreter]
    assert_equal :ACCEPT, pipeline[:gir_graph][:states].last[:op]
    assert_equal({ from: 0, to: 1, actions: [] }, pipeline[:gir_graph][:edges].first)
    assert_equal [{ op: :STRING, arg: "abc" }], pipeline[:rseq_compact]
    assert_equal [{ op: :RUN_CLASS, arg: "[ab]" }], Onibi::Regexp.new("[ab]").pipeline[:rseq_compact]
    assert_equal [{ op: :RUN_ANY, arg: 1 }], Onibi::Regexp.new(".").pipeline[:rseq_compact]
    assert_equal [{ op: :RUN_CLASS, arg: "[a-z]+[0-9]+" }], Onibi::Regexp.new("[a-z]+[0-9]+").pipeline[:rseq_compact]
  end

  def test_literal_rseq_vm_matches_substring
    regexp = Onibi::Regexp.new("abc")
    assert regexp.vm_match?("xxabcxx")
    refute regexp.vm_match?("xxabxx")
    assert_equal({ start: 2, end: 5 }, regexp.vm_match_result("xxabcxx"))
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
    edges = regexp.pipeline[:gir_graph][:edges]
    assert_equal([0, 2], edges.map { |edge| edge[:to] })
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

  def test_wildcard_repeat_sequence_rseq_vm
    regexp = Onibi::Regexp.new("a.*z")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.vm_match?("a-middle-z")
    refute regexp.vm_match?("a-middle")
  end

  def test_bounded_repeat_dispatches_to_rseq
    regexp = Onibi::Regexp.new("a{2,3}")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.match?("baaaac")
    refute regexp.match?("bc")
  end

  def test_quantifier_gir_has_ordered_repeat_cycle
    edges = Onibi::Regexp.new("a*").pipeline[:gir_graph][:edges]
    assert_equal [{ from: 0, to: 1, actions: [] },
                  { from: 1, to: 0, actions: [] },
                  { from: 1, to: 2, actions: [] }], edges
  end

  def test_simple_character_class_dispatches_to_rseq
    regexp = Onibi::Regexp.new("[ab]")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.match?("xxbxx")
    refute regexp.match?("xxcxx")
  end

  def test_character_class_repeat_dispatches_to_rseq
    regexp = Onibi::Regexp.new("[a-z]+")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.match?("item-2026")
    refute regexp.match?("123")
  end

  def test_character_class_pair_repeat_dispatches_to_rseq
    regexp = Onibi::Regexp.new("[a-z]+[0-9]+")
    assert_equal :RSEQ, regexp.pipeline[:vm]
    assert regexp.match?("token-abc123-end")
    refute regexp.match?("token-abc-end")
  end

  def test_dynamic_features_select_dynamic_interpreter
    assert_equal :DYNAMIC, Onibi::Regexp.new("(a)-\\1").pipeline[:interpreter]
  end

  def test_anchor_assertions_are_edge_actions
    edges = Onibi::Regexp.new("^abc$").pipeline[:gir_graph][:edges]
    assert_equal :ASSERT_BEGIN_BUFFER, edges.first[:actions].first[:op]
    assert_equal :ASSERT_END_BUFFER, edges.last[:actions].first[:op]
  end

  def test_capture_tokens_and_execution_class
    regexp = Onibi::Regexp.new("(abc)")
    assert_equal :TAGGED_ORDERED, regexp.pipeline[:interpreter]
    assert_equal(%i[group_start literal literal literal group_end], regexp.pipeline[:tokens].map { |token| token[:kind] })
    actions = regexp.pipeline[:gir_graph][:edges].flat_map { |edge| edge[:actions] }
    assert_equal(%i[CAPTURE_OPEN CAPTURE_CLOSE], actions.map { |action| action[:op] })
    assert regexp.match?("xxabcxx")
    refute regexp.match?("xxabxx")
  end
end
