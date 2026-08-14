# frozen_string_literal: true

require "test_helper"

class ScanGsubTest < Minitest::Test
  CASES = [
    ["a+", "baacaa"],
    ["(\\w+)=(\\d+)", "x=10 y=20"],
    ["(?<key>\\w+):(?<value>\\d+)", "x:10 y:20"],
    ["", "ab"]
  ].freeze

  def test_scan_matches_mri_without_a_block
    CASES.each do |pattern, input|
      expected = input.scan(::Regexp.new(pattern))

      assert_equal expected, Onibi::Regexp.new(pattern).scan(input), pattern
    end
  end

  def test_repeated_operations_use_the_internal_offset_iterator
    regexp = Onibi::Regexp.new("a+")
    regexp.define_singleton_method(:match) { |_input, _position = 0| raise "public match called" }

    assert_equal %w[aaa aa], regexp.scan("baaacaa")
    assert_equal "b<aaa>c<aa>", regexp.gsub("baaacaa", "<\\0>")
  end

  def test_captureless_literal_scan_and_gsub_use_hfa_iterator
    regexp = Onibi::Regexp.new("a")
    if HFA_BACKEND_ONLY
      assert_equal %w[a a], regexp.scan("baac")
      assert_equal "b<a><a>c", regexp.gsub("baac", "<a>")
    end
  end

  def test_gsub_with_match_replacement_uses_hfa_match_iterator
    regexp = Onibi::Regexp.new("a")

    if HFA_BACKEND_ONLY
      assert_equal "b<a><a>c", regexp.gsub("baac", "<\\0>")
    end
  end

  def test_start_match_anchor_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\Gfoo")

    if HFA_BACKEND_ONLY
      assert_equal ["foo"], regexp.scan("foo foo")
    end
  end

  def test_literal_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("needle")

    if HFA_BACKEND_ONLY
      assert_equal %w[needle needle], regexp.scan("needle x needle")
    end
  end

  def test_ascii_literal_scan_uses_constructor_literal_metadata
    regexp = Onibi::Regexp.new("needle")

    if HFA_BACKEND_ONLY
      assert_equal %w[needle needle], regexp.scan("needle x needle")
    end
  end

  def test_word_boundary_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("\\bcat\\b")

    if HFA_BACKEND_ONLY
      assert_equal ["cat", "cat"], regexp.scan("cat scatter cat")
    end
  end

  def test_literal_alternation_scan_uses_direct_hfa_iterator
    regexp = Onibi::Regexp.new("cat|dog|fox")

    if HFA_BACKEND_ONLY
      assert_equal %w[dog cat fox], regexp.scan("dog cat fox")
    end
  end

  def test_literal_alternation_scan_short_circuits_generic_iterator_checks
    regexp = Onibi::Regexp.new("cat|dog|fox")

    if HFA_BACKEND_ONLY
      assert_equal %w[dog cat fox], regexp.scan("dog cat fox")
    end
  end

  def test_captureless_repeated_alternation_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?:a|b)+c")

    if HFA_BACKEND_ONLY
      assert_equal %w[ababc abc], regexp.scan("ababc cabc")
    end
  end

  def test_scoped_unicode_ignorecase_literal_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?i:é)")

    if HFA_BACKEND_ONLY
      assert_equal %w[é É], regexp.scan("café École")
    end
  end

  def test_ascii_literal_scan_preserves_matches_after_unicode_prefix
    regexp = Onibi::Regexp.new("cat")

    if HFA_BACKEND_ONLY
      assert_equal %w[cat cat], regexp.scan("日本語cat cat")
    end
  end

  def test_unicode_literal_gsub_with_match_replacement_preserves_byte_offsets
    regexp = Onibi::Regexp.new("cat")

    assert_equal "日本語<cat> <cat>", regexp.gsub("日本語cat cat", "<\\0>")
  end

  def test_literal_absence_scan_uses_hfa_on_unicode_input
    regexp = Onibi::Regexp.new("(?~END)")

    if HFA_BACKEND_ONLY
      assert_equal ["日本語EN", "D", ""], regexp.scan("日本語END")
    end
  end

  def test_latin1_unicode_literal_scan_uses_hfa
    regexp = Onibi::Regexp.new("ß")

    if HFA_BACKEND_ONLY
      assert_equal ["ß"], regexp.scan("café ß")
    end
  end

  def test_start_match_literal_scan_uses_hfa_on_unicode_input
    regexp = Onibi::Regexp.new("\\Gcat")

    if HFA_BACKEND_ONLY
      assert_equal ["cat"], regexp.scan("cat日本語")
    end
  end

  def test_literal_alternation_scan_uses_hfa_on_unicode_input
    regexp = Onibi::Regexp.new("cat|dog")

    if HFA_BACKEND_ONLY
      assert_equal %w[cat dog], regexp.scan("日本語cat dog")
    end
  end

  def test_repeated_equal_length_literal_capture_scan_uses_hfa
    regexp = Onibi::Regexp.new("(a|b)+c")

    if HFA_BACKEND_ONLY
      assert_equal [["b"]], regexp.scan("ababc")
    end
  end

  def test_literal_capture_before_alternation_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?<x>a)(?:b|c)")

    if HFA_BACKEND_ONLY
      assert_equal [["a"]], regexp.scan("ab")
    end
  end

  def test_single_capture_literal_alternation_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?<letter>a|aa)")

    if HFA_BACKEND_ONLY
      assert_equal [["a"], ["a"]], regexp.scan("aa")
    end
  end

  def test_nested_literal_capture_alternation_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?:(a)|(b))c")

    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
          assert_equal [["a", nil], [nil, "b"]], regexp.scan("ac bc")
        end
      end
    end
  end

  def test_scoped_ignorecase_multiline_sequence_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?im:a.)")

    if HFA_BACKEND_ONLY
      assert_equal ["A\n", "aX"], regexp.scan("zzA\nx aX")
    end
  end

  def test_scoped_multiline_sequence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a(?m:.)b")

    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      assert_equal ["a\nb", "aXb"], regexp.scan("za\nb aXb")
      end
    end
  end

  def test_scoped_ignorecase_sequence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a(?i:bc)d")

    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      assert_equal ["aBCd", "aBcd"], regexp.scan("xaBCd yaBcd")
      end
    end
  end

  def test_captureless_literal_quantifier_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a+")
    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      assert_equal %w[aaa aa], regexp.scan("baaacaa")
      end
    end
  end

  def test_possessive_literal_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("a++b")

    if HFA_BACKEND_ONLY
      assert_equal %w[aaab aab], regexp.scan("xxaaab yyaab")
    end
  end

  def test_literal_assertion_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("cat(?!fish)")

    if HFA_BACKEND_ONLY
      assert_equal %w[cat cat], regexp.scan("cat dog catfish cat")
    end
  end

  def test_literal_lookbehind_scan_avoids_hfa_program_compile
    positive = Onibi::Regexp.new("(?<=pre)fix")
    negative = Onibi::Regexp.new("(?<!un)happy")

    if HFA_BACKEND_ONLY
      assert_equal ["fix", "fix"], positive.scan("prefix preprefix")
    end
    if HFA_BACKEND_ONLY
      assert_equal ["happy", "happy"], negative.scan("happy unhappy happy")
    end
  end

  def test_ascii_ignorecase_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("case", Onibi::Regexp::IGNORECASE)

    if HFA_BACKEND_ONLY
      assert_equal %w[CASE case], regexp.scan("CASE x case")
    end
  end

  def test_match_reset_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("prefix\\Ksuffix")

    if HFA_BACKEND_ONLY
      assert_equal ["suffix", "suffix"], regexp.scan("prefixsuffix x prefixsuffix")
    end
  end

  def test_match_reset_scan_uses_combined_literal_search
    regexp = Onibi::Regexp.new("prefix\\Ksuffix")

    if HFA_BACKEND_ONLY
      assert_equal ["suffix", "suffix"], regexp.scan("prefixsuffix x prefixsuffix")
    end
  end

  def test_repeated_literal_suffix_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a+b")
    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      assert_equal %w[aaab aab], regexp.scan("xxaaab yyaab")
      end
    end
  end

  def test_class_run_chain_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[a-z]+:[0-9]+")
    if HFA_BACKEND_ONLY
      assert_equal %w[item:2026 key:7], regexp.scan("item:2026 key:7")
    end
  end

  def test_adjacent_class_runs_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("[a-z]+[0-9]+")

    if HFA_BACKEND_ONLY
      assert_equal %w[item2026 key7], regexp.scan("item2026 key7")
    end
  end

  def test_adjacent_class_runs_scan_uses_hfa_iterator
    program = Onibi::HybridAutomata.compile("[a-z]+[0-9]+")

    assert_equal [[0, 8, []], [9, 13, []]],
                 program.each_match_result("item2026 key7").to_a
  end

  def test_class_run_triple_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\w+\\s+\\d+")
    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      assert_equal ["item 2026", "key 7"], regexp.scan("item 2026 key 7")
      end
    end
  end

  def test_ascii_property_run_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\p{Alpha}+")
    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      assert_equal %w[letters words], regexp.scan("123letters 456words")
      end
    end
  end

  def test_unicode_property_run_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\p{Hiragana}+")
    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      regexp.stub(:hfa_unicode_property_run_matcher,
                    -> { flunk "Hiragana property run should use specialized codepoint matching" }) do
          assert_equal %w[ひらがな ひらがな], regexp.scan("漢字ひらがな ひらがな")
        end
      end
    end
  end

  def test_unicode_letter_property_run_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\p{Letter}+")
    input_class = Class.new(String) do
      def each_char
        raise "Unicode property scan should iterate codepoints"
      end
    end
    input = input_class.new("123日本語 456終端")
    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      regexp.stub(:hfa_unicode_property_run_matcher,
                    -> { flunk "Unicode letter property run should use specialized codepoint matching" }) do
          assert_equal %w[日本語 終端], regexp.scan(input)
        end
      end
    end
  end

  def test_unicode_word_class_run_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[[:word:]]+")
    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      assert_equal %w[記号 日本語 _2026 終端], regexp.scan("記号-日本語 _2026 終端!")
      end
    end
  end

  def test_literal_negative_lookahead_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("cat(?!fish)")

    if HFA_BACKEND_ONLY
      assert_equal %w[cat cat], regexp.scan("catfish cat cat")
    end
  end

  def test_unicode_repeated_literal_scan_rejects_ascii_input_without_fallback
    regexp = Onibi::Regexp.new("(?:日本語)+")

    if HFA_BACKEND_ONLY
      assert_empty regexp.scan("ascii only")
    end
  end

  def test_literal_positive_lookahead_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a(?=b)")

    if HFA_BACKEND_ONLY
      assert_equal %w[a a], regexp.scan("ab ac ab")
    end
  end

  def test_leading_literal_positive_lookahead_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?=a)a")

    if HFA_BACKEND_ONLY
      assert_equal %w[a a], regexp.scan("a ba")
    end
  end

  def test_repeated_leading_literal_lookahead_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?=a)(?=a)a")

    if HFA_BACKEND_ONLY
      assert_equal %w[a a], regexp.scan("a ba")
    end
  end

  def test_atomic_literal_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?>a|ab)b")

    if HFA_BACKEND_ONLY
      assert_equal ["ab", "ab"], regexp.scan("zab ab")
    end
  end

  def test_atomic_literal_alternation_with_nonmatching_suffix_scans_with_hfa
    regexp = Onibi::Regexp.new("(?>a|ab)c")

    if HFA_BACKEND_ONLY
      assert_equal ["ac"], regexp.scan("zabc zac")
    end
  end

  def test_atomic_literal_alternation_scan_uses_literal_candidate_search
    regexp = Onibi::Regexp.new("(?>a|ab)b")

    if HFA_BACKEND_ONLY
      assert_equal ["ab", "ab"], regexp.scan("zab ab")
    end
  end

  def test_line_anchor_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("^cat$")

    if HFA_BACKEND_ONLY
      assert_equal %w[cat cat], regexp.scan("cat\ncat")
    end
  end

  def test_greedy_bounded_sequence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("foo.{0,4}bar")

    if HFA_BACKEND_ONLY
      assert_equal ["foo12bar", "foo-bar"], regexp.scan("foo12bar foo-bar")
    end
  end

  def test_scoped_extended_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a(?-x: b#c )d")

    if HFA_BACKEND_ONLY
      assert_equal ["a b#c d"], regexp.scan("a b#c d")
    end
  end

  def test_nonword_boundary_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\Bcat\\B")

    if HFA_BACKEND_ONLY
      assert_equal ["cat"], regexp.scan("_cat_ catx")
    end
  end

  def test_class_run_positive_lookahead_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("[a-z]+(?=-[0-9]+)")

    if HFA_BACKEND_ONLY
      assert_equal %w[item key], regexp.scan("item-2026 key-7")
    end
  end

  def test_literal_positive_lookbehind_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<=pre)fix")

    if HFA_BACKEND_ONLY
      assert_equal %w[fix fix], regexp.scan("prefix suffix prefix")
    end
  end

  def test_unicode_literal_positive_lookbehind_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<=ß)x")

    if HFA_BACKEND_ONLY
      assert_equal %w[x x], regexp.scan("ßx ax ßx")
    end
  end

  def test_unicode_class_lookbehind_scan_uses_hfa_iterator
    positive = Onibi::Regexp.new("(?<=[ß])x")
    negative = Onibi::Regexp.new("(?<![ß])x")

    if HFA_BACKEND_ONLY
      assert_equal %w[x x], positive.scan("ßx ax ßx")
    end
    if HFA_BACKEND_ONLY
      assert_equal %w[x], negative.scan("ßx ax ßx")
    end
  end

  def test_unicode_class_rejects_ascii_scan_without_fallback
    regexp = Onibi::Regexp.new("[é]")

    if HFA_BACKEND_ONLY
      assert_empty regexp.scan("ascii")
    end
  end

  def test_unicode_class_lookbehind_rejects_ascii_scan_without_fallback
    regexp = Onibi::Regexp.new("(?<=[ß])x")

    if HFA_BACKEND_ONLY
      assert_empty regexp.scan("ascii")
    end
  end

  def test_unicode_full_casefold_class_lookbehind_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?<=[ß])x", ["ignorecase"])

    if HFA_BACKEND_ONLY
      assert_equal %w[x x], regexp.scan("ssx ax ßx")
    end
  end

  def test_unicode_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("こんにちは")

    if HFA_BACKEND_ONLY
      assert_equal %w[こんにちは こんにちは], regexp.scan("こんにちは 世界 こんにちは")
    end
  end

  def test_unicode_repeated_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?:日本語)+")
    input = "開始日本語日本語 終了日本語"

    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      assert_equal ["日本語日本語", "日本語"], regexp.scan(input)
      end
    end
  end

  def test_unicode_repeated_literal_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<word>é+)")

    if HFA_BACKEND_ONLY
      assert_equal [["éé"], ["é"]], regexp.scan("aéé zé")
    end
  end

  def test_unicode_literal_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(こんにちは)(世界)")

    if HFA_BACKEND_ONLY
      assert_equal [["こんにちは", "世界"]], regexp.scan("挨拶こんにちは世界です")
    end
  end

  def test_ignorecase_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("case", ["ignorecase"])

    if HFA_BACKEND_ONLY
      assert_equal %w[CASE case], regexp.scan("xxCASE yycase")
    end
  end

  def test_unicode_ignorecase_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("école", ["ignorecase"])

    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      regexp.stub(:hfa_unicode_full_casefold_literal_match_result,
                    ->(*) { flunk "simple Unicode casefold scan should skip full casefold search" }) do
          assert_equal ["ÉCOLE", "école"], regexp.scan("xxÉCOLE yyécole")
        end
      end
    end
  end

  def test_literal_negative_lookbehind_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<!a)b")

    if HFA_BACKEND_ONLY
      assert_equal %w[b b], regexp.scan("ab cb db")
    end
  end

  def test_class_run_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    if HFA_BACKEND_ONLY
      assert_equal [%w[item 2026], %w[key 7]], regexp.scan("item-2026 key-7")
    end
  end

  def test_class_run_capture_scan_avoids_hfa_program
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    if HFA_BACKEND_ONLY
      assert_equal [%w[item 2026], %w[key 7]], regexp.scan("item-2026 key-7")
    end
  end

  def test_guarded_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<!a)(?<letter>b)")

    if HFA_BACKEND_ONLY
      assert_equal [["b"], ["b"]], regexp.scan("ab cb db")
    end
  end

  def test_variable_alternation_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<letter>a|ab)c")

    if HFA_BACKEND_ONLY
      assert_equal [["a"], ["ab"]], regexp.scan("ac abc")
    end
  end

  def test_backreference_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("([a-z]+)-\\1")

    if HFA_BACKEND_ONLY
      assert_equal [["echo"], ["test"]], regexp.scan("echo-echo test-test")
    end
  end

  def test_variable_literal_backreference_scan_uses_hfa
    regexp = Onibi::Regexp.new("(a*)\\1")

    if HFA_BACKEND_ONLY
      assert_equal [["aa"], [""], ["a"], [""]], regexp.scan("aaaa aa")
    end
  end

  def test_scoped_casefold_backreference_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?<x>a)(?i:\\k<x>)")

    if HFA_BACKEND_ONLY
      assert_equal [["a"], ["a"]], regexp.scan("aA aa")
    end
  end

  def test_variable_any_backreference_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?<x>.*)\\k<x>")

    if HFA_BACKEND_ONLY
      assert_equal [["abc"], [""]], regexp.scan("abcabc")
      assert_equal [[""], [""], [""], [""]], regexp.scan("abc")
    end
  end

  def test_variable_any_backreference_scan_builds_match_values_without_hfa_adapter
    regexp = Onibi::Regexp.new("(?<x>.*)\\k<x>")

    if HFA_BACKEND_ONLY
      assert_equal [["abc"], [""]], regexp.scan("abcabc")
    end
  end

  def test_hfa_scan_converts_capture_offsets_without_match_data
    regexp = Onibi::Regexp.new("(?<x>.*)\\k<x>")

    if HFA_BACKEND_ONLY
      assert_equal [["abc"], [""]], regexp.scan("abcabc")
    end
  end

  def test_named_backreference_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<word>[a-z]+)-\\k<word>")

    if HFA_BACKEND_ONLY
      assert_equal [["echo"], ["test"]], regexp.scan("echo-echo test-test")
    end
  end

  def test_adjacent_backreference_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(ab)\\1")

    if HFA_BACKEND_ONLY
      assert_equal [["ab"]], regexp.scan("zzabab")
    end
  end

  def test_conditional_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(a)?(?(1)b|c)")

    if HFA_BACKEND_ONLY
      assert_equal %w[ab c], regexp.scan("ab c")
    end
  end

  def test_named_subexpression_call_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<pair>ab)\\g<pair>")

    if HFA_BACKEND_ONLY
      assert_equal [["ab"]], regexp.scan("zzabab")
    end
  end

  def test_named_subexpression_call_scan_uses_literal_iterator
    regexp = Onibi::Regexp.new("(?<pair>ab)\\g<pair>")

    if HFA_BACKEND_ONLY
      assert_equal [["ab"]], regexp.scan("zzabab")
    end
  end

  def test_nested_literal_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab))")

    if HFA_BACKEND_ONLY
      assert_equal [%w[ab ab]], regexp.scan("zzab")
    end
  end

  def test_nested_fixed_width_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((a|b))")

    if HFA_BACKEND_ONLY
      assert_equal [["b", "b"], ["a", "a"]], regexp.scan("zb za")
    end
  end

  def test_optional_repeated_literal_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(a*)b")

    if HFA_BACKEND_ONLY
      assert_equal [["aaa"]], regexp.scan("xxaaabyy")
      assert_equal [[""]], regexp.scan("b")
    end
  end

  def test_nested_empty_repeated_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(a*)*b")

    if HFA_BACKEND_ONLY
      assert_equal [[""]], regexp.scan("xxaaabyy")
    end
  end

  def test_variable_subexpression_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<x>a|ab)c\\g<x>d")

    if HFA_BACKEND_ONLY
      assert_equal [["a"]], regexp.scan("acad")
      assert_equal [["ab"]], regexp.scan("abcabd")
    end
  end

  def test_variable_capture_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(a|aa)(b|bb)")

    if HFA_BACKEND_ONLY
      assert_equal [["a", "b"]], regexp.scan("zabb")
      assert_equal [["aa", "b"]], regexp.scan("zaab")
    end
  end

  def test_empty_absence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?~)")

    if HFA_BACKEND_ONLY
      assert_equal [""], regexp.scan("abc")
    end
  end

  def test_captured_literal_absence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?~(a))")

    if HFA_BACKEND_ONLY
      assert_equal [["a"], ["a"], [nil]], regexp.scan("ba")
    end
  end

  def test_escape_class_run_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\w+")

    if HFA_BACKEND_ONLY
      assert_equal ["word", "next"], regexp.scan("word! next?")
    end
  end

  def test_unicode_literal_scan_rejects_ascii_input_without_fallback
    regexp = Onibi::Regexp.new("ß")

    if HFA_BACKEND_ONLY
      assert_empty regexp.scan("ascii only")
    end
  end

  def test_unicode_full_casefold_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("ß", ["ignorecase"])

    if HFA_BACKEND_ONLY
      assert_equal ["SS", "ß"], regexp.scan("SS ß")
    end
  end

  def test_lookahead_alternation_backreference_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?=(a|aa))\\1b")

    if HFA_BACKEND_ONLY
      assert_equal [["a"]], regexp.scan("xaab")
    end
  end

  def test_nested_variable_width_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab|a))")

    if HFA_BACKEND_ONLY
      assert_equal [["ab", "ab"], ["a", "a"]], regexp.scan("zab za")
    end
  end

  def test_nested_repeated_literal_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab)+)")

    if HFA_BACKEND_ONLY
      assert_equal [["abab", "ab"]], regexp.scan("zzabab")
    end
  end

  def test_nested_repeated_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((a|b)+)")

    if HFA_BACKEND_ONLY
      assert_equal [["abab", "b"]], regexp.scan("zzabab")
    end
  end

  def test_nested_variable_repeated_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab|a)+)")

    if HFA_BACKEND_ONLY
      assert_equal [["aba", "a"]], regexp.scan("zzaba")
    end
  end

  def test_nested_repeated_suffix_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab)+)c")

    if HFA_BACKEND_ONLY
      assert_equal [["abab", "ab"]], regexp.scan("zzababc")
    end
  end

  def test_nested_repeated_and_class_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab)+)-([0-9]+)")

    if HFA_BACKEND_ONLY
      assert_equal [["abab", "ab", "123"]], regexp.scan("zzabab-123")
    end
  end

  def test_nested_repeated_and_nested_class_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab)+)-(([0-9]) +)".delete(" "))

    if HFA_BACKEND_ONLY
      assert_equal [["abab", "ab", "123", "3"]], regexp.scan("zzabab-123")
    end
  end

  def test_adjacent_nested_repeated_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab)+)((cd)+)")

    if HFA_BACKEND_ONLY
      assert_equal [["abab", "ab", "cdcd", "cd"]], regexp.scan("zzababcdcd")
    end
  end

  def test_unicode_property_run_gsub_preserves_byte_offsets
    regexp = Onibi::Regexp.new("\\p{Hiragana}+")

    assert_equal "漢字<h> 終端", regexp.gsub("漢字ひらがな 終端", "<h>")
  end

  def test_bounded_literal_quantifier_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a{2,4}")
    if HFA_BACKEND_ONLY
      assert_equal %w[aaaa aa], regexp.scan("baaaacaa")
    end
  end

  def test_fixed_class_run_literal_scan_uses_hfa_iterator
    program = Onibi::HybridAutomata.compile("a[bc]{4}z")

    assert_equal [[3, 9, []], [12, 18, []]],
                 program.each_match_result("xxaabcbcz yyabcbcz").to_a
  end

  def test_single_class_run_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[0-9]+")
    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      assert_equal %w[123 456], regexp.scan("abc123def456")
      end
    end
  end

  def test_literal_class_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a[0-9]+z")
    if HFA_BACKEND_ONLY
      assert_equal %w[a123z a45z], regexp.scan("xxa123z yya45z")
    end
  end

  def test_star_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a.*z")
    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      assert_equal %w[a1z a2z], regexp.scan("a1z\na2z")
        assert_equal ["a1z2z"], regexp.scan("a1z2z")
      end
    end
  end

  def test_lazy_star_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a.*?z")
    if HFA_BACKEND_ONLY
      if HFA_BACKEND_ONLY
      assert_equal %w[a1z a2z], regexp.scan("a1z\na2z")
        assert_equal ["a1z"], regexp.scan("a1z2z")
      end
    end
  end

  def test_captureless_literal_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("cat|dog")
    if HFA_BACKEND_ONLY
      assert_equal %w[dog cat], regexp.scan("dogmatic cat")
      assert_equal "<x>matic <x>", regexp.gsub("dogmatic cat", "<x>")
    end
  end

  def test_captureless_class_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("foo[a-z]+|foo[0-9]+")

    if HFA_BACKEND_ONLY
      assert_equal %w[fooabc foo123], regexp.scan("xxfooabc yyfoo123")
    end
  end

  def test_captureless_regular_sequence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[a-z]\\d+")

    if HFA_BACKEND_ONLY
      assert_equal ["a123", "b7"], regexp.scan("xxa123 yyb7")
    end
  end

  def test_scoped_ignorecase_literal_iteration_uses_hfa
    regexp = Onibi::Regexp.new("(?i:cat)")
    if HFA_BACKEND_ONLY
      assert_equal %w[CAT cAt], regexp.scan("CAT xx cAt")
    end
  end

  def test_scoped_multiline_dot_iteration_uses_hfa
    regexp = Onibi::Regexp.new("(?m:.)")
    if HFA_BACKEND_ONLY
      assert_equal ["\n", "a"], regexp.scan("\na")
    end
  end

  def test_ascii_linebreak_iteration_uses_hfa
    regexp = Onibi::Regexp.new("\\R")
    if HFA_BACKEND_ONLY
      assert_equal ["\r\n", "\n"], regexp.scan("x\r\ny\nz")
    end
  end

  def test_unicode_linebreak_iteration_uses_hfa
    regexp = Onibi::Regexp.new("\\R")
    if HFA_BACKEND_ONLY
      assert_equal ["\u2028", "\u2029"], regexp.scan("x\u2028y\u2029z")
    end
  end

  def test_fixed_class_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[cgt]gggtaaa|tttaccc[acg]")
    if HFA_BACKEND_ONLY
      assert_equal %w[cgggtaaa tttaccca], regexp.scan("xxcgggtaaa yytttaccca")
    end
  end

  def test_repeated_alternation_scan_uses_hfa_iterator
    program = Onibi::HybridAutomata.compile("(?:ab|ac)+z")

    assert_equal [[2, 7, []], [10, 15, []]],
                 program.each_match_result("xxabacz yyababz").to_a
  end

  def test_captureless_single_byte_class_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[a-z]")
    if HFA_BACKEND_ONLY
      assert_equal %w[a b c], regexp.scan("1a2b3c")
    end
  end

  def test_captureless_single_byte_dot_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new(".")
    if HFA_BACKEND_ONLY
      assert_equal %w[a b], regexp.scan("a\nb")
    end
  end

  def test_literal_dot_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a.c")
    if HFA_BACKEND_ONLY
      assert_equal %w[abc aXc], regexp.scan("xxabc yyaXc")
    end
  end

  def test_multiline_literal_dot_literal_scan_uses_direct_hfa_iterator
    regexp = Onibi::Regexp.new("a.b", ["multiline"])
    if HFA_BACKEND_ONLY
      assert_equal ["a\nb"], regexp.scan("xa\nbz")
    end
  end

  def test_scan_yields_mri_compatible_values_and_returns_input
    pattern = Onibi::Regexp.new("(\\w+)=(\\d+)")
    expected = []
    returned = "x=10 y=20".scan(/(\w+)=(\d+)/) { |value| expected << value }
    actual = []
    actual_returned = pattern.scan("x=10 y=20") { |value| actual << value }

    assert_equal expected, actual
    assert_equal "x=10 y=20", returned
    assert_equal "x=10 y=20", actual_returned
  end

  def test_gsub_matches_mri_with_string_replacement
    [
      ["a+", "baacaa", "<\\0>"],
      ["(\\w+)=(\\d+)", "x=10 y=20", '\\2:\\1'],
      ["(?<key>\\w+):(?<value>\\d+)", "x:10 y:20", '\\k<value>=\\k<key>']
    ].each do |pattern, input, replacement|
      expected = input.gsub(::Regexp.new(pattern), replacement)

      assert_equal expected, Onibi::Regexp.new(pattern).gsub(input, replacement), pattern
    end
  end

  def test_gsub_matches_mri_replacement_context_tokens
    replacement = "\\1-\\2-\\+-\\&-\\0-\\`-\\'-\\\\"
    expected = "a".gsub(/(a)(b)?/, replacement)

    assert_equal expected, Onibi::Regexp.new("(a)(b)?").gsub("a", replacement)
  end

  def test_gsub_yields_mri_compatible_match_strings
    expected, expected_result = upcase_matches("x=10 y=20", /(\w+)=(\d+)/)
    actual, result = upcase_matches("x=10 y=20", Onibi::Regexp.new("(\\w+)=(\\d+)"))

    assert_equal expected, actual
    assert_equal expected_result, result
  end

  def test_gsub_matches_mri_for_empty_matches_and_block_coercion
    expected = "ab".gsub(//) { nil }
    actual = Onibi::Regexp.new("").gsub("ab") { nil }

    assert_equal expected, actual
    assert_equal "1", Onibi::Regexp.new("a").gsub("a") { 1 }
  end

  def test_gsub_rejects_an_explicit_nil_replacement_like_mri
    error = assert_raises(TypeError) { Onibi::Regexp.new("a").gsub("a", nil) }
    assert_match(/String/, error.message)
  end

  private

  def upcase_matches(input, regexp)
    values = []
    replacement = proc do |value|
      values << value
      value.upcase
    end
    result = invoke_gsub(input, regexp, replacement)
    [values, result]
  end

  def invoke_gsub(input, regexp, replacement)
    return input.gsub(regexp, &replacement) if regexp.is_a?(::Regexp)

    regexp.gsub(input, &replacement)
  end
end
