# frozen_string_literal: true

require_relative "../../test_helper"

class ClassRunSwarBenchmarkTest < Minitest::Test
  def test_class_run_and_baseline_loop_have_identical_result
    input = ("abcxyz123" * 8).freeze
    run = Onibi::Experimental::Swar::ClassRun.new("a-z")
    expected = Onibi::ClassPredicates.compiled("a-z").matches?(input[0])

    assert_equal expected, !run.search(input, 0, capture: false).equal?(false)
    assert_equal [0, 6, []], run.search(input, 0, capture: true)
  end
end
