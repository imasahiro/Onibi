# frozen_string_literal: true

require "test_helper"

class QuantifierModeTest < Minitest::Test
  def test_lazy_quantifier_stops_at_the_first_successful_boundary
    match = Onibi::Regexp.new("a+?a").match("aaa")

    assert_equal "aa", match[0]
  end

  def test_lazy_optional_quantifier_prefers_zero_repetitions
    match = Onibi::Regexp.new("a??b").match("b")

    assert_equal "b", match[0]
  end

  def test_possessive_quantifier_does_not_backtrack
    refute Onibi::Regexp.new("a++a").match?("aaa")
    assert Onibi::Regexp.new("a++").match?("aaa")
  end

  def test_possessive_bounded_quantifier_does_not_backtrack
    regexp = Onibi::Regexp.new("a{1,3}+a")

    assert regexp.match?("aaa")
    assert regexp.match?("aaaa")
    %w[aaa aaaa].each do |input|
      assert_equal Regexp.new("a{1,3}+a").match?(input), regexp.match?(input)
    end
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
end
