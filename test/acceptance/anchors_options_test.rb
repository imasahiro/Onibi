# frozen_string_literal: true

require "test_helper"

class AnchorsOptionsTest < Minitest::Test
  def test_anchors_match_whole_input
    assert Onibi::Regexp.new("^cat$").match?("cat")
    refute Onibi::Regexp.new("^cat$").match?("wildcat")
  end

  def test_case_insensitive_option
    assert Onibi::Regexp.new("cat", ["ignorecase"]).match?("A CAT")
  end

  def test_multiline_option
    assert Onibi::Regexp.new("^cat$", ["multiline"]).match?("dog\ncat\nbird")
  end
end
