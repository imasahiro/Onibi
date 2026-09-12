# frozen_string_literal: true

require "test_helper"
require "timeout"

class WorkBudgetPollTest < Minitest::Test
  def test_each_native_executor_polls_inside_one_candidate
    cases = [
      ["a*", "a" * 300, 0],
      ["(?=a*)a*b", "a" * 300, 1],
      ["(?<x>a+)\\k<x>z", "a" * 300, 2]
    ]

    cases.each do |pattern, subject, execution_kind|
      info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)
      assert_equal execution_kind, info[:exec_kind], pattern
      assert_operator info[:poll_count], :>, 0, pattern
      assert_operator info[:work_charged], :>=, 128, pattern
      assert_operator info[:max_charged_work], :<=, 128, pattern
      assert_equal 0, info[:fallback], pattern
    end
  end

  def test_long_backreference_uses_bounded_charges
    subject = "#{"a" * 512}z"
    info = Onibi::Regexp.new("(?<x>a{256})\\k<x>z").send(
      :__onibi_diagnostics__, subject
    )

    assert_equal 2, info[:exec_kind]
    assert_equal 1, info[:status]
    assert_operator info[:poll_count], :>, 0
    assert_operator info[:max_charged_work], :<=, 128
    assert_equal 0, info[:fallback]
  end

  def test_casefold_backreference_polls_with_reloaded_subject_offsets
    subject = "#{"A" * 128}z"
    pattern = "(?i:(?<x>a{64})\\k<x>)z"
    info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)

    assert_equal 2, info[:exec_kind]
    assert_equal 1, info[:status]
    assert_operator info[:poll_count], :>, 0
    assert_operator info[:max_charged_work], :<=, 128
    assert_equal 0, info[:fallback]
  end

  def test_regular_timeout_interrupts_one_candidate
    input = "a" * 20_000_000
    regexp = Onibi::Regexp.new("a*", timeout: 0.001)

    assert_raises(Onibi::Regexp::TimeoutError) { regexp.match?(input) }

    regexp = Onibi::Regexp.new("a*")
    assert_raises(Interrupt) do
      Timeout.timeout(0.01, Interrupt) { regexp.match?(input) }
    end
  end
end
