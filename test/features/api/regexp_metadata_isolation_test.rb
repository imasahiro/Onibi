# frozen_string_literal: true

require "test_helper"

class RegexpMetadataIsolationTest < Minitest::Test
  def test_empty_metadata_getters_are_fresh_and_mutable
    regexp = Onibi::Regexp.new("abc")
    names = regexp.names
    later_names = regexp.names
    captures = regexp.named_captures
    later_captures = regexp.named_captures

    refute_same names, later_names
    refute_same captures, later_captures
    refute names.frozen?
    refute captures.frozen?

    names << "new"
    captures["new"] = [1]

    assert_equal [], regexp.names
    assert_equal({}, regexp.named_captures)
    assert_equal [], later_names
    assert_equal({}, later_captures)
  end

  def test_names_copy_nested_strings_without_changing_native_matching
    regexp = Onibi::Regexp.new("(?<x>é)")
    other = Onibi::Regexp.new("(?<x>é)")
    names = regexp.names
    later_names = regexp.names

    refute_same names, later_names
    refute_same names.first, later_names.first
    refute names.frozen?
    refute names.first.frozen?
    assert_equal Encoding::UTF_8, names.first.encoding

    names.first << "_changed"
    names << "new"

    assert_equal ["x"], later_names
    assert_equal ["x"], regexp.names
    assert_equal ["x"], other.names
    assert_equal Encoding::UTF_8, regexp.names.first.encoding

    info = regexp.send(:__onibi_diagnostics__, "é")
    assert_equal 1, info[:status]
    assert_equal 0, info[:fallback]
    assert_equal 1, info[:regular]
    assert_equal [[0, 2]], info[:captures]
  end

  def test_named_capture_copies_keep_duplicate_indices_and_native_matching
    regexp = Onibi::Regexp.new("(?<x>a)(?<x>b)")
    other = Onibi::Regexp.new("(?<x>a)(?<x>b)")
    captures = regexp.named_captures
    later_captures = regexp.named_captures

    refute_same captures, later_captures
    refute_same captures["x"], later_captures["x"]
    assert_same captures.keys.first, later_captures.keys.first
    assert captures.keys.first.frozen?
    refute captures.frozen?
    refute captures["x"].frozen?

    captures["x"] << 99
    captures["new"] = [3]

    assert_equal({ "x" => [1, 2] }, later_captures)
    assert_equal({ "x" => [1, 2] }, regexp.named_captures)
    assert_equal({ "x" => [1, 2] }, other.named_captures)

    info = regexp.send(:__onibi_diagnostics__, "ab")
    assert_equal 1, info[:status]
    assert_equal 0, info[:fallback]
    assert_equal 1, info[:regular]
    assert_equal [[0, 1], [1, 2]], info[:captures]
  end

  def test_metadata_matches_mri_mutability_and_encoding
    expected = ::Regexp.new("(?<x>é)")
    actual = Onibi::Regexp.new("(?<x>é)")

    assert_equal expected.names, actual.names
    assert_equal expected.named_captures, actual.named_captures
    assert_equal expected.names.first.encoding, actual.names.first.encoding
    assert_equal expected.named_captures.keys.first.encoding,
                 actual.named_captures.keys.first.encoding
    refute actual.names.frozen?
    refute actual.named_captures.frozen?
    refute actual.names.first.frozen?
    refute actual.named_captures.values.first.frozen?
    assert actual.named_captures.keys.first.frozen?
  end
end
