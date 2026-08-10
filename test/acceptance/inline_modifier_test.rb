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

  def test_scoped_multiline_modifier_applies_dot_all_only_inside_group
    regexp = Onibi::Regexp.new("a(?m:.)b")

    assert regexp.match?("a\nb")
    refute Onibi::Regexp.new("a(?m:.)c.").match?("a\nb\n")
  end

  def test_scoped_extended_modifier_ignores_whitespace_and_comments_only_inside_group
    regexp = Onibi::Regexp.new("a(?x: b # inner comment\n c )d")

    assert regexp.match?("abcd")
    refute regexp.match?("a bcd")
  end

  def test_scoped_extended_disable_preserves_whitespace_and_comments_inside_group
    regexp = Onibi::Regexp.new("a(?-x: b#c )d", ["extended"])

    assert regexp.match?("a b#c d")
    refute regexp.match?("ab#cd")
  end

  def test_nested_negative_extended_scope_preserves_its_literal_whitespace
    regexp = Onibi::Regexp.new("(?x:(?-x: a b ) c)")

    assert regexp.match?(" a b c")
    refute regexp.match?("a b c")
  end

  def test_scoped_combined_ignorecase_and_multiline_modifiers
    regexp = Onibi::Regexp.new("(?im:a.)")
    disabled = Onibi::Regexp.new("(?-im:a.)", ["ignorecase", "multiline"])
    extended = Onibi::Regexp.new("(?imx: a # scoped comment\n)")

    assert regexp.match?("A\n")
    refute disabled.match?("A\n")
    assert extended.match?("A")
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

  def test_supported_modifier_scopes_match_mri
    cases = [
      ["(?i:cat)dog", 0, "CATdog"],
      ["(?-i:cat)dog", Regexp::IGNORECASE, "CATdog"],
      ["a(?m:.)b", 0, "a\nb"],
      ["(?-m:a.)", Regexp::MULTILINE, "a\n"],
      ["(?x:a b # comment\n c)", 0, "abc"],
      ["(?-x:a b#c )", Regexp::EXTENDED, "a b#c "],
      ["(?imx:a . # comment\n)", 0, "A\n"],
      ["(?-imx:a .)", Regexp::IGNORECASE | Regexp::MULTILINE | Regexp::EXTENDED, "A\n"]
    ]

    cases.each do |source, options, input|
      mri_options = Regexp.new(source, options)
      onibi_options = option_names(options)

      assert_equal mri_options.match?(input), Onibi::Regexp.new(source, onibi_options).match?(input), source
    end
  end

  private

  def option_names(options)
    names = []
    names << "ignorecase" if (options & Regexp::IGNORECASE).positive?
    names << "multiline" if (options & Regexp::MULTILINE).positive?
    names << "extended" if (options & Regexp::EXTENDED).positive?
    names
  end
end
