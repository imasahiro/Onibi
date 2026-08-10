# frozen_string_literal: true

require "test_helper"

class ExtendedModeTest < Minitest::Test
  def test_extended_mode_ignores_whitespace_and_hash_comments
    pattern = "a b # middle comment\n c"

    assert Onibi::Regexp.new(pattern, ["extended"]).match?("abc")
  end

  def test_extended_mode_preserves_whitespace_inside_character_classes
    regexp = Onibi::Regexp.new("[ a]", ["extended"])

    assert regexp.match?(" ")
    assert regexp.match?("a")
  end

  def test_inline_extended_modifier_ignores_whitespace_and_comments
    assert Onibi::Regexp.new("(?x)a b # comment\n c").match?("abc")
  end

  def test_inline_extended_disable_modifier_preserves_whitespace
    refute Onibi::Regexp.new("(?-x)a b", ["extended"]).match?("ab")
  end
end
