# frozen_string_literal: true

require "test_helper"

class CharacterClassTest < Minitest::Test
  def test_positive_negated_and_range_classes
    assert Onibi::Regexp.new("[abc]").match?("xby")
    assert Onibi::Regexp.new("[^a]").match?("xby")
    assert Onibi::Regexp.new("[a-z]").match?("xby")
    refute Onibi::Regexp.new("[a-z]").match?("123")
  end

  def test_core_character_escapes
    assert Onibi::Regexp.new("\\d+").match?("id=42")
    assert Onibi::Regexp.new("\\s").match?("a b")
    assert Onibi::Regexp.new("\\w+").match?("word_1")
  end
end
