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

    assert_equal %w[a a], regexp.scan("baac")
    assert_equal "b<a><a>c", regexp.gsub("baac", "<a>")
  end

  def test_gsub_with_match_replacement_uses_hfa_match_iterator
    regexp = Onibi::Regexp.new("a")

    assert_equal "b<a><a>c", regexp.gsub("baac", "<\\0>")
  end

  def test_start_match_anchor_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\Gfoo")

    assert_equal ["foo"], regexp.scan("foo foo")
  end

  def test_literal_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("needle")

    assert_equal %w[needle needle], regexp.scan("needle x needle")
  end

  def test_ascii_literal_scan_uses_constructor_literal_metadata
    regexp = Onibi::Regexp.new("needle")

    assert_equal %w[needle needle], regexp.scan("needle x needle")
  end

  def test_word_boundary_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("\\bcat\\b")

    assert_equal %w[cat cat], regexp.scan("cat scatter cat")
  end

  def test_literal_alternation_scan_uses_direct_hfa_iterator
    regexp = Onibi::Regexp.new("cat|dog|fox")

    assert_equal %w[dog cat fox], regexp.scan("dog cat fox")
  end

  def test_literal_alternation_scan_short_circuits_generic_iterator_checks
    regexp = Onibi::Regexp.new("cat|dog|fox")

    assert_equal %w[dog cat fox], regexp.scan("dog cat fox")
  end

  def test_captureless_repeated_alternation_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?:a|b)+c")

    assert_equal %w[ababc abc], regexp.scan("ababc cabc")
  end

  def test_scoped_unicode_ignorecase_literal_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?i:é)")

    assert_equal %w[é É], regexp.scan("café École")
  end

  def test_ascii_literal_scan_preserves_matches_after_unicode_prefix
    regexp = Onibi::Regexp.new("cat")

    assert_equal %w[cat cat], regexp.scan("日本語cat cat")
  end

  def test_unicode_literal_gsub_with_match_replacement_preserves_byte_offsets
    regexp = Onibi::Regexp.new("cat")

    assert_equal "日本語<cat> <cat>", regexp.gsub("日本語cat cat", "<\\0>")
  end

  def test_literal_absence_scan_uses_hfa_on_unicode_input
    regexp = Onibi::Regexp.new("(?~END)")

    assert_equal ["日本語EN", "D", ""], regexp.scan("日本語END")
  end

  def test_latin1_unicode_literal_scan_uses_hfa
    regexp = Onibi::Regexp.new("ß")

    assert_equal ["ß"], regexp.scan("café ß")
  end

  def test_start_match_literal_scan_uses_hfa_on_unicode_input
    regexp = Onibi::Regexp.new("\\Gcat")

    assert_equal ["cat"], regexp.scan("cat日本語")
  end

  def test_literal_alternation_scan_uses_hfa_on_unicode_input
    regexp = Onibi::Regexp.new("cat|dog")

    assert_equal %w[cat dog], regexp.scan("日本語cat dog")
  end

  def test_repeated_equal_length_literal_capture_scan_uses_hfa
    regexp = Onibi::Regexp.new("(a|b)+c")

    assert_equal [["b"]], regexp.scan("ababc")
  end

  def test_literal_capture_before_alternation_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?<x>a)(?:b|c)")

    assert_equal [["a"]], regexp.scan("ab")
  end

  def test_single_capture_literal_alternation_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?<letter>a|aa)")

    assert_equal [["a"], ["a"]], regexp.scan("aa")
  end

  def test_nested_literal_capture_alternation_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?:(a)|(b))c")

    assert_equal [["a", nil], [nil, "b"]], regexp.scan("ac bc")
  end

  def test_scoped_ignorecase_multiline_sequence_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?im:a.)")

    assert_equal %W[A\n aX], regexp.scan("zzA\nx aX")
  end

  def test_scoped_multiline_sequence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a(?m:.)b")

    assert_equal %W[a\nb aXb], regexp.scan("za\nb aXb")
  end

  def test_scoped_ignorecase_sequence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a(?i:bc)d")

    assert_equal %w[aBCd aBcd], regexp.scan("xaBCd yaBcd")
  end

  def test_captureless_literal_quantifier_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a+")

    assert_equal %w[aaa aa], regexp.scan("baaacaa")
  end

  def test_possessive_literal_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("a++b")

    assert_equal %w[aaab aab], regexp.scan("xxaaab yyaab")
  end

  def test_literal_assertion_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("cat(?!fish)")

    assert_equal %w[cat cat], regexp.scan("cat dog catfish cat")
  end

  def test_literal_lookbehind_scan_avoids_hfa_program_compile
    positive = Onibi::Regexp.new("(?<=pre)fix")
    negative = Onibi::Regexp.new("(?<!un)happy")

    assert_equal %w[fix fix], positive.scan("prefix preprefix")

    assert_equal %w[happy happy], negative.scan("happy unhappy happy")
  end

  def test_ascii_ignorecase_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("case", Onibi::Regexp::IGNORECASE)

    assert_equal %w[CASE case], regexp.scan("CASE x case")
  end

  def test_match_reset_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("prefix\\Ksuffix")

    assert_equal %w[suffix suffix], regexp.scan("prefixsuffix x prefixsuffix")
  end

  def test_match_reset_scan_uses_combined_literal_search
    regexp = Onibi::Regexp.new("prefix\\Ksuffix")

    assert_equal %w[suffix suffix], regexp.scan("prefixsuffix x prefixsuffix")
  end

  def test_repeated_literal_suffix_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a+b")

    assert_equal %w[aaab aab], regexp.scan("xxaaab yyaab")
  end

  def test_class_run_chain_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[a-z]+:[0-9]+")

    assert_equal %w[item:2026 key:7], regexp.scan("item:2026 key:7")
  end

  def test_adjacent_class_runs_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("[a-z]+[0-9]+")

    assert_equal %w[item2026 key7], regexp.scan("item2026 key7")
  end

  def test_adjacent_class_runs_scan_uses_hfa_iterator
    program = Onibi::HybridAutomata.compile("[a-z]+[0-9]+")

    assert_equal [[0, 8, []], [9, 13, []]],
                 program.each_match_result("item2026 key7").to_a
  end

  def test_class_run_triple_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\w+\\s+\\d+")

    assert_equal ["item 2026", "key 7"], regexp.scan("item 2026 key 7")
  end

  def test_ascii_property_run_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\p{Alpha}+")

    assert_equal %w[letters words], regexp.scan("123letters 456words")
  end

  def test_unicode_property_run_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\p{Hiragana}+")

    regexp.stub(:hfa_unicode_property_run_matcher,
                -> { flunk "Hiragana property run should use specialized codepoint matching" }) do
      assert_equal %w[ひらがな ひらがな], regexp.scan("漢字ひらがな ひらがな")
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

    regexp.stub(:hfa_unicode_property_run_matcher,
                -> { flunk "Unicode letter property run should use specialized codepoint matching" }) do
      assert_equal %w[日本語 終端], regexp.scan(input)
    end
  end

  def test_unicode_word_class_run_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[[:word:]]+")

    assert_equal %w[記号 日本語 _2026 終端], regexp.scan("記号-日本語 _2026 終端!")
  end

  def test_literal_negative_lookahead_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("cat(?!fish)")

    assert_equal %w[cat cat], regexp.scan("catfish cat cat")
  end

  def test_unicode_repeated_literal_scan_rejects_ascii_input_without_fallback
    regexp = Onibi::Regexp.new("(?:日本語)+")

    assert_empty regexp.scan("ascii only")
  end

  def test_literal_positive_lookahead_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a(?=b)")

    assert_equal %w[a a], regexp.scan("ab ac ab")
  end

  def test_leading_literal_positive_lookahead_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?=a)a")

    assert_equal %w[a a], regexp.scan("a ba")
  end

  def test_repeated_leading_literal_lookahead_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?=a)(?=a)a")

    assert_equal %w[a a], regexp.scan("a ba")
  end

  def test_atomic_literal_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?>a|ab)b")

    assert_equal %w[ab ab], regexp.scan("zab ab")
  end

  def test_atomic_literal_alternation_with_nonmatching_suffix_scans_with_hfa
    regexp = Onibi::Regexp.new("(?>a|ab)c")

    assert_equal ["ac"], regexp.scan("zabc zac")
  end

  def test_atomic_literal_alternation_scan_uses_literal_candidate_search
    regexp = Onibi::Regexp.new("(?>a|ab)b")

    assert_equal %w[ab ab], regexp.scan("zab ab")
  end

  def test_line_anchor_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("^cat$")

    assert_equal %w[cat cat], regexp.scan("cat\ncat")
  end

  def test_greedy_bounded_sequence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("foo.{0,4}bar")

    assert_equal %w[foo12bar foo-bar], regexp.scan("foo12bar foo-bar")
  end

  def test_scoped_extended_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a(?-x: b#c )d")

    assert_equal ["a b#c d"], regexp.scan("a b#c d")
  end

  def test_nonword_boundary_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\Bcat\\B")

    assert_equal ["cat"], regexp.scan("_cat_ catx")
  end

  def test_class_run_positive_lookahead_scan_avoids_hfa_program_compile
    regexp = Onibi::Regexp.new("[a-z]+(?=-[0-9]+)")

    assert_equal %w[item key], regexp.scan("item-2026 key-7")
  end

  def test_literal_positive_lookbehind_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<=pre)fix")

    assert_equal %w[fix fix], regexp.scan("prefix suffix prefix")
  end

  def test_unicode_literal_positive_lookbehind_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<=ß)x")

    assert_equal %w[x x], regexp.scan("ßx ax ßx")
  end

  def test_unicode_class_lookbehind_scan_uses_hfa_iterator
    positive = Onibi::Regexp.new("(?<=[ß])x")
    negative = Onibi::Regexp.new("(?<![ß])x")

    assert_equal %w[x x], positive.scan("ßx ax ßx")

    assert_equal %w[x], negative.scan("ßx ax ßx")
  end

  def test_unicode_class_rejects_ascii_scan_without_fallback
    regexp = Onibi::Regexp.new("[é]")

    assert_empty regexp.scan("ascii")
  end

  def test_unicode_class_lookbehind_rejects_ascii_scan_without_fallback
    regexp = Onibi::Regexp.new("(?<=[ß])x")

    assert_empty regexp.scan("ascii")
  end

  def test_unicode_full_casefold_class_lookbehind_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?<=[ß])x", ["ignorecase"])

    assert_equal %w[x x], regexp.scan("ssx ax ßx")
  end

  def test_unicode_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("こんにちは")

    assert_equal %w[こんにちは こんにちは], regexp.scan("こんにちは 世界 こんにちは")
  end

  def test_unicode_repeated_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?:日本語)+")
    input = "開始日本語日本語 終了日本語"

    assert_equal %w[日本語日本語 日本語], regexp.scan(input)
  end

  def test_unicode_repeated_literal_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<word>é+)")

    assert_equal [["éé"], ["é"]], regexp.scan("aéé zé")
  end

  def test_unicode_literal_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(こんにちは)(世界)")

    assert_equal [%w[こんにちは 世界]], regexp.scan("挨拶こんにちは世界です")
  end

  def test_ignorecase_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("case", ["ignorecase"])

    assert_equal %w[CASE case], regexp.scan("xxCASE yycase")
  end

  def test_unicode_ignorecase_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("école", ["ignorecase"])

    regexp.stub(:hfa_unicode_full_casefold_literal_match_result,
                ->(*) { flunk "simple Unicode casefold scan should skip full casefold search" }) do
      assert_equal %w[ÉCOLE école], regexp.scan("xxÉCOLE yyécole")
    end
  end

  def test_literal_negative_lookbehind_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<!a)b")

    assert_equal %w[b b], regexp.scan("ab cb db")
  end

  def test_class_run_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    assert_equal [%w[item 2026], %w[key 7]], regexp.scan("item-2026 key-7")
  end

  def test_class_run_capture_scan_avoids_hfa_program
    regexp = Onibi::Regexp.new("([a-z]+)-([0-9]+)")

    assert_equal [%w[item 2026], %w[key 7]], regexp.scan("item-2026 key-7")
  end

  def test_guarded_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<!a)(?<letter>b)")

    assert_equal [["b"], ["b"]], regexp.scan("ab cb db")
  end

  def test_variable_alternation_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<letter>a|ab)c")

    assert_equal [["a"], ["ab"]], regexp.scan("ac abc")
  end

  def test_backreference_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("([a-z]+)-\\1")

    assert_equal [["echo"], ["test"]], regexp.scan("echo-echo test-test")
  end

  def test_variable_literal_backreference_scan_uses_hfa
    regexp = Onibi::Regexp.new("(a*)\\1")

    assert_equal [["aa"], [""], ["a"], [""]], regexp.scan("aaaa aa")
  end

  def test_scoped_casefold_backreference_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?<x>a)(?i:\\k<x>)")

    assert_equal [["a"], ["a"]], regexp.scan("aA aa")
  end

  def test_variable_any_backreference_scan_uses_hfa
    regexp = Onibi::Regexp.new("(?<x>.*)\\k<x>")

    assert_equal [["abc"], [""]], regexp.scan("abcabc")
    assert_equal [[""], [""], [""], [""]], regexp.scan("abc")
  end

  def test_variable_any_backreference_scan_builds_match_values_without_hfa_adapter
    regexp = Onibi::Regexp.new("(?<x>.*)\\k<x>")

    assert_equal [["abc"], [""]], regexp.scan("abcabc")
  end

  def test_hfa_scan_converts_capture_offsets_without_match_data
    regexp = Onibi::Regexp.new("(?<x>.*)\\k<x>")

    assert_equal [["abc"], [""]], regexp.scan("abcabc")
  end

  def test_named_backreference_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<word>[a-z]+)-\\k<word>")

    assert_equal [["echo"], ["test"]], regexp.scan("echo-echo test-test")
  end

  def test_adjacent_backreference_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(ab)\\1")

    assert_equal [["ab"]], regexp.scan("zzabab")
  end

  def test_conditional_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(a)?(?(1)b|c)")

    assert_equal %w[ab c], regexp.scan("ab c")
  end

  def test_named_subexpression_call_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<pair>ab)\\g<pair>")

    assert_equal [["ab"]], regexp.scan("zzabab")
  end

  def test_named_subexpression_call_scan_uses_literal_iterator
    regexp = Onibi::Regexp.new("(?<pair>ab)\\g<pair>")

    assert_equal [["ab"]], regexp.scan("zzabab")
  end

  def test_nested_literal_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab))")

    assert_equal [%w[ab ab]], regexp.scan("zzab")
  end

  def test_nested_fixed_width_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((a|b))")

    assert_equal [%w[b b], %w[a a]], regexp.scan("zb za")
  end

  def test_optional_repeated_literal_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(a*)b")

    assert_equal [["aaa"]], regexp.scan("xxaaabyy")
    assert_equal [[""]], regexp.scan("b")
  end

  def test_nested_empty_repeated_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(a*)*b")

    assert_equal [[""]], regexp.scan("xxaaabyy")
  end

  def test_variable_subexpression_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?<x>a|ab)c\\g<x>d")

    assert_equal [["a"]], regexp.scan("acad")
    assert_equal [["ab"]], regexp.scan("abcabd")
  end

  def test_variable_capture_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(a|aa)(b|bb)")

    assert_equal [%w[a b]], regexp.scan("zabb")
    assert_equal [%w[aa b]], regexp.scan("zaab")
  end

  def test_empty_absence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?~)")

    assert_equal [""], regexp.scan("abc")
  end

  def test_captured_literal_absence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?~(a))")

    assert_equal [["a"], ["a"], [nil]], regexp.scan("ba")
  end

  def test_escape_class_run_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("\\w+")

    assert_equal %w[word next], regexp.scan("word! next?")
  end

  def test_unicode_literal_scan_rejects_ascii_input_without_fallback
    regexp = Onibi::Regexp.new("ß")

    assert_empty regexp.scan("ascii only")
  end

  def test_unicode_full_casefold_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("ß", ["ignorecase"])

    assert_equal %w[SS ß], regexp.scan("SS ß")
  end

  def test_lookahead_alternation_backreference_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("(?=(a|aa))\\1b")

    assert_equal [["a"]], regexp.scan("xaab")
  end

  def test_nested_variable_width_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab|a))")

    assert_equal [%w[ab ab], %w[a a]], regexp.scan("zab za")
  end

  def test_nested_repeated_literal_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab)+)")

    assert_equal [%w[abab ab]], regexp.scan("zzabab")
  end

  def test_nested_repeated_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((a|b)+)")

    assert_equal [%w[abab b]], regexp.scan("zzabab")
  end

  def test_nested_variable_repeated_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab|a)+)")

    assert_equal [%w[aba a]], regexp.scan("zzaba")
  end

  def test_nested_repeated_suffix_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab)+)c")

    assert_equal [%w[abab ab]], regexp.scan("zzababc")
  end

  def test_nested_repeated_and_class_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab)+)-([0-9]+)")

    assert_equal [%w[abab ab 123]], regexp.scan("zzabab-123")
  end

  def test_nested_repeated_and_nested_class_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab)+)-(([0-9]) +)".delete(" "))

    assert_equal [%w[abab ab 123 3]], regexp.scan("zzabab-123")
  end

  def test_adjacent_nested_repeated_capture_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("((ab)+)((cd)+)")

    assert_equal [%w[abab ab cdcd cd]], regexp.scan("zzababcdcd")
  end

  def test_unicode_property_run_gsub_preserves_byte_offsets
    regexp = Onibi::Regexp.new("\\p{Hiragana}+")

    assert_equal "漢字<h> 終端", regexp.gsub("漢字ひらがな 終端", "<h>")
  end

  def test_bounded_literal_quantifier_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a{2,4}")

    assert_equal %w[aaaa aa], regexp.scan("baaaacaa")
  end

  def test_fixed_class_run_literal_scan_uses_hfa_iterator
    program = Onibi::HybridAutomata.compile("a[bc]{4}z")

    assert_equal [[3, 9, []], [12, 18, []]],
                 program.each_match_result("xxaabcbcz yyabcbcz").to_a
  end

  def test_single_class_run_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[0-9]+")

    assert_equal %w[123 456], regexp.scan("abc123def456")
  end

  def test_literal_class_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a[0-9]+z")

    assert_equal %w[a123z a45z], regexp.scan("xxa123z yya45z")
  end

  def test_star_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a.*z")

    assert_equal %w[a1z a2z], regexp.scan("a1z\na2z")
    assert_equal ["a1z2z"], regexp.scan("a1z2z")
  end

  def test_lazy_star_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a.*?z")

    assert_equal %w[a1z a2z], regexp.scan("a1z\na2z")
    assert_equal ["a1z"], regexp.scan("a1z2z")
  end

  def test_captureless_literal_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("cat|dog")

    assert_equal %w[dog cat], regexp.scan("dogmatic cat")
    assert_equal "<x>matic <x>", regexp.gsub("dogmatic cat", "<x>")
  end

  def test_captureless_alternation_exposes_match_ranges_without_result_tuples
    regexp = Onibi::Regexp.new("a[NSt]|BY")
    spec = regexp.send(:hfa_captureless_alternation_scan_spec)
    ranges = []

    regexp.send(:hfa_captureless_alternation_each_range, "aN BY aS", spec) do |start_position, finish_position|
      ranges << [start_position, finish_position]
    end

    assert_equal [[0, 2], [3, 5], [6, 8]], ranges
  end

  def test_captureless_alternation_gsub_does_not_accept_another_branch_candidate
    regexp = Onibi::Regexp.new("aND|caN|Ha[DS]|WaS")

    assert_equal "gaVtgWWggaKHaatKWcBScSWa", regexp.gsub("gaVtgWWggaKHaatKWcBScSWa", "<3>")
  end

  def test_captureless_class_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("foo[a-z]+|foo[0-9]+")

    assert_equal %w[fooabc foo123], regexp.scan("xxfooabc yyfoo123")
  end

  def test_captureless_regular_sequence_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[a-z]\\d+")

    assert_equal %w[a123 b7], regexp.scan("xxa123 yyb7")
  end

  def test_scoped_ignorecase_literal_iteration_uses_hfa
    regexp = Onibi::Regexp.new("(?i:cat)")

    assert_equal %w[CAT cAt], regexp.scan("CAT xx cAt")
  end

  def test_scoped_multiline_dot_iteration_uses_hfa
    regexp = Onibi::Regexp.new("(?m:.)")

    assert_equal %W[\n a], regexp.scan("\na")
  end

  def test_ascii_linebreak_iteration_uses_hfa
    regexp = Onibi::Regexp.new("\\R")

    assert_equal ["\r\n", "\n"], regexp.scan("x\r\ny\nz")
  end

  def test_unicode_linebreak_iteration_uses_hfa
    regexp = Onibi::Regexp.new("\\R")

    assert_equal ["\u2028", "\u2029"], regexp.scan("x\u2028y\u2029z")
  end

  def test_fixed_class_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[cgt]gggtaaa|tttaccc[acg]")

    assert_equal %w[cgggtaaa tttaccca], regexp.scan("xxcgggtaaa yytttaccca")
    assert regexp.send(:hfa_captureless_alternation_scan_spec)
  end

  def test_captureless_middle_class_alternation_scan_uses_literal_anchor
    regexp = Onibi::Regexp.new("a[act]ggtaaa|tttacc[agt]t")

    assert_equal %w[acggtaaa tttaccgt], regexp.scan("xxacggtaaa yytttaccgt")
    assert regexp.send(:hfa_captureless_alternation_scan_spec)
  end

  def test_captureless_mixed_alternation_scan_uses_class_and_literal_branches
    regexp = Onibi::Regexp.new("a[NSt]|BY")

    assert_equal %w[aN BY], regexp.scan("aN xx BY")
    assert regexp.send(:hfa_captureless_alternation_scan_spec)
  end

  def test_repeated_alternation_scan_uses_hfa_iterator
    program = Onibi::HybridAutomata.compile("(?:ab|ac)+z")

    assert_equal [[2, 7, []], [10, 15, []]],
                 program.each_match_result("xxabacz yyababz").to_a
  end

  def test_captureless_single_byte_class_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("[a-z]")

    assert_equal %w[a b c], regexp.scan("1a2b3c")
  end

  def test_captureless_single_byte_dot_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new(".")

    assert_equal %w[a b], regexp.scan("a\nb")
  end

  def test_literal_dot_literal_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new("a.c")

    assert_equal %w[abc aXc], regexp.scan("xxabc yyaXc")
  end

  def test_multiline_literal_dot_literal_scan_uses_direct_hfa_iterator
    regexp = Onibi::Regexp.new("a.b", ["multiline"])

    assert_equal ["a\nb"], regexp.scan("xa\nbz")
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

  def test_linebreak_alternation_scan_uses_hfa_iterator
    regexp = Onibi::Regexp.new(">.*\\n|\\n")

    regexp.stub(:codegen_each_result, ->(*) { flunk "linebreak alternation should use HFA" }) do
      assert_equal [">header\n", "\n"], regexp.scan(">header\nsequence\n")
    end
  end

  def test_linebreak_alternation_gsub_materializes_directly
    regexp = Onibi::Regexp.new(">.*\\n|\\n")
    input = ">header\nsequence\n"

    assert_equal ["sequence", input.bytesize],
                 regexp.send(:hfa_linebreak_replace_api, input, "", nil)
    assert_equal "sequence", regexp.gsub(input, "")
  end

  def test_delimited_negated_class_gsub_uses_hfa_result_shape
    regexp = Onibi::Regexp.new("<[^>]*>")

    assert_equal "| |", regexp.gsub("<first> <second>", "|")
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
