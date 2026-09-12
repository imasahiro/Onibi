# frozen_string_literal: true

require "test_helper"

class RawMatchResultTest < Minitest::Test
  CASES = [
    ["regular", "abc", "xxabc", 0, [[2, 5]]],
    ["tagged", "^(a*)(a*)", "aaa", 1, [[0, 3], [0, 3], [3, 3]]],
    ["dynamic", "(a+)\\1", "zaaaa", 2, [[1, 5], [1, 3]]]
  ].freeze

  def test_each_executor_returns_one_raw_match_shape
    CASES.each do |name, pattern, subject, exec_kind, ranges|
      info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)

      assert_equal 1, info[:status], name
      assert_equal exec_kind, info[:exec_kind], name
      assert_equal ranges.length, info[:raw_num_regs], name
      assert_equal ranges, info[:raw_registers], name
      assert_equal ranges.first.first, info[:match_start], name
      assert_equal ranges.first.last, info[:match_end], name
      assert_equal ranges.drop(1), info[:captures], name
    end
  end

  def test_no_match_resets_raw_ranges
    info = Onibi::Regexp.new("(a)\\1").send(:__onibi_diagnostics__, "aba")

    assert_equal 0, info[:status]
    assert_equal [[-1, -1], [-1, -1]], info[:raw_registers]
  end
end
