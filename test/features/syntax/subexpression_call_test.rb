# frozen_string_literal: true

require "test_helper"

class SubexpressionCallTest < Minitest::Test
  def test_root_subexpression_recursion_reports_mri_error
    error = assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\g<0>") }

    assert_equal "never ending recursion: /\\g<0>/", error.message
  end

  def test_numbered_subexpression_call_reuses_a_capturing_group
    regexp = Onibi::Regexp.new("(a)\\g<1>")

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

  def test_subexpression_call_uses_definition_site_ignorecase
    pattern = "(?i:(?<letter>a))(?-i:\\g<letter>)"

    assert_equal Regexp.new(pattern).match("aA").to_a,
                 Onibi::Regexp.new(pattern).match("aA").to_a
  end

  def test_call_site_ignorecase_does_not_change_subexpression_definition
    pattern = "(?-i:(?<letter>a))(?i:\\g<letter>)"

    assert_nil Onibi::Regexp.new(pattern).match("aA")
    assert_equal Regexp.new(pattern).match("aa").to_a,
                 Onibi::Regexp.new(pattern).match("aa").to_a
  end
end
