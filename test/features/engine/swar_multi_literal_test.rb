# frozen_string_literal: true

require_relative "../../test_helper"

class SwarMultiLiteralTest < Minitest::Test
  def test_public_matching_uses_swar_for_literal_alternation_and_agrees_with_mri
    pattern = "sherlock|watson|moriarty|adler"
    input = "elementary, watson; sherlock followed"
    expected = ::Regexp.new(pattern).match(input)
    regexp = Onibi::Regexp.new(pattern)
    actual = regexp.match(input)

    assert_equal expected[0], actual[0]
    assert_equal expected.offset(0), actual.offset(0)
    assert regexp.match?(input)
    assert regexp.send(:codegen_program).swar?
  end

  def test_prefilter_returns_sorted_unique_candidates_for_different_lengths
    prefilter = Onibi::Experimental::Swar::MultiLiteralPrefilter.new(%w[alpha alphabet beta])

    assert_equal [2, 11], prefilter.candidate_positions("xxalphabet-beta", 0)
  end

  def test_prefilter_splits_patterns_without_exceeding_the_word_width
    patterns = 20.times.map { |index| format("p%02d", index) }
    prefilter = Onibi::Experimental::Swar::MultiLiteralPrefilter.new(patterns)

    assert_operator prefilter.bucket_count, :>, 1
    assert(prefilter.buckets.all? { |bucket| bucket.width <= Onibi::Experimental::Swar::WORD_BITS })
    assert_equal Onibi::Experimental::Swar::WORD_BITS, Onibi::Experimental::Swar::WORD_MASK.bit_length
    assert_equal [3, 7], prefilter.candidate_positions("xx-p19-p00", 0)
  end

  def test_swar_and_baseline_codegen_have_identical_results
    ast = Onibi::Parser.new("a|ab|cab|dab").parse
    swar = Onibi::Codegen::GeneratedProgram.ast(ast)
    baseline = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
    inputs = ["", "ab", "xxcab", "zz", "dab-a"]

    expected = inputs.map { |input| baseline.search(input, 0, capture: true) }
    actual = inputs.map { |input| swar.search(input, 0, capture: true) }

    assert swar.swar?
    refute baseline.swar?
    assert_equal expected, actual
  end

  def test_ineligible_patterns_keep_the_baseline_search
    ignorecase_ast = Onibi::Parser.new("cat|dog").parse
    nonliteral_ast = Onibi::Parser.new("cat|d.g").parse

    refute Onibi::Codegen::GeneratedProgram.ast(ignorecase_ast, options: ["ignorecase"]).swar?
    refute Onibi::Codegen::GeneratedProgram.ast(nonliteral_ast).swar?
  end
end
