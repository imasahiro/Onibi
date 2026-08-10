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

  def test_unmatched_capture_offset_is_a_pair_of_nil_values
    match_data = Onibi::Regexp.new("(?<prefix>a)?b").match("b")

    assert_equal [nil, nil], match_data.offset(:prefix)
    assert_nil match_data.begin(:prefix)
    assert_nil match_data.end(:prefix)
  end
end
