# frozen_string_literal: true

require "test_helper"

class LookaheadTest < Minitest::Test
  def test_positive_lookahead_asserts_without_consuming
    match = Onibi::Regexp.new("a(?=b)").match("ab")

    assert_equal "a", match[0]
  end

  def test_negative_lookahead_rejects_the_asserted_suffix
    regexp = Onibi::Regexp.new("a(?!b)")

    assert_equal "a", regexp.match("ac")[0]
    assert_nil regexp.match("ab")
  end

  def test_positive_lookbehind_asserts_without_consuming
    match = Onibi::Regexp.new("(?<=a)b").match("ab")

    assert_equal "b", match[0]
  end

  def test_negative_lookbehind_rejects_the_asserted_prefix
    regexp = Onibi::Regexp.new("(?<!a)b")

    assert_equal "b", regexp.match("cb")[0]
    assert_nil regexp.match("ab")
  end

  def test_lookbehind_rejects_a_variable_width_body
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?<=a+)b") }
  end

  def test_lookbehind_accepts_finite_alternation_widths
    pattern = "(?<=a|bc)c"
    input = "bcc"

    assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
  end

  def test_ignorecase_lookbehind_uses_casefold_consumption_width
    pattern = "(?i:(?<=ß)c)"
    input = "SSc"

    assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    assert Onibi::Regexp.new(pattern).match?(input)
  end

  def test_ignorecase_lookbehind_tracks_class_and_quantifier_widths
    [["(?i:(?<=[ß])x)", "SSx"], ["(?i:(?<=[ß])x)", "ßx"],
     ["(?i:(?<=[ß]{1})x)", "SSx"], ["(?i:(?<=[ß]{1})x)", "ßx"]].each do |pattern, input|
      assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    end

    pattern = "(?i:(?<=[aß])x)"
    assert_equal Regexp.new(pattern).match?("aßx"), Onibi::Regexp.new(pattern).match?("aßx")
  end

  def test_ignorecase_lookbehind_preserves_fold_overlap_for_literals
    [["(?<=ß)ss", "ßss"], ["(?<=ß).", "ßa"], ["(?<=ffi)ﬃ", "ﬃffi"]].each do |pattern, input|
      expected = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_reverse_fold_lookbehind_can_end_at_input_boundary
    source = "(?<=ss)ß"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßß")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßß")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_lookbehind_alternation
    source = "(?<=ss|ß)ß"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßß")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßß")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_lookbehind_fixed_quantifier_branch
    source = "(?<=s{2}|ß)ß"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßß")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßß")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_overlap_does_not_skip_same_width_literal
    source = "(?<=s{2}|ß)ss"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßß")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßß")

    assert_nil expected
    assert_nil actual
  end

  def test_ignorecase_reverse_fold_literal_matches_before_absolute_end
    source = "ss\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ß")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ß")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_alternate_fold_literal_matches_before_absolute_end
    source = "σ\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("σς")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("σς")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_greek_optional_keeps_alternate_before_absolute_end
    source = "σ?\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("σς")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("σς")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_greek_backreference_keeps_alternate_capture
    source = "(σ)\\1\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ςσ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ςσ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_long_s_fixed_repeat_stops_before_absolute_end
    source = "s{2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("sſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("sſ")

    assert_nil expected
    assert_nil actual
  end

  def test_ignorecase_long_s_reverse_literal_run_stops_before_absolute_end
    source = "ss\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_nil expected
    assert_nil actual
  end

  def test_ignorecase_long_s_class_repeat_stops_before_absolute_end
    source = "[s]{2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_nil expected
    assert_nil actual
  end

  def test_ignorecase_alternate_long_s_class_repeat_stops_at_anchor
    source = "[ſ]{2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_nil expected
    assert_nil actual
  end

  def test_ignorecase_long_s_optional_class_stops_before_absolute_end
    source = "[s]?\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_posix_optional_class_keeps_single_source_width
    source = "[[:alpha:]]?\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ss")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ss")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_unicode_property_optional_class_keeps_fold_width
    source = "[\\p{L}]?\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ss")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ss")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_posix_fixed_repeat_keeps_source_width_at_anchor
    source = "[[:alpha:]]{2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ffi")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ffi")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_posix_class_keeps_source_width_at_anchor
    source = "[[:alpha:]]\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("SS")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("SS")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_alternate_reverse_fold_is_not_accepted_at_anchor
    source = "(ſ|s)\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_expanded_lookbehind_preserves_mri_zero_width_tail
    source = "(?<=ß)\\p{L}"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßa")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßa")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_literal_is_not_accepted_at_anchor
    [["ſ\\z", "ſ"], ["K\\z", "K"], ["(a|ſ)\\z", "ſ"]].each do |source, input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_posix_alternation_keeps_source_width_at_anchor
    source = "(a|[[:alpha:]])\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("SS")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("SS")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_posix_optional_can_expand_a_non_ascii_source_at_anchor
    source = "[[:alpha:]]?\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_property_alternation_keeps_expanded_width_at_anchor
    ["(a|\\p{L})\\z", "(\\p{L}|a)\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("SS")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("SS")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_reverse_fold_lookbehind_keeps_zero_width_tail
    ["(?<=ss)\\p{L}", "(?<=ss)."].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßa")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßa")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_nested_posix_repeat_keeps_codepoint_width_at_anchor
    ["(?:[[:alpha:]]){2}\\z", "(?:[[:alpha:]]){2}$"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ffi")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ffi")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_property_capture_backreference_keeps_fold_origin
    source = "(\\p{L}|ß)\\1\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_expanded_lookbehind_rejects_direct_tail_before_input
    [["(?<=a|ß)x", "ßx"], ["(?<!a|ß)x", "ßx"]].each do |source, input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_expanded_lookbehind_does_not_match_direct_tail
    [["(?<=ß)ß", "ßa"], ["(?<=ß)a", "ßa"], ["(?<=ss)a", "ßa"]].each do |source, input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_lookbehind_prefers_expanded_overlap_at_later_position
    source = "(?<=ss|s)s"
    input = "ßss"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_anchor_boundary_through_wrappers
    ["(?>ſ|s)\\z", "(?i:ſ|s)\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſ")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſ")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_property_alternation_keeps_width_with_absolute_start
    source = "\\A(?:\\p{L}|a)\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("SS")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("SS")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_posix_capture_backreference_keeps_identical_long_s
    source = "([[:alpha:]])\\1\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_property_quantifier_backreference_keeps_nonempty_capture
    ["(\\p{L}+?)\\1\\z", "(\\p{L}*)\\1\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_alternating_and_unbounded_captures_keep_fold_origin
    ["(s|ß)\\1\\z", "(s)*\\1\\z", "(s)+\\1\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_reverse_literal_repeat_rejects_folded_capture_backreference
    source = "(ſ)+\\1\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("SS")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("SS")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_literal_run_can_end_at_line_anchor
    source = "ss$"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_forward_fold_literal_can_end_at_absolute_anchor
    source = "K\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("k")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("k")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_quantifier_keeps_source_width_at_absolute_anchor
    source = "s{1,2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_optional_literal_capture_keeps_fold_candidate
    ["(ss?)\\1\\z", "(s?s)\\1\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_reverse_fold_repeat_restarts_at_source_boundary
    ["s{1,2}\\z", "ſ{1,2}\\z"].each do |source|
      %w[ſſ sſ ſs].each do |input|
        expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
        actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

        assert_equal expected&.to_a, actual&.to_a
        assert_equal expected && [expected.begin(0), expected.end(0)],
                     actual && [actual.begin(0), actual.end(0)]
      end
    end
  end

  def test_ignorecase_split_literal_repeat_rejects_reverse_fold_boundary
    source = "ss{1,2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_bounded_repeat_capture_keeps_backreference_candidate
    ["(ſ{1,2})\\1\\z", "(s{1,2})\\1\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_optional_forward_fold_keeps_zero_width_at_absolute_anchor
    source = "k?\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("K")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("K")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_kelvin_bounded_repeat_rejects_reverse_source_at_anchor
    source = "k{1,2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("K")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("K")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_greek_bounded_repeat_keeps_fold_source_width
    source = "σ{1,2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("Σ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("Σ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_lookbehind_rejects_nested_variable_width_alternation
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?<=a(?:b|cd))x") }
  end

  def test_lookbehind_rejects_variable_width_linebreak_escape
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?<=\\R).") }
  end
end
