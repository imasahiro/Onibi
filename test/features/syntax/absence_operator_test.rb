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
end
