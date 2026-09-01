# frozen_string_literal: true

require "test_helper"
require "timeout"
require_relative "../../support/differential_harness"

class GirSemanticRegressionTest < Minitest::Test
  def test_subexpression_calls_keep_definition_site_options
    assert_match_differential("(?i:(?<x>a))(?-i:\\g<x>)", "aA")
    assert_match_differential("(?-i:(?<x>a))(?i:\\g<x>)", "aA")
  end

  def test_match_reset_is_transactional_across_alternatives
    assert_match_differential("(?:a\\Kx|ab)", "ab")
    assert_match_differential("(?:a\\Kb|ab)", "ab")
  end

  def test_utf8_lowercase_property_matches_mri
    assert_match_differential("\\p{Lower}", "é")
  end

  def test_utf8_alphabetic_property_matches_mri
    assert_match_differential("\\p{Alpha}", "あ")
  end

  def test_utf8_word_property_matches_mri
    assert_match_differential("\\p{Word}", "あ")
  end

  def test_word_boundaries_use_multibyte_character_classes
    [["\\Bx", "éx"], ["x\\B", "xあ"], ["\\bあ\\b", " あ "]].each do |pattern, input|
      assert_match_differential(pattern, input)
    end
  end

  def test_public_match_positions_use_character_offsets
    assert_match_differential("éx", "あéx")
    assert_match_differential("éx", "あéx", position: 1)
  end

  def test_scan_slices_multibyte_matches_by_byte_range
    input = "xéあy"
    pattern = "[éあ]"

    assert_equal input.scan(::Regexp.new(pattern)), Onibi::Regexp.new(pattern).scan(input)
  end

  def test_gsub_slices_multibyte_matches_by_byte_range
    input = "xéあy"
    pattern = "[éあ]"

    expected = input.gsub(::Regexp.new(pattern)) { |value| "<#{value}>" }
    actual = Onibi::Regexp.new(pattern).gsub(input) { |value| "<#{value}>" }
    assert_equal expected, actual
  end

  def test_nullable_large_repeat_terminates_with_mri_capture_state
    assert_match_differential("(a?){9}", "aaaa")
  end

  def test_greedy_and_lazy_repeats_keep_mri_capture_priority
    assert_match_differential("(a*)(a*)", "aaa")
    assert_match_differential("(a*?)(a*)", "aaa")
  end

  def test_converging_repeat_paths_keep_distinct_counter_state
    assert_match_differential("(?:aa|a){9,10}b", "aaaaaaaaaab")
  end

  def test_timeout_stops_one_long_anchored_candidate
    skip "MRI regexp timeout is not available" unless defined?(::Regexp::TimeoutError)

    input = "a" * 20_000_000
    pattern = "\\Aa*\\z"

    expected = assert_raises(::Regexp::TimeoutError) do
      ::Regexp.new(pattern, timeout: 0.001).match?(input)
    end
    actual = assert_raises(Onibi::Regexp::TimeoutError) do
      Onibi::Regexp.new(pattern, timeout: 0.001).match?(input)
    end

    assert_equal expected.message, actual.message
  end

  def test_interrupt_stops_one_long_anchored_candidate
    input = "a" * 20_000_000
    regexp = Onibi::Regexp.new("\\Aa*\\z")

    assert_raises(Interrupt) do
      Timeout.timeout(0.01, Interrupt) { regexp.match?(input) }
    end
  end

  private

  def assert_match_differential(pattern, input, position: :absent)
    fixture = {
      name: "#{pattern.inspect} on #{input.inspect}",
      pattern: pattern,
      options: nil,
      input: input,
      operation: :match
    }
    fixture[:position] = position unless position == :absent
    result = DifferentialHarness.compare(fixture)

    assert result.fetch(:equal), result.fetch(:message)
  end
end
