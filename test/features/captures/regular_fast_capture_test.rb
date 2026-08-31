# frozen_string_literal: true

require "test_helper"

class RegularFastCaptureTest < Minitest::Test
  CASES = [
    ["(a)", "a"], ["((a)b)", "zab"], ["(a)?b", "ab"],
    ["(a)?b", "b"], ["(a)|(b)", "a"], ["(a)|(b)", "b"],
    ["(a|ab)", "ab"], ["(a*)", "aaa"], ["(a*?)a", "aaa"],
    ["(a)+", "aaa"], ["()", ""], ["(a?)", ""]
  ].freeze

  def test_raw_capture_ranges_match_mri
    CASES.each do |pattern, subject|
      regexp = Onibi::Regexp.new(pattern)
      info = regexp.send(:__onibi_diagnostics__, subject)
      expected = Regexp.new(pattern).match(subject)
      expected_ranges = expected ? expected.captures.each_index.map { |i| expected.offset(i + 1) } : []
      assert_equal 0, info[:exec_kind], pattern
      assert_equal 0, info[:dfs], pattern
      expected_ranges = expected_ranges.map { |range| range.all?(&:nil?) ? [-1, -1] : range }
      assert_equal expected_ranges, info[:captures], pattern
    end
  end
end
