# frozen_string_literal: true

require "test_helper"

class MatchApiTest < Minitest::Test
  def test_match_returns_match_data_with_full_match_and_offset
    match = Onibi::Regexp.new("cat").match("wildcat")

    assert_instance_of Onibi::MatchData, match
    assert_equal "cat", match[0]
    assert_equal 4, match.begin(0)
    assert_equal 7, match.end(0)
  end

  def test_captureless_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("cat")

    match = regexp.match("wildcat")
    assert_equal "cat", match[0]
    assert_equal [4, 7], match.offset(0)
  end

  def test_always_failing_assertion_uses_hfa_for_all_match_apis
    regexp = Onibi::Regexp.new("(?!)")

    refute regexp.match?("anything")
    assert_nil regexp.match("anything")

    assert_empty regexp.scan("anything")
  end

  def test_exact_literal_match_uses_hfa_string_path_without_program_dispatch
    regexp = Onibi::Regexp.new("needle")

    assert regexp.match?("prefix-needle-suffix")
  end

  def test_exact_literal_match_short_circuits_common_failure_checks
    regexp = Onibi::Regexp.new("needle")

    assert_equal "needle", regexp.match("prefix-needle-suffix").to_s
  end

  def test_exact_literal_default_position_skips_position_normalization
    regexp = Onibi::Regexp.new("needle")

    regexp.stub(:normalize_match_position, ->(*) { flunk "default exact literal position should be zero" }) do
      assert regexp.match?("prefix-needle-suffix")
    end
  end

  def test_exact_literal_match_question_uses_constructor_fast_metadata
    regexp = Onibi::Regexp.new("needle")

    assert regexp.match?("prefix-needle-suffix")
  end

  def test_exact_literal_match_question_short_circuits_common_failure_checks
    regexp = Onibi::Regexp.new("needle")

    assert regexp.match?("prefix-needle-suffix")
  end

  def test_scoped_ignorecase_match_question_uses_hfa
    regexp = Onibi::Regexp.new("(?i:cat)")

    assert regexp.match?("xxCAtxx")
    refute regexp.match?("dog")
  end

  def test_scoped_ignorecase_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?i:cat)")

    assert_equal "CAt", regexp.match("xxCAtxx").to_s
  end

  def test_scoped_multiline_match_question_uses_hfa
    regexp = Onibi::Regexp.new("(?m:.)")

    assert regexp.match?("\n")
  end

  def test_ascii_linebreak_match_uses_hfa
    regexp = Onibi::Regexp.new("\\R")

    assert_equal "\r\n", regexp.match("x\r\ny")[0]

    assert regexp.match?("x\ny")
  end

  def test_start_match_anchor_uses_hfa
    regexp = Onibi::Regexp.new("\\Gfoo")

    assert regexp.match?("xxfoo", 2)
    refute regexp.match?("xxfoo", 0)

    assert_equal "foo", regexp.match("xxfoo", 2).to_s
  end

  def test_unicode_linebreak_match_uses_hfa
    regexp = Onibi::Regexp.new("\\R")

    assert_equal "\u2028", regexp.match("x\u2028y")[0]
  end

  def test_unicode_exact_literal_match_question_matches_mri_without_facade_metadata
    regexp = Onibi::Regexp.new("こんにちは")

    input = "挨拶はこんにちはです"
    assert_equal ::Regexp.new("こんにちは").match?(input), regexp.match?(input)
    assert_equal ::Regexp.new("こんにちは").match?(input, 3), regexp.match?(input, 3)
    assert_equal ::Regexp.new("こんにちは").match?(input, 4), regexp.match?(input, 4)
  end

  def test_word_boundary_literal_match_uses_hfa_string_path
    regexp = Onibi::Regexp.new("\\bcat\\b")

    assert regexp.match?("a cat naps")
    refute regexp.match?("scatter")
  end

  def test_word_boundary_literal_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("\\bcat\\b")

    assert regexp.match?("a cat naps")
    refute regexp.match?("scatter")
  end

  def test_word_boundary_literal_matches_mri_across_public_apis
    regexp = Onibi::Regexp.new("\\bcat\\b")
    input = "cat scatter cat"
    mri = ::Regexp.new("\\bcat\\b")

    assert_equal mri.match?(input), regexp.match?(input)
    assert_equal mri.match(input).to_s, regexp.match(input).to_s
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_literal_lookaround_match_uses_hfa_string_path
    regexp = Onibi::Regexp.new("a(?=b)")

    assert regexp.match?("ab")
    refute regexp.match?("ac")
  end

  def test_possessive_literal_match_uses_hfa_string_path
    regexp = Onibi::Regexp.new("a++b")

    assert regexp.match?("aaaaab")
    refute regexp.match?("aaaac")
  end

  def test_possessive_literal_match_returns_the_longest_one_byte_run
    match = Onibi::Regexp.new("a++b").match("zaaaab")

    assert_equal "aaaab", match[0]
    assert_equal [1, 6], match.offset(0)
  end

  def test_literal_alternation_match_uses_hfa_result
    regexp = Onibi::Regexp.new("cat|dog")

    match = regexp.match("a dog")
    assert_equal "dog", match[0]
    assert_equal [2, 5], match.offset(0)

    assert_equal "a", Onibi::Regexp.new("a|aa").match("aa")[0]
  end

  def test_literal_alternation_match_uses_direct_hfa_result
    regexp = Onibi::Regexp.new("cat|dog|fox")

    match = regexp.match("dog then cat")
    assert_equal "dog", match[0]
    assert_equal [0, 3], match.offset(0)
  end

  def test_single_byte_class_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[a-z]")

    match = regexp.match("123x")
    assert_equal "x", match[0]
    assert_equal [3, 4], match.offset(0)
  end

  def test_literal_alternation_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("cat|dog|fox")

    regexp.stub(:hfa_literal_alternation_result_safe?,
                -> { flunk "Literal alternation should use constructor dispatch metadata" }) do
      assert regexp.match?("the quick fox")
    end
  end

  def test_singleton_class_alternation_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a|[b]")

    assert_equal "a", regexp.match("xa").to_s
    assert_equal "b", regexp.match("xb").to_s
    assert_nil regexp.match("xc")
  end

  def test_captureless_class_run_alternation_match_uses_hfa_result
    regexp = Onibi::Regexp.new("foo[a-z]+|foo[0-9]+")

    assert_equal "fooabc", regexp.match("xxfooabc!").to_s
    assert_equal "foo123", regexp.match("xxfoo123!").to_s
  end

  def test_single_byte_dot_match_uses_hfa_result
    regexp = Onibi::Regexp.new(".")

    match = regexp.match("\nx")
    assert_equal "x", match[0]
    assert_equal [1, 2], match.offset(0)
  end

  def test_literal_dot_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a.c")

    match = regexp.match("xxabc yy")
    assert_equal "abc", match[0]
    assert_equal [2, 5], match.offset(0)
  end

  def test_single_class_run_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[0-9]+")

    match = regexp.match("abc123def")
    assert_equal "123", match[0]
    assert_equal [3, 6], match.offset(0)
  end

  def test_fixed_class_run_literal_match_uses_hfa_result
    program = Onibi::HybridAutomata.compile("a[bc]{4}z")

    assert_equal [3, 9, []], program.match_result("xxaabcbcz yy")
  end

  def test_literal_class_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a[0-9]+z")

    match = regexp.match("xxa123z yy")
    assert_equal "a123z", match[0]
    assert_equal [2, 7], match.offset(0)
  end

  def test_digit_run_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\d+")

    match = regexp.match("id=123")
    assert_equal "123", match[0]
    assert_equal [3, 6], match.offset(0)
  end

  def test_star_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a.*z")

    match = regexp.match("a-first-z-second-z")
    assert_equal "a-first-z-second-z", match[0]
    assert_equal [0, 18], match.offset(0)
  end

  def test_lazy_star_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a.*?z")

    match = regexp.match("a-first-z-second-z")
    assert_equal "a-first-z", match[0]
    assert_equal [0, 9], match.offset(0)
  end

  def test_lazy_star_literal_match_question_uses_direct_path
    regexp = Onibi::Regexp.new("a.*?z")

    assert regexp.match?("a-first-z-second-z")
    refute regexp.match?("a-first-x")
  end

  def test_lazy_literal_quantifier_match_uses_hfa_result
    {
      "a+?" => %w[a ba],
      "a+?a" => %w[aa aaa],
      "a??b" => %w[b b]
    }.each do |pattern, (expected, input)|
      regexp = Onibi::Regexp.new(pattern)

      assert_equal expected, regexp.match(input).to_s
    end
  end

  def test_match_returns_nil_and_match_question_mark_returns_boolean
    regexp = Onibi::Regexp.new("cat")

    assert_nil regexp.match("dog")
    assert_equal true, regexp.match?("cat")
    assert_equal false, regexp.match?("dog")
  end

  def test_captureless_match_question_mark_uses_hfa
    regexp = Onibi::Regexp.new("cat")

    assert regexp.match?("wildcat")
  end

  def test_literal_quantifier_match_question_mark_uses_hfa
    regexp = Onibi::Regexp.new("a+")

    assert regexp.match?("caaab")
    refute regexp.match?("cbbb")
  end

  def test_regular_composite_match_question_mark_uses_hfa
    regexp = Onibi::Regexp.new("(?:ab|ac)+z")

    assert regexp.match?("prefix abacabz suffix")
    refute regexp.match?("prefix abaxz suffix")
  end

  def test_captured_class_run_chain_match_question_uses_boolean_hfa_path
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    assert regexp.match?("prefix item-2026 suffix")
    refute regexp.match?("prefix item- suffix")
  end

  def test_captured_class_run_chain_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    regexp.stub(:hfa_captured_class_run_chain_result_safe?,
                -> { flunk "captured class-run chain should use constructor dispatch metadata" }) do
      assert regexp.match?("prefix item-2026 suffix")
    end
  end

  def test_captured_class_run_metadata_does_not_claim_alternating_capture_groups
    regexp = Onibi::Regexp.new("(a|b)-([0-9]+)")

    assert regexp.match?("a-2026")
    refute regexp.instance_variable_get(:@hfa_captured_class_run_chain_fast)
  end

  def test_unicode_literal_capture_match_question_uses_byte_string_path
    regexp = Onibi::Regexp.new("(こんにちは)(世界)")

    assert regexp.match?("挨拶こんにちは世界です")
    refute regexp.match?("挨拶こんにちは地球です")
  end

  def test_unicode_range_runtime_uses_linear_range_scan
    regexp = Onibi::Regexp.new("[ぁ-ん]+")

    assert regexp.match?("文字列ひらがな終端")
    refute regexp.match?("漢字カタカナ")
  end

  def test_unicode_literal_capture_match_question_uses_constructor_fast_metadata
    regexp = Onibi::Regexp.new("(こんにちは)(世界)")

    regexp.stub(:hfa_fixed_literal_capture_result_safe?,
                -> { flunk "Unicode literal captures should use constructor metadata" }) do
      assert regexp.match?("挨拶こんにちは世界です")
    end
  end

  def test_ascii_unicode_property_run_match_question_uses_byte_table_path
    regexp = Onibi::Regexp.new("\\p{Alpha}+")

    assert regexp.match?("prefix letters suffix")
    refute regexp.match?("12345")
  end

  def test_ascii_unicode_property_run_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("\\p{Alpha}+")

    regexp.stub(:hfa_ascii_unicode_run_result_safe?,
                -> { flunk "ASCII Unicode property run should use constructor dispatch metadata" }) do
      assert regexp.match?("prefix letters suffix")
    end
  end

  def test_ascii_unicode_property_tables_are_shared_between_regexp_instances
    first = Onibi::Regexp.new("\\p{Alpha}+")
    second = Onibi::Regexp.new("\\p{Alpha}+")

    assert_same first.send(:hfa_ascii_unicode_run_table), second.send(:hfa_ascii_unicode_run_table)
  end

  def test_ascii_run_chain_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("\\w+\\s+\\d+")

    regexp.stub(:hfa_ascii_run_chain_result_safe?,
                -> { flunk "ASCII run chain should use constructor dispatch metadata" }) do
      assert regexp.match?("item 2026")
    end
  end

  def test_unicode_property_run_match_question_uses_direct_character_path
    regexp = Onibi::Regexp.new("\\p{Hiragana}+")

    assert regexp.match?("漢字ひらがな漢字")
    refute regexp.match?("漢字カタカナ漢字")
  end

  def test_single_unicode_property_match_question_uses_hfa
    regexp = Onibi::Regexp.new("\\p{Han}")

    assert regexp.match?("漢")
    refute regexp.match?("あ")
  end

  def test_unicode_word_class_run_match_question_uses_direct_character_path
    regexp = Onibi::Regexp.new("[[:word:]]+")

    assert regexp.match?("記号-日本語_2026-終端")
    refute regexp.match?("---😀")
  end

  def test_unicode_word_class_run_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("[[:word:]]+")

    regexp.stub(:hfa_unicode_word_class_run_result_safe?,
                -> { flunk "Unicode word class run should use constructor dispatch metadata" }) do
      assert regexp.match?("記号-日本語_2026-終端")
    end
  end

  def test_ascii_ignorecase_match_question_uses_candidate_string_path
    regexp = Onibi::Regexp.new("case", Onibi::Regexp::IGNORECASE)

    assert regexp.match?("prefix CASE suffix")
    refute regexp.match?("prefix dog suffix")
  end

  def test_ascii_ignorecase_match_question_uses_constructor_fast_metadata
    regexp = Onibi::Regexp.new("case", Onibi::Regexp::IGNORECASE)

    assert regexp.match?("prefix CASE suffix")
  end

  def test_ascii_ignorecase_match_question_short_circuits_common_checks
    regexp = Onibi::Regexp.new("case", Onibi::Regexp::IGNORECASE)

    assert regexp.match?("prefix CASE suffix")
  end

  def test_ascii_ignorecase_match_uses_constructor_fast_metadata
    regexp = Onibi::Regexp.new("case", Onibi::Regexp::IGNORECASE)

    match = regexp.match("prefix CASE suffix")
    assert_equal "CASE", match[0]
    assert_equal [7, 11], match.offset(0)
  end

  def test_ascii_ignorecase_match_short_circuits_common_checks
    regexp = Onibi::Regexp.new("case", Onibi::Regexp::IGNORECASE)

    assert_equal "CASE", regexp.match("prefix CASE suffix").to_s
  end

  def test_adjacent_ascii_class_runs_use_direct_match_question_path
    regexp = Onibi::Regexp.new("[[:alpha:]]+[[:digit:]]+")

    assert regexp.match?("item2026")
  end

  def test_adjacent_ascii_class_runs_use_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("[a-z]+[0-9]+")

    regexp.stub(:hfa_ascii_adjacent_run_result_safe?,
                -> { flunk "adjacent class runs should use constructor dispatch metadata" }) do
      assert regexp.match?("item2026")
    end
  end

  def test_atomic_literal_alternation_uses_direct_match_question_path
    regexp = Onibi::Regexp.new("(?>a|ab)b")

    assert regexp.match?("ab")
  end

  def test_atomic_literal_match_question_short_circuits_common_checks
    regexp = Onibi::Regexp.new("(?>a|ab)b")

    assert regexp.match?("ab")
  end

  def test_atomic_literal_alternation_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?>a|ab)b")

    assert_equal "ab", regexp.match("zab").to_s
    assert_nil regexp.match("zac")
  end

  def test_atomic_literal_alternation_with_nonmatching_suffix_uses_hfa
    regexp = Onibi::Regexp.new("(?>a|ab)c")

    assert_equal "ac", regexp.match("zac").to_s
    assert_nil regexp.match("zabc")
  end

  def test_subexpression_literal_call_uses_direct_match_question_path
    regexp = Onibi::Regexp.new("(?<pair>ab)\\g<pair>")

    assert regexp.match?("abab")
  end

  def test_subexpression_literal_match_question_short_circuits_common_checks
    regexp = Onibi::Regexp.new("(?<pair>ab)\\g<pair>")

    assert regexp.match?("abab")
  end

  def test_greedy_dot_star_literal_uses_direct_match_question_path
    regexp = Onibi::Regexp.new("a.*z")

    assert regexp.match?("a-middle-z")
  end

  def test_bounded_literal_match_question_uses_direct_hfa_path
    regexp = Onibi::Regexp.new("a{4,12}")

    assert regexp.match?("baaaaaaaac")
    refute regexp.match?("baaac")
  end

  def test_bounded_literal_match_question_short_circuits_common_checks
    regexp = Onibi::Regexp.new("a{4,12}")

    assert regexp.match?("baaaaaaaac")
  end

  def test_bounded_literal_match_returns_the_greedy_run_and_respects_position
    regexp = Onibi::Regexp.new("a{2,4}")

    match = regexp.match("zaaaaa")
    assert_equal "aaaa", match[0]
    assert_equal [1, 5], match.offset(0)
    assert_nil regexp.match("zaaaaa", 5)
  end

  def test_bounded_literal_public_apis_match_mri
    pattern = "a{2,4}"
    input = "zaaa x aaaa"
    regexp = Onibi::Regexp.new(pattern)
    mri = Regexp.new(pattern)

    assert_equal input.match?(mri), regexp.match?(input)
    assert_equal input.match(mri).to_s, regexp.match(input).to_s
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_ascii_ignorecase_literal_public_apis_match_mri
    pattern = "case"
    input = "xxCASEyy case"
    regexp = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE)
    mri = Regexp.new(pattern, Regexp::IGNORECASE)

    assert_equal input.match?(mri), regexp.match?(input)
    assert_equal input.match(mri).to_s, regexp.match(input).to_s
    assert_equal input.scan(mri), regexp.scan(input)
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_unicode_ignorecase_literal_public_apis_match_mri
    pattern = "école"
    input = "xxÉCOLEyy école"
    regexp = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE)
    mri = Regexp.new(pattern, Regexp::IGNORECASE)

    assert_equal input.match?(mri), regexp.match?(input)
    assert_equal input.match(mri).to_s, regexp.match(input).to_s
    assert_equal input.scan(mri), regexp.scan(input)
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_literal_alternation_public_apis_match_mri
    pattern = "cat|dog"
    input = "dog and cat"
    regexp = Onibi::Regexp.new(pattern)
    mri = Regexp.new(pattern)

    assert_equal input.match?(mri), regexp.match?(input)
    assert_equal input.match(mri).to_s, regexp.match(input).to_s
    assert_equal input.scan(mri), regexp.scan(input)
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_empty_absence_public_apis_match_mri
    pattern = "(?~)"
    input = "abc"
    regexp = Onibi::Regexp.new(pattern)
    mri = Regexp.new(pattern)

    assert_equal input.match?(mri), regexp.match?(input)
    assert_equal input.match(mri).to_s, regexp.match(input).to_s
    assert_equal input.scan(mri), regexp.scan(input)
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_match_reset_literal_match_question_uses_adjacent_string_path
    regexp = Onibi::Regexp.new("prefix\\Ksuffix")

    assert regexp.match?("xxprefixsuffixyy")
    refute regexp.match?("xxprefix-suffixyy")
  end

  def test_standalone_absence_match_question_uses_constant_path
    regexp = Onibi::Regexp.new("(?~END)")

    assert regexp.match?("payloadEND")
    assert regexp.match?("payload")
    assert regexp.match?("")
  end

  def test_literal_absence_match_and_scan_use_hfa_results
    regexp = Onibi::Regexp.new("(?~END)")

    assert_equal "EN", regexp.match("END").to_s
    assert_equal "xxEN", regexp.match("xxENDyy").to_s
    assert_equal "abc", regexp.match("abc").to_s

    assert_equal ["EN", "D", ""], regexp.scan("END")
    assert_equal ["xxEN", "D", "yy", ""], regexp.scan("xxENDyy")
  end

  def test_literal_absence_match_uses_hfa_on_unicode_input
    regexp = Onibi::Regexp.new("(?~END)")

    assert regexp.match?("日本語END")
    assert_equal "日本語EN", regexp.match("日本語END").to_s
  end

  def test_scan_safety_classifies_input_encoding_once
    input_class = Class.new(String) do
      attr_reader :ascii_only_calls

      def initialize(value)
        super
        @ascii_only_calls = 0
      end

      def ascii_only?
        @ascii_only_calls += 1
        super
      end
    end
    regexp = Onibi::Regexp.new("cat")
    input = input_class.new("cat")

    assert regexp.send(:hfa_scan_input_safe?, input)
    assert_equal 1, input.ascii_only_calls
  end

  def test_generic_match_reuses_precomputed_input_encoding
    input_class = Class.new(String) do
      attr_reader :ascii_only_calls

      def initialize(value)
        super
        @ascii_only_calls = 0
      end

      def ascii_only?
        @ascii_only_calls += 1
        super
      end
    end
    regexp = Onibi::Regexp.new("a+")
    input = input_class.new("aaa")

    assert_equal "aaa", regexp.send(:hfa_generic_match, input, 0, ascii_input: true).to_s
    assert_equal 1, input.ascii_only_calls
  end

  def test_capture_offset_walker_classifies_input_once_across_recursion
    input_class = Class.new(String) do
      attr_reader :ascii_only_calls

      def initialize(value)
        super
        @ascii_only_calls = 0
      end

      def ascii_only?
        @ascii_only_calls += 1
        super
      end
    end
    regexp = Onibi::Regexp.new("([a]+)+")
    input = input_class.new("aaa")
    offsets = Array.new(regexp.send(:hfa_capture_count))

    result = regexp.send(:hfa_consume_capture_node, regexp.instance_variable_get(:@ast), input, 0,
                         input.bytesize, offsets)

    assert_equal 3, result
    assert_equal 1, input.ascii_only_calls
  end

  def test_match_reset_literal_match_question_uses_combined_literal_path
    regexp = Onibi::Regexp.new("prefix\\Ksuffix")

    regexp.stub(:hfa_match_reset_literal_result_safe?,
                -> { flunk "match-reset literal should use combined literal path" }) do
      assert regexp.match?("xxprefixsuffixyy")
      refute regexp.match?("xxprefix-suffixyy")
    end
  end

  def test_match_reset_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("prefix\\Ksuffix")

    assert_equal "suffix", regexp.match("xxprefixsuffixyy").to_s
    assert_nil regexp.match("xxprefix-suffixyy")
  end

  def test_absolute_anchor_match_uses_hfa_result
    regexp = Onibi::Regexp.new("^cat$")

    assert_equal "cat", regexp.match("cat").to_s
    assert_nil regexp.match("xcat")
  end

  def test_before_final_newline_anchor_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\Acat\\Z")

    assert_equal "cat", regexp.match("cat\n").to_s
    assert_equal "cat", regexp.match("cat").to_s
    assert_nil regexp.match("cat\nx")
  end

  def test_greedy_bounded_sequence_match_uses_hfa_result
    regexp = Onibi::Regexp.new("foo.{0,4}bar")

    assert_equal "foo12bar", regexp.match("xfoo12bar").to_s
    assert_nil regexp.match("fooxxxxxbar")
  end

  def test_scoped_extended_options_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a(?-x: b#c )d")

    assert_equal "a b#c d", regexp.match("a b#c d").to_s
  end

  def test_nested_scoped_extended_options_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?x:(?-x: a b ) c)")

    assert_equal " a b c", regexp.match(" a b c").to_s
  end

  def test_nonword_boundary_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\Bcat\\B")

    assert_equal "cat", regexp.match("_cat_").to_s
    assert_nil regexp.match(" catx ")
  end

  def test_match_reset_literal_match_question_matches_mri_after_hfa_lowering
    regexp = Onibi::Regexp.new("prefix\\Ksuffix")

    input = "xxprefixsuffixyy"
    expected = ::Regexp.new("prefix\\Ksuffix").match?(input)
    assert_equal expected, regexp.match?(input)
  end

  def test_class_run_positive_lookahead_match_question_uses_boolean_path
    regexp = Onibi::Regexp.new("[a-z]+(?=-[0-9]+)")

    assert regexp.match?("prefix item-2026 suffix")
    refute regexp.match?("prefix item- suffix")
  end

  def test_class_run_positive_lookahead_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("[a-z]+(?=-[0-9]+)")

    regexp.stub(:hfa_class_run_positive_lookahead_result_safe?,
                -> { flunk "Class-run lookahead should use constructor dispatch metadata" }) do
      assert regexp.match?("prefix item-2026 suffix")
    end
  end

  def test_class_run_positive_lookahead_matches_mri_across_public_apis
    regexp = Onibi::Regexp.new("[a-z]+(?=-[0-9]+)")
    input = "item-2026 other-thing item-7"
    mri = ::Regexp.new("[a-z]+(?=-[0-9]+)")

    assert_equal mri.match?(input), regexp.match?(input)
    assert_equal mri.match(input).to_s, regexp.match(input).to_s
    assert_equal input.scan(mri), regexp.scan(input)
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_negative_literal_lookahead_uses_early_constructor_dispatch
    regexp = Onibi::Regexp.new("cat(?!fish)")

    regexp.stub(:hfa_literal_assertion_result_safe?,
                -> { flunk "negative literal lookahead should use early constructor dispatch" }) do
      assert regexp.match?("a cat naps")
      refute regexp.match?("a catfish naps")
    end
  end

  def test_negative_literal_lookahead_matches_mri_across_public_apis
    regexp = Onibi::Regexp.new("cat(?!fish)")
    input = "cat catfish cat"
    mri = ::Regexp.new("cat(?!fish)")

    assert_equal mri.match?(input), regexp.match?(input)
    assert_equal mri.match(input).to_s, regexp.match(input).to_s
    assert_equal input.scan(mri), regexp.scan(input)
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_repeated_class_backreference_uses_early_constructor_dispatch
    regexp = Onibi::Regexp.new("([a-z]+)-\\1")

    regexp.stub(:hfa_repeated_class_backref_result_safe?,
                -> { flunk "repeated class backreference should use early constructor dispatch" }) do
      assert regexp.match?("echo-echo")
    end
  end

  def test_repeated_class_backreference_matches_mri_across_public_apis
    regexp = Onibi::Regexp.new("([a-z]+)-\\1")
    input = "echo-echo x echo-ec echo-echo"
    mri = ::Regexp.new("([a-z]+)-\\1")

    assert_equal mri.match?(input), regexp.match?(input)
    assert_equal mri.match(input).to_a, regexp.match(input).to_a
    assert_equal input.scan(mri), regexp.scan(input)
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_ascii_character_class_run_match_question_uses_byte_table_path
    regexp = Onibi::Regexp.new("[a-z&&[^aeiou]]+")

    assert regexp.match?("aei-bcdfg-ou")
    refute regexp.match?("aei-OU")
  end

  def test_ascii_shorthand_run_chain_match_question_uses_byte_tables
    regexp = Onibi::Regexp.new("\\w+\\s+\\d+")

    assert regexp.match?("item 2026")
    refute regexp.match?("item-2026")
  end

  def test_literal_conditional_match_question_uses_alternative_string_path
    regexp = Onibi::Regexp.new("(a)?(?(1)b|c)")

    assert regexp.match?("prefix ab suffix")
    assert regexp.match?("prefix c suffix")
    refute regexp.match?("prefix d suffix")
  end

  def test_literal_conditional_public_apis_match_mri
    pattern = "(a)?(?(1)b|c)"
    input = "c ab"
    regexp = Onibi::Regexp.new(pattern)
    mri = Regexp.new(pattern)

    assert_equal input.match?(mri), regexp.match?(input)
    assert_equal input.match(mri).to_s, regexp.match(input).to_s
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_repeated_class_backreference_match_question_uses_byte_string_path
    regexp = Onibi::Regexp.new("([a-z]+)-\\1")

    assert regexp.match?("prefix echo-echo suffix")
    refute regexp.match?("prefix echo-ecoh suffix")
  end

  def test_anchored_class_run_match_question_uses_full_input_byte_path
    regexp = Onibi::Regexp.new("\\A[a-z]+\\z")

    assert regexp.match?("anchored")
    refute regexp.match?("anchored1")
  end

  def test_anchored_class_run_public_apis_match_mri
    pattern = "\\A[a-z]+\\z"
    input = "anchored"
    regexp = Onibi::Regexp.new(pattern)
    mri = Regexp.new(pattern)

    assert_equal input.match?(mri), regexp.match?(input)
    assert_equal input.match(mri).to_s, regexp.match(input).to_s
    assert_equal input.scan(mri), regexp.scan(input)
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_unicode_property_run_public_apis_match_mri
    pattern = "\\p{Hiragana}+"
    input = "漢字ひらがな終端"
    regexp = Onibi::Regexp.new(pattern)
    mri = Regexp.new(pattern)

    assert_equal input.match?(mri), regexp.match?(input)
    assert_equal input.match(mri).to_s, regexp.match(input).to_s
    assert_equal input.scan(mri), regexp.scan(input)
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_anchored_class_run_match_and_scan_use_hfa_results
    regexp = Onibi::Regexp.new("\\A[a-z]+\\z")

    assert_equal "anchored", regexp.match("anchored").to_s
    assert_nil regexp.match("anchored1")

    assert_equal ["anchored"], regexp.scan("anchored")
    assert_empty regexp.scan("anchored1")
  end

  def test_literal_alternation_match_question_uses_direct_string_search
    regexp = Onibi::Regexp.new("cat|dog|fox")

    assert regexp.match?("the quick fox")
    refute regexp.match?("the quick hen")
  end

  def test_literal_alternation_match_question_short_circuits_common_checks
    regexp = Onibi::Regexp.new("cat|dog|fox")

    assert regexp.match?("the quick fox")
  end

  def test_selective_class_run_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[a-z&&[^aeiou]]+")

    assert_equal "bcdfg", regexp.match("ae-bcdfg-io").to_s
    assert_nil regexp.match("aeiou")
  end

  def test_class_run_positive_lookahead_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[a-z]+(?=-[0-9]+)")

    assert_equal "abc", regexp.match("abc-123").to_s
    assert_nil regexp.match("abc-def")
  end

  def test_dot_literal_match_question_uses_direct_byte_path
    regexp = Onibi::Regexp.new("a.c")

    assert regexp.match?("prefix-abc-suffix")
    refute regexp.match?("prefix-a\nc-suffix")
  end

  def test_dot_literal_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("a.c")

    regexp.stub(:hfa_dot_literal_result_safe?,
                -> { flunk "Dot literal should use constructor dispatch metadata" }) do
      assert regexp.match?("prefix-abc-suffix")
    end
  end

  def test_ascii_literal_match_question_uses_string_path_on_utf8_input
    regexp = Onibi::Regexp.new("needle")

    assert regexp.match?("前needle後")
  end

  def test_repeated_alternation_match_uses_hfa_result
    program = Onibi::HybridAutomata.compile("(?:ab|ac)+z")

    assert_equal [2, 11, []], program.match_result("xxabacababz yy")
  end

  def test_literal_quantifier_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a+")

    match = regexp.match("caaab")
    assert_equal "aaa", match[0]
    assert_equal [1, 4], match.offset(0)
  end

  def test_repeated_literal_suffix_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a+b")

    match = regexp.match("xxaaab yy")
    assert_equal "aaab", match[0]
    assert_equal [2, 6], match.offset(0)
  end

  def test_class_run_chain_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[a-z]+:[0-9]+")

    match = regexp.match("xxitem:2026 yy")
    assert_equal "xxitem:2026", match[0]
    assert_equal [0, 11], match.offset(0)
  end

  def test_adjacent_class_runs_match_uses_hfa_result
    program = Onibi::HybridAutomata.compile("[a-z]+[0-9]+")

    assert_equal [0, 10, []], program.match_result("xxitem2026yy")
  end

  def test_class_run_triple_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\w+\\s+\\d+")

    match = regexp.match("xxitem 2026yy")
    assert_equal "xxitem 2026", match[0]
    assert_equal [0, 11], match.offset(0)
  end

  def test_ascii_property_run_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\p{Alpha}+")

    match = regexp.match("123letters456")
    assert_equal "letters", match[0]
    assert_equal [3, 10], match.offset(0)
  end

  def test_unicode_property_run_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\p{Hiragana}+")

    match = regexp.match("漢字ひらがな終端")
    assert_equal "ひらがな", match[0]
    assert_equal [6, 18], match.offset(0)
  end

  def test_unicode_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("こんにちは")

    match = regexp.match("挨拶はこんにちはです")
    assert_equal "こんにちは", match[0]
    assert_equal [9, 24], match.offset(0)
  end

  def test_unicode_exact_literal_match_uses_hfa_string_path
    regexp = Onibi::Regexp.new("こんにちは")

    assert regexp.match?("挨拶はこんにちはです")
  end

  def test_unicode_repeated_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?:日本語)+")

    match = regexp.match("開始日本語日本語終了")
    assert_equal "日本語日本語", match[0]
    assert_equal [6, 24], match.offset(0)
  end

  def test_unicode_repeated_literal_match_question_skips_program_compile
    regexp = Onibi::Regexp.new("(?:日本語)+")

    assert regexp.match?("開始日本語日本語終了")
  end

  def test_unicode_repeated_literal_unit_is_cached
    regexp = Onibi::Regexp.new("(?:日本語)+")

    assert regexp.match?("開始日本語終了")
    assert_equal "日本語", regexp.instance_variable_get(:@hfa_unicode_repeated_literal_unit)
  end

  def test_unicode_literal_captures_use_hfa_result
    regexp = Onibi::Regexp.new("(こんにちは)(世界)")

    match = regexp.match("挨拶こんにちは世界です")
    assert_equal %w[こんにちは世界 こんにちは 世界], match.to_a
    assert_equal [[6, 27], [6, 21], [21, 27]],
                 [match.offset(0), match.offset(1), match.offset(2)]
  end

  def test_unicode_literal_capture_match_question_uses_string_path
    regexp = Onibi::Regexp.new("(こんにちは)(世界)")

    assert regexp.match?("挨拶こんにちは世界です")
  end

  def test_ignorecase_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("case", ["ignorecase"])

    match = regexp.match("xxCASEyy")
    assert_equal "CASE", match[0]
    assert_equal [2, 6], match.offset(0)
  end

  def test_unicode_ignorecase_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("école", ["ignorecase"])

    match = regexp.match("xxÉCOLEyy")
    assert_equal "ÉCOLE", match[0]
    assert_equal [2, 8], match.offset(0)
  end

  def test_unicode_ignorecase_literal_match_question_uses_boolean_string_path
    regexp = Onibi::Regexp.new("école", ["ignorecase"])

    assert regexp.match?("xxÉCOLEyy")
  end

  def test_unicode_ignorecase_match_question_uses_constructor_fast_metadata
    regexp = Onibi::Regexp.new("école", Onibi::Regexp::IGNORECASE)

    regexp.stub(:hfa_unicode_ignorecase_literal_result_safe?,
                -> { flunk "Unicode ignorecase match? should use constructor metadata" }) do
      assert regexp.match?("xxÉCOLEyy")
    end
  end

  def test_unicode_ignorecase_literal_fold_is_cached
    regexp = Onibi::Regexp.new("école", ["ignorecase"])

    assert regexp.match?("ÉCOLE")
    assert_equal "école", regexp.instance_variable_get(:@hfa_unicode_ignorecase_literal_fold)
  end

  def test_unicode_property_run_match_question_mark_uses_hfa
    regexp = Onibi::Regexp.new("\\p{Hiragana}+")

    assert regexp.match?("漢字ひらがな終端")
    refute regexp.match?("漢字カタカナ終端")
  end

  def test_unicode_property_run_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("\\p{Hiragana}+")

    regexp.stub(:hfa_unicode_property_run_result_safe?,
                -> { flunk "Unicode property run should use constructor dispatch metadata" }) do
      assert regexp.match?("漢字ひらがな終端")
    end
  end

  def test_unicode_property_match_question_mark_honors_start_position
    regexp = Onibi::Regexp.new("\\p{Hiragana}+")

    assert regexp.match?("漢字abcひらがな", 5)
    refute regexp.match?("漢字abcひらがな", 9)
  end

  def test_ascii_backreference_match_question_mark_uses_hfa
    regexp = Onibi::Regexp.new("([a-z]+)-\\1")

    assert regexp.match?("echo-echo")
  end

  def test_variable_literal_backreference_match_uses_hfa
    regexp = Onibi::Regexp.new("(a*)\\1")

    assert regexp.match?("aaaa")
    assert_equal %w[aaaa aa], regexp.match("aaaa").to_a
  end

  def test_scoped_casefold_backreference_match_uses_hfa
    regexp = Onibi::Regexp.new("(?<x>a)(?i:\\k<x>)")

    assert regexp.match?("aA")
    assert_equal %w[aA a], regexp.match("zaA").to_a
  end

  def test_variable_any_backreference_match_uses_hfa
    regexp = Onibi::Regexp.new("(?<x>.*)\\k<x>")

    assert regexp.match?("abcabc")
    assert_equal %w[abcabc abc], regexp.match("abcabc").to_a
    assert_equal %w[aa a], regexp.match("aaa").to_a
  end

  def test_ascii_exact_literal_match_matches_mri_after_hfa_lowering
    regexp = Onibi::Regexp.new("needle")

    assert_equal ::Regexp.new("needle").match?("prefix-needle-suffix"), regexp.match?("prefix-needle-suffix")
  end

  def test_hfa_capture_result_names_are_cached
    regexp = Onibi::Regexp.new("(?<word>[a-z]+)-(?<id>[0-9]+)")

    first = regexp.send(:hfa_result_names)
    second = regexp.send(:hfa_result_names)

    assert_same first, second
    assert_equal({ "word" => 1, "id" => 2 }, first)
  end

  def test_hfa_simple_capture_count_is_cached
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    assert_equal 2, regexp.send(:hfa_simple_capture_count)
    assert_equal 2, regexp.send(:hfa_simple_capture_count)
  end

  def test_simple_capture_match_uses_its_direct_offset_path_first
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    assert_equal %w[item-2026 item 2026], regexp.match("item-2026").to_a
  end

  def test_nested_repeated_capture_match_uses_its_direct_offset_path_first
    regexp = Onibi::Regexp.new("(?<outer>(?<inner>ab)+)c")

    assert_equal %w[ababc abab ab], regexp.match("ababc").to_a
  end

  def test_nested_repeated_capture_shape_is_cached
    regexp = Onibi::Regexp.new("(?<outer>(?<inner>ab)+)c")

    first = regexp.send(:hfa_nested_repeated_capture_parts)
    second = regexp.send(:hfa_nested_repeated_capture_parts)

    assert_same first, second
  end

  def test_nested_repeated_capture_spec_is_cached
    regexp = Onibi::Regexp.new("(?<outer>(?<inner>ab)+)c")

    first = regexp.send(:hfa_nested_repeated_capture_spec)
    second = regexp.send(:hfa_nested_repeated_capture_spec)

    assert_same first, second
  end

  def test_nested_literal_capture_safety_analysis_is_cached
    regexp = Onibi::Regexp.new("(?<outer>(?<inner>ab))")
    regexp.send(:hfa_nested_literal_capture_result_safe?)

    assert regexp.send(:hfa_nested_literal_capture_result_safe?)
  end

  def test_repeated_capture_shapes_are_cached
    repeated = Onibi::Regexp.new("(?<head>(?<unit>ab)+)-(?<tail>[0-9]+)")
    adjacent = Onibi::Regexp.new("((ab)+)((cd)+)")

    assert_same repeated.send(:hfa_repeated_class_capture_parts), repeated.send(:hfa_repeated_class_capture_parts)
    assert_same adjacent.send(:hfa_adjacent_nested_repeated_capture_groups),
                adjacent.send(:hfa_adjacent_nested_repeated_capture_groups)
  end

  def test_tagged_hfa_offset_helper_builds_match_data
    regexp = Onibi::Regexp.new("(?<word>[a-z]+)")

    match = regexp.send(:hfa_offset_match_data, "xxwordyy", 2, 6, [[2, 6]], { "word" => 1 })

    assert_equal %w[word word], match.to_a
    assert_equal [2, 6], match.offset("word")
  end

  def test_tagged_hfa_capture_strategy_is_selected_once
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    first = regexp.send(:hfa_capture_offset_strategy)
    second = regexp.send(:hfa_capture_offset_strategy)

    assert_equal :simple, first
    assert_same first, second
  end

  def test_repeated_capture_span_avoids_length_list
    regexp = Onibi::Regexp.new("(?<outer>(?<inner>ab)+)c")
    unit = regexp.instance_variable_get(:@ast).parts.first.body.parts.first.expression.body

    assert_equal [4, 2], regexp.send(:hfa_repeated_match_span, unit, "ababc", 0, 4)
  end

  def test_adjacent_nested_capture_spec_is_cached
    regexp = Onibi::Regexp.new("((ab)+)((cd)+)")

    first = regexp.send(:hfa_adjacent_nested_repeated_capture_spec)
    second = regexp.send(:hfa_adjacent_nested_repeated_capture_spec)

    assert_same first, second
    assert_equal [%w[ab cd], [1, 2, 3, 4], 4], [first[1], first[2], first[3]]
  end

  def test_repeated_class_capture_spec_is_cached
    regexp = Onibi::Regexp.new("(?<head>(?<unit>ab)+)-(?<tail>[0-9]+)")

    first = regexp.send(:hfa_repeated_class_capture_spec)
    second = regexp.send(:hfa_repeated_class_capture_spec)

    assert_same first, second
    assert_equal [[1, 2], 2], [first[2], first[4]]
  end

  def test_hfa_match_question_safety_analysis_is_cached
    regexp = Onibi::Regexp.new("needle.")
    calls = 0
    original = regexp.method(:hfa_contains_possessive_quantifier?)
    regexp.define_singleton_method(:hfa_contains_possessive_quantifier?) do
      calls += 1
      original.call
    end

    3.times { assert regexp.match?("needlex") }
    assert_equal 1, calls
  end

  def test_match_question_dispatch_short_circuits_hfa_safety_conditions
    regexp = Onibi::Regexp.new("needle.")
    regexp.define_singleton_method(:hfa_match_question_safe?) { true }
    failure = -> { flunk "unneeded HFA safety condition was evaluated" }
    regexp.define_singleton_method(:hfa_start_match_result_safe?) do
      failure.call
    end

    assert regexp.match?("needlex")
  end

  def test_match_program_fast_paths_share_one_dispatch_condition
    source = File.read(File.join(PROJECT_ROOT, "lib/onibi.rb"))
    start = source.index("    def match(input")
    finish = source.index("\n    def ", start + 1)
    match_method = source[start...finish]
    shared_condition = Regexp.new(
      "if ascii_input &&\\s+\\(hfa_captureless_regular_sequence_result_safe\\?\\s+\\|\\|\\s+" \
      "hfa_scoped_ignorecase_sequence_result_safe\\?\\s+\\|\\|\\s+hfa_scoped_multiline_sequence_result_safe\\?"
    )

    assert_equal 1, match_method.scan(shared_condition).length
  end

  def test_scan_program_fast_paths_share_one_dispatch_condition
    source = File.read(File.join(PROJECT_ROOT, "lib/onibi.rb"))
    start = source.index("    def hfa_each_result")
    finish = source.index("\n    def ", start + 1)
    scan_method = source[start...finish]
    shared_condition = Regexp.new(
      "if hfa_greedy_bounded_sequence_result_safe\\?\\s+\\|\\|\\s+" \
      "hfa_lazy_bounded_sequence_result_safe\\?\\s+\\|\\|\\s+" \
      "hfa_scoped_extended_literal_result_safe\\?"
    )

    assert_equal 1, scan_method.scan(shared_condition).length
  end

  def test_encoding_neutral_scan_safety_is_checked_once
    regexp = Onibi::Regexp.new("(?<=a)b")
    calls = 0
    regexp.define_singleton_method(:hfa_encoding_neutral_scan_safe?) do
      calls += 1
      true
    end

    assert regexp.send(:hfa_scan_input_safe?, "ab")
    assert_equal 1, calls
  end

  def test_hfa_match_question_skips_timeout_wrapper_when_unconfigured
    regexp = Onibi::Regexp.new("needle")

    regexp.stub(:with_timeout, ->(*) { flunk "unconfigured HFA match? should skip timeout wrapper" }) do
      assert regexp.match?("needle")
    end
  end

  def test_unicode_hfa_safety_analysis_is_cached
    regexp = Onibi::Regexp.new("\\p{Letter}+")

    3.times { assert regexp.match?("日本語") }
    assert_equal true, regexp.instance_variable_get(:@hfa_unicode_match_safe)
  end

  def test_unicode_letter_runtime_falls_back_outside_fast_ranges
    regexp = Onibi::Regexp.new("\\p{Letter}+")

    assert regexp.match?("é")
    refute regexp.match?("123!")
  end

  def test_unicode_hfa_default_position_skips_position_normalization
    regexp = Onibi::Regexp.new("\\p{Letter}+")

    regexp.stub(:normalize_match_position, ->(*) { flunk "default Unicode HFA position should be zero" }) do
      assert regexp.match?("日本語")
    end
  end

  def test_ascii_hfa_default_position_skips_position_normalization
    regexp = Onibi::Regexp.new("\\p{Alpha}+")

    regexp.stub(:normalize_match_position, ->(*) { flunk "default ASCII HFA position should be zero" }) do
      assert regexp.match?("letters")
    end
  end

  def test_match_question_mark_uses_hfa_for_non_ascii_exact_literals
    regexp = Onibi::Regexp.new("é")

    assert regexp.match?("café")
  end

  def test_captureless_repeated_alternation_match_uses_hfa
    regexp = Onibi::Regexp.new("(?:a|b)+c")

    assert_equal "ababc", regexp.match("ababc cabc").to_s
  end

  def test_scoped_unicode_ignorecase_literal_match_uses_hfa
    regexp = Onibi::Regexp.new("(?i:é)")

    assert_equal "é", regexp.match("café École").to_s
  end

  def test_scoped_unicode_ignorecase_literal_match_question_uses_hfa
    regexp = Onibi::Regexp.new("(?i:é)")

    assert regexp.match?("café École")
  end

  def test_scoped_unicode_simple_casefold_match_question_skips_full_casefold
    regexp = Onibi::Regexp.new("(?i:é)")

    regexp.stub(:hfa_unicode_full_casefold_literal_match_result,
                ->(*) { flunk "simple Unicode casefold should skip full casefold search" }) do
      assert regexp.match?("café École")
    end
  end

  def test_consuming_prefix_before_absolute_start_anchor_is_hfa_failure
    regexp = Onibi::Regexp.new("a\\A")

    refute regexp.match?("a")
    assert_nil regexp.match("a")
  end

  def test_consuming_suffix_after_absolute_end_anchor_is_hfa_failure
    regexp = Onibi::Regexp.new("\\za")

    refute regexp.match?("a")
    assert_nil regexp.match("a")
  end

  def test_ascii_literal_match_preserves_bytes_after_unicode_prefix
    match = Onibi::Regexp.new("cat").match("日本語cat")

    assert_equal "cat", match.to_s
    assert_equal [9, 12], match.offset(0)
  end

  def test_start_match_literal_uses_hfa_on_unicode_input
    regexp = Onibi::Regexp.new("\\Gcat")

    assert regexp.match?("日本語cat", 3)
    assert_equal "cat", regexp.match("日本語cat", 3).to_s
  end

  def test_literal_alternation_match_uses_hfa_on_unicode_input
    regexp = Onibi::Regexp.new("cat|dog")

    assert_equal "cat", regexp.match("日本語cat").to_s
  end

  def test_repeated_equal_length_literal_capture_match_uses_hfa
    regexp = Onibi::Regexp.new("(a|b)+c")

    assert_equal %w[ababc b], regexp.match("ababc").to_a
  end

  def test_literal_capture_before_alternation_match_uses_hfa
    regexp = Onibi::Regexp.new("(?<x>a)(?:b|c)")

    assert_equal %w[ab a], regexp.match("ab").to_a
  end

  def test_single_capture_literal_alternation_match_uses_hfa
    regexp = Onibi::Regexp.new("(?<letter>a|aa)")

    assert_equal %w[a a], regexp.match("aa").to_a
  end

  def test_nested_literal_capture_alternation_match_uses_hfa
    regexp = Onibi::Regexp.new("(?:(a)|(b))c")

    assert_equal ["ac", "a", nil], regexp.match("ac").to_a
    assert_equal ["bc", nil, "b"], regexp.match("bc").to_a
  end

  def test_scoped_ignorecase_multiline_sequence_match_uses_hfa
    regexp = Onibi::Regexp.new("(?im:a.)")

    assert_equal "A\n", regexp.match("zzA\nx").to_s
  end

  def test_match_and_match_question_mark_accept_a_start_position
    regexp = Onibi::Regexp.new("cat")

    assert_equal 2, regexp.match("xxcat", 2).begin(0)
    assert regexp.match?("xxcat", 2)
    assert_equal 2, regexp.match("xxcat", -3.5).begin(0)
    assert_nil regexp.match("xxcat", 99)
    assert_raises(TypeError) { regexp.match?("xxcat", nil) }
  end

  def test_match_operator_returns_match_beginning_or_nil
    regexp = Onibi::Regexp.new("cat")

    assert_equal 4, regexp =~ "wildcat"
    assert_nil regexp =~ "dog"
  end

  def test_case_operator_returns_boolean
    regexp = Onibi::Regexp.new("cat")

    assert regexp.send("===", "wildcat")
    refute regexp.send("===", "dog")
  end

  def test_unary_match_operator_uses_last_input
    regexp = Onibi::Regexp.new("cat")

    eval('$_ = "wildcat"', TOPLEVEL_BINDING, __FILE__, __LINE__)
    assert_equal 4, ~regexp
  ensure
    eval("$_ = nil", TOPLEVEL_BINDING, __FILE__, __LINE__)
  end

  def test_match_exposes_numbered_captures
    match = Onibi::Regexp.new("(ab)(cd)").match("xxabcdyy")

    assert_equal "abcd", match[0]
    assert_equal %w[ab cd], match.captures
    assert_equal "ab", match[1]
    assert_equal "cd", match[2]
  end

  def test_simple_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(ab)(cd)")

    match = regexp.match("xxabcdyy")
    assert_equal %w[ab cd], match.captures
    assert_equal([[2, 6], [2, 4], [4, 6]], (0..2).map { |index| match.offset(index) })
  end

  def test_class_run_captures_use_hfa_result
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    match = regexp.match("item-2026")
    assert_equal %w[item 2026], match.captures
  end

  def test_optional_capture_match_uses_hfa_result_and_preserves_unmatched_offset
    regexp = Onibi::Regexp.new("(?<prefix>a)?b")

    matched = regexp.match("ab")
    missing = regexp.match("b")
    assert_equal "a", matched["prefix"]
    assert_nil missing["prefix"]
    assert_equal [nil, nil], missing.offset("prefix")
  end

  def test_repeated_literal_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<pair>ab)+")

    match = regexp.match("abab")
    assert_equal ["ab"], match.captures
    assert_equal [2, 4], match.offset("pair")
  end

  def test_optional_repeated_literal_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(a*)b")

    repeated = regexp.match("xxaaabyy")
    empty = regexp.match("b")
    assert_equal "aaa", repeated[1]
    assert_equal [2, 5], repeated.offset(1)
    assert_equal "", empty[1]
    assert_equal [0, 0], empty.offset(1)
  end

  def test_nested_empty_repeated_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(a*)*b")

    match = regexp.match("xxaaabyy")
    assert_equal "aaab", match[0]
    assert_equal "", match[1]
    assert_equal [5, 5], match.offset(1)
  end

  def test_variable_subexpression_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<x>a|ab)c\\g<x>d")

    assert_equal "a", regexp.match("acad")["x"]
    assert_equal "ab", regexp.match("abcabd")["x"]
  end

  def test_variable_capture_alternation_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(a|aa)(b|bb)")

    first = regexp.match("abb")
    second = regexp.match("aab")
    assert_equal %w[ab a b], first.to_a
    assert_equal %w[aab aa b], second.to_a
  end

  def test_empty_absence_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?~)")

    match = regexp.match("abc")
    assert_equal "", match[0]
    assert_equal [3, 3], match.offset(0)
  end

  def test_captured_literal_absence_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?~(a))")

    matched = regexp.match("ba")
    assert_equal "b", matched[0]
    assert_equal "a", matched[1]
    assert_equal [1, 2], matched.offset(1)
  end

  def test_escape_class_run_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\w+")

    assert_equal "word", regexp.match("word!")[0]
  end

  def test_unicode_class_rejects_ascii_input_without_fallback
    regexp = Onibi::Regexp.new("[é]")

    assert_nil regexp.match("ascii")
  end

  def test_lookahead_alternation_backreference_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?=(a|aa))\\1b")

    assert_equal %w[ab a], regexp.match("aab").to_a
    assert_equal %w[ab a], regexp.match("ab").to_a
  end

  def test_lookahead_alternation_backreference_match_question_uses_hfa
    regexp = Onibi::Regexp.new("(?=(a|aa))\\1b")

    assert regexp.match?("aab")
    refute regexp.match?("aac")
  end

  def test_fixed_alternation_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<letter>a|b)c")

    assert_equal "a", regexp.match("ac")["letter"]
    assert_equal "b", regexp.match("bc")["letter"]
  end

  def test_literal_possessive_match_question_uses_hfa
    regexp = Onibi::Regexp.new("a++a")

    refute regexp.match?("aaa")
  end

  def test_literal_possessive_match_question_short_circuits_common_checks
    regexp = Onibi::Regexp.new("a++a")

    refute regexp.match?("aaa")
  end

  def test_bounded_literal_possessive_match_question_uses_hfa
    regexp = Onibi::Regexp.new("a{1,3}+a")

    assert regexp.match?("aaa")
    assert regexp.match?("aaaa")
  end

  def test_literal_negative_lookahead_match_uses_hfa_result
    regexp = Onibi::Regexp.new("cat(?!fish)")

    assert_equal "cat", regexp.match("a cat naps")[0]
    assert_nil regexp.match("catfish")
  end

  def test_literal_negative_lookahead_match_question_short_circuits_common_checks
    regexp = Onibi::Regexp.new("cat(?!fish)")

    assert regexp.match?("a cat naps")
  end

  def test_unicode_repeated_literal_rejects_ascii_input_without_fallback
    regexp = Onibi::Regexp.new("(?:日本語)+")

    assert_nil regexp.match("ascii only")
  end

  def test_literal_positive_lookahead_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a(?=b)")

    assert_equal "a", regexp.match("ab")[0]
    assert_nil regexp.match("ac")
  end

  def test_leading_literal_positive_lookahead_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?=a)a")

    assert_equal "a", regexp.match("a")[0]
    assert_nil regexp.match("b")
  end

  def test_repeated_leading_literal_lookahead_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?=a)(?=a)a")

    assert_equal "a", regexp.match("a").to_s
    assert_nil regexp.match("b")
  end

  def test_literal_positive_lookbehind_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<=pre)fix")

    assert_equal "fix", regexp.match("prefix")[0]
    assert_nil regexp.match("suffix")
  end

  def test_unicode_literal_positive_lookbehind_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<=ß)x")

    assert_equal "x", regexp.match("ßx")[0]
    assert_nil regexp.match("ax")
  end

  def test_unicode_class_positive_lookbehind_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<=[ß])x")

    assert_equal "x", regexp.match("ßx")[0]
    assert_nil regexp.match("ax")
  end

  def test_unicode_class_negative_lookbehind_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<![ß])x")

    assert_nil regexp.match("ßx")
    assert_equal "x", regexp.match("ax")[0]
  end

  def test_positive_literal_lookbehind_match_question_uses_combined_literal_path
    regexp = Onibi::Regexp.new("(?<=pre)fix")

    regexp.stub(:hfa_literal_assertion_result_safe?,
                -> { flunk "Positive lookbehind should use combined literal path" }) do
      assert regexp.match?("prefix")
      assert regexp.match?("xxprefix", 3)
      refute regexp.match?("xfix")
    end
  end

  def test_literal_lookbehind_matches_mri_across_public_apis
    regexp = Onibi::Regexp.new("(?<=pre)fix")
    input = "prefix prefixture"
    mri = ::Regexp.new("(?<=pre)fix")

    assert_equal mri.match?(input), regexp.match?(input)
    assert_equal mri.match(input).to_s, regexp.match(input).to_s
    assert_equal input.scan(mri), regexp.scan(input)
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_class_lookbehind_matches_mri_across_public_apis
    regexp = Onibi::Regexp.new("(?<=[a-z])cat")
    input = "acat x1cat zcat"
    mri = ::Regexp.new("(?<=[a-z])cat")

    assert_equal mri.match?(input), regexp.match?(input)
    assert_equal mri.match(input).to_s, regexp.match(input).to_s
    assert_equal input.scan(mri), regexp.scan(input)
    assert_equal input.gsub(mri, "<\\0>"), regexp.gsub(input, "<\\0>")
  end

  def test_negative_literal_lookbehind_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("(?<!un)happy")

    regexp.stub(:hfa_literal_assertion_result_safe?,
                -> { flunk "Negative lookbehind should use constructor dispatch metadata" }) do
      assert regexp.match?("very happy")
      refute regexp.match?("unhappy")
    end
  end

  def test_literal_negative_lookbehind_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<!a)b")

    assert_equal "b", regexp.match("cb")[0]
    assert_nil regexp.match("ab")
  end

  def test_guarded_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<!a)(?<letter>b)")

    assert_equal "b", regexp.match("cb")["letter"]
    assert_nil regexp.match("ab")
  end

  def test_variable_literal_alternation_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<letter>a|ab)c")

    assert_equal "a", regexp.match("ac")["letter"]
    assert_equal "ab", regexp.match("abc")["letter"]
  end

  def test_single_capture_literal_alternation_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<letter>a|aa)")

    match = regexp.match("xaa")
    assert_equal "a", match[0]
    assert_equal "a", match["letter"]
    assert_equal [1, 2], match.offset("letter")
  end

  def test_adjacent_greedy_capture_match_uses_hfa_result
    {
      "(a*)(a*)" => ["aa", ["aa", ""]],
      "(.*)(.*)" => ["abc", ["abc", ""]]
    }.each do |pattern, (input, captures)|
      regexp = Onibi::Regexp.new(pattern)

      match = regexp.match(input)
      assert_equal captures, match.captures
    end
  end

  def test_literal_subexpression_call_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<letter>a)\\g<letter>")

    match = regexp.match("xaa")
    assert_equal "aa", match[0]
    assert_equal "a", match["letter"]
    assert_equal [1, 2], match.offset("letter")
  end

  def test_unicode_repeated_literal_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<word>é+)")

    match = regexp.match("aééz")
    assert_equal "éé", match[0]
    assert_equal "éé", match["word"]
    assert_equal [1, 3], match.offset("word")
  end

  def test_unicode_repeated_capture_character_offsets_use_unit_width
    regexp = Onibi::Regexp.new("(?<word>é+)")

    assert_equal [1, 3], regexp.send(:hfa_unicode_repeated_literal_capture_character_offsets, "aééz", 1, 5)
  end

  def test_unicode_repeated_literal_capture_match_question_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<word>é+)")

    assert regexp.match?("aééz")
  end

  def test_captureless_regular_sequence_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[a-z]\\d+")

    assert_equal "a123", regexp.match("xxa123!").to_s
    assert_nil regexp.match("xxabc!")
  end

  def test_scoped_ignorecase_literal_sequence_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a(?i:bc)d")

    assert_equal "aBCd", regexp.match("xxaBCdyy").to_s
    assert_nil regexp.match("xxaBXdyy")
  end

  def test_scoped_multiline_any_sequence_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a(?m:.)d")

    assert_equal "a\nd", regexp.match("xxa\ndyy").to_s
    assert_equal "aXd", regexp.match("xxaXdyy").to_s
  end

  def test_lazy_bounded_literal_sequence_match_uses_hfa_result
    regexp = Onibi::Regexp.new("foo.{2,4}?bar")

    assert_equal "foo12bar", regexp.match("xxfoo12bar--foo1234bar").to_s
  end

  def test_lazy_bounded_literal_sequence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("foo.{2,4}?bar")

    assert_equal %w[foo12bar foo1234bar], regexp.scan("foo12bar foo1234bar")
  end

  def test_repeated_literal_capture_with_suffix_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<letter>a)+b")

    match = regexp.match("aaab")
    assert_equal "a", match["letter"]
    assert_equal [2, 3], match.offset("letter")
  end

  def test_repeated_class_capture_with_suffix_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<digits>\\d+);")

    match = regexp.match("id=2026;")
    assert_equal "2026", match["digits"]
  end

  def test_simple_backreference_match_uses_hfa_result
    regexp = Onibi::Regexp.new("([a-z]+)-\\1")

    match = regexp.match("echo-echo")
    assert_equal "echo", match[1]
    assert_equal [0, 4], match.offset(1)
  end

  def test_named_backreference_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<word>[a-z]+)-\\k<word>")

    match = regexp.match("echo-echo")
    assert_equal "echo", match[:word]
    assert_equal [0, 4], match.offset(:word)
  end

  def test_adjacent_literal_backreference_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(ab)\\1")

    match = regexp.match("zzabab")
    assert_equal "ab", match[1]
    assert_equal [2, 4], match.offset(1)
  end

  def test_literal_backreference_with_separator_uses_hfa_result
    regexp = Onibi::Regexp.new("(ab)-\\1")

    match = regexp.match("zzab-ab")
    assert_equal "ab", match[1]
    assert_equal [2, 4], match.offset(1)
  end

  def test_optional_conditional_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(a)?(?(1)b|c)")

    assert_equal "ab", regexp.match("ab")[0]
    assert_equal "c", regexp.match("c")[0]
  end

  def test_named_optional_conditional_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<letter>a)?(?(<letter>)b|c)")

    assert_equal "ab", regexp.match("ab")[0]
    assert_equal "c", regexp.match("c")[0]
  end

  def test_named_subexpression_call_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<pair>ab)\\g<pair>")

    match = regexp.match("zzabab")
    assert_equal "ab", match[:pair]
    assert_equal [2, 4], match.offset(:pair)
  end

  def test_nested_literal_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab))")

    match = regexp.match("zzab")
    assert_equal %w[ab ab], match.captures
    assert_equal [[2, 4], [2, 4]], [match.offset(1), match.offset(2)]
  end

  def test_named_nested_literal_captures_use_hfa_result
    regexp = Onibi::Regexp.new("(?<outer>(?<inner>ab))")

    match = regexp.match("zzab")
    assert_equal "ab", match[:outer]
    assert_equal "ab", match[:inner]
  end

  def test_nested_fixed_width_alternation_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((a|b))")

    match = regexp.match("zzb")
    assert_equal %w[b b], match.captures
    assert_equal [[2, 3], [2, 3]], [match.offset(1), match.offset(2)]
  end

  def test_nested_variable_width_alternation_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((a|ab))")

    match = regexp.match("zzab")
    assert_equal %w[a a], match.captures
    assert_equal [[2, 3], [2, 3]], [match.offset(1), match.offset(2)]
  end

  def test_nested_repeated_literal_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab)+)")

    match = regexp.match("zzabab")
    assert_equal %w[abab ab], match.captures
    assert_equal [[2, 6], [4, 6]], [match.offset(1), match.offset(2)]
  end

  def test_nested_repeated_alternation_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((a|b)+)")

    match = regexp.match("zzabab")
    assert_equal %w[abab b], match.captures
    assert_equal [[2, 6], [5, 6]], [match.offset(1), match.offset(2)]
  end

  def test_nested_variable_repeated_alternation_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab|a)+)")

    match = regexp.match("zzaba")
    assert_equal %w[aba a], match.captures
    assert_equal [[2, 5], [4, 5]], [match.offset(1), match.offset(2)]
  end

  def test_nested_repeated_capture_with_suffix_uses_hfa_result
    regexp = Onibi::Regexp.new("((ab)+)c")

    match = regexp.match("zzababc")
    assert_equal %w[ababc abab ab], match.to_a
    assert_equal [[2, 6], [4, 6]], [match.offset(1), match.offset(2)]
  end

  def test_nested_repeated_and_class_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab)+)-([0-9]+)")

    match = regexp.match("zzabab-123")
    assert_equal %w[abab-123 abab ab 123], match.to_a
    assert_equal [[2, 6], [4, 6], [7, 10]], [match.offset(1), match.offset(2), match.offset(3)]
  end

  def test_nested_repeated_and_nested_class_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab)+)-(([0-9]) +)".delete(" "))

    match = regexp.match("zzabab-123")
    assert_equal %w[abab-123 abab ab 123 3], match.to_a
    assert_equal [[2, 6], [4, 6], [7, 10], [9, 10]],
                 [match.offset(1), match.offset(2), match.offset(3), match.offset(4)]
  end

  def test_adjacent_nested_repeated_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab)+)((cd)+)")

    match = regexp.match("zzababcdcd")
    assert_equal %w[ababcdcd abab ab cdcd cd], match.to_a
    assert_equal [[2, 6], [4, 6], [6, 10], [8, 10]],
                 [match.offset(1), match.offset(2), match.offset(3), match.offset(4)]
  end

  def test_match_exposes_capture_offsets_and_size
    match = Onibi::Regexp.new("(ab)(cd)").match("xxabcdyy")

    assert_equal [2, 6], match.offset(0)
    assert_equal [2, 4], match.offset(1)
    assert_equal [4, 6], match.offset(2)
    assert_equal 3, match.length
    assert_equal 3, match.size
  end

  def test_match_reports_unmatched_and_repeated_captures
    optional = Onibi::Regexp.new("(a)?b").match("b")
    repeated = Onibi::Regexp.new("(ab)+").match("abab")

    assert_nil optional[1]
    assert_equal [nil, nil], optional.offset(1)
    assert_equal "ab", repeated[1]
    assert_equal [2, 4], repeated.offset(1)
  end

  def test_match_values_at_extracts_indices_and_ranges
    match = Onibi::Regexp.new("(ab)(cd)").match("xxabcdyy")

    assert_equal ["abcd", "cd", nil], match.values_at(0, 2, 9)
    assert_equal %w[abcd ab], match.values_at(0..1)
  end

  def test_match_exposes_input_regexp_and_surrounding_text
    regexp = Onibi::Regexp.new("cat")
    input = "wildcatdog"
    match = regexp.match(input)

    assert_same input, match.string
    assert_same regexp, match.regexp
    assert_equal "wild", match.pre_match
    assert_equal "dog", match.post_match
  end

  def test_match_exposes_byte_offsets_and_match_length
    match = Onibi::Regexp.new("é").match("aéz")

    assert_equal 1, match.bytebegin(0)
    assert_equal 3, match.byteend(0)
    assert_equal [1, 3], match.byteoffset(0)
    assert_equal 1, match.match_length(0)
  end

  def test_match_data_has_value_object_semantics
    first = Onibi::Regexp.new("cat").match("wildcat")
    second = Onibi::Regexp.new("cat").match("wildcat")
    different = Onibi::Regexp.new("cat").match("cat")

    assert_equal first, second
    assert first.eql?(second)
    assert_equal first.hash, second.hash
    refute_equal first, different
  end

  def test_match_data_supports_pattern_matching_destructuring
    match = Onibi::Regexp.new("(?<animal>cat)(dog)").match("catdog")

    assert_equal %w[cat dog], match.deconstruct
    assert_equal({ animal: "cat" }, match.deconstruct_keys([:animal]))
    assert_equal({ animal: "cat" }, match.deconstruct_keys(nil))
  end

  def test_match_data_destructuring_rejects_string_keys
    match = Onibi::Regexp.new("(?<animal>cat)").match("cat")

    assert_raises(TypeError) { match.deconstruct_keys(["animal"]) }
  end

  def test_match_data_inspect_uses_ruby_class_name
    match = Onibi::Regexp.new("(?<animal>cat)(?<dog>dog)?").match("cat")

    assert_equal '#<MatchData "cat" animal:"cat" dog:nil>', match.inspect
  end

  def test_offset_apis_validate_indices_and_accept_named_captures
    match = Onibi::Regexp.new("(?<animal>cat)").match("cat")

    assert_equal [0, 3], match.offset("animal")
    assert_equal 0, match.begin(:animal)
    assert_equal 3, match.end(:animal)
    assert_raises(IndexError) { match.offset(-1) }
    assert_raises(IndexError) { match.bytebegin(2) }
    assert_raises(TypeError) { match.match_length(nil) }
  end
end
