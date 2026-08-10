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
end
