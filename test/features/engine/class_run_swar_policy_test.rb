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

  def test_ascii8bit_input_uses_byte_semantics
    run = Onibi::Experimental::Swar::ClassRun.new("^,\\n")
    input = "#{"\xFF" * 128},tail".b

    assert run.profitable?(input, 0)
    assert_equal [0, 128, []], run.search(input, 0, capture: true)
  end

  def test_utf8_input_uses_logical_character_fallback
    run = Onibi::Experimental::Swar::ClassRun.new("a-z")

    refute run.profitable?("abcé", 0)
    assert_equal [0, 3, []], run.search("abcé", 0, capture: true)
  end

  def test_utf8_search_slices_at_explicit_character_position
    input = ClassRunPositionTrackingString.new("ééabc!")
    run = Onibi::Experimental::Swar::ClassRun.new("a-z")

    assert_equal [2, 5, []], run.search(input, 2, capture: true)
    assert(input.slices.any? { |arguments| arguments.first.is_a?(Range) && arguments.first.begin == 2 })
  end

  class ClassRunPositionTrackingString < String
    attr_reader :slices

    def initialize(value)
      super
      @slices = []
    end

    def [](*arguments)
      @slices << arguments
      super
    end
  end
end
