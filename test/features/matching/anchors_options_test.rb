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

  def test_line_start_does_not_match_the_empty_line_after_a_final_newline
    pattern = "^\\z"
    input = "a\n"

    assert_nil ::Regexp.new(pattern).match(input)
    assert_nil Onibi::Regexp.new(pattern).match(input)
  end
end
