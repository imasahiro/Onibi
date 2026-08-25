# frozen_string_literal: true

require "test_helper"

class QuantifierModeTest < Minitest::Test
  def test_lazy_quantifier_stops_at_the_first_successful_boundary
    match = Onibi::Regexp.new("a+?a").match("aaa")

    assert_equal "aa", match[0]
  end

  def test_lazy_exact_bound_uses_mri_optional_boundary
    source = "a{2}?b"

    %w[b ab aab aaab].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = Onibi::Regexp.new(source).match(input)

      assert_equal expected&.to_a, actual&.to_a, input
      assert_equal expected&.offset(0), actual&.offset(0), input
    end
  end

  def test_lazy_exact_bound_clamps_position_past_input_end
    source = "a{2}?"

    ["", "a", "ba"].each do |input|
      expected = ::Regexp.new(source).match(input, input.length + 2)
      actual = Onibi::Regexp.new(source).match(input, input.length + 2)

      assert_equal expected&.to_a, actual&.to_a, input
      assert_equal expected&.offset(0), actual&.offset(0), input
    end
  end

  def test_lazy_exact_bound_keeps_unicode_fold_repetition_as_one_operand
    [["s{2}?", "ß"], ["s{2}?s", "ßs"], ["ss{2}?", "sß"],
     ["[a-z]{2}?", "ß"]].each do |source, input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal expected&.to_a, actual&.to_a, source
      assert_equal expected&.offset(0), actual&.offset(0), source
    end
  end

  def test_casefold_optional_stops_before_absolute_end_anchor
    %w[ſ sſ].each do |input|
      source = "s?\\z"
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal expected&.to_a, actual&.to_a, input
      assert_equal expected&.offset(0), actual&.offset(0), input
    end
  end

  def test_casefold_optional_stops_before_grouped_absolute_end_anchor
    source = "s?(\\z)"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected&.offset(0), actual&.offset(0)
  end

  def test_casefold_optional_keeps_consuming_before_character_class
    source = "s?[a-z]"
    %w[ſs ſſ].each do |input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, ::Regexp::IGNORECASE).match(input)

      assert_equal expected.to_a, actual.to_a
      assert_equal [expected.begin(0), expected.end(0)], [actual.begin(0), actual.end(0)]
    end
  end

  def test_casefold_lazy_exact_repeat_prefers_zero_before_absolute_end
    source = "s{2}?\\z"
    %w[sſ ſs ſſ].each do |input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, ::Regexp::IGNORECASE).match(input)

      assert_equal expected.to_a, actual.to_a
      assert_equal [expected.begin(0), expected.end(0)], [actual.begin(0), actual.end(0)]
    end
  end

  def test_casefold_group_literal_does_not_cross_absolute_end_anchor
    source = "(s)\\z"
    actual = Onibi::Regexp.new(source, ::Regexp::IGNORECASE).match("ſ")

    assert_nil actual
  end

  def test_casefold_backreference_matches_long_s
    source = "(s)\\1"
    ["sſ"].each do |input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, ::Regexp::IGNORECASE).match(input)

      assert_equal expected.to_a, actual.to_a
      assert_equal [expected.begin(0), expected.end(0)], [actual.begin(0), actual.end(0)]
    end
  end

  def test_casefold_backreference_keeps_mri_direction
    source = "(s)\\1"
    actual = Onibi::Regexp.new(source, ::Regexp::IGNORECASE).match("ſs")

    assert_nil actual
  end

  def test_lazy_optional_quantifier_prefers_zero_repetitions
    match = Onibi::Regexp.new("a??b").match("b")

    assert_equal "b", match[0]
  end

  def test_possessive_quantifier_does_not_backtrack
    refute Onibi::Regexp.new("a++a").match?("aaa")
    assert Onibi::Regexp.new("a++").match?("aaa")
  end

  def test_possessive_quantifier_accepts_a_terminal_zero_width_iteration
    expected = ::Regexp.new("a$++").match("a")
    actual = Onibi::Regexp.new("a$++").match("a")

    assert_equal expected.to_a, actual.to_a
  end

  def test_possessive_bounded_quantifier_does_not_backtrack
    regexp = Onibi::Regexp.new("a{1,3}+a")

    assert regexp.match?("aaa")
    assert regexp.match?("aaaa")
    %w[aaa aaaa].each do |input|
      assert_equal Regexp.new("a{1,3}+a").match?(input), regexp.match?(input)
    end
  end

  def test_bounded_possessive_units_repeat_until_input_end
    expected = ::Regexp.new(".{0,2}+").match("aaab")
    actual = Onibi::Regexp.new(".{0,2}+").match("aaab")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(0), actual.offset(0)
  end

  def test_possessive_nullable_unit_keeps_terminal_anchor_capture
    source = "((?<value>(?:$|.))*+)"
    expected = ::Regexp.new(source).match("ab")
    actual = Onibi::Regexp.new(source).match("ab")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(1), actual.offset(1)
  end

  def test_nested_possessive_quantifier_keeps_zero_repetitions
    source = "(\\s)+?*+"
    expected = ::Regexp.new(source).match("xyz")
    actual = Onibi::Regexp.new(source).match("xyz")

    assert_equal expected.to_a, actual&.to_a
  end

  def test_nested_possessive_zero_width_unit_keeps_capture_state
    source = "(?=(?<value>.))+?*+"
    expected = ::Regexp.new(source).match("a\nb")
    actual = Onibi::Regexp.new(source).match("a\nb")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(1), actual.offset(1)
  end

  def test_bounded_possessive_zero_width_unit_keeps_capture_state
    source = "(\\b){0,2}+"
    expected = ::Regexp.new(source).match("123")
    actual = Onibi::Regexp.new(source).match("123")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(1), actual.offset(1)
  end

  def test_nested_lazy_nullable_unit_keeps_the_shortest_candidate
    source = "(?<value>(?:\\w|\\p{L})*?++)"
    expected = ::Regexp.new(source).match("É")
    actual = Onibi::Regexp.new(source).match("É")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(1), actual.offset(1)
  end

  def test_nested_lazy_zero_repetition_does_not_create_a_capture
    source = "(?:(\\b)*?)*?++"
    expected = ::Regexp.new(source).match("123")
    actual = Onibi::Regexp.new(source).match("123")

    assert_equal expected.to_a, actual.to_a
  end

  def test_bounded_possessive_alternation_keeps_first_zero_width_branch
    source = "(?<value>(?:(?=.)|(?:[ab]|c)){0,2}+)\\g<value>"
    expected = ::Regexp.new(source).match("aba")
    actual = Onibi::Regexp.new(source).match("aba")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(1), actual.offset(1)
  end

  def test_lazy_suffix_keeps_bounded_possessive_minimum
    source = "(?:\\b){1,3}+?"
    expected = ::Regexp.new(source).match("")
    actual = Onibi::Regexp.new(source).match("")

    assert_equal expected&.to_a, actual&.to_a
  end

  def test_possessive_quantifier_preserves_ordered_choice_for_equal_lengths
    match = Onibi::Regexp.new("(a|aa)++").match("aa")

    assert_equal "a", match[1]
  end

  def test_greedy_quantifier_preserves_ordered_alternation
    mri = Regexp.new("(a|ab)+").match("ab")
    onibi = Onibi::Regexp.new("(a|ab)+").match("ab")

    assert_equal mri.to_a, onibi.to_a
  end

  def test_zero_width_quantifier_accepts_one_zero_width_iteration
    match = Onibi::Regexp.new("(?=a)+").match("ab")

    assert_equal "", match[0]
    assert_equal [0, 0], match.offset(0)
  end

  def test_finite_zero_width_quantifier_repeats_anchor
    expected = ::Regexp.new("\\z{2}").match("a")
    actual = Onibi::Regexp.new("\\z{2}").match("a")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(0), actual.offset(0)
  end

  def test_zero_width_group_iteration_updates_the_last_capture
    expected = ::Regexp.new("($|a)*").match("a")
    actual = Onibi::Regexp.new("($|a)*").match("a")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(1), actual.offset(1)
  end

  def test_multiline_greedy_dot_after_terminal_assertion_matches_mri
    pattern = "(?=\\z).*"

    %w[x xy é xéy].each do |input|
      expected = ::Regexp.new(pattern, ::Regexp::MULTILINE).match(input)
      actual = Onibi::Regexp.new(pattern, Onibi::Regexp::MULTILINE).match(input)

      if expected
        refute_nil actual, input
        assert_equal expected.to_a, actual.to_a, input
        assert_equal expected.offset(0), actual.offset(0), input
      else
        assert_nil actual, input
      end
    end
  end

  def test_zero_width_absence_searches_for_the_first_non_matching_position
    %w[aa aba].each do |input|
      expected = ::Regexp.new("(?~(?=a))").match(input)
      actual = Onibi::Regexp.new("(?~(?=a))").match(input)
      assert_equal expected.to_a, actual.to_a
      assert_equal expected.offset(0), actual.offset(0)
    end
  end

  def test_nullable_nested_quantifier_keeps_the_empty_capture
    %w[a aa].each do |input|
      mri = Regexp.new("(a?)+").match(input)
      onibi = Onibi::Regexp.new("(a?)+").match(input)
      assert_equal mri.to_a, onibi.to_a
    end

    mri = Regexp.new("(a*)+").match("a")
    onibi = Onibi::Regexp.new("(a*)+").match("a")
    assert_equal mri.to_a, onibi.to_a
  end
end
