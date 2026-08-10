# frozen_string_literal: true

require "test_helper"

class InlineModifierTest < Minitest::Test
  def test_inline_ignorecase_modifier_applies_to_the_remaining_pattern
    assert Onibi::Regexp.new("(?i)cat").match?("CAT")
  end

  def test_inline_ignorecase_disable_modifier_turns_casefolding_off
    refute Onibi::Regexp.new("(?-i)cat", ["ignorecase"]).match?("CAT")
  end

  def test_scoped_ignorecase_modifier_can_wrap_the_entire_pattern
    assert Onibi::Regexp.new("(?i:cat)").match?("CAT")
  end
end
