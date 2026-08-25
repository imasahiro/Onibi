# frozen_string_literal: true

require "test_helper"

class RegexpSyntaxSemanticsTest < Minitest::Test
  def test_common_control_character_escapes_match_their_literal_characters
    { "n" => "\n", "r" => "\r", "t" => "\t", "f" => "\f", "v" => "\v", "a" => "\a",
      "e" => "\e" }.each do |escape, character|
      assert Onibi::Regexp.new("\\#{escape}").match?(character), escape
    end
  end

  def test_hex_and_unicode_escapes_match_literal_characters
    assert Onibi::Regexp.new("\\x41").match?("A")
    assert Onibi::Regexp.new("\\u0041").match?("A")
    assert Onibi::Regexp.new("\\u{1F600}").match?("😀")
    assert Onibi::Regexp.new("\\u{41 42}").match?("AB")
  end

  def test_octal_escapes_match_the_encoded_byte
    assert Onibi::Regexp.new("\\0").match?("\0")
    assert Onibi::Regexp.new("\\01").match?("\x01")
    assert Onibi::Regexp.new("\\101").match?("A")
    assert Onibi::Regexp.new("\\141").match?("a")
  end

  def test_invalid_hex_and_unicode_escapes_raise_regexp_error
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\x") }
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\u12") }
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\u{}") }
  end

  def test_short_multibyte_hex_escape_matches_mri_error
    error = assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\xE9") }

    assert_equal "too short escaped multibyte character: /\\xE9/", error.message
  end

  def test_trailing_escape_error_matches_mri
    error = assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\") }

    assert_equal "too short escape sequence: /\\/", error.message
  end

  def test_character_classes_decode_literal_escape_sequences
    assert Onibi::Regexp.new("[\\x41]").match?("A")
    assert Onibi::Regexp.new("[\\n]").match?("\n")
    assert Onibi::Regexp.new("[\\u{1F600}]").match?("😀")
  end

  def test_control_escapes_match_control_characters
    assert Onibi::Regexp.new("\\cA").match?("\x01")
    assert Onibi::Regexp.new("\\C-A").match?("\x01")
  end

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
