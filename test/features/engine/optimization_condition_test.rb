# frozen_string_literal: true

require_relative "../../test_helper"

class OptimizationConditionTest < Minitest::Test
  def test_input_mode_has_one_source_of_truth_for_ascii_and_byte_paths
    regexp = Onibi::Regexp.new("(?~END)")

    assert_equal [true, false], regexp.send(:hfa_input_mode, "payload")
    assert_equal [false, true], regexp.send(:hfa_input_mode, "日本語")
  end

  def test_literal_absence_match_question_preserves_ascii_and_unicode_results
    regexp = Onibi::Regexp.new("(?~END)")

    assert regexp.match?("payload")
    assert regexp.match?("日本語")
  end

  def test_literal_absence_scan_preserves_ascii_and_unicode_results
    regexp = Onibi::Regexp.new("(?~END)")

    assert_equal ["payload", ""], regexp.scan("payload")
    assert_equal ["日本語EN", "D", ""], regexp.scan("日本語END")
  end
end
