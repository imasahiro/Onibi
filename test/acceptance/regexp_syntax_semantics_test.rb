# frozen_string_literal: true

require "test_helper"

class RegexpSyntaxSemanticsTest < Minitest::Test
  def test_dot_excludes_newline_unless_multiline_is_enabled
    refute Onibi::Regexp.new(".").match?("\n")
    assert Onibi::Regexp.new(".", ["multiline"]).match?("\n")
  end

  def test_line_anchors_are_line_anchors_regardless_of_multiline_option
    regexp = Onibi::Regexp.new("^cat$", ["multiline"])

    assert regexp.match?("dog\ncat\nbird")
    assert regexp.match?("cat\ndog")
  end

  def test_absolute_anchors_distinguish_final_newline
    assert Onibi::Regexp.new("\\Acat\\Z").match?("cat\n")
    refute Onibi::Regexp.new("\\Acat\\z").match?("cat\n")
    refute Onibi::Regexp.new("\\Acat\\Z").match?("xcat\n")
  end

  def test_open_upper_bound_quantifier_defaults_to_zero_minimum
    regexp = Onibi::Regexp.new("\\Aa{,3}\\z")

    assert regexp.match?("")
    assert regexp.match?("aaa")
    refute regexp.match?("aaaa")
  end
end
