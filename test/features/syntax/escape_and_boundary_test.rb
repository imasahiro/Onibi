# frozen_string_literal: true

require "test_helper"

class EscapeAndBoundaryTest < Minitest::Test
  def test_negated_digit_and_word_shorthand_classes
    assert Onibi::Regexp.new("\\D").match?("x")
    refute Onibi::Regexp.new("\\D").match?("7")
    assert Onibi::Regexp.new("\\W").match?("-")
    refute Onibi::Regexp.new("\\W").match?("_")
  end

  def test_word_shorthand_is_ascii_only_like_ruby
    regexp = Onibi::Regexp.new("\\w")

    assert regexp.match?("_")
    assert regexp.match?("7")
    refute regexp.match?("あ")
  end

  def test_hex_and_non_hex_shorthand_classes
    { "\\h" => %w[a F], "\\H" => %W[g \n] }.each do |source, inputs|
      inputs.each { |input| assert Onibi::Regexp.new(source).match?(input) }
    end
    refute Onibi::Regexp.new("\\h").match?("g")
    refute Onibi::Regexp.new("\\H").match?("F")
  end

  def test_non_space_shorthand_classes
    assert Onibi::Regexp.new("\\S").match?("x")
    refute Onibi::Regexp.new("\\S").match?(" ")
  end

  def test_linebreak_shorthand_matches_crlf_as_one_linebreak
    regexp = Onibi::Regexp.new("\\R")

    assert_equal "\r\n", regexp.match("x\r\nyy")[0]
    assert_equal "\n", regexp.match("x\nyy")[0]
    refute regexp.match?("x")
  end

  def test_grapheme_escape_matches_extended_clusters
    ["a\u0301", "🇯🇵", "क्\u200dष", "👩‍🚀"].each do |input|
      expected = Regexp.new("\\X").match(input)
      actual = Onibi::Regexp.new("\\X").match(input)
      assert_equal expected[0], actual[0], input.inspect
      assert_equal expected.offset(0), actual.offset(0), input.inspect
    end
  end

  def test_word_boundaries
    assert Onibi::Regexp.new("\\bcat\\b").match?("a cat!")
    refute Onibi::Regexp.new("\\bcat\\b").match?("scatter")
    assert Onibi::Regexp.new("\\Bcat\\B").match?("scatter")
    refute Onibi::Regexp.new("\\Bcat\\B").match?("a cat!")
  end

  def test_start_match_anchor
    assert Onibi::Regexp.new("\\Gcat").match?("cat nap")
    refute Onibi::Regexp.new("\\Gcat").match?("a cat")
  end

  def test_meta_escape_matches_high_bit_ascii8bit_byte
    regexp = Onibi::Regexp.new("\\M-a".b)

    assert regexp.match?([0xe1].pack("C*").b)
    refute regexp.match?([0xe2].pack("C*").b)
  end

  def test_meta_control_escape_matches_high_bit_control_byte
    regexp = Onibi::Regexp.new("\\M-\\C-A".b)

    assert regexp.match?([0x81].pack("C*").b)
    refute regexp.match?([0x01].pack("C*").b)
  end

  def test_meta_hex_escape_matches_high_bit_ascii8bit_byte
    regexp = Onibi::Regexp.new("\\M-\\x41".b)

    assert regexp.match?([0xc1].pack("C*").b)
    refute regexp.match?([0x41].pack("C*").b)
  end

  def test_meta_escape_rejects_utf8_patterns_that_produce_invalid_bytes
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\M-a") }
  end
end
