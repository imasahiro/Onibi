# frozen_string_literal: true

require "test_helper"

class SubexpressionCallTest < Minitest::Test
  def test_numbered_subexpression_call_reuses_a_capturing_group
    regexp = Onibi::Regexp.new("(a)\\g1")

    assert_equal "aa", regexp.match("aa")[0]
  end

  def test_named_subexpression_call_reuses_a_named_group
    regexp = Onibi::Regexp.new("(?<letter>a)\\g<letter>")

    assert_equal "aa", regexp.match("aa")[0]
  end

  def test_subexpression_call_updates_capture_span_at_call_site
    expected = Regexp.new("(?<pair>ab)\\g<pair>").match("abab")
    actual = Onibi::Regexp.new("(?<pair>ab)\\g<pair>").match("abab")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(1), actual.offset(1)
  end
end
