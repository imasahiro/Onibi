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
end
