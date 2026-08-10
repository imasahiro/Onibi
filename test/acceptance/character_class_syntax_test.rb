# frozen_string_literal: true

require "test_helper"

class CharacterClassSyntaxTest < Minitest::Test
  def test_nested_character_class_is_a_union
    regexp = Onibi::Regexp.new("[a-z[0-9]]")

    assert regexp.match?("m")
    assert regexp.match?("7")
    refute regexp.match?("_")
  end

  def test_character_class_intersection_excludes_nested_range
    regexp = Onibi::Regexp.new("[a-w&&[^c-g]z]")

    assert regexp.match?("a")
    refute regexp.match?("d")
    assert regexp.match?("w")
    refute regexp.match?("y")
  end

  def test_escaped_hyphen_and_closing_bracket_are_literals
    regexp = Onibi::Regexp.new("[\\-\\]]")

    assert regexp.match?("-")
    assert regexp.match?("]")
    refute regexp.match?("a")
  end

  def test_unicode_property_escapes_inside_character_classes
    hiragana = Onibi::Regexp.new("[\\p{Hiragana}]")
    not_alpha = Onibi::Regexp.new("[\\P{Alpha}]")

    assert hiragana.match?("あ")
    refute hiragana.match?("A")
    assert not_alpha.match?("1")
    refute not_alpha.match?("A")
  end

  def test_caret_control_escapes_inside_character_classes
    regexp = Onibi::Regexp.new("[\\cA\\C-B]")

    assert regexp.match?("\x01")
    assert regexp.match?("\x02")
    refute regexp.match?("A")
  end

  def test_meta_escapes_inside_ascii8bit_character_classes
    literal = Onibi::Regexp.new("[\\M-a]".b)
    control = Onibi::Regexp.new("[\\M-\\C-A]".b)
    hex = Onibi::Regexp.new("[\\M-\\x41]".b)

    assert literal.match?([0xe1].pack("C*").b)
    assert control.match?([0x81].pack("C*").b)
    assert hex.match?([0xc1].pack("C*").b)
  end
end
