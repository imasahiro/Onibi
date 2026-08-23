# frozen_string_literal: true

require "test_helper"

class AbsenceOperatorTest < Minitest::Test
  def test_absence_operator_stops_before_the_forbidden_match
    match = Onibi::Regexp.new("(?~real)").match("surrealist")

    assert_equal "surrea", match[0]
  end

  def test_absence_operator_can_be_followed_by_a_suffix
    match = Onibi::Regexp.new("(?~real)ist").match("surrealist")

    assert_equal "ealist", match[0]
  end

  def test_absence_operator_evaluates_bytecode_body_alternatives
    regexp = Onibi::Regexp.new("(?~a|b)")

    assert_equal "", regexp.match("a")[0]
    assert_equal "x", regexp.match("xaby")[0]
    assert_equal "cd", regexp.match("cd")[0]
  end

  def test_absence_operator_preserves_body_captures
    match = Onibi::Regexp.new("(?~(a|b))").match("xaby")

    assert_equal "x", match[0]
    assert_equal "a", match[1]
  end

  def test_absence_operator_matches_mri_for_unbounded_greedy_body
    regexp = Onibi::Regexp.new("(?~a+)")

    actual = %w[a aa aaa aaaa aaaaa].map do |input|
      regexp.match(input)[0]
    end
    assert_equal ["", "a", "a", "aa", "aa"], actual
  end

  def test_absence_operator_scans_for_a_greedy_body_match
    regexp = Onibi::Regexp.new("(?~a+)")

    assert_equal "b", regexp.match("ba")[0]
    assert_equal "x", regexp.match("xaby")[0]
  end

  def test_absence_operator_backtracks_to_a_suffix
    match = Onibi::Regexp.new("(?~a+)b").match("ab")

    assert_equal "b", match[0]
    assert_equal [1, 2], match.offset(0)
  end

  def test_absence_operator_retries_after_a_zero_width_star_body
    match = Onibi::Regexp.new("(?~a*)").match("b")

    assert_equal "", match[0]
    assert_equal [1, 1], match.offset(0)
  end

  def test_absence_operator_handles_unbounded_range_bodies
    regexp = Onibi::Regexp.new("(?~a{2,})")

    assert_equal(%w[aa aaa], %w[aaaa aaaaa].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_unbounded_class_ranges
    regexp = Onibi::Regexp.new("(?~[ab]{2,})")

    assert_equal(%w[aa ab], %w[aaaa abab].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_unbounded_group_ranges
    regexp = Onibi::Regexp.new("(?~(ab){2,})")

    assert_equal(%w[ab aba ababa], %w[ab abab ababab].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_unbounded_alternation_ranges
    regexp = Onibi::Regexp.new("(?~(a|b){2,})")

    assert_equal(%w[ab aba], %w[abab ababab].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_variable_alternation_lengths
    regexp = Onibi::Regexp.new("(?~(a|ab){2,})")

    assert_equal(%w[aa ab], %w[aaa abab].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_does_not_export_quantifier_body_captures
    match = Onibi::Regexp.new("(?~(a|b){2,})").match("xabab")

    assert_equal "xab", match[0]
    assert_nil match[1]
  end

  def test_absence_operator_handles_nested_equal_length_captures
    match = Onibi::Regexp.new("(?~((a|b)){2,})").match("abab")

    assert_equal "ab", match[0]
    assert_nil match[1]
    assert_nil match[2]
  end

  def test_absence_operator_clears_nested_repeat_captures
    match = Onibi::Regexp.new("(?~((ab)+))").match("ab")

    assert_equal "a", match[0]
    assert_equal "ab", match[1]
    assert_nil match[2]
  end

  def test_absence_operator_tracks_odd_nested_repeat_captures
    regexp = Onibi::Regexp.new("(?~((ab)+))")

    odd = regexp.match("ababab")
    even = regexp.match("abab")
    assert_equal "ab", odd[1]
    assert_nil even[1]
  end

  def test_absence_operator_tracks_nested_alternation_captures
    regexp = Onibi::Regexp.new("(?~((a|b)+))")

    assert_equal %w[a b], regexp.match("aba").to_a.first(2)
    assert_equal %w[aba ab], regexp.match("ababab").to_a.first(2)
  end

  def test_absence_operator_clears_nested_bounded_captures
    match = Onibi::Regexp.new("(?~((a|ab){2,}))").match("abab")

    assert_equal "ab", match[0]
    assert_nil match[1]
    assert_nil match[2]
  end

  def test_absence_operator_tracks_variable_nested_alternation
    regexp = Onibi::Regexp.new("(?~((ab|a)+))")

    assert_equal %w[ab a], regexp.match("abab").to_a.first(2)
    assert_equal %w[abab], regexp.match("ababab").to_a.first(1)
  end

  def test_absence_operator_tracks_bounded_variable_alternation
    regexp = Onibi::Regexp.new("(?~((ab|a){2,}))")

    assert_equal %w[aba], regexp.match("abab").to_a.first(1)
    assert_equal %w[abab], regexp.match("ababab").to_a.first(1)
  end
end
