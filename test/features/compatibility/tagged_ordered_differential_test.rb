# frozen_string_literal: true

require "test_helper"

class TaggedOrderedDifferentialTest < Minitest::Test
  CASES = [
    ["ordered left branch", "^(a|ab)", "ab"],
    ["ordered longer left branch", "^(ab|a)", "ab"],
    ["greedy capture priority", "^(a*)(a*)", "aaa"],
    ["failed match reset branch", "(?:a\\Kx|ab)", "ab"],
    ["successful match reset branch", "(?:a\\Kb|ab)", "ab"],
    ["word boundary", "\\b(a)", "a"],
    ["positive assertion capture", "(?=(a))a", "a"],
    ["lookbehind assertion", "(?<=a)b", "ab"],
    ["counter assertion", "(?=a{9})a{9}", "a" * 9],
    ["counter lookbehind", "(?<=a{9})b", "#{"a" * 9}b"],
    ["rejected alternative capture", "^(?:(a?){2}z|b)", "b"],
    ["nested positive assertions", "^(?=(?=(a))a)a", "a"],
    ["nested counter assertion", "^(?=(?=a{2})a{2})a{2}", "aa"],
    ["nullable progress", "(?:a|)*b", "aaaab"],
    ["large exact repeat", "a{9}", "aaaaaaaaaa"],
    ["large greedy range", "a{9,10}", "aaaaaaaaaa"],
    ["large lazy range", "a{9,10}?", "aaaaaaaaaa"],
    ["large nullable lazy range", "a{0,9}?", "aaaaaaaaa"],
    ["large nullable lazy continuation", "a{0,9}?a", "a"],
    ["large nullable exact repeat", "(?:a?){9}", "aaaa"],
    ["large capture repeat", "(a){9}", "aaaaaaaaa"],
    ["large nullable capture", "(a?){9}", "aaaa"],
    ["large nullable capture consumes maximum", "(a?){9}", "a" * 9],
    ["large lazy nullable capture", "(a?){9,10}?", "aaaa"],
    ["converging counter paths", "(?:aa|a){9,10}b", "aaaaaaaaaab"],
    ["nested compact lazy priority", "(?:a{9,10}?){9,10}?a", "a" * 91],
    ["nested nullable compact priority", "(?:(?:a?){9}){9,10}?a", "a" * 91]
  ].freeze

  def test_tagged_ordered_results_match_mri
    CASES.each do |name, pattern, subject|
      expected = ::Regexp.new(pattern).match(subject)
      info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)

      assert info[:rseq], name
      assert_equal 1, info[:exec_kind], name
      assert_equal 1, info[:status], name
      assert_equal expected.bytebegin(0), info[:match_start], name
      assert_equal expected.byteend(0), info[:match_end], name
      assert_equal capture_ranges(expected), info[:captures], name
    end
  end

  def test_supported_cases_use_only_tagged_executor
    CASES.each do |name, pattern, subject|
      info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)

      assert_operator info[:tagged], :>, 0, name
      assert_equal 0, info[:regular], name
      assert_equal 0, info[:dynamic], name
      assert_equal 0, info[:dfs], name
      assert_equal 0, info[:fallback], name
    end
  end

  def test_one_attempt_reports_one_tagged_invocation
    info = Onibi::Regexp.new("^a").send(:__onibi_diagnostics__, "a")

    assert_equal 1, info[:tagged]
    assert_equal 0, info[:dynamic]
    assert_equal 0, info[:dfs]
    assert_equal 0, info[:fallback]
  end

  def test_numeric_repeat_bound_does_not_change_program_shape
    small = program_shape("a{9}")
    large = program_shape("a{100000}")
    nullable_small = program_shape("(?:a?){9}")
    nullable_large = program_shape("(?:a?){100000}")
    optional_fixed_small = program_shape("a{9}?")
    optional_fixed_large = program_shape("a{100000}?")
    lazy_choice_small = program_shape("^(?:(a*?){9}|a+)b")
    lazy_choice_large = program_shape("^(?:(a*?){100000}|a+)b")

    assert_equal small, large
    assert_equal nullable_small, nullable_large
    assert_equal optional_fixed_small, optional_fixed_large
    assert_equal lazy_choice_small, lazy_choice_large
  end

  def test_optional_fixed_repeat_matches_mri_without_executor_fallback
    [
      ["a{9}?", ["", "a" * 8, "a" * 9, "a" * 10]],
      ["a{9}?a", ["", "a", "a" * 8, "a" * 9, "a" * 10]],
      ["(a){9}?a", ["", "a", "a" * 8, "a" * 9, "a" * 10]],
      ["a{9,9}?", ["", "a" * 8, "a" * 9, "a" * 10]]
    ].each do |pattern, subjects|
      subjects.each do |subject|
        expected = ::Regexp.new(pattern).match(subject)
        info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)

        assert info[:rseq], [pattern, subject.length]
        assert_equal 1, info[:exec_kind], [pattern, subject.length]
        assert_equal expected.nil? ? 0 : 1, info[:status], [pattern, subject.length]
        if expected
          assert_equal expected.bytebegin(0), info[:match_start], [pattern, subject.length]
          assert_equal expected.byteend(0), info[:match_end], [pattern, subject.length]
          assert_equal capture_ranges(expected), info[:captures], [pattern, subject.length]
        end
        assert_equal 0, info[:dynamic], [pattern, subject.length]
        assert_equal 0, info[:dfs], [pattern, subject.length]
        assert_equal 0, info[:fallback], [pattern, subject.length]
      end
    end
  end

  def test_nullable_fixed_repeat_capture_history_matches_mri
    {
      "(a?){9}a" => 1..9,
      "(a?){9}aa" => 2..9,
      "(a?){9,9}?a" => 1..9,
      "(a?){9,9}?aa" => 2..9,
      "((?:a|)){9}a" => 1..9,
      "((?:a|)){9}aa" => 2..9,
      "(a?){3}a" => 1..3,
      "(a?){2,2}?a" => 1..2,
      "(a?){9,10}a" => 1..10,
      "(a?){9,10}?a" => 1..10
    }.each do |pattern, lengths|
      lengths.each do |length|
        subject = "a" * length
        expected = ::Regexp.new(pattern).match(subject)
        info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)

        assert expected, [pattern, length]
        assert info[:rseq], [pattern, length]
        assert_equal 1, info[:exec_kind], [pattern, length]
        assert_equal 1, info[:status], [pattern, length]
        assert_equal expected.bytebegin(0), info[:match_start], [pattern, length]
        assert_equal expected.byteend(0), info[:match_end], [pattern, length]
        assert_equal capture_ranges(expected), info[:captures], [pattern, length]
        assert_equal 0, info[:dynamic], [pattern, length]
        assert_equal 0, info[:dfs], [pattern, length]
        assert_equal 0, info[:fallback], [pattern, length]
      end
    end
  end

  def test_nullable_fixed_repeat_does_not_move_capture_open_past_other_continuations
    ["(a?){9}b", "(a?){9,9}?b", "((?:a|)){9}b"].each do |pattern|
      (0..8).each do |length|
        subject = "#{"a" * length}b"
        expected = ::Regexp.new(pattern).match(subject)
        info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)

        assert_equal expected.nil? ? 0 : 1, info[:status], [pattern, length]
        next unless expected && info[:status] == 1

        assert_equal expected.bytebegin(0), info[:match_start], [pattern, length]
        assert_equal expected.byteend(0), info[:match_end], [pattern, length]
        assert_equal capture_ranges(expected), info[:captures], [pattern, length]
      end
    end
  end

  def test_outer_optional_owns_nullable_repeat_capture_history
    {
      "^(?:(a?){9})?a" => (1..9).map { |length| "a" * length },
      "^(?:(a?){9})?aa" => (2..9).map { |length| "a" * length },
      "^(?:(a?){9})?b" => (0..8).map { |length| "#{"a" * length}b" },
      "^(?:(a?){9}x)?a" => (1..9).map { |length| "a" * length },
      "^(?:(a?){9}b)?a" => (1..9).map { |length| "a" * length }
    }.each do |pattern, subjects|
      subjects.each do |subject|
        assert_native_differential(pattern, subject)
      end
    end
  end

  def test_outer_alternatives_do_not_publish_rejected_repeat_history
    [
      "^(?:(a?){9}|z)a",
      "^(?:z|(a?){9})a",
      "^(?:(a?){9}a|z)",
      "^(?:a|(a?){9}a)",
      "^(?:(a?){9}x|a)"
    ].each do |pattern|
      [*(1..9).map { |length| "a" * length }, "z", "za"].each do |subject|
        assert_native_differential(pattern, subject)
      end
    end
  end

  def test_nested_choice_repeats_keep_deferred_capture_state_local
    {
      "^(?:(a?){9}){1,2}a" => 1..10,
      "^((?:(a?){9})?){2}a" => 1..9,
      "^(?:(?:(a?){9})?|z)a" => 1..9,
      "^(?:(a?){9}){2}a" => 1..12,
      "^(?:(a?){9,10}?){3}a" => 1..12
    }.each do |pattern, lengths|
      lengths.each do |length|
        assert_native_differential(pattern, "a" * length)
      end
    end
  end

  def test_nested_duplicate_frontier_keeps_capture_event_alternatives
    assert_native_differential("^(?:(a?){2}){2}a$", "a")
  end

  def test_assertions_keep_deferred_capture_state_local
    {
      "^(?=((a?){9}a))a" => %w[a aa ab],
      "^(?=(?:(a?){9})?a)a" => %w[a aa ab],
      "^(?!((a?){9})b)a" => %w[a aa ab],
      "^(?=((a?){9}aa))aa" => %w[a aa ab]
    }.each do |pattern, subjects|
      subjects.each do |subject|
        assert_native_differential(pattern, subject)
      end
    end
  end

  def test_assertion_event_rollback_matches_mri_without_fallback
    {
      "^(?:(?=(a)z)b|a)" => %w[a],
      "^(?:(?!(a)z)a|a)" => %w[a],
      "^(?:(?!(a))a|a)" => %w[a],
      "^(?:(?=(a))b|a)" => %w[a]
    }.each do |pattern, subjects|
      subjects.each do |subject|
        assert_native_differential(pattern, subject)
      end
    end
  end

  def test_lazy_nullable_capture_in_preferred_alternative_matches_mri
    [
      "^(?:(a??){9}|a+)b",
      "^(?:(a*?){9}|a+)b",
      "^(?:(a??){9}|a+)x",
      "^(?:(a*?){9}|a+)x",
      "^(?:(a??){4}|a+)b",
      "^(?:(a*?){4}|a+)b",
      "^(?:(a??){4}|a+)x",
      "^(?:(a*?){4}|a+)x"
    ].each do |pattern|
      continuation = pattern[-1]
      (0..12).each do |length|
        assert_native_differential(pattern, ("a" * length) + continuation)
      end
    end
  end

  def test_rejected_lazy_repeat_threads_do_not_publish_capture_history
    [
      "^(?:(a??){9}z|a+)b",
      "^(?:(a*?){9}z|a+)b",
      "^(?:(a??){9}z|a+)x",
      "^(?:(a*?){9}z|a+)x",
      "^(?:(?:(a??){9}){2}z|a+)b",
      "^(?:(?:(a*?){9}){2}z|a+)x"
    ].each do |pattern|
      continuation = pattern[-1]
      (1..12).each do |length|
        assert_native_differential(pattern, ("a" * length) + continuation)
      end
    end
  end

  def test_lazy_repeat_capture_history_passes_through_assertions
    [
      "^(?=(?:(a??){9}|a+)b)a+b",
      "^(?=(?:(a*?){9}|a+)b)a+b",
      "^(?!(?:(a??){9}|a+)z)a+b",
      "^(?!(?:(a*?){9}|a+)z)a+b"
    ].each do |pattern|
      (1..12).each do |length|
        assert_native_differential(pattern, "#{"a" * length}b")
      end
    end
  end

  private

  def capture_ranges(match)
    (1...match.size).map do |index|
      [match.bytebegin(index) || -1, match.byteend(index) || -1]
    end
  end

  def assert_native_differential(pattern, subject)
    expected = ::Regexp.new(pattern).match(subject)
    info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)
    label = [pattern, subject]

    assert info[:rseq], label
    assert_equal 1, info[:exec_kind], label
    assert_equal expected.nil? ? 0 : 1, info[:status], label
    if expected && info[:status] == 1
      assert_equal expected.bytebegin(0), info[:match_start], label
      assert_equal expected.byteend(0), info[:match_end], label
      assert_equal capture_ranges(expected), info[:captures], label
    end
    assert_equal 0, info[:dynamic], label
    assert_equal 0, info[:dfs], label
    assert_equal 0, info[:fallback], label
  end

  def program_shape(pattern)
    info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, "")

    assert info[:rseq]
    assert_equal 1, info[:exec_kind]
    [info[:state_payloads].length, info[:edges].length, info[:actions].length]
  end
end
