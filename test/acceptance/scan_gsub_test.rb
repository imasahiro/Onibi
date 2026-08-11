# frozen_string_literal: true

require "test_helper"

class ScanGsubTest < Minitest::Test
  CASES = [
    ["a+", "baacaa"],
    ["(\\w+)=(\\d+)", "x=10 y=20"],
    ["(?<key>\\w+):(?<value>\\d+)", "x:10 y:20"],
    ["", "ab"]
  ].freeze

  def test_scan_matches_mri_without_a_block
    CASES.each do |pattern, input|
      expected = input.scan(::Regexp.new(pattern))

      assert_equal expected, Onibi::Regexp.new(pattern).scan(input), pattern
    end
  end

  def test_scan_yields_mri_compatible_values_and_returns_input
    pattern = Onibi::Regexp.new("(\\w+)=(\\d+)")
    expected = []
    returned = "x=10 y=20".scan(/(\w+)=(\d+)/) { |value| expected << value }
    actual = []
    actual_returned = pattern.scan("x=10 y=20") { |value| actual << value }

    assert_equal expected, actual
    assert_equal "x=10 y=20", returned
    assert_equal "x=10 y=20", actual_returned
  end

  def test_gsub_matches_mri_with_string_replacement
    [
      ["a+", "baacaa", "<\\0>"],
      ["(\\w+)=(\\d+)", "x=10 y=20", '\\2:\\1'],
      ["(?<key>\\w+):(?<value>\\d+)", "x:10 y:20", '\\k<value>=\\k<key>']
    ].each do |pattern, input, replacement|
      expected = input.gsub(::Regexp.new(pattern), replacement)

      assert_equal expected, Onibi::Regexp.new(pattern).gsub(input, replacement), pattern
    end

    replacement = "\\1-\\2-\\+-\\&-\\0-\\`-\\'-\\\\"
    expected = "a".gsub(/(a)(b)?/, replacement)

    assert_equal expected, Onibi::Regexp.new("(a)(b)?").gsub("a", replacement)
  end

  def test_gsub_yields_mri_compatible_match_strings
    expected = []
    "x=10 y=20".gsub(/(\w+)=(\d+)/) { |value| expected << value; value.upcase }

    actual = []
    result = Onibi::Regexp.new("(\\w+)=(\\d+)").gsub("x=10 y=20") do |value|
      actual << value
      value.upcase
    end

    assert_equal expected, actual
    assert_equal "X=10 Y=20", result
  end

  def test_gsub_matches_mri_for_empty_matches_and_block_coercion
    expected = "ab".gsub(//) { nil }
    actual = Onibi::Regexp.new("").gsub("ab") { nil }

    assert_equal expected, actual
    assert_equal "1", Onibi::Regexp.new("a").gsub("a") { 1 }
  end

  def test_gsub_rejects_an_explicit_nil_replacement_like_mri
    error = assert_raises(TypeError) { Onibi::Regexp.new("a").gsub("a", nil) }
    mri_error = assert_raises(TypeError) { "a".gsub(/a/, nil) }
    assert_equal mri_error.class, error.class
    assert_match(/String/, error.message)
  end
end
