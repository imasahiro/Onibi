# frozen_string_literal: true

require "test_helper"

class DfaBudgetTest < Minitest::Test
  def test_zero_budget_retains_no_specialization_and_preserves_results
    Onibi::Regexp.dfa_memory_budget = 0
    regexp = Onibi::Regexp.new("ab+")

    assert regexp.match?("xxabbb")
    assert_nil regexp.instance_variable_get(:@dfa_specialization)
  ensure
    Onibi::Regexp.dfa_memory_budget = 1
  end
end
