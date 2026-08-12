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

  def test_dense_negated_class_matches_mri
    pattern = "[^,\\n]+"
    input = "#{"a" * 128},tail"
    expected = ::Regexp.new(pattern).match(input)
    actual = Onibi::Regexp.new(pattern).match(input)

    assert_equal [expected[0], expected.offset(0)], [actual[0], actual.offset(0)]
  end
end
