# frozen_string_literal: true

require "test_helper"

class ConditionalGroupTest < Minitest::Test
  def test_conditional_group_selects_yes_branch_when_capture_matched
    regexp = Onibi::Regexp.new("(a)?(?(1)b|c)")

    assert_equal "ab", regexp.match("ab")[0]
  end

  def test_conditional_group_selects_no_branch_when_capture_unmatched
    regexp = Onibi::Regexp.new("(a)?(?(1)b|c)")

    assert_equal "c", regexp.match("c")[0]
  end

  def test_named_conditional_group_selects_branch_from_named_capture
    regexp = Onibi::Regexp.new("(?<letter>a)?(?(<letter>)b|c)")

    assert_equal "ab", regexp.match("ab")[0]
    assert_equal "c", regexp.match("c")[0]
  end

  def test_conditional_group_executes_an_alternating_yes_branch
    regexp = Onibi::Regexp.new("(a)?(?(1)(b|c)|d)")

    assert_equal %w[ab a b], regexp.match("ab").to_a
    assert_equal %w[ac a c], regexp.match("ac").to_a
  end

  def test_nested_nullable_capture_keeps_unset_conditional_candidate
    source = "([ab]?)?(?(1)s+|.+)"
    %w[a b c ab].each do |input|
      expected = ::Regexp.new(source).match(input)
      actual = Onibi::Regexp.new(source).match(input)
      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end
end
