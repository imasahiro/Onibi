# frozen_string_literal: true

require "test_helper"

class FixedIntervalOptionalSuffixTest < Minitest::Test
  def test_fixed_interval_question_mark_is_a_greedy_optional_exact_repeat
    [[2, 0..3], [9, 0..10]].each do |count, lengths|
      pattern = "a{#{count}}?"

      lengths.each do |length|
        assert_native_match(pattern, "a" * length)
      end
    end
  end

  def test_equal_range_question_mark_stays_a_lazy_exact_repeat
    [[2, 0..3], [9, 0..10]].each do |count, lengths|
      pattern = "a{#{count},#{count}}?"

      lengths.each do |length|
        assert_native_match(pattern, "a" * length)
      end
    end
  end

  def test_equal_range_lazy_repeat_keeps_exact_sequence_semantics
    [2, 9].each do |count|
      pattern = "a{#{count},#{count}}?a"

      ["", "a", "a" * count, "a" * (count + 1)].each do |subject|
        assert_native_match(pattern, subject)
      end
    end
  end

  def test_optional_exact_repeat_keeps_sequence_and_capture_semantics
    [2, 9].each do |count|
      pattern = "(a){#{count}}?a"

      ["", "a", "a" * count, "a" * (count + 1)].each do |subject|
        assert_native_match(pattern, subject)
      end
    end
  end

  def test_optional_exact_repeat_keeps_nullable_capture_semantics
    [2, 9].each do |count|
      pattern = "(a?){#{count}}?"

      ["", "a", "a" * count].each do |subject|
        assert_native_match(pattern, subject)
      end
    end
  end

  private

  def assert_native_match(pattern, subject)
    expected = ::Regexp.new(pattern).match(subject)
    actual = Onibi::Regexp.new(pattern).match(subject)

    if expected.nil?
      assert_nil actual, [pattern, subject.length]
      return
    end

    assert_equal expected.to_a, actual&.to_a, [pattern, subject.length]
    assert_equal expected.offset(0), actual&.offset(0), [pattern, subject.length]

    (1...expected.size).each do |index|
      assert_equal expected.offset(index), actual&.offset(index), [pattern, subject.length, index]
    end
  end
end
