# frozen_string_literal: true

require "test_helper"

class MatchDataIndexTest < Minitest::Test
  def test_match_value_access_coerces_integer_like_indices_and_rejects_unknown_names
    match = Onibi::Regexp.new("(?<animal>cat)").match("cat")

    assert_equal "cat", match[0.9]
    assert_equal ["cat"], match.values_at(0.9)
    assert_raises(IndexError) { match["unknown"] }
    assert_raises(IndexError) { match.values_at("unknown") }
    assert_raises(TypeError) { match[nil] }
  end

  def test_match_value_access_returns_nil_beyond_negative_capture_range
    match = Onibi::Regexp.new("(a)(b)").match("ab")

    assert_nil match[-3]
    assert_equal [nil], match.values_at(-3)
    assert_equal "a", match[-2]
  end

  def test_match_value_access_supports_mri_slice_form
    expected = Regexp.new("(a)(?<animal>b)?").match("ab")
    actual = Onibi::Regexp.new("(a)(?<animal>b)?").match("ab")

    assert_equal expected[0, 2], actual[0, 2]
    assert_equal expected[1, 2], actual[1, 2]
    assert_equal expected[0..1], actual[0..1]
    assert_equal expected[0, nil], actual[0, nil]
    assert_nil actual[5, 1]
  end

  def test_match_values_at_normalizes_negative_range_bounds
    match = Onibi::Regexp.new("(a)(b)").match("ab")

    assert_equal %w[a b], match.values_at(1..-1)
    assert_equal %w[ab a b], match.values_at(-3..-1)
    assert_raises(RangeError) { match.values_at(-4..-1) }
  end

  def test_match_uses_integer_or_name_indices_only
    match = Onibi::Regexp.new("(?<x>a)(b)?").match("a")

    assert_raises(TypeError) { match.match(0..1) }
    assert_raises(TypeError) { match.match([0, 1]) }
    assert_raises(TypeError) { match.match(nil) }
    assert_raises(IndexError) { match.match(-1.2) }
    assert_raises(TypeError) { match[[0, 1]] }
    assert_raises(TypeError) { match.values_at([0, 1]) }
    assert_equal %w[a a], match[0..1]
  end

  def test_offsets_coerce_float_indices_like_mri
    match = Onibi::Regexp.new("(?<x>é)").match("é")

    assert_equal [0, 1], match.offset(0.9)
    assert_equal [0, 2], match.byteoffset(0.9)
    assert_equal 0, match.begin(-0.1)
  end
end
