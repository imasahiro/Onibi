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

  def test_lookbehind_rejects_nested_variable_width_alternation
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?<=a(?:b|cd))x") }
  end

  def test_lookbehind_rejects_variable_width_linebreak_escape
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?<=\\R).") }
  end
end
