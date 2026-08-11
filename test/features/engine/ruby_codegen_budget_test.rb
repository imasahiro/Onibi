# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenBudgetTest < Minitest::Test
  def test_budget_counts_steps_and_raises_on_limit
    budget = Onibi::Codegen::ExecutionBudget.new(limit: 2)

    budget.consume!
    budget.consume!
    assert_raises(Onibi::Regexp::TimeoutError) { budget.consume! }
    assert_equal 3, budget.steps
  end
end
