# frozen_string_literal: true

require "test_helper"

class MatchDataValueSemanticsTest < Minitest::Test
  def payload(source, subject, ranges, options = 0)
    regexp = Onibi::Regexp.new(source, options)
    Onibi::MatchData.send(:__onibi_new__, regexp, subject, ranges)
  end

  def ranges_for(source, subject, options = 0)
    match = ::Regexp.new(source, options).match(subject)
    match.length.times.map do |index|
      begin_offset, end_offset = match.offset(index)
      begin_offset.nil? ? [-1, -1] : [begin_offset, end_offset]
    end
  end

  def test_inspect_matches_mri_for_numeric_named_nil_and_empty_captures
    [
      ["(a)(b)?", "a"],
      ["(?<x>a)(?<x>b)?", "a"],
      ["(?<empty>)(?<missing>a)?", ""]
    ].each do |source, subject|
      expected = ::Regexp.new(source).match(subject)
      actual = payload(source, subject, ranges_for(source, subject))
      assert_equal expected.inspect, actual.inspect
    end
  end

  def test_equality_and_hash_use_owned_snapshot_regexp_and_registers
    source = "(?<x>a)(b)?"
    ranges = ranges_for(source, "a")
    first = payload(source, "a", ranges)
    equal = payload(source.dup, "a".dup, ranges.map(&:dup))
    different_subject = payload(source, "b", [[0, 1], [-1, -1], [-1, -1]])
    different_ranges = payload(source, "a", [[0, 1], [-1, -1], [0, 1]])
    different_regexp = payload(source, "a", ranges, Regexp::IGNORECASE)

    assert_equal first, equal
    assert first.eql?(equal)
    assert_equal first.hash, equal.hash
    refute_equal first, different_subject
    refute_equal first, different_ranges
    refute_equal first, different_regexp
    refute_equal first, Object.new
    refute first.eql?(nil)
  end

  def test_value_methods_ignore_mutated_public_getters_and_gc_compaction
    source = "(?<x>a)(b)?"
    match_data = payload(source, "a", ranges_for(source, "a"))
    expected_inspect = match_data.inspect
    expected_hash = match_data.hash

    match_data.to_a[0].replace("changed")
    match_data.captures << "changed"
    match_data.names << "changed"
    match_data.named_captures["x"].replace("changed")
    GC.start
    GC.compact

    assert_equal expected_inspect, match_data.inspect
    assert_equal expected_hash, match_data.hash
    assert_equal match_data, match_data
  end
end
