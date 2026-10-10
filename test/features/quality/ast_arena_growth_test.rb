# frozen_string_literal: true

require "test_helper"

class AstArenaGrowthTest < Minitest::Test
  FLAT_CAPTURE_COUNTS = [10, 11, 40].freeze
  NESTED_CAPTURE_DEPTHS = [15, 16, 40].freeze

  def test_named_and_unnamed_captures_survive_arena_growth
    FLAT_CAPTURE_COUNTS.each do |count|
      subject = capture_subject(count)

      assert_native_capture_match(flat_capture_pattern(count, named: true),
                                  subject, "#{count} named captures")
      assert_native_capture_match(flat_capture_pattern(count, named: false),
                                  subject, "#{count} unnamed captures")
    end
  end

  def test_nested_captures_survive_arena_growth
    NESTED_CAPTURE_DEPTHS.each do |depth|
      opening_groups = "(" * depth
      closing_groups = ")" * depth
      pattern = "#{opening_groups}é#{closing_groups}"

      assert_native_capture_match(pattern, "xé!", "nested depth #{depth}")
    end
  end

  def test_conditional_implicit_no_branch_survives_arena_growth
    [2, 3, 4].each do |prefix_length|
      prefix = "x" * prefix_length
      capture_groups = "(b)" * 7
      subject_captures = "b" * 7
      subject = "#{prefix}#{subject_captures}"
      pattern = "#{prefix}(a)?#{capture_groups}(?(1)c)"

      assert_native_capture_match(pattern, subject,
                                  "conditional prefix #{prefix_length}")
    end
  end

  private

  def capture_subject(count)
    Array.new(count) { |index| ("a".ord + (index % 26)).chr }.join
  end

  def flat_capture_pattern(count, named:)
    capture_subject(count).chars.each_with_index.map do |character, index|
      named ? "(?<n#{index}>#{character})" : "(#{character})"
    end.join
  end

  def assert_native_capture_match(pattern, subject, label)
    mri_regexp = Regexp.new(pattern)
    mri_match = mri_regexp.match(subject)
    onibi_regexp = Onibi::Regexp.new(pattern)
    onibi_match = onibi_regexp.match(subject)
    diagnostics = onibi_regexp.send(:__onibi_diagnostics__, subject)

    refute_nil mri_match, label
    refute_nil onibi_match, label
    return unless mri_match && onibi_match

    assert_equal mri_match.captures, onibi_match.captures, label
    expected_ranges = (0...mri_match.length).map do |index|
      byte_start = mri_match.bytebegin(index)
      byte_end = mri_match.byteend(index)
      [byte_start || -1, byte_end || -1]
    end
    assert_equal expected_ranges, diagnostics.fetch(:raw_registers), label
    assert_equal 1, diagnostics.fetch(:status), label
    assert diagnostics.fetch(:rseq), label
    assert_equal 0, diagnostics.fetch(:fallback), label
  end
end
