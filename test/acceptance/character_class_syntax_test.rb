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
end
