# frozen_string_literal: true

require_relative "../../test_helper"

class ClassRunSwarPolicyTest < Minitest::Test
  def test_class_run_uses_swar_only_for_long_enough_ascii_input
    run = Onibi::Experimental::Swar::ClassRun.new("a-z")

    refute run.profitable?("abc", 0)
    assert run.profitable?("abc" * 32, 0)
    assert_equal [0, 96, []], run.search("abc" * 32, 0, capture: true)
  end

  def test_dense_negated_class_is_eligible_for_long_ascii_runs
    run = Onibi::Experimental::Swar::ClassRun.new("^,\\n")
    input = "a" * 128

    assert run.profitable?(input, 0)
    assert_equal [0, 128, []], run.search(input, 0, capture: true)
  end
end
