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
end
