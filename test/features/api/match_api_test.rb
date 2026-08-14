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

  def test_literal_alternation_match_uses_hfa_result
    regexp = Onibi::Regexp.new("cat|dog")

    regexp.stub(:codegen_match, ->(*) { flunk "literal alternation match should use HFA" }) do
      match = regexp.match("a dog")
      assert_equal "dog", match[0]
      assert_equal [2, 5], match.offset(0)
    end

    assert_equal "a", Onibi::Regexp.new("a|aa").match("aa")[0]
  end

  def test_single_byte_class_match_uses_hfa_result
    regexp = Onibi::Regexp.new("[a-z]")

    regexp.stub(:codegen_match, ->(*) { flunk "single-byte class match should use HFA" }) do
      match = regexp.match("123x")
      assert_equal "x", match[0]
      assert_equal [3, 4], match.offset(0)
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
      assert regexp.match?("caaab")
      refute regexp.match?("cbbb")
    end
  end

  def test_regular_composite_match_question_mark_uses_hfa
    regexp = Onibi::Regexp.new("(?:ab|ac)+z")

    regexp.stub(:codegen_match?, ->(*) { flunk "regular composite match? should use HFA" }) do
      assert regexp.match?("prefix abacabz suffix")
      refute regexp.match?("prefix abaxz suffix")
    end
  end

  def test_repeated_alternation_match_uses_hfa_result
    program = Onibi::HybridAutomata.compile("(?:ab|ac)+z")

    assert_equal [2, 11, []], program.match_result("xxabacababz yy")
  end

  def test_literal_quantifier_match_uses_hfa_result
    regexp = Onibi::Regexp.new("a+")

    regexp.stub(:codegen_match, ->(*) { flunk "literal quantifier match should use HFA" }) do
      match = regexp.match("caaab")
      assert_equal "aaa", match[0]
      assert_equal [1, 4], match.offset(0)
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

  def test_unicode_property_run_match_question_mark_uses_hfa
    regexp = Onibi::Regexp.new("\\p{Hiragana}+")

    regexp.stub(:codegen_match?, ->(*) { flunk "Unicode property match? should use HFA" }) do
      assert regexp.match?("漢字ひらがな終端")
      refute regexp.match?("漢字カタカナ終端")
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
    regexp = Onibi::Regexp.new("needle")
    calls = 0
    original = regexp.method(:hfa_contains_possessive_quantifier?)
    regexp.define_singleton_method(:hfa_contains_possessive_quantifier?) do
      calls += 1
      original.call
    end

    3.times { assert regexp.match?("needle") }
    assert_equal 1, calls
  end

  def test_hfa_match_question_skips_timeout_wrapper_when_unconfigured
    regexp = Onibi::Regexp.new("needle")

    regexp.stub(:with_timeout, ->(*) { flunk "unconfigured HFA match? should skip timeout wrapper" }) do
      assert regexp.match?("needle")
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

  def test_literal_positive_lookbehind_match_uses_hfa_result
    regexp = Onibi::Regexp.new("(?<=pre)fix")

    regexp.stub(:codegen_match, ->(*) { flunk "literal positive lookbehind match should use HFA" }) do
      assert_equal "fix", regexp.match("prefix")[0]
      assert_nil regexp.match("suffix")
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
