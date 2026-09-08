# frozen_string_literal: true

require "test_helper"
require "timeout"

class DynamicDifferentialTest < Minitest::Test
  CASES = [
    ["numbered backreference", "(a)\\1", %w[aa aba]],
    ["named backreference", "(?<word>ab)\\k<word>", %w[abab abac]],
    ["duplicate named backreference", "(?<x>a)(?<x>b)\\k<x>", %w[aba abb abc]],
    ["duplicate named backreference priority", "(?<x>a)(?<x>aa)\\k<x>", %w[aaaaa]],
    ["unmatched backreference", "(a)?\\1", %w[b a aa]],
    ["repeated backreference", "(a*)\\1", %w[b aa aaaa]],
    ["ignorecase backreference", "(a)\\1", %w[aA AA ab], Onibi::Regexp::IGNORECASE],
    ["empty backreference", "(?<empty>)\\k<empty>", %w[a]],
    ["nested backreference", "((a)b)\\1", %w[abab abb]],
    ["nested named backreference", "(?<x>(?<y>ab))\\k<x>", %w[abab ab]],
    ["conditional", "(a)?(?(1)b|c)", %w[ab ac cb]],
    ["named conditional", "(?<x>a)?(?(<x>)b|c)", %w[ab ac]],
    ["subexpression call", "(?<x>a+)\\g<x>", %w[aaaa aaab]],
    ["numbered subexpression call", "(a)\\g<1>", %w[aa ab]],
    ["nested subexpression call", "(?<x>(?<y>ab))\\g<x>", %w[abab ab]],
    ["recursive subexpression call", "(?<x>a(?:\\g<x>)?)\\g<x>", %w[aaa aaaa ab]],
    ["converging conditional", "(?:(a?)|)(?(1)b|c)", %w[b c ab]],
    ["atomic group", "(?>a|ab)b", %w[ab abb]],
    ["absence", "(?~a)b", %w[ab bb aab]],
    ["absence conditional capture priority",
     "(?~(a+))(?(1)a|b)", %w[aaa]],
    ["dynamic negative lookahead", "(?!((a)\\2))b", %w[ab bb]],
    ["dynamic positive lookahead", "(?=(a)\\1)aa", %w[aa aaa]],
    ["zero-length backreference repeat", "(?<x>)\\k<x>+", %w[a]],
    ["nullable repeat capture priority",
     "(?<x>)(?:(?<q>a?)\\k<x>|b)*a",
     %w[a aaa aaaa ba baa baaa aba bba]],
    ["nullable repeat capture priority with consuming suffix",
     "(?<x>)(?:(?<q>a?)\\k<x>|b)*b", %w[b ab bab bba]],
    ["nullable repeat capture priority through subexpression call",
     "(?<x>)(?:(?<q>a?)\\g<x>|b)*a",
     %w[a aaa aaaa ba baa baaa aba bba]],
    ["nullable repeat capture priority through subexpression call with consuming suffix",
     "(?<x>)(?:(?<q>a?)\\g<x>|b)*b", %w[b ab bab bba]],
    ["zero-width unreferenced capture loop",
     "(?<x>)(?:\\k<x>(?<y>)|b)*c", %w[c bc bbc bbbc]],
    ["zero-progress absence repeat", "\\K(?~(?=z))+", %w[aa]]
  ].freeze

  def test_dynamic_raw_results_match_mri
    CASES.each do |name, pattern, subjects, options|
      regexp = Onibi::Regexp.new(pattern, options || 0)
      subjects.each do |subject|
        expected = ::Regexp.new(pattern, options || 0).match(subject)
        info = regexp.send(:__onibi_diagnostics__, subject)

        assert_equal 2, info[:exec_kind], [name, subject]
        assert_operator info[:dynamic], :>, 0, [name, subject]
        assert_equal expected.nil? ? 0 : 1, info[:status], [name, subject]
        assert_equal expected&.bytebegin(0) || 0, info[:match_start],
                     [name, subject]
        assert_equal expected&.byteend(0) || 0, info[:match_end],
                     [name, subject]
        expected_captures = if expected
                              raw_capture_ranges(expected)
                            else
                              unmatched_capture_ranges(info)
                            end
        assert_equal expected_captures, info[:captures], [name, subject]
        assert_equal 0, info[:dfs], [name, subject]
        assert_equal 0, info[:fallback], [name, subject]
      end
    end
  end

  def test_zero_width_threads_keep_distinct_capture_presence
    pattern = "(?:(a?)|)(?(1)b|c)"
    regexp = Onibi::Regexp.new(pattern)
    expected_matches = {
      "b" => ["b", ""],
      "c" => ["c", nil],
      "ab" => %w[ab a]
    }

    expected_matches.each do |subject, expected|
      actual = regexp.match(subject)

      assert_equal expected, actual&.to_a, subject
      info = regexp.send(:__onibi_diagnostics__, subject)
      assert_equal 2, info[:exec_kind], subject
      assert_operator info[:dynamic], :>, 0, subject
      assert_equal 0, info[:dfs], subject
      assert_equal 0, info[:fallback], subject
    end
  end

  def test_zero_width_loop_with_unreferenced_capture_terminates
    pattern = "(?<x>)(?:\\k<x>(?<y>)|b)*c"
    expected = ::Regexp.new(pattern).match("c")

    actual = Timeout.timeout(2) do
      Onibi::Regexp.new(pattern).match("c")
    end

    assert_equal expected&.to_a, actual&.to_a
    assert_equal [expected.begin(0), expected.end(0)],
                 [actual.begin(0), actual.end(0)]
  end

  def test_nullable_repeat_priority_matches_mri_for_binary_subjects
    patterns = [
      "(?<x>)(?:(?<q>a?)\\k<x>|b)*a",
      "(?<x>)(?:(?<q>a?)\\k<x>|b)*b",
      "(?<x>)(?:(?<q>a?)\\g<x>|b)*a",
      "(?<x>)(?:(?<q>a?)\\g<x>|b)*b",
      "(?<x>)(?:b|(?<q>a?)\\k<x>)*a",
      "(?<x>)(?:b|(?<q>a?)\\k<x>)*?a",
      "(?<x>)(?:(?<q>a?)\\k<x>|b)*?a",
      "(?<x>)(?:b|(?<q>a?)\\g<x>)*?b"
    ]
    subjects = [""] + (1..5).flat_map do |length|
      %w[a b].repeated_permutation(length).map(&:join)
    end

    patterns.each do |pattern|
      regexp = Onibi::Regexp.new(pattern)
      subjects.each do |subject|
        expected = ::Regexp.new(pattern).match(subject)
        info = regexp.send(:__onibi_diagnostics__, subject)

        assert_equal 2, info[:exec_kind], [pattern, subject]
        assert_equal expected.nil? ? 0 : 1, info[:status], [pattern, subject]
        assert_equal expected&.bytebegin(0) || 0, info[:match_start],
                     [pattern, subject]
        assert_equal expected&.byteend(0) || 0, info[:match_end],
                     [pattern, subject]
        expected_captures = if expected
                              raw_capture_ranges(expected)
                            else
                              unmatched_capture_ranges(info)
                            end
        assert_equal expected_captures, info[:captures], [pattern, subject]
      end
    end
  end

  def test_conditional_nullable_repeat_captures_match_mri
    patterns = [
      "(?<x>)(?:(?(<x>)(?<q>a?)|b))*a",
      "(?<x>)(?:(?(<x>)(?<q>a?)|b))*b",
      "(?<x>)(?:(?(<x>)(?<q>a?)|(?<r>b?)))*a",
      "(?<x>)(?:(?(<x>)(?<q>a?)|(?<r>b?)))*b",
      "(?<x>)(?:(?(<x>)(?<q>a?)|b)|c)*a",
      "(?<x>)(?:(?(<x>)(?<q>a?)|b)|c)*b",
      "(?<x>)(?:(?(<x>)(?<q>a?)|b)\\k<x>)*a",
      "(?<x>)(?:(?(<x>)(?<q>a?)|b)\\g<x>)*a",
      "(?<x>)(?:(?(<x>)b|(?<q>a?)))*a",
      "(?<x>)(?:(?(<x>)b|(?<q>a?)))*b"
    ]
    subjects = (0..5).flat_map do |length|
      %w[a b c].repeated_permutation(length).map(&:join)
    end

    patterns.each do |pattern|
      expected_regexp = ::Regexp.new(pattern)
      actual_regexp = Onibi::Regexp.new(pattern)
      subjects.each do |subject|
        expected = Timeout.timeout(1) { expected_regexp.match(subject) }
        info = Timeout.timeout(1) do
          actual_regexp.send(:__onibi_diagnostics__, subject)
        end
        expected_captures = if expected
                              raw_capture_ranges(expected)
                            else
                              unmatched_capture_ranges(info)
                            end

        assert_equal expected.nil? ? 0 : 1, info[:status], [pattern, subject]
        assert_equal expected&.bytebegin(0) || 0, info[:match_start],
                     [pattern, subject]
        assert_equal expected&.byteend(0) || 0, info[:match_end],
                     [pattern, subject]
        assert_equal expected_captures, info[:captures], [pattern, subject]
      end
    end
  end

  private

  def raw_capture_ranges(match)
    (1...match.length).map do |index|
      begin_offset, end_offset = match.byteoffset(index)
      [begin_offset || -1, end_offset || -1]
    end
  end

  def unmatched_capture_ranges(info)
    Array.new(info.fetch(:capture_count), [-1, -1])
  end
end
