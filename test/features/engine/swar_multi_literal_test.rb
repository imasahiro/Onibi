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

  def test_swar_prefilter_implements_candidate_source_protocol
    source = Onibi::Experimental::Swar::MultiLiteralPrefilter.new(%w[alpha beta])

    input = "#{"x" * Onibi::Experimental::Swar::MINIMUM_INPUT_BYTES}alpha"

    assert source.eligible?(input, 0)
    assert_equal [Onibi::Experimental::Swar::MINIMUM_INPUT_BYTES], source.candidate_positions(input, 0)
    assert source.preserves_order?
  end

  def test_prefilter_splits_patterns_without_exceeding_the_word_width
    patterns = 20.times.map { |index| format("p%02d", index) }
    prefilter = Onibi::Experimental::Swar::MultiLiteralPrefilter.new(patterns)

    assert_operator prefilter.bucket_count, :>, 1
    assert(prefilter.buckets.all? { |bucket| bucket.width <= Onibi::Experimental::Swar::WORD_BITS })
    assert_equal Onibi::Experimental::Swar::WORD_BITS, Onibi::Experimental::Swar::WORD_MASK.bit_length
    assert_equal [3, 7], prefilter.candidate_positions("xx-p19-p00", 0)
  end

  def test_word_width_prefix_filters_long_literals_without_changing_public_results
    patterns, input = long_literal_fixture
    ast = Onibi::Parser.new(patterns.join("|")).parse
    default_program = Onibi::Codegen::GeneratedProgram.ast(ast)
    experimental_program = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: %i[swar swar_long_literals])

    refute default_program.swar?
    assert experimental_program.swar?
    assert experimental_program.search(input, 0, capture: false)
  end

  def test_word_width_literals_require_explicit_internal_optimization
    word_bits = Onibi::Experimental::Swar::WORD_BITS
    ast = Onibi::Parser.new("#{"a" * word_bits}|#{"b" * word_bits}").parse
    default_program = Onibi::Codegen::GeneratedProgram.ast(ast)
    experimental_program = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: %i[swar swar_long_literals])

    refute default_program.swar?
    assert experimental_program.swar?
  end

  def test_public_long_literal_alternation_agrees_with_mri
    patterns, input = long_literal_fixture
    expected = ::Regexp.new(patterns.join("|")).match(input)
    actual = Onibi::Regexp.new(patterns.join("|")).match(input)

    assert_equal expected[0], actual[0]
    assert_equal expected.offset(0), actual.offset(0)
  end

  def test_short_inputs_are_not_profitable_for_the_default_swar_search
    prefilter = Onibi::Experimental::Swar::MultiLiteralPrefilter.new(%w[a b])
    minimum = Onibi::Experimental::Swar::MINIMUM_INPUT_BYTES

    refute prefilter.profitable?("a", 0)
    assert prefilter.profitable?("#{"x" * (minimum - 1)}a", 0)
  end

  def test_single_character_swar_requires_explicit_internal_optimization
    ast = Onibi::Parser.new("a|b|c|d").parse
    default_program = Onibi::Codegen::GeneratedProgram.ast(ast)
    experimental_program = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: %i[swar swar_single_character])

    refute default_program.swar?
    assert experimental_program.swar?
    assert experimental_program.search("#{"x" * 100}d", 0, capture: false)
  end

  def test_swar_and_baseline_codegen_have_identical_results
    ast = Onibi::Parser.new("aa|ab|cab|dab").parse
    swar = Onibi::Codegen::GeneratedProgram.ast(ast)
    baseline = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])
    inputs = ["", "ab", "xxcab", "zz", "dab-aa"]

    expected = inputs.map { |input| baseline.search(input, 0, capture: true) }
    actual = inputs.map { |input| swar.search(input, 0, capture: true) }

    assert swar.swar?
    refute baseline.swar?
    assert_equal expected, actual
  end

  def test_character_class_prefilter_produces_ordered_candidate_positions
    source = Onibi::Experimental::Swar::ClassPrefilter.new("a-z")

    assert_equal [1, 3, 4], source.candidate_positions("1a2bc", 0)
    assert source.preserves_order?
  end

  def test_leading_character_class_uses_class_prefilter_in_search_plan
    regexp = Onibi::Regexp.new("[a-z]\\d+")

    assert_equal :class_prefilter, regexp.send(:codegen_program).search_plan.search_mode
    assert_equal "a2", regexp.match("--a2--").to_s
  end

  def test_ineligible_patterns_keep_the_baseline_search
    ignorecase_ast = Onibi::Parser.new("cat|dog").parse
    nonliteral_ast = Onibi::Parser.new("cat|d.g").parse

    refute Onibi::Codegen::GeneratedProgram.ast(ignorecase_ast, options: ["ignorecase"]).swar?
    refute Onibi::Codegen::GeneratedProgram.ast(nonliteral_ast).swar?
  end

  def test_class_run_swar_returns_run_end_for_ascii_class
    run = Onibi::Experimental::Swar::ClassRun.new("a-z")

    assert_equal [0, 3, []], run.search("abc123", 0, capture: true)
    assert_equal false, run.search("123", 0, capture: false)
  end

  def test_default_policy_keeps_single_and_word_width_literals_opt_in
    word_bits = Onibi::Experimental::Swar::WORD_BITS

    assert_equal :default, Onibi::Experimental::Swar::LiteralAlternation.policy_for(%w[aa bb])
    assert_equal :opt_in, Onibi::Experimental::Swar::LiteralAlternation.policy_for(%w[a b])
    assert_equal :opt_in, Onibi::Experimental::Swar::LiteralAlternation.policy_for(["a" * word_bits, "b" * word_bits])
    assert_equal :opt_in,
                 Onibi::Experimental::Swar::LiteralAlternation.policy_for(["a" * (word_bits + 1),
                                                                           "b" * (word_bits + 1)])
  end

  def test_default_policy_falls_back_for_late_and_no_match_inputs
    ast = Onibi::Parser.new("sherlock|watson|moriarty").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert program.search("sherlock", 0, capture: false)
    assert program.search("#{"x" * 500}moriarty", 0, capture: false)
    refute program.search("#{"x" * 500}nobody", 0, capture: false)
    assert_equal false, program.prefilter_profitable?("#{"x" * 500}moriarty", 0)
  end

  private

  def long_literal_fixture
    word_bits = Onibi::Experimental::Swar::WORD_BITS
    patterns = ["a" * (word_bits + 1), "b" * (word_bits + 2)]
    [patterns, "xx#{patterns.last}"]
  end
end
