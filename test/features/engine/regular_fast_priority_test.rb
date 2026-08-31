# frozen_string_literal: true

require "test_helper"

class RegularFastPriorityTest < Minitest::Test
  CASES = [["a|ab", "ab"], ["ab|a", "ab"], ["a*", "aaa"],
           ["a+", "aaa"], ["a*?a", "aaa"], ["a+?a", "aaa"],
           ["a{2,4}", "aaaa"], ["a{0,8}", "aaaa"]].freeze

  def test_ordered_frontier_matches_mri_ranges
    CASES.each do |pattern, subject|
      regexp = Onibi::Regexp.new(pattern)
      info = regexp.send(:__onibi_diagnostics__, subject)
      expected = Regexp.new(pattern).match(subject)
      expected_range = expected ? [expected.begin(0), expected.end(0)] : nil
      assert_equal 0, info[:exec_kind], pattern
      assert_equal 0, info[:dfs], pattern
      assert_equal 0, info[:fallback], pattern
      assert_equal expected_range, [info[:match_start], info[:match_end]], pattern
    end
  end
end
