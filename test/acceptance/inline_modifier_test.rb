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

  def test_scoped_ignorecase_modifier_does_not_escape_its_group
    regexp = Onibi::Regexp.new("a(?i:bc)d")

    assert regexp.match?("aBCd")
    refute_nil regexp.match("aBCd")
    refute regexp.match?("ABCD")
  end

  def test_inline_multiline_modifier_enables_dot_all
    assert Onibi::Regexp.new("(?m).").match?("\n")
  end

  def test_inline_multiline_disable_modifier_turns_dot_all_off
    refute Onibi::Regexp.new("(?-m).", ["multiline"]).match?("\n")
  end

  def test_combined_inline_modifiers_enable_multiple_modes
    assert Onibi::Regexp.new("(?imx)a # comment\n").match?("A")
  end

  def test_combined_inline_modifiers_disable_multiple_modes
    regexp = Onibi::Regexp.new("(?-imx). a", %w[ignorecase multiline extended])

    refute regexp.match?("\n A")
  end
end
