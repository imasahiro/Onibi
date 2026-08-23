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
  end
end
