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

    regexp.stub(:codegen_match, ->(*) { flunk "captureless literal match should use HFA" }) do
      match = regexp.match("wildcat")
      assert_equal "cat", match[0]
      assert_equal [4, 7], match.offset(0)
    end
  end

  def test_always_failing_assertion_uses_hfa_for_all_match_apis
    regexp = Onibi::Regexp.new("(?!)")

    regexp.stub(:codegen_match?, ->(*) { flunk "always-failing assertion match? should use HFA" }) do
      refute regexp.match?("anything")
    end
    regexp.stub(:codegen_match, ->(*) { flunk "always-failing assertion match should use HFA" }) do
      assert_nil regexp.match("anything")
    end
    regexp.stub(:codegen_each_match, ->(*) { flunk "always-failing assertion scan should use HFA" }) do
      assert_empty regexp.scan("anything")
    end
  end

  def test_exact_literal_match_uses_hfa_string_path_without_program_dispatch
    regexp = Onibi::Regexp.new("needle")

    regexp.stub(:hfa_program, -> { flunk "exact literal should use HFA string path" }) do
      assert regexp.match?("prefix-needle-suffix")
    end
  end

  def test_exact_literal_default_position_skips_position_normalization
    regexp = Onibi::Regexp.new("needle")

    regexp.stub(:normalize_match_position, ->(*) { flunk "default exact literal position should be zero" }) do
      assert regexp.match?("prefix-needle-suffix")
    end
  end

  def test_exact_literal_match_question_uses_constructor_fast_metadata
    regexp = Onibi::Regexp.new("needle")

    regexp.stub(:hfa_exact_literal_result_safe?, -> { flunk "exact literal match? should use constructor metadata" }) do
      assert regexp.match?("prefix-needle-suffix")
    end
  end

  def test_scoped_ignorecase_match_question_uses_hfa
    regexp = Onibi::Regexp.new("(?i:cat)")

    regexp.stub(:codegen_match?, ->(*) { flunk "scoped ignorecase match? should use HFA" }) do
      assert regexp.match?("xxCAtxx")
      refute regexp.match?("dog")
    end
  end

  def test_scoped_ignorecase_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?i:cat)")

    regexp.stub(:codegen_match, ->(*) { flunk "scoped ignorecase match should use HFA" }) do
      assert_equal "CAt", regexp.match("xxCAtxx").to_s
    end
  end

  def test_scoped_multiline_match_question_uses_hfa
    regexp = Onibi::Regexp.new("(?m:.)")

    regexp.stub(:codegen_match?, ->(*) { flunk "scoped multiline match? should use HFA" }) do
      assert regexp.match?("\n")
    end
  end

  def test_ascii_linebreak_match_uses_hfa
    regexp = Onibi::Regexp.new("\\R")

    regexp.stub(:codegen_match, ->(*) { flunk "ASCII linebreak match should use HFA" }) do
      assert_equal "\r\n", regexp.match("x\r\ny")[0]
    end
    regexp.stub(:codegen_match?, ->(*) { flunk "ASCII linebreak match? should use HFA" }) do
      assert regexp.match?("x\ny")
    end
  end

  def test_start_match_anchor_uses_hfa
    regexp = Onibi::Regexp.new("\\Gfoo")

    regexp.stub(:codegen_match?, ->(*) { flunk "start-match match? should use HFA" }) do
      assert regexp.match?("xxfoo", 2)
      refute regexp.match?("xxfoo", 0)
    end
    regexp.stub(:codegen_match, ->(*) { flunk "start-match match should use HFA" }) do
      assert_equal "foo", regexp.match("xxfoo", 2).to_s
    end
  end

  def test_unicode_linebreak_match_uses_hfa
    regexp = Onibi::Regexp.new("\\R")

    regexp.stub(:codegen_match, ->(*) { flunk "Unicode linebreak match should use HFA" }) do
      assert_equal "\u2028", regexp.match("x\u2028y")[0]
    end
  end

  def test_unicode_exact_literal_match_question_uses_constructor_fast_metadata
    regexp = Onibi::Regexp.new("こんにちは")

    regexp.stub(:hfa_unicode_exact_literal_result_safe?,
                -> { flunk "Unicode exact literal match? should use constructor metadata" }) do
      assert regexp.match?("挨拶はこんにちはです")
      assert regexp.match?("挨拶はこんにちはです", 3)
      refute regexp.match?("挨拶はこんにちはです", 4)
    end
  end

  def test_word_boundary_literal_match_uses_hfa_string_path
    regexp = Onibi::Regexp.new("\\bcat\\b")

    regexp.stub(:hfa_program, -> { flunk "word-boundary literal should use HFA string path" }) do
      assert regexp.match?("a cat naps")
      refute regexp.match?("scatter")
    end
  end

  def test_word_boundary_literal_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("\\bcat\\b")

    regexp.stub(:hfa_program, -> { flunk "Word-boundary literal should use constructor dispatch metadata" }) do
      assert regexp.match?("a cat naps")
      refute regexp.match?("scatter")
    end
  end

  def test_literal_lookaround_match_uses_hfa_string_path
    regexp = Onibi::Regexp.new("a(?=b)")

    regexp.stub(:hfa_program, -> { flunk "literal lookaround should use HFA string path" }) do
      assert regexp.match?("ab")
      refute regexp.match?("ac")
    end
  end

  def test_possessive_literal_match_uses_hfa_string_path
    regexp = Onibi::Regexp.new("a++b")

    regexp.stub(:hfa_program, -> { flunk "possessive literal should use HFA string path" }) do
      assert regexp.match?("aaaaab")
      refute regexp.match?("aaaac")
    end
  end

  def test_possessive_literal_match_returns_the_longest_one_byte_run
    match = Onibi::Regexp.new("a++b").match("zaaaab")

    assert_equal "aaaab", match[0]
    assert_equal [1, 6], match.offset(0)
  end

  def test_literal_alternation_match_uses_hfa_result
    regexp = Onibi::Regexp.new("cat|dog")

    regexp.stub(:codegen_match, ->(*) { flunk "literal alternation match should use HFA" }) do
      match = regexp.match("a dog")
      assert_equal "dog", match[0]
      assert_equal [2, 5], match.offset(0)
    end

    assert_equal "a", Onibi::Regexp.new("a|aa").match("aa")[0]
  end

  def test_literal_alternation_match_uses_direct_hfa_result
    regexp = Onibi::Regexp.new("cat|dog|fox")

    regexp.stub(:hfa_program, -> { flunk "literal alternation match should avoid HFA program" }) do
      match = regexp.match("dog then cat")
      assert_equal "dog", match[0]
      assert_equal [0, 3], match.offset(0)
    end
  end

  def test_single_byte_class_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[a-z]")

    regexp.stub(:codegen_match, ->(*) { flunk "single-byte class match should use HFA" }) do
      match = regexp.match("123x")
      assert_equal "x", match[0]
      assert_equal [3, 4], match.offset(0)
    end
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

    regexp.stub(:codegen_match, ->(*) { flunk "singleton-class alternation should use HFA" }) do
      assert_equal "a", regexp.match("xa").to_s
      assert_equal "b", regexp.match("xb").to_s
      assert_nil regexp.match("xc")
    end
  end

  def test_captureless_class_run_alternation_match_uses_hfa_result
    regexp = Onibi::Regexp.new("foo[a-z]+|foo[0-9]+")

    regexp.stub(:codegen_match, ->(*) { flunk "captureless class alternation should use HFA" }) do
      assert_equal "fooabc", regexp.match("xxfooabc!").to_s
      assert_equal "foo123", regexp.match("xxfoo123!").to_s
    end
  end

  def test_single_byte_dot_match_uses_hfa_result
    regexp = Onibi::Regexp.new(".")

    regexp.stub(:codegen_match, ->(*) { flunk "single-byte dot match should use HFA" }) do
      match = regexp.match("\nx")
      assert_equal "x", match[0]
      assert_equal [1, 2], match.offset(0)
    end
  end

  def test_literal_dot_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a.c")

    regexp.stub(:codegen_match, ->(*) { flunk "literal/dot/literal match should use HFA" }) do
      match = regexp.match("xxabc yy")
      assert_equal "abc", match[0]
      assert_equal [2, 5], match.offset(0)
    end
  end

  def test_single_class_run_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[0-9]+")

    regexp.stub(:codegen_match, ->(*) { flunk "single class run match should use HFA" }) do
      match = regexp.match("abc123def")
      assert_equal "123", match[0]
      assert_equal [3, 6], match.offset(0)
    end
  end

  def test_fixed_class_run_literal_match_uses_hfa_result
    program = Onibi::HybridAutomata.compile("a[bc]{4}z")

    assert_equal [3, 9, []], program.match_result("xxaabcbcz yy")
  end

  def test_literal_class_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a[0-9]+z")

    regexp.stub(:codegen_match, ->(*) { flunk "literal/class/literal match should use HFA" }) do
      match = regexp.match("xxa123z yy")
      assert_equal "a123z", match[0]
      assert_equal [2, 7], match.offset(0)
    end
  end

  def test_digit_run_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\d+")

    regexp.stub(:codegen_match, ->(*) { flunk "digit run match should use HFA" }) do
      match = regexp.match("id=123")
      assert_equal "123", match[0]
      assert_equal [3, 6], match.offset(0)
    end
  end

  def test_star_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a.*z")

    regexp.stub(:codegen_match, ->(*) { flunk "star literal match should use HFA" }) do
      match = regexp.match("a-first-z-second-z")
      assert_equal "a-first-z-second-z", match[0]
      assert_equal [0, 18], match.offset(0)
    end
  end

  def test_lazy_star_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a.*?z")

    regexp.stub(:codegen_match, ->(*) { flunk "lazy star literal match should use HFA" }) do
      match = regexp.match("a-first-z-second-z")
      assert_equal "a-first-z", match[0]
      assert_equal [0, 9], match.offset(0)
    end
  end

  def test_lazy_star_literal_match_question_uses_direct_path
    regexp = Onibi::Regexp.new("a.*?z")

    regexp.stub(:hfa_match_question_safe?, -> { flunk "Lazy dot-star match? should use direct path" }) do
      assert regexp.match?("a-first-z-second-z")
      refute regexp.match?("a-first-x")
    end
  end

  def test_lazy_literal_quantifier_match_uses_hfa_result
    {
      "a+?" => ["a", "ba"],
      "a+?a" => ["aa", "aaa"],
      "a??b" => ["b", "b"]
    }.each do |pattern, (expected, input)|
      regexp = Onibi::Regexp.new(pattern)

      regexp.stub(:codegen_match, ->(*) { flunk "lazy literal #{pattern} match should use HFA" }) do
        assert_equal expected, regexp.match(input).to_s
      end
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

    regexp.stub(:codegen_match?, ->(*) { flunk "captureless match? should use HFA" }) do
      assert regexp.match?("wildcat")
    end
  end

  def test_literal_quantifier_match_question_mark_uses_hfa
    regexp = Onibi::Regexp.new("a+")

    regexp.stub(:codegen_match?, ->(*) { flunk "literal quantifier should use HFA" }) do
      regexp.stub(:hfa_program, -> { flunk "literal quantifier match? should avoid HFA program compilation" }) do
        assert regexp.match?("caaab")
        refute regexp.match?("cbbb")
      end
    end
  end

  def test_regular_composite_match_question_mark_uses_hfa
    regexp = Onibi::Regexp.new("(?:ab|ac)+z")

    regexp.stub(:codegen_match?, ->(*) { flunk "regular composite match? should use HFA" }) do
      assert regexp.match?("prefix abacabz suffix")
      refute regexp.match?("prefix abaxz suffix")
    end
  end

  def test_captured_class_run_chain_match_question_uses_boolean_hfa_path
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    regexp.stub(:hfa_program, -> { flunk "captured class-run match? should avoid program compilation" }) do
      assert regexp.match?("prefix item-2026 suffix")
      refute regexp.match?("prefix item- suffix")
    end
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

    regexp.stub(:hfa_program, -> { flunk "Unicode literal capture match? should avoid program compilation" }) do
      assert regexp.match?("挨拶こんにちは世界です")
      refute regexp.match?("挨拶こんにちは地球です")
    end
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

    regexp.stub(:hfa_program, -> { flunk "ASCII Unicode property match? should avoid program compilation" }) do
      assert regexp.match?("prefix letters suffix")
      refute regexp.match?("12345")
    end
  end

  def test_ascii_unicode_property_run_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("\\p{Alpha}+")

    regexp.stub(:hfa_ascii_unicode_run_result_safe?,
                -> { flunk "ASCII Unicode property run should use constructor dispatch metadata" }) do
      assert regexp.match?("prefix letters suffix")
    end
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

    regexp.stub(:hfa_program, -> { flunk "Unicode property match? should avoid program compilation" }) do
      assert regexp.match?("漢字ひらがな漢字")
      refute regexp.match?("漢字カタカナ漢字")
    end
  end

  def test_single_unicode_property_match_question_uses_hfa
    regexp = Onibi::Regexp.new("\\p{Han}")

    regexp.stub(:codegen_match?, ->(*) { flunk "single Unicode property match? should use HFA" }) do
      assert regexp.match?("漢")
      refute regexp.match?("あ")
    end
  end

  def test_unicode_word_class_run_match_question_uses_direct_character_path
    regexp = Onibi::Regexp.new("[[:word:]]+")

    regexp.stub(:hfa_program, -> { flunk "Unicode word class match? should avoid program compilation" }) do
      assert regexp.match?("記号-日本語_2026-終端")
      refute regexp.match?("---😀")
    end
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

    regexp.stub(:hfa_ignorecase_literal_match_result, ->(*) { flunk "ASCII ignorecase match? should use boolean string path" }) do
      assert regexp.match?("prefix CASE suffix")
      refute regexp.match?("prefix dog suffix")
    end
  end

  def test_ascii_ignorecase_match_question_uses_constructor_fast_metadata
    regexp = Onibi::Regexp.new("case", Onibi::Regexp::IGNORECASE)

    regexp.stub(:hfa_ignorecase_literal_result_safe?, -> { flunk "ignorecase literal match? should use constructor metadata" }) do
      assert regexp.match?("prefix CASE suffix")
    end
  end

  def test_ascii_ignorecase_match_uses_constructor_fast_metadata
    regexp = Onibi::Regexp.new("case", Onibi::Regexp::IGNORECASE)

    regexp.stub(:hfa_ignorecase_literal_result_safe?, -> { flunk "ignorecase literal match should use constructor metadata" }) do
      match = regexp.match("prefix CASE suffix")
      assert_equal "CASE", match[0]
      assert_equal [7, 11], match.offset(0)
    end
  end

  def test_adjacent_ascii_class_runs_use_direct_match_question_path
    regexp = Onibi::Regexp.new("[[:alpha:]]+[[:digit:]]+")

    regexp.stub(:hfa_match_question_safe?, -> { flunk "adjacent class runs should use direct match? path" }) do
      assert regexp.match?("item2026")
    end
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

    regexp.stub(:hfa_match_question_safe?, -> { flunk "atomic literal alternation should use direct match? path" }) do
      assert regexp.match?("ab")
    end
  end

  def test_atomic_literal_alternation_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?>a|ab)b")

    regexp.stub(:codegen_match, ->(*) { flunk "atomic literal alternation match should use HFA" }) do
      assert_equal "ab", regexp.match("zab").to_s
      assert_nil regexp.match("zac")
    end
  end

  def test_subexpression_literal_call_uses_direct_match_question_path
    regexp = Onibi::Regexp.new("(?<pair>ab)\\g<pair>")

    regexp.stub(:hfa_match_question_safe?, -> { flunk "subexpression literal call should use direct match? path" }) do
      assert regexp.match?("abab")
    end
  end

  def test_greedy_dot_star_literal_uses_direct_match_question_path
    regexp = Onibi::Regexp.new("a.*z")

    regexp.stub(:hfa_match_question_safe?, -> { flunk "greedy dot-star literal should use direct match? path" }) do
      assert regexp.match?("a-middle-z")
    end
  end

  def test_bounded_literal_match_question_uses_direct_hfa_path
    regexp = Onibi::Regexp.new("a{4,12}")

    regexp.stub(:hfa_match_question_safe?, -> { flunk "bounded literal should use direct match? path" }) do
      assert regexp.match?("baaaaaaaac")
      refute regexp.match?("baaac")
    end
  end

  def test_bounded_literal_match_question_uses_early_constructor_dispatch
    regexp = Onibi::Regexp.new("a{4,12}")

    regexp.stub(:hfa_bounded_literal_result_safe?,
                -> { flunk "bounded literal should use early constructor dispatch" }) do
      assert regexp.match?("baaaaaaaac")
    end
  end

  def test_bounded_literal_match_returns_the_greedy_run_and_respects_position
    regexp = Onibi::Regexp.new("a{2,4}")

    match = regexp.match("zaaaaa")
    assert_equal "aaaa", match[0]
    assert_equal [1, 5], match.offset(0)
    assert_nil regexp.match("zaaaaa", 5)
  end

  def test_match_reset_literal_match_question_uses_adjacent_string_path
    regexp = Onibi::Regexp.new("prefix\\Ksuffix")

    regexp.stub(:hfa_program, -> { flunk "match-reset literal match? should avoid program compilation" }) do
      assert regexp.match?("xxprefixsuffixyy")
      refute regexp.match?("xxprefix-suffixyy")
    end
  end

  def test_standalone_absence_match_question_uses_constant_path
    regexp = Onibi::Regexp.new("(?~END)")

    regexp.stub(:hfa_match_question_safe?, -> { flunk "Standalone absence should use constant match? path" }) do
      assert regexp.match?("payloadEND")
      assert regexp.match?("payload")
      assert regexp.match?("")
    end
  end

  def test_literal_absence_match_and_scan_use_hfa_results
    regexp = Onibi::Regexp.new("(?~END)")

    regexp.stub(:codegen_match, ->(*) { flunk "literal absence match should use HFA" }) do
      assert_equal "EN", regexp.match("END").to_s
      assert_equal "xxEN", regexp.match("xxENDyy").to_s
      assert_equal "abc", regexp.match("abc").to_s
    end
    regexp.stub(:codegen_each_result, ->(*) { flunk "literal absence scan should use HFA" }) do
      assert_equal ["EN", "D", ""], regexp.scan("END")
      assert_equal ["xxEN", "D", "yy", ""], regexp.scan("xxENDyy")
    end
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

    regexp.stub(:codegen_match, ->(*) { flunk "match-reset literal match should use HFA" }) do
      assert_equal "suffix", regexp.match("xxprefixsuffixyy").to_s
      assert_nil regexp.match("xxprefix-suffixyy")
    end
  end

  def test_absolute_anchor_match_uses_hfa_result
    regexp = Onibi::Regexp.new("^cat$")

    regexp.stub(:codegen_match, ->(*) { flunk "absolute anchor match should use HFA" }) do
      assert_equal "cat", regexp.match("cat").to_s
      assert_nil regexp.match("xcat")
    end
  end

  def test_before_final_newline_anchor_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\Acat\\Z")

    regexp.stub(:codegen_match, ->(*) { flunk "before-final-newline anchor should use HFA" }) do
      assert_equal "cat", regexp.match("cat\n").to_s
      assert_equal "cat", regexp.match("cat").to_s
      assert_nil regexp.match("cat\nx")
    end
  end

  def test_greedy_bounded_sequence_match_uses_hfa_result
    regexp = Onibi::Regexp.new("foo.{0,4}bar")

    regexp.stub(:codegen_match, ->(*) { flunk "greedy bounded sequence should use HFA" }) do
      assert_equal "foo12bar", regexp.match("xfoo12bar").to_s
      assert_nil regexp.match("fooxxxxxbar")
    end
  end

  def test_scoped_extended_options_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a(?-x: b#c )d")

    regexp.stub(:codegen_match, ->(*) { flunk "scoped extended option should use HFA" }) do
      assert_equal "a b#c d", regexp.match("a b#c d").to_s
    end
  end

  def test_nested_scoped_extended_options_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?x:(?-x: a b ) c)")

    regexp.stub(:codegen_match, ->(*) { flunk "nested scoped extended option should use HFA" }) do
      assert_equal " a b c", regexp.match(" a b c").to_s
    end
  end

  def test_nonword_boundary_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\Bcat\\B")

    regexp.stub(:codegen_match, ->(*) { flunk "nonword-boundary literal should use HFA" }) do
      assert_equal "cat", regexp.match("_cat_").to_s
      assert_nil regexp.match(" catx ")
    end
  end

  def test_match_reset_literal_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("prefix\\Ksuffix")

    regexp.stub(:hfa_match_reset_literal_combined_literal,
                -> { flunk "Match-reset literal should use constructor dispatch metadata" }) do
      assert regexp.match?("xxprefixsuffixyy")
    end
  end

  def test_class_run_positive_lookahead_match_question_uses_boolean_path
    regexp = Onibi::Regexp.new("[a-z]+(?=-[0-9]+)")

    regexp.stub(:hfa_program, -> { flunk "class-run lookahead match? should avoid program compilation" }) do
      assert regexp.match?("prefix item-2026 suffix")
      refute regexp.match?("prefix item- suffix")
    end
  end

  def test_class_run_positive_lookahead_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("[a-z]+(?=-[0-9]+)")

    regexp.stub(:hfa_class_run_positive_lookahead_result_safe?,
                -> { flunk "Class-run lookahead should use constructor dispatch metadata" }) do
      assert regexp.match?("prefix item-2026 suffix")
    end
  end

  def test_negative_literal_lookahead_uses_early_constructor_dispatch
    regexp = Onibi::Regexp.new("cat(?!fish)")

    regexp.stub(:hfa_literal_assertion_result_safe?,
                -> { flunk "negative literal lookahead should use early constructor dispatch" }) do
      assert regexp.match?("a cat naps")
      refute regexp.match?("a catfish naps")
    end
  end

  def test_repeated_class_backreference_uses_early_constructor_dispatch
    regexp = Onibi::Regexp.new("([a-z]+)-\\1")

    regexp.stub(:hfa_repeated_class_backref_result_safe?,
                -> { flunk "repeated class backreference should use early constructor dispatch" }) do
      assert regexp.match?("echo-echo")
    end
  end

  def test_ascii_character_class_run_match_question_uses_byte_table_path
    regexp = Onibi::Regexp.new("[a-z&&[^aeiou]]+")

    regexp.stub(:hfa_program, -> { flunk "ASCII character-class match? should avoid program compilation" }) do
      assert regexp.match?("aei-bcdfg-ou")
      refute regexp.match?("aei-OU")
    end
  end

  def test_ascii_shorthand_run_chain_match_question_uses_byte_tables
    regexp = Onibi::Regexp.new("\\w+\\s+\\d+")

    regexp.stub(:hfa_program, -> { flunk "ASCII shorthand run chain match? should avoid program compilation" }) do
      assert regexp.match?("item 2026")
      refute regexp.match?("item-2026")
    end
  end

  def test_literal_conditional_match_question_uses_alternative_string_path
    regexp = Onibi::Regexp.new("(a)?(?(1)b|c)")

    regexp.stub(:hfa_program, -> { flunk "literal conditional match? should avoid program compilation" }) do
      assert regexp.match?("prefix ab suffix")
      assert regexp.match?("prefix c suffix")
      refute regexp.match?("prefix d suffix")
    end
  end

  def test_literal_conditional_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("(a)?(?(1)b|c)")

    regexp.stub(:hfa_literal_conditional_result_safe?,
                -> { flunk "Literal conditional should use constructor dispatch metadata" }) do
      assert regexp.match?("ab")
      assert regexp.match?("c")
    end
  end

  def test_repeated_class_backreference_match_question_uses_byte_string_path
    regexp = Onibi::Regexp.new("([a-z]+)-\\1")

    regexp.stub(:hfa_program, -> { flunk "class backreference match? should avoid program compilation" }) do
      assert regexp.match?("prefix echo-echo suffix")
      refute regexp.match?("prefix echo-ecoh suffix")
    end
  end

  def test_anchored_class_run_match_question_uses_full_input_byte_path
    regexp = Onibi::Regexp.new("\\A[a-z]+\\z")

    regexp.stub(:hfa_program, -> { flunk "anchored class-run match? should avoid program compilation" }) do
      assert regexp.match?("anchored")
      refute regexp.match?("anchored1")
    end
  end

  def test_anchored_class_run_match_question_uses_constructor_dispatch_metadata
    regexp = Onibi::Regexp.new("\\A[a-z]+\\z")

    regexp.stub(:hfa_anchored_class_run_result_safe?,
                -> { flunk "Anchored class run should use constructor dispatch metadata" }) do
      assert regexp.match?("anchored")
      refute regexp.match?("anchored1")
    end
  end

  def test_anchored_class_run_match_and_scan_use_hfa_results
    regexp = Onibi::Regexp.new("\\A[a-z]+\\z")

    regexp.stub(:codegen_match, ->(*) { flunk "anchored class run match should use HFA" }) do
      assert_equal "anchored", regexp.match("anchored").to_s
      assert_nil regexp.match("anchored1")
    end
    regexp.stub(:codegen_each_result, ->(*) { flunk "anchored class run scan should use HFA" }) do
      assert_equal ["anchored"], regexp.scan("anchored")
      assert_empty regexp.scan("anchored1")
    end
  end

  def test_literal_alternation_match_question_uses_direct_string_search
    regexp = Onibi::Regexp.new("cat|dog|fox")

    regexp.stub(:hfa_program, -> { flunk "literal alternation match? should avoid program compilation" }) do
      assert regexp.match?("the quick fox")
      refute regexp.match?("the quick hen")
    end
  end

  def test_selective_class_run_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[a-z&&[^aeiou]]+")

    regexp.stub(:codegen_match, ->(*) { flunk "selective class run match should use HFA" }) do
      assert_equal "bcdfg", regexp.match("ae-bcdfg-io").to_s
      assert_nil regexp.match("aeiou")
    end
  end

  def test_class_run_positive_lookahead_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[a-z]+(?=-[0-9]+)")

    regexp.stub(:codegen_match, ->(*) { flunk "class-run lookahead match should use HFA" }) do
      assert_equal "abc", regexp.match("abc-123").to_s
      assert_nil regexp.match("abc-def")
    end
  end

  def test_dot_literal_match_question_uses_direct_byte_path
    regexp = Onibi::Regexp.new("a.c")

    regexp.stub(:hfa_program, -> { flunk "dot literal match? should avoid program compilation" }) do
      assert regexp.match?("prefix-abc-suffix")
      refute regexp.match?("prefix-a\nc-suffix")
    end
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

    regexp.stub(:hfa_program, -> { flunk "ASCII literal match? should avoid HFA compilation on UTF-8 input" }) do
      regexp.stub(:codegen_match?, ->(*) { flunk "ASCII literal match? should use string path on UTF-8 input" }) do
        assert regexp.match?("前needle後")
      end
    end
  end

  def test_repeated_alternation_match_uses_hfa_result
    program = Onibi::HybridAutomata.compile("(?:ab|ac)+z")

    assert_equal [2, 11, []], program.match_result("xxabacababz yy")
  end

  def test_literal_quantifier_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a+")

    regexp.stub(:codegen_match, ->(*) { flunk "literal quantifier match should use HFA" }) do
      regexp.stub(:hfa_program, -> { flunk "literal quantifier match should avoid HFA program compilation" }) do
        match = regexp.match("caaab")
        assert_equal "aaa", match[0]
        assert_equal [1, 4], match.offset(0)
      end
    end
  end

  def test_repeated_literal_suffix_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a+b")

    regexp.stub(:codegen_match, ->(*) { flunk "repeated literal suffix match should use HFA" }) do
      match = regexp.match("xxaaab yy")
      assert_equal "aaab", match[0]
      assert_equal [2, 6], match.offset(0)
    end
  end

  def test_class_run_chain_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[a-z]+:[0-9]+")

    regexp.stub(:codegen_match, ->(*) { flunk "class run chain match should use HFA" }) do
      match = regexp.match("xxitem:2026 yy")
      assert_equal "xxitem:2026", match[0]
      assert_equal [0, 11], match.offset(0)
    end
  end

  def test_adjacent_class_runs_match_uses_hfa_result
    program = Onibi::HybridAutomata.compile("[a-z]+[0-9]+")

    assert_equal [0, 10, []], program.match_result("xxitem2026yy")
  end

  def test_class_run_triple_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\w+\\s+\\d+")

    regexp.stub(:codegen_match, ->(*) { flunk "class run triple should use HFA" }) do
      match = regexp.match("xxitem 2026yy")
      assert_equal "xxitem 2026", match[0]
      assert_equal [0, 11], match.offset(0)
    end
  end

  def test_ascii_property_run_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\p{Alpha}+")

    regexp.stub(:codegen_match, ->(*) { flunk "ASCII property run should use HFA" }) do
      match = regexp.match("123letters456")
      assert_equal "letters", match[0]
      assert_equal [3, 10], match.offset(0)
    end
  end

  def test_unicode_property_run_match_uses_hfa_result
    regexp = Onibi::Regexp.new("\\p{Hiragana}+")

    regexp.stub(:codegen_match, ->(*) { flunk "Unicode property run should use HFA" }) do
      match = regexp.match("漢字ひらがな終端")
      assert_equal "ひらがな", match[0]
      assert_equal [6, 18], match.offset(0)
    end
  end

  def test_unicode_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("こんにちは")

    regexp.stub(:codegen_match, ->(*) { flunk "unicode literal should use HFA result" }) do
      match = regexp.match("挨拶はこんにちはです")
      assert_equal "こんにちは", match[0]
      assert_equal [9, 24], match.offset(0)
    end
  end

  def test_unicode_exact_literal_match_uses_hfa_string_path
    regexp = Onibi::Regexp.new("こんにちは")

    regexp.stub(:hfa_program, -> { flunk "unicode exact literal should use HFA string path" }) do
      assert regexp.match?("挨拶はこんにちはです")
    end
  end

  def test_unicode_repeated_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?:日本語)+")

    regexp.stub(:codegen_match, ->(*) { flunk "unicode repeated literal should use HFA result" }) do
      match = regexp.match("開始日本語日本語終了")
      assert_equal "日本語日本語", match[0]
      assert_equal [6, 24], match.offset(0)
    end
  end

  def test_unicode_repeated_literal_match_question_skips_program_compile
    regexp = Onibi::Regexp.new("(?:日本語)+")

    regexp.stub(:hfa_program, -> { flunk "Unicode repeated literal match? should use string path" }) do
      assert regexp.match?("開始日本語日本語終了")
    end
  end

  def test_unicode_repeated_literal_unit_is_cached
    regexp = Onibi::Regexp.new("(?:日本語)+")

    assert regexp.match?("開始日本語終了")
    assert_equal "日本語", regexp.instance_variable_get(:@hfa_unicode_repeated_literal_unit)
  end

  def test_unicode_literal_captures_use_hfa_result
    regexp = Onibi::Regexp.new("(こんにちは)(世界)")

    regexp.stub(:codegen_match, ->(*) { flunk "unicode literal captures should use HFA result" }) do
      match = regexp.match("挨拶こんにちは世界です")
      assert_equal ["こんにちは世界", "こんにちは", "世界"], match.to_a
      assert_equal [[6, 27], [6, 21], [21, 27]],
                   [match.offset(0), match.offset(1), match.offset(2)]
    end
  end

  def test_unicode_literal_capture_match_question_uses_string_path
    regexp = Onibi::Regexp.new("(こんにちは)(世界)")

    regexp.stub(:hfa_program, -> { flunk "Unicode literal capture match? should use string path" }) do
      assert regexp.match?("挨拶こんにちは世界です")
    end
  end

  def test_ignorecase_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("case", ["ignorecase"])

    regexp.stub(:codegen_match, ->(*) { flunk "ignorecase literal should use HFA result" }) do
      match = regexp.match("xxCASEyy")
      assert_equal "CASE", match[0]
      assert_equal [2, 6], match.offset(0)
    end
  end

  def test_unicode_ignorecase_literal_match_uses_hfa_result
    regexp = Onibi::Regexp.new("école", ["ignorecase"])

    regexp.stub(:codegen_match, ->(*) { flunk "unicode ignorecase literal should use HFA result" }) do
      match = regexp.match("xxÉCOLEyy")
      assert_equal "ÉCOLE", match[0]
      assert_equal [2, 8], match.offset(0)
    end
  end

  def test_unicode_ignorecase_literal_match_question_uses_boolean_string_path
    regexp = Onibi::Regexp.new("école", ["ignorecase"])

    regexp.stub(:hfa_program, -> { flunk "Unicode ignorecase match? should use string path" }) do
      assert regexp.match?("xxÉCOLEyy")
    end
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

    regexp.stub(:codegen_match?, ->(*) { flunk "Unicode property match? should use HFA" }) do
      assert regexp.match?("漢字ひらがな終端")
      refute regexp.match?("漢字カタカナ終端")
    end
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

    regexp.stub(:codegen_match?, ->(*) { flunk "ASCII backreference match? should use HFA" }) do
      assert regexp.match?("echo-echo")
    end
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

  def test_match_question_mark_keeps_codegen_for_non_ascii_semantics
    regexp = Onibi::Regexp.new("é")

    regexp.stub(:hfa_program, -> { flunk "non-ASCII match? should use codegen" }) do
      assert regexp.match?("café")
    end
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

    regexp.stub(:codegen_match, ->(*) { flunk "simple captures should use HFA result" }) do
      match = regexp.match("xxabcdyy")
      assert_equal %w[ab cd], match.captures
      assert_equal([[2, 6], [2, 4], [4, 6]], (0..2).map { |index| match.offset(index) })
    end
  end

  def test_class_run_captures_use_hfa_result
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    regexp.stub(:codegen_match, ->(*) { flunk "class-run captures should use HFA result" }) do
      match = regexp.match("item-2026")
      assert_equal %w[item 2026], match.captures
    end
  end

  def test_optional_capture_match_uses_hfa_result_and_preserves_unmatched_offset
    regexp = Onibi::Regexp.new("(?<prefix>a)?b")

    regexp.stub(:codegen_match, ->(*) { flunk "optional captures should use HFA result" }) do
      matched = regexp.match("ab")
      missing = regexp.match("b")
      assert_equal "a", matched["prefix"]
      assert_nil missing["prefix"]
      assert_equal [nil, nil], missing.offset("prefix")
    end
  end

  def test_repeated_literal_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<pair>ab)+")

    regexp.stub(:codegen_match, ->(*) { flunk "repeated captures should use HFA result" }) do
      match = regexp.match("abab")
      assert_equal ["ab"], match.captures
      assert_equal [2, 4], match.offset("pair")
    end
  end

  def test_fixed_alternation_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<letter>a|b)c")

    regexp.stub(:codegen_match, ->(*) { flunk "fixed alternation captures should use HFA result" }) do
      assert_equal "a", regexp.match("ac")["letter"]
      assert_equal "b", regexp.match("bc")["letter"]
    end
  end

  def test_literal_possessive_match_question_uses_hfa
    regexp = Onibi::Regexp.new("a++a")

    regexp.stub(:codegen_match?, ->(*) { flunk "literal possessive match? should use HFA" }) do
      refute regexp.match?("aaa")
    end
  end

  def test_bounded_literal_possessive_match_question_uses_hfa
    regexp = Onibi::Regexp.new("a{1,3}+a")

    regexp.stub(:codegen_match?, ->(*) { flunk "bounded literal possessive match? should use HFA" }) do
      assert regexp.match?("aaa")
      assert regexp.match?("aaaa")
    end
  end

  def test_literal_negative_lookahead_match_uses_hfa_result
    regexp = Onibi::Regexp.new("cat(?!fish)")

    regexp.stub(:codegen_match, ->(*) { flunk "literal negative lookahead match should use HFA" }) do
      assert_equal "cat", regexp.match("a cat naps")[0]
      assert_nil regexp.match("catfish")
    end
  end

  def test_literal_positive_lookahead_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a(?=b)")

    regexp.stub(:codegen_match, ->(*) { flunk "literal positive lookahead match should use HFA" }) do
      assert_equal "a", regexp.match("ab")[0]
      assert_nil regexp.match("ac")
    end
  end

  def test_leading_literal_positive_lookahead_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?=a)a")

    regexp.stub(:codegen_match, ->(*) { flunk "leading literal positive lookahead should use HFA" }) do
      assert_equal "a", regexp.match("a")[0]
      assert_nil regexp.match("b")
    end
  end

  def test_repeated_leading_literal_lookahead_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?=a)(?=a)a")

    regexp.stub(:codegen_match, ->(*) { flunk "repeated leading lookahead should use HFA" }) do
      assert_equal "a", regexp.match("a").to_s
      assert_nil regexp.match("b")
    end
  end

  def test_literal_positive_lookbehind_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<=pre)fix")

    regexp.stub(:codegen_match, ->(*) { flunk "literal positive lookbehind match should use HFA" }) do
      assert_equal "fix", regexp.match("prefix")[0]
      assert_nil regexp.match("suffix")
    end
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

    regexp.stub(:codegen_match, ->(*) { flunk "literal negative lookbehind match should use HFA" }) do
      assert_equal "b", regexp.match("cb")[0]
      assert_nil regexp.match("ab")
    end
  end

  def test_guarded_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<!a)(?<letter>b)")

    regexp.stub(:codegen_match, ->(*) { flunk "guarded capture match should use HFA" }) do
      assert_equal "b", regexp.match("cb")["letter"]
      assert_nil regexp.match("ab")
    end
  end

  def test_variable_literal_alternation_capture_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<letter>a|ab)c")

    regexp.stub(:codegen_match, ->(*) { flunk "variable alternation capture should use HFA" }) do
      assert_equal "a", regexp.match("ac")["letter"]
      assert_equal "ab", regexp.match("abc")["letter"]
    end
  end

  def test_single_capture_literal_alternation_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<letter>a|aa)")

    regexp.stub(:codegen_match, ->(*) { flunk "single capture alternation should use HFA" }) do
      match = regexp.match("xaa")
      assert_equal "a", match[0]
      assert_equal "a", match["letter"]
      assert_equal [1, 2], match.offset("letter")
    end
  end

  def test_repeated_literal_capture_with_suffix_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<letter>a)+b")

    regexp.stub(:codegen_match, ->(*) { flunk "repeated capture suffix should use HFA" }) do
      match = regexp.match("aaab")
      assert_equal "a", match["letter"]
      assert_equal [2, 3], match.offset("letter")
    end
  end

  def test_repeated_class_capture_with_suffix_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<digits>\\d+);")

    regexp.stub(:codegen_match, ->(*) { flunk "repeated class capture suffix should use HFA" }) do
      match = regexp.match("id=2026;")
      assert_equal "2026", match["digits"]
    end
  end

  def test_simple_backreference_match_uses_hfa_result
    regexp = Onibi::Regexp.new("([a-z]+)-\\1")

    regexp.stub(:codegen_match, ->(*) { flunk "backreference match should use HFA result" }) do
      match = regexp.match("echo-echo")
      assert_equal "echo", match[1]
      assert_equal [0, 4], match.offset(1)
    end
  end

  def test_named_backreference_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<word>[a-z]+)-\\k<word>")

    regexp.stub(:codegen_match, ->(*) { flunk "named backreference match should use HFA result" }) do
      match = regexp.match("echo-echo")
      assert_equal "echo", match[:word]
      assert_equal [0, 4], match.offset(:word)
    end
  end

  def test_adjacent_literal_backreference_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(ab)\\1")

    regexp.stub(:codegen_match, ->(*) { flunk "adjacent backreference match should use HFA result" }) do
      match = regexp.match("zzabab")
      assert_equal "ab", match[1]
      assert_equal [2, 4], match.offset(1)
    end
  end

  def test_literal_backreference_with_separator_uses_hfa_result
    regexp = Onibi::Regexp.new("(ab)-\\1")

    regexp.stub(:codegen_match, ->(*) { flunk "literal backreference match should use HFA result" }) do
      match = regexp.match("zzab-ab")
      assert_equal "ab", match[1]
      assert_equal [2, 4], match.offset(1)
    end
  end

  def test_optional_conditional_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(a)?(?(1)b|c)")

    regexp.stub(:codegen_match, ->(*) { flunk "conditional match should use HFA result" }) do
      assert_equal "ab", regexp.match("ab")[0]
      assert_equal "c", regexp.match("c")[0]
    end
  end

  def test_named_optional_conditional_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<letter>a)?(?(<letter>)b|c)")

    regexp.stub(:codegen_match, ->(*) { flunk "named conditional match should use HFA result" }) do
      assert_equal "ab", regexp.match("ab")[0]
      assert_equal "c", regexp.match("c")[0]
    end
  end

  def test_named_subexpression_call_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<pair>ab)\\g<pair>")

    regexp.stub(:codegen_match, ->(*) { flunk "subexpression call match should use HFA result" }) do
      match = regexp.match("zzabab")
      assert_equal "ab", match[:pair]
      assert_equal [2, 4], match.offset(:pair)
    end
  end

  def test_nested_literal_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab))")

    regexp.stub(:codegen_match, ->(*) { flunk "nested literal captures should use HFA result" }) do
      match = regexp.match("zzab")
      assert_equal %w[ab ab], match.captures
      assert_equal [[2, 4], [2, 4]], [match.offset(1), match.offset(2)]
    end
  end

  def test_named_nested_literal_captures_use_hfa_result
    regexp = Onibi::Regexp.new("(?<outer>(?<inner>ab))")

    regexp.stub(:codegen_match, ->(*) { flunk "named nested captures should use HFA result" }) do
      match = regexp.match("zzab")
      assert_equal "ab", match[:outer]
      assert_equal "ab", match[:inner]
    end
  end

  def test_nested_fixed_width_alternation_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((a|b))")

    regexp.stub(:codegen_match, ->(*) { flunk "nested alternation captures should use HFA result" }) do
      match = regexp.match("zzb")
      assert_equal ["b", "b"], match.captures
      assert_equal [[2, 3], [2, 3]], [match.offset(1), match.offset(2)]
    end
  end

  def test_nested_variable_width_alternation_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((a|ab))")

    regexp.stub(:codegen_match, ->(*) { flunk "nested variable alternation captures should use HFA result" }) do
      match = regexp.match("zzab")
      assert_equal ["a", "a"], match.captures
      assert_equal [[2, 3], [2, 3]], [match.offset(1), match.offset(2)]
    end
  end

  def test_nested_repeated_literal_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab)+)")

    regexp.stub(:codegen_match, ->(*) { flunk "nested repeated captures should use HFA result" }) do
      match = regexp.match("zzabab")
      assert_equal ["abab", "ab"], match.captures
      assert_equal [[2, 6], [4, 6]], [match.offset(1), match.offset(2)]
    end
  end

  def test_nested_repeated_alternation_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((a|b)+)")

    regexp.stub(:codegen_match, ->(*) { flunk "nested repeated alternation should use HFA result" }) do
      match = regexp.match("zzabab")
      assert_equal ["abab", "b"], match.captures
      assert_equal [[2, 6], [5, 6]], [match.offset(1), match.offset(2)]
    end
  end

  def test_nested_variable_repeated_alternation_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab|a)+)")

    regexp.stub(:codegen_match, ->(*) { flunk "nested variable repeated alternation should use HFA result" }) do
      match = regexp.match("zzaba")
      assert_equal ["aba", "a"], match.captures
      assert_equal [[2, 5], [4, 5]], [match.offset(1), match.offset(2)]
    end
  end

  def test_nested_repeated_capture_with_suffix_uses_hfa_result
    regexp = Onibi::Regexp.new("((ab)+)c")

    regexp.stub(:codegen_match, ->(*) { flunk "nested repeated suffix capture should use HFA result" }) do
      match = regexp.match("zzababc")
      assert_equal ["ababc", "abab", "ab"], match.to_a
      assert_equal [[2, 6], [4, 6]], [match.offset(1), match.offset(2)]
    end
  end

  def test_nested_repeated_and_class_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab)+)-([0-9]+)")

    regexp.stub(:codegen_match, ->(*) { flunk "multiple nested captures should use HFA result" }) do
      match = regexp.match("zzabab-123")
      assert_equal ["abab-123", "abab", "ab", "123"], match.to_a
      assert_equal [[2, 6], [4, 6], [7, 10]], [match.offset(1), match.offset(2), match.offset(3)]
    end
  end

  def test_nested_repeated_and_nested_class_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab)+)-(([0-9]) +)".delete(" "))

    regexp.stub(:codegen_match, ->(*) { flunk "nested class captures should use HFA result" }) do
      match = regexp.match("zzabab-123")
      assert_equal ["abab-123", "abab", "ab", "123", "3"], match.to_a
      assert_equal [[2, 6], [4, 6], [7, 10], [9, 10]],
                   [match.offset(1), match.offset(2), match.offset(3), match.offset(4)]
    end
  end

  def test_adjacent_nested_repeated_captures_use_hfa_result
    regexp = Onibi::Regexp.new("((ab)+)((cd)+)")

    regexp.stub(:codegen_match, ->(*) { flunk "adjacent nested repeated captures should use HFA result" }) do
      match = regexp.match("zzababcdcd")
      assert_equal ["ababcdcd", "abab", "ab", "cdcd", "cd"], match.to_a
      assert_equal [[2, 6], [4, 6], [6, 10], [8, 10]],
                   [match.offset(1), match.offset(2), match.offset(3), match.offset(4)]
    end
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
