# frozen_string_literal: true

require "test_helper"

class MatchDataTest < Minitest::Test
  def test_match_data_exposes_full_match_captures_and_offsets
    match_data = Onibi::MatchData.new("abcd", ["bc"], [[0, 4], [1, 3]])

    assert_equal "abcd", match_data[0]
    assert_equal ["bc"], match_data.captures
    assert_equal 0, match_data.begin(0)
    assert_equal 3, match_data.end(1)
    assert_equal %w[abcd bc], match_data.to_a
  end

  def test_captureless_factory_preserves_match_data_contract
    match_data = Onibi::MatchData.captureless("xxcat", 2, 5, Onibi::Regexp.new("cat"))

    assert_equal "cat", match_data[0]
    assert_equal [], match_data.captures
    assert_equal [2, 5], match_data.offset(0)
    assert_equal "xx", match_data.pre_match
  end

  def test_offset_factory_preserves_match_data_contract
    regexp = Onibi::Regexp.new("(?<word>[a-z]+)")
    match_data = Onibi::MatchData.from_offsets("xxwordyy", 2, 6, [[2, 6]], { "word" => 1 }, regexp)

    assert_equal %w[word word], match_data.to_a
    assert_equal [2, 6], match_data.offset(:word)
    assert_equal regexp, match_data.regexp
  end

  def test_unmatched_capture_offset_is_a_pair_of_nil_values
    match_data = Onibi::Regexp.new("(?<prefix>a)?b").match("b")

    assert_equal [nil, nil], match_data.offset(:prefix)
    assert_nil match_data.begin(:prefix)
    assert_nil match_data.end(:prefix)
  end

  def test_match_returns_the_value_for_an_index_or_name
    match = Onibi::Regexp.new("(?<animal>cat)(dog)").match("catdog")

    assert_equal "catdog", match.match(0)
    assert_equal "cat", match.match(1)
    assert_equal "cat", match.match("animal")
    assert_equal "cat", match.match(:animal)
  end

  def test_inspect_includes_unnamed_capture_values
    expected = Regexp.new("(a)(b)?").match("ab").inspect
    actual = Onibi::Regexp.new("(a)(b)?").match("ab").inspect

    assert_equal expected, actual
  end

  def test_values_at_pads_ranges_past_capture_count
    match = Onibi::Regexp.new("(a)(b)?").match("a")

    assert_equal ["a", nil, nil, nil, nil], match.values_at(1..5)
    assert_equal [nil, nil, nil], match.values_at(5..7)
    assert_equal ["a", "a", nil], match.values_at(..2)
    assert_equal ["a", nil], match.values_at(1..)
  end

  def test_offsets_report_unknown_group_names_as_index_errors
    match = Onibi::Regexp.new("(?<name>a)").match("a")

    assert_raises(IndexError) { match.begin("missing") }
    assert_raises(IndexError) { match.offset(:missing) }
  end
end
