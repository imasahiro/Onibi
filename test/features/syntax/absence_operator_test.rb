# frozen_string_literal: true

require "test_helper"

class AbsenceOperatorTest < Minitest::Test
  def test_absence_operator_stops_before_the_forbidden_match
    match = Onibi::Regexp.new("(?~real)").match("surrealist")

    assert_equal "surrea", match[0]
  end

  def test_absence_operator_can_be_followed_by_a_suffix
    match = Onibi::Regexp.new("(?~real)ist").match("surrealist")

    assert_equal "ealist", match[0]
  end

  def test_absence_operator_evaluates_bytecode_body_alternatives
    regexp = Onibi::Regexp.new("(?~a|b)")

    assert_equal "", regexp.match("a")[0]
    assert_equal "x", regexp.match("xaby")[0]
    assert_equal "cd", regexp.match("cd")[0]
  end

  def test_absence_operator_applies_casefold_to_literal_delimiters
    pattern = "(?~a)"
    expected = ::Regexp.new(pattern, ::Regexp::IGNORECASE).match("A")
    actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match("A")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(0), actual.offset(0)
  end

  def test_absence_operator_casefolds_unbounded_quantifiers
    ["(?~a+)", "(?~a*)"].each do |pattern|
      expected = ::Regexp.new(pattern, ::Regexp::IGNORECASE).match("aA")
      actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match("aA")

      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal expected.offset(0), actual.offset(0), pattern
    end
  end

  def test_absence_operator_keeps_zero_length_suffix_candidate
    pattern = "(?~(?=a))b"
    %w[ba aab].each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_keeps_all_probe_lengths_for_suffix_backtracking
    [
      ["(?~(?=a))\\w", "aba"],
      ["(?~(?=a))b", "xaxbxaxb"],
      ["(?~(?=a))A", "BAa"]
    ].each do |pattern, input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal expected.offset(0), actual.offset(0), pattern
    end
  end

  def test_absence_operator_rejects_nullable_body_before_a_suffix
    [0, Onibi::Regexp::IGNORECASE].each do |options|
      pattern = "(?~a?)b"
      expected = ::Regexp.new(pattern, options).match("b")
      actual = Onibi::Regexp.new(pattern, options).match("b")

      assert_nil expected
      assert_nil actual
    end
  end

  def test_absence_operator_preserves_body_captures
    match = Onibi::Regexp.new("(?~(a|b))").match("xaby")

    assert_equal "x", match[0]
    assert_equal "a", match[1]
  end

  def test_absence_operator_preserves_captures_used_by_a_backreference_body
    pattern = "(?<x>a)(?~\\k<x>)"
    expected = ::Regexp.new(pattern).match("xaba")
    actual = Onibi::Regexp.new(pattern).match("xaba")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(1), actual.offset(1)
  end

  def test_absence_body_captures_are_not_visible_to_a_following_suffix
    pattern = "(?~(?<x>a))\\k<x>"
    expected = ::Regexp.new(pattern).match("a")
    actual = Onibi::Regexp.new(pattern).match("a")

    assert_nil expected
    assert_nil actual
  end

  def test_absence_failed_probe_clears_incomplete_direct_capture
    assert_absence_failed_probe_control(
      label: "failed absence probe clears an incomplete direct capture",
      pattern: "(?~((a|ab){2,}))",
      subject: "abab",
      start: 0,
      expected_values: ["ab", nil, nil],
      expected_char_ranges: [[0, 2], [nil, nil], [nil, nil]],
      expected_byte_ranges: [[0, 2], [nil, nil], [nil, nil]]
    )
  end

  def test_absence_failed_probe_marks_incomplete_capture_unset_for_condition
    assert_absence_failed_probe_control(
      label: "failed absence probe marks an incomplete capture unset",
      pattern: "\\A(?~((a|ab){2,}))(?(1)b|a)",
      subject: "abab",
      start: 0,
      expected_values: ["aba", nil, nil],
      expected_char_ranges: [[0, 3], [nil, nil], [nil, nil]],
      expected_byte_ranges: [[0, 3], [nil, nil], [nil, nil]]
    )
  end

  def test_absence_failed_probe_preserves_unrelated_capture
    assert_absence_failed_probe_control(
      label: "failed absence probe preserves an unrelated capture",
      pattern: "\\A(x)(?~((a|ab){2,}))",
      subject: "xabab",
      start: 0,
      expected_values: ["xab", "x", nil, nil],
      expected_char_ranges: [[0, 3], [0, 1], [nil, nil], [nil, nil]],
      expected_byte_ranges: [[0, 3], [0, 1], [nil, nil], [nil, nil]]
    )
  end

  def test_absence_failed_probe_preserves_prior_direct_body_capture
    assert_absence_failed_probe_control(
      label: "failed probe preserves an unrelated direct body capture",
      pattern: "(?~((?:ab)(c)(?:d|de){2,}))",
      subject: "abcdde",
      start: 0,
      expected_values: ["abcd", nil, "c"],
      expected_char_ranges: [[0, 4], [nil, nil], [2, 3]],
      expected_byte_ranges: [[0, 4], [nil, nil], [2, 3]]
    )
  end

  def test_absence_restores_pushed_capture_for_suffix_condition
    pattern = "\\A(?~((a|b){2,}))(?(2)z|a)"
    expected = ::Regexp.new(pattern).match("ab")
    actual = Onibi::Regexp.new(pattern).match("ab")

    assert_equal ["a", "ab", nil], expected.to_a
    expected_ranges = (0...expected.length).map do |index|
      [expected.begin(index), expected.end(index)]
    end
    assert_equal [[0, 1], [0, 2], [nil, nil]], expected_ranges
    assert_equal expected.to_a, actual&.to_a
    assert_equal expected.offset(0), actual&.offset(0)
    assert_equal expected.offset(1), actual&.offset(1)
    assert_nil actual&.begin(2)
    assert_nil actual&.end(2)
  end

  def test_absence_restores_non_nil_call_capture_snapshot
    pattern = "\\A(?<x>a|b)(?~\\g<x>)"
    expected = ::Regexp.new(pattern).match("ab")
    actual = Onibi::Regexp.new(pattern).match("ab")

    assert_equal %w[a a], expected.to_a
    assert_equal expected.to_a, actual&.to_a
    assert_equal expected.offset(1), actual&.offset(1)
  end

  def test_absence_rollback_covers_unused_backreference_branch
    pattern = "\\A(?~(a))(?:a|\\1)"
    expected = ::Regexp.new(pattern).match("ab")
    actual = Onibi::Regexp.new(pattern).match("ab")

    assert_equal ["a", nil], expected.to_a
    assert_equal expected.to_a, actual&.to_a
    assert_nil actual&.begin(1)
    assert_nil actual&.end(1)
  end

  def test_repeated_absence_capture_uses_the_zero_width_endpoint
    pattern = "((?~a))*+"
    expected = ::Regexp.new(pattern).match("b")
    actual = Onibi::Regexp.new(pattern).match("b")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(1), actual.offset(1)
  end

  def test_absence_operator_preserves_captures_from_a_failed_suffix
    pattern = "(?~(?:(a|b)a))"

    assert_absence_failed_probe_control(
      label: "failed suffix direct capture at active bound",
      pattern: pattern,
      subject: "a",
      start: 0,
      expected_values: %w[a a],
      expected_char_ranges: [[0, 1], [0, 1]],
      expected_byte_ranges: [[0, 1], [0, 1]]
    )

    %w[a ab b abc].each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)
      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_matches_mri_for_unbounded_greedy_body
    regexp = Onibi::Regexp.new("(?~a+)")

    actual = %w[a aa aaa aaaa aaaaa].map do |input|
      regexp.match(input)[0]
    end
    assert_equal ["", "a", "a", "aa", "aa"], actual
  end

  def test_absence_operator_matches_mri_for_unbounded_any_body
    pattern = "(?~.+)"
    %w[a ab abc abcd].each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)
      assert_equal expected&.to_a, actual&.to_a, input
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)], input
    end
  end

  def test_absence_endpoint_publishes_all_late_probe_captures
    assert_absence_failed_probe_control(
      label: "late probe publishes multiple captures",
      pattern: "(?~(a+)(b+))c",
      subject: "cxxaabb",
      start: 0,
      expected_values: %w[c a b],
      expected_char_ranges: [[0, 1], [4, 5], [5, 6]],
      expected_byte_ranges: [[0, 1], [4, 5], [5, 6]]
    )
  end

  def test_absence_endpoint_clears_capture_from_later_unset_probe
    assert_absence_failed_probe_control(
      label: "later positive probe leaves capture unset",
      pattern: "(?~(?:(a)|b))c",
      subject: "cxxab",
      start: 0,
      expected_values: ["c", nil],
      expected_char_ranges: [[0, 1], [nil, nil]],
      expected_byte_ranges: [[0, 1], [nil, nil]]
    )
  end

  def test_absence_endpoint_publishes_condition_capture_before_suffix
    assert_absence_failed_probe_control(
      label: "late probe capture selects following conditional",
      pattern: "(?~(a))c(?(1)d|e)",
      subject: "cdxxa",
      start: 0,
      expected_values: %w[cd a],
      expected_char_ranges: [[0, 2], [4, 5]],
      expected_byte_ranges: [[0, 2], [4, 5]]
    )
  end

  def test_absence_endpoint_keeps_prefix_backreference_registers
    assert_absence_failed_probe_control(
      label: "late probe output keeps prefix backreference register",
      pattern: "\\A(c)(?~(a))\\1",
      subject: "ccxa",
      start: 0,
      expected_values: %w[cc c a],
      expected_char_ranges: [[0, 2], [0, 1], [3, 4]],
      expected_byte_ranges: [[0, 2], [0, 1], [3, 4]]
    )
  end

  def test_absence_endpoint_publication_charges_large_saved_endpoint_set
    pattern = "(?~(z))"
    endpoint_count = 512
    subject = "#{"a" * endpoint_count}z!"
    expected = ::Regexp.new(pattern).match(subject)

    small_budget = Onibi::Regexp.new(pattern, timeout: 0.001)
    assert_raises(Onibi::Regexp::TimeoutError) do
      small_budget.match("#{"a" * 20_000}z!")
    end

    regexp = Onibi::Regexp.new(pattern)
    actual = regexp.match(subject)
    assert_equal expected.to_a, actual.to_a
    assert_equal absence_match_snapshot(expected), absence_match_snapshot(actual)
    assert_instance_of Onibi::MatchData, actual

    info = regexp.send(:__onibi_diagnostics__, subject)
    assert_equal 2, info[:exec_kind]
    assert_operator info[:dynamic], :>, 0
    assert_equal 0, info[:fallback]
    assert_equal 1, info[:status]
    assert_equal expected.bytebegin(0), info[:match_start]
    assert_equal expected.byteend(0), info[:match_end]
    assert_operator info[:work_charged], :>=, 17 * endpoint_count
  end

  def test_nested_absence_endpoint_transfer_work_grows_linearly
    pattern = "(?~(?:(?!(?=\\A(?~((z)|a))x))x))"
    endpoint_counts = [32, 64]
    work_by_endpoint_count = endpoint_counts.to_h do |endpoint_count|
      subject = "#{"b" * (2 * endpoint_count)}z!"
      expected = ::Regexp.new(pattern).match(subject)
      regexp = Onibi::Regexp.new(pattern)
      actual = regexp.match(subject)

      assert_equal expected.to_a, actual.to_a, endpoint_count
      assert_equal absence_match_snapshot(expected),
                   absence_match_snapshot(actual), endpoint_count

      info = regexp.send(:__onibi_diagnostics__, subject)
      assert_equal 2, info[:exec_kind]
      assert_operator info[:dynamic], :>, 0
      assert_equal 0, info[:fallback]
      assert_equal 1, info[:status]
      assert_operator info[:tag_events], :>=, endpoint_count
      [endpoint_count, info[:work_charged]]
    end

    assert_operator work_by_endpoint_count.fetch(64), :<=,
                    3 * work_by_endpoint_count.fetch(32),
                    "nested endpoint transfer work must grow linearly"
  end

  def test_absence_sparse_pending_capture_scan_charges_unset_slots
    unused_capture_count = 256
    suffix = Array.new(unused_capture_count) { "(?!(?:q(a)))" }.join
    pattern = "(?~(?:b(?~(?:(a?)(?=a)))))#{suffix}"
    subject = "bab"
    expected = ::Regexp.new(pattern).match(subject)
    regexp = Onibi::Regexp.new(pattern)
    actual = regexp.match(subject)

    assert_equal expected.to_a, actual.to_a
    assert_equal absence_match_snapshot(expected),
                 absence_match_snapshot(actual)

    info = regexp.send(:__onibi_diagnostics__, subject)
    assert_equal 2, info[:exec_kind]
    assert_operator info[:dynamic], :>, 0
    assert_equal 0, info[:fallback]
    assert_equal 1, info[:status]
    assert_operator info[:work_charged], :>=, 13_000,
                    "sparse pending scan work must include unset slots"
  end

  def test_absence_operator_backtracks_nested_unbounded_capture_to_a_suffix
    assert_absence_failed_probe_control(
      label: "later positive probe capture reaches an earlier endpoint",
      pattern: "(?~(a+))b",
      subject: "abcabc",
      start: 0,
      expected_values: %w[b a],
      expected_char_ranges: [[1, 2], [3, 4]],
      expected_byte_ranges: [[1, 2], [3, 4]]
    )

    ["(?~(a+))b", "(?~((a|b)+))c"].each do |pattern|
      %w[b ab abb abc abcabc].each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)
        if expected
          assert_equal expected.to_a, actual&.to_a, [pattern, input]
          assert_equal [expected.begin(0), expected.end(0)],
                       [actual.begin(0), actual.end(0)], [pattern, input]
        else
          assert_nil actual, [pattern, input]
        end
      end
    end
  end

  def test_absence_body_capture_presence_is_visible_to_conditionals
    [
      ["(?~(a+))(?(1)a|b)", %w[a aa aaa aaaa ab ba aaba]],
      ["(?~(a|ab))(?(1)a|b)", %w[a aa ab ba]],
      ["(?~(?:(a|b)a))(?(1)a|b)", %w[a aa ab ba b]]
    ].each do |pattern, inputs|
      inputs.each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)

        if expected
          assert_equal expected.to_a, actual&.to_a, [pattern, input]
          assert_equal expected.offset(0), actual&.offset(0), [pattern, input]
        else
          assert_nil actual, [pattern, input]
        end
      end
    end
  end

  def test_zero_width_absence_runs_suffix_at_the_internal_match_start
    [
      ["(?~(?=a))a", %w[ab aab ba]],
      ["(?~(?=a))(?!a)", %w[ab aab ba]]
    ].each do |pattern, inputs|
      inputs.each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)

        if expected
          assert_equal expected.to_a, actual&.to_a, [pattern, input]
          assert_equal expected.offset(0), actual&.offset(0), [pattern, input]
        else
          assert_nil actual, [pattern, input]
        end
      end
    end
  end

  def test_absence_operator_scans_for_a_greedy_body_match
    regexp = Onibi::Regexp.new("(?~a+)")

    assert_equal "b", regexp.match("ba")[0]
    assert_equal "x", regexp.match("xaby")[0]
  end

  def test_absence_operator_backtracks_to_a_suffix
    match = Onibi::Regexp.new("(?~a+)b").match("ab")

    assert_equal "b", match[0]
    assert_equal [1, 2], match.offset(0)
  end

  def test_absence_operator_retries_after_a_zero_width_star_body
    match = Onibi::Regexp.new("(?~a*)").match("b")

    assert_equal "", match[0]
    assert_equal [1, 1], match.offset(0)
  end

  def test_absence_operator_handles_zero_width_body_positions
    ["(?~^)", "(?~\\b)", "(?~(?=a))"].each do |pattern|
      expected = ::Regexp.new(pattern).match("ab")
      actual = Onibi::Regexp.new(pattern).match("ab")

      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal expected.offset(0), actual.offset(0), pattern
    end
  end

  def test_absence_operator_keeps_captures_from_a_zero_width_body
    pattern = "(?~(?:(?!a)(a?)))"
    expected = ::Regexp.new(pattern).match("ab")
    actual = Onibi::Regexp.new(pattern).match("ab")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(0), actual.offset(0)
    assert_equal expected.offset(1), actual.offset(1)
  end

  def test_absence_operator_keeps_capture_from_a_positive_lookahead_boundary
    pattern = "(?~(?:(a?)(?=a)))"

    assert_absence_failed_probe_control(
      label: "positive lookahead capture at the absence boundary",
      pattern: pattern,
      subject: "ab",
      start: 0,
      expected_values: ["b", ""],
      expected_char_ranges: [[1, 2], [1, 1]],
      expected_byte_ranges: [[1, 2], [1, 1]]
    )

    %w[ab abb abc].each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_keeps_parent_capture_before_a_failed_negative_assertion
    assert_absence_failed_probe_control(
      label: "parent capture before a failing negative assertion",
      pattern: "(?~(?:(a?)(?!b)))",
      subject: "ab",
      start: 0,
      expected_values: ["b", ""],
      expected_char_ranges: [[1, 2], [1, 1]],
      expected_byte_ranges: [[1, 2], [1, 1]]
    )
  end

  def test_absence_operator_discards_capture_writes_from_failed_assertion_children
    cases = [
      [
        "failed positive assertion child",
        "(?~(?:(?=(a)z)))",
        "ab",
        ["ab", nil],
        [[0, 2], [nil, nil]]
      ],
      [
        "failed negative assertion child",
        "(?~(?:(?!(a))))",
        "a",
        ["a", nil],
        [[0, 1], [nil, nil]]
      ]
    ]

    cases.each do |label, pattern, subject, expected_values, ranges|
      assert_absence_failed_probe_control(
        label: label,
        pattern: pattern,
        subject: subject,
        start: 0,
        expected_values: expected_values,
        expected_char_ranges: ranges,
        expected_byte_ranges: ranges
      )
    end
  end

  def test_absence_operator_rolls_back_pushed_capture_before_a_failed_assertion
    assert_absence_failed_probe_control(
      label: "pushed capture before a failing positive assertion",
      pattern: "(?~(?:(a)+(?=z)))",
      subject: "aax",
      start: 0,
      expected_values: ["aax", nil],
      expected_char_ranges: [[0, 3], [nil, nil]],
      expected_byte_ranges: [[0, 3], [nil, nil]]
    )
  end

  def test_nested_absence_keeps_parent_capture_before_a_failed_assertion
    assert_absence_failed_probe_control(
      label: "nested absence capture before a failing positive assertion",
      pattern: "(?~(?:b(?~(?:(a?)(?=a)))))",
      subject: "bab",
      start: 0,
      expected_values: ["ba", ""],
      expected_char_ranges: [[0, 2], [1, 1]],
      expected_byte_ranges: [[0, 2], [1, 1]]
    )
  end

  def test_nested_absence_preserves_reversed_output_capture_ranges
    target = "(?~(?:b(?~(?:(?=(?:(a?){9}){2}a)(?=a)))))"
    cases = [
      ["target", target, "bab", [[0, 2], [2, 1]]],
      ["repeat 8", target.sub("{9}", "{8}"), "bab", [[0, 2], [2, 1]]],
      ["repeat 10", target.sub("{9}", "{10}"), "bab", [[0, 2], [2, 1]]],
      [
        "no inner absence",
        "(?~(?:b(?:(?=(?:(a?){9}){2}a)(?=a))))",
        "bab",
        [[0, 0], [2, 1]]
      ],
      [
        "no outer absence",
        "(?~(?:(?=(?:(a?){9}){2}a)(?=a)))",
        "bab",
        [[0, 1], [2, 1]]
      ],
      [
        "normal empty pair",
        "(?~(?:b(?~(?:(a?)(?=a)))))",
        "bab",
        [[0, 2], [1, 1]]
      ],
      ["unset pair", "(?~(?:(?=(a)z)))", "ab", [[0, 2], [nil, nil]]],
      ["fixed three", "(?~(a|b){3})", "xabab", [[0, 3], [nil, nil]]]
    ]
    byte_offsets = lambda do |match|
      (0...match.length).map { |index| match.byteoffset(index) }
    end

    cases.each do |label, pattern, subject, expected_offsets|
      expected = ::Regexp.new(pattern).match(subject)
      regexp = Onibi::Regexp.new(pattern)
      actual = regexp.match(subject)

      assert_equal expected_offsets, byte_offsets.call(expected), label
      assert_equal expected_offsets, byte_offsets.call(actual), label

      diagnostics = regexp.send(:__onibi_diagnostics__, subject)
      assert_equal 2, diagnostics[:exec_kind], label
      assert_equal 0, diagnostics[:fallback], label

      if expected_offsets[1] == [2, 1]
        assert_equal [2, 1], expected.offset(1), label
        assert_equal [2, 1], actual.offset(1), label
        assert_equal [2, 1], actual.byteoffset(1), label
        assert_equal 2, actual.begin(1), label
        assert_equal 1, actual.end(1), label
        assert_equal(-1, actual.match_length(1), label)

        [[:to_a], [:captures], [:[], 1]].each do |method, *arguments|
          expected_error = assert_raises(ArgumentError, label) do
            expected.public_send(method, *arguments)
          end
          actual_error = assert_raises(ArgumentError, label) do
            actual.public_send(method, *arguments)
          end
          assert_equal expected_error.message, actual_error.message, label
        end
      else
        assert_equal expected.to_a, actual.to_a, label
        assert_equal expected.captures, actual.captures, label
        assert_equal expected[1], actual[1], label
      end
    end
  end

  def test_nested_absence_output_range_controls_preserve_normal_and_unset_pairs
    cases = [
      ["normal empty pair", "(?~(?:b(?~(?:(a?)(?=a)))))", "bab"],
      ["unset pair", "(?~(?:(?=(a)z)))", "ab"],
      ["fixed three", "(?~(a|b){3})", "xabab"]
    ]

    cases.each do |label, pattern, subject|
      expected = ::Regexp.new(pattern).match(subject)
      regexp = Onibi::Regexp.new(pattern)
      actual = regexp.match(subject)

      assert_equal expected.to_a, actual.to_a, label
      assert_equal expected.offset(0), actual.offset(0), label
      assert_equal expected.offset(1), actual.offset(1), label
      assert_equal expected.byteoffset(1), actual.byteoffset(1), label

      diagnostics = regexp.send(:__onibi_diagnostics__, subject)
      assert_equal 2, diagnostics[:exec_kind], label
      assert_equal 0, diagnostics[:fallback], label
    end
  end

  def test_nested_absence_preserves_utf8_reversed_output_capture_ranges
    pattern = "(?~(?:b(?~(?:(?=(?:(a?){9}){2}a)(?=a)))))"
    subject = "ébab"
    expected = ::Regexp.new(pattern).match(subject)
    regexp = Onibi::Regexp.new(pattern)
    actual = regexp.match(subject)

    assert_equal [[0, 3], [3, 2]], [expected.offset(0), expected.offset(1)]
    assert_equal [[0, 4], [4, 3]], [expected.byteoffset(0), expected.byteoffset(1)]
    assert_equal expected.offset(0), actual.offset(0)
    assert_equal expected.offset(1), actual.offset(1)
    assert_equal expected.byteoffset(0), actual.byteoffset(0)
    assert_equal expected.byteoffset(1), actual.byteoffset(1)
    assert_equal(-1, actual.match_length(1))

    [[:to_a], [:captures], [:[], 1]].each do |method, *arguments|
      expected_error = assert_raises(ArgumentError) do
        expected.public_send(method, *arguments)
      end
      actual_error = assert_raises(ArgumentError) do
        actual.public_send(method, *arguments)
      end
      assert_equal expected_error.message, actual_error.message
    end

    diagnostics = regexp.send(:__onibi_diagnostics__, subject)
    assert_equal 2, diagnostics[:exec_kind]
    assert_equal 0, diagnostics[:fallback]
  end

  def test_absence_operator_clears_empty_capture_at_input_end
    pattern = "(?~(?:(?!a)(a?)))"
    expected = ::Regexp.new(pattern).match("a")
    actual = Onibi::Regexp.new(pattern).match("a")

    assert_equal expected.to_a, actual.to_a
    assert_equal expected.offset(0), actual.offset(0)
  end

  def test_absence_operator_clears_nullable_captures_on_suffix_failure_at_end
    ["(?~(?:(a?)a))", "(?~(?:(a?)(a|b)))"].each do |pattern|
      expected = ::Regexp.new(pattern).match("")
      actual = Onibi::Regexp.new(pattern).match("")
      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal expected.offset(0), actual.offset(0), pattern
    end
  end

  def test_absence_operator_applies_quantifier_boundary_to_suffix_bodies
    cases = [
      ["(?~(?:a*(a|b)))", %w[aa aab ab aaaab aaab]],
      ["(?~(?:a*[ab]))", %w[aa aab ab aaaab]],
      ["(?~(?:a*.))", %w[aa aab ab aaaab]]
    ]

    cases.each do |pattern, inputs|
      inputs.each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)
        assert_equal expected.to_a, actual.to_a, [pattern, input]
        assert_equal expected.offset(0), actual.offset(0), [pattern, input]
      end
    end
  end

  def test_absence_operator_preserves_repeated_atom_boundary
    pattern = "(?~(?:a+a))"
    %w[aaaab aaaa baaaa].each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a
      assert_equal expected.offset(0), actual.offset(0)
    end
  end

  def test_absence_operator_preserves_quantified_suffix_boundary
    [
      ["(?~(?:a+.))", "aaaab"],
      ["(?~(?:[ab]+[ab]))", "aaaab"],
      ["(?~(?:[ab]+a))", "aaaab"],
      ["(?~(?:[ab]+a))", "aaa"],
      ["(?~(?:a+aa))", "aaaab"],
      ["(?~(?:a+a+))", "aaaab"],
      ["(?~(?:a+a*))", "aaab"]
    ].each do |pattern, input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal expected.offset(0), actual.offset(0), pattern
    end
  end

  def test_absence_operator_discards_capture_from_failed_quantified_suffix
    pattern = "(?~(?:a+(a|b)))"
    %w[aab aaaa].each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a
      assert_equal expected.offset(0), actual.offset(0)
    end
  end

  def test_absence_operator_uses_fixed_star_suffix_width
    [
      ["(?~(?:a*aa))", "aaa"],
      ["(?~(?:a*aa))", "aaab"],
      ["(?~(?:a*aaa))", "aaaa"]
    ].each do |pattern, input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal expected.offset(0), actual.offset(0), pattern
    end
  end

  def test_absence_operator_uses_star_wildcard_boundary
    %w[aaab aaaab].each do |input|
      pattern = "(?~(?:a*.))"
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a
      assert_equal expected.offset(0), actual.offset(0)
    end
  end

  def test_absence_operator_uses_same_wildcard_quantifier_boundary
    %w[aab aaab aaaab abab].each do |input|
      pattern = "(?~(?:.*.))"
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a
      assert_equal expected.offset(0), actual.offset(0)
    end
  end

  def test_absence_operator_uses_fixed_width_wildcard_suffix_boundary
    {
      "(?~(?:.*[ab]))" => %w[aaa aaaa aaaaa aaac aaca abca aca acb],
      "(?~(?:.*aa))" => %w[aaa aaaa aaaaa],
      "(?~(?:.*(a|b)))" => %w[aaa aaaa aaaaa aaac aaca abca aca acb],
      "(?~(?:.*a+))" => %w[aaa baa aaaa aaab aaba baaa]
    }.each do |pattern, inputs|
      inputs.each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)

        assert_equal expected.to_a, actual.to_a
        assert_equal expected.offset(0), actual.offset(0)
      end
    end
  end

  def test_absence_operator_replays_variable_suffix_backtracking
    pattern = "(?~(?:.*(ab|a)))"
    inputs = %w[aba aab aabaa abba xxaba xaba xxxaba xxxxaba]

    inputs.each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_replays_finite_and_positive_quantifier_probes
    cases = [
      ["(?~(?:a?(ab|a)))", %w[aab aaba baab]],
      ["(?~(?:b+(ab|a)))", %w[bab baab]],
      ["(?~(?:b*(a|aa)))", %w[ba baa bbaa bbba bbbaa]]
    ]

    cases.each do |pattern, inputs|
      inputs.each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)

        assert_equal expected.to_a, actual.to_a, [pattern, input]
        assert_equal expected.offset(0), actual.offset(0), [pattern, input]
      end
    end
  end

  def test_absence_operator_restores_repeated_suffix_capture_frames
    {
      "(?~(?:a+(a|aa)))" => %w[aaa aab aaba baa bbaa baab],
      "(?~(?:a+(ab|a)))" => %w[aaa aaba baab],
      "(?~(?:b+(ab|a)))" => %w[bab baab bbaa]
    }.each do |pattern, inputs|
      inputs.each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)

        assert_equal expected.to_a, actual.to_a, [pattern, input]
        assert_equal expected.offset(0), actual.offset(0), [pattern, input]
      end
    end
  end

  def test_absence_operator_uses_consuming_width_for_nullable_suffix
    ["(?~(?:.*a?))", "(?~(?:.*a*))"].each do |pattern|
      %w[aaa abac abba aabaa ac].each do |input|
        expected = ::Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)

        assert_equal expected.to_a, actual.to_a, [pattern, input]
        assert_equal expected.offset(0), actual.offset(0), [pattern, input]
      end
    end
  end

  def test_absence_operator_retries_after_a_nested_zero_width_body
    %w[aa ab abc].each do |input|
      pattern = "(?~(?~a))"
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_keeps_a_nullable_body_capture
    match = Onibi::Regexp.new("(?~(a?))").match("a")

    assert_equal ["", "a"], match.to_a
    assert_equal [0, 0], match.offset(0)
    assert_equal [0, 1], match.offset(1)
  end

  def test_absence_operator_propagates_nested_bytecode_endpoints
    cases = [
      ["(?~(?~(?=a)))", "ab"],
      ["(?~(?~(?=a)))", "abb"],
      ["(?~(?:b(?~(?=a))))", "ba"]
    ]

    cases.each do |pattern, input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)
      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_handles_overlapping_nested_zero_width_boundaries
    cases = [
      ["(?~(?:a(?~(?=a))))", "aa"],
      ["(?~(?:b(?~(?=a))))", "ba"],
      ["(?~(?:b(?~(?=b))))", "bb"]
    ]

    cases.each do |pattern, input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)
      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_preserves_alternation_branch_order
    cases = [
      ["(?~(?:b|(?~(?=a))))", "abb"],
      ["(?~(?:(?~(?=a))|b))", "abb"]
    ]

    cases.each do |pattern, input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)
      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_accounts_for_suffix_after_nested_zero_width_body
    %w[ab aba abb aab].each do |input|
      pattern = "(?~(?:(?~(?=a))b))"
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)
      assert_equal expected.to_a, actual.to_a, input
      assert_equal expected.offset(0), actual.offset(0), input
    end
  end

  def test_absence_operator_handles_unbounded_range_bodies
    regexp = Onibi::Regexp.new("(?~a{2,})")

    assert_equal(%w[aa aaa], %w[aaaa aaaaa].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_unbounded_class_ranges
    regexp = Onibi::Regexp.new("(?~[ab]{2,})")

    assert_equal(%w[aa ab], %w[aaaa abab].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_unbounded_group_ranges
    regexp = Onibi::Regexp.new("(?~(ab){2,})")

    assert_equal(%w[ab aba ababa], %w[ab abab ababab].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_unbounded_alternation_ranges
    regexp = Onibi::Regexp.new("(?~(a|b){2,})")

    assert_equal(%w[ab aba], %w[abab ababab].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_handles_variable_alternation_lengths
    regexp = Onibi::Regexp.new("(?~(a|ab){2,})")

    assert_equal(%w[aa ab ab], %w[aaa abab ababa].map { |input| regexp.match(input)[0] })
  end

  def test_absence_operator_does_not_export_quantifier_body_captures
    fixed_pattern = "(?~(a|b){2})"
    fixed_expected = ::Regexp.new(fixed_pattern).match("xabab")
    fixed_actual = Onibi::Regexp.new(fixed_pattern).match("xabab")

    assert_equal %w[xa b], fixed_expected.to_a
    assert_equal fixed_expected.to_a, fixed_actual&.to_a
    assert_equal fixed_expected.offset(0), fixed_actual&.offset(0)
    assert_equal fixed_expected.offset(1), fixed_actual&.offset(1)

    match = Onibi::Regexp.new("(?~(a|b){2,})").match("xabab")

    assert_equal "xab", match[0]
    assert_nil match[1]
  end

  def test_absence_operator_handles_nested_equal_length_captures
    match = Onibi::Regexp.new("(?~((a|b)){2,})").match("abab")

    assert_equal "ab", match[0]
    assert_nil match[1]
    assert_nil match[2]
  end

  def test_absence_operator_clears_nested_repeat_captures
    match = Onibi::Regexp.new("(?~((ab)+))").match("ab")

    assert_equal "a", match[0]
    assert_equal "ab", match[1]
    assert_nil match[2]
  end

  def test_absence_operator_tracks_odd_nested_repeat_captures
    regexp = Onibi::Regexp.new("(?~((ab)+))")

    odd = regexp.match("ababab")
    even = regexp.match("abab")
    assert_equal "ab", odd[1]
    assert_nil even[1]
  end

  def test_absence_operator_tracks_nested_alternation_captures
    regexp = Onibi::Regexp.new("(?~((a|b)+))")

    assert_equal %w[a b], regexp.match("aba").to_a.first(2)
    assert_equal %w[aba ab], regexp.match("ababab").to_a.first(2)
    assert_equal %w[aa a], regexp.match("aaaaa").to_a.first(2)
    assert_equal %w[aa a], regexp.match("aaaba").to_a.first(2)
  end

  def test_absence_operator_clears_nested_bounded_captures
    match = Onibi::Regexp.new("(?~((a|ab){2,}))").match("abab")

    assert_equal "ab", match[0]
    assert_nil match[1]
    assert_nil match[2]

    match = Onibi::Regexp.new("(?~((a|ab){2,}))").match("aa")

    assert_equal %w[a aa], match.to_a.first(2)
    assert_nil match[2]
  end

  def test_absence_operator_tracks_variable_nested_alternation
    regexp = Onibi::Regexp.new("(?~((ab|a)+))")

    assert_equal %w[ab a], regexp.match("abab").to_a.first(2)
    assert_equal %w[abab], regexp.match("ababab").to_a.first(1)
    assert_equal %w[a a], regexp.match("aaa").to_a.first(2)
    assert_equal %w[aa ab], regexp.match("aaba").to_a.first(2)
  end

  def test_absence_operator_tracks_nullable_nested_repeat_frames
    regexp = Onibi::Regexp.new("(?~((ab|a)*))")

    assert_equal ["a", ""], regexp.match("aba").to_a.first(2)
    assert_equal ["aa", ""], regexp.match("aabaa").to_a.first(2)
  end

  def test_absence_operator_tracks_bounded_variable_alternation
    regexp = Onibi::Regexp.new("(?~((ab|a){2,}))")

    assert_equal %w[aba], regexp.match("abab").to_a.first(1)
    assert_equal %w[abab], regexp.match("ababab").to_a.first(1)
  end

  def test_absence_operator_tracks_finite_nested_repeat_frames
    regexp = Onibi::Regexp.new("(?~((ab|a){1,3}))")

    assert_equal ["", "a"], regexp.match("a").to_a.first(2)
    assert_equal %w[aa ab], regexp.match("aaba").to_a.first(2)

    nullable = Onibi::Regexp.new("(?~((ab|a){0,3}))")

    assert_equal ["a", ""], nullable.match("aba").to_a.first(2)
  end

  def test_absence_operator_restores_nested_repeat_suffix_frames
    regexp = Onibi::Regexp.new("(?~((ab|a)+b))")

    assert_equal %w[a ab], regexp.match("ab").to_a.first(2)
    assert_equal ["aa", nil], regexp.match("aab").to_a.first(2)
    assert_equal ["ab", nil], regexp.match("abb").to_a.first(2)
  end

  def test_absence_operator_restores_deep_nested_repeat_captures
    regexp = Onibi::Regexp.new("(?~(((a|b)+)c))")

    assert_equal %w[a ac a], regexp.match("ac").to_a.first(3)
    assert_equal ["aa", nil, "a"], regexp.match("aac").to_a.first(3)

    variable = Onibi::Regexp.new("(?~(((ab|a)+)c))")
    assert_equal ["ab", nil, nil], variable.match("ab").to_a.first(3)
    assert_equal ["aa", nil, "a"], variable.match("aac").to_a.first(3)
  end

  def test_absence_operator_restores_outer_quantifier_suffix_captures
    pattern = "(?~((a|b)+)c)"
    assert_absence_failed_probe_control(
      label: "outer quantifier later bound failure",
      pattern: pattern,
      subject: "aac",
      start: 0,
      expected_values: ["aa", "a", nil],
      expected_char_ranges: [[0, 2], [1, 2], [nil, nil]],
      expected_byte_ranges: [[0, 2], [1, 2], [nil, nil]]
    )

    regexp = Onibi::Regexp.new(pattern)

    assert_equal ["a", nil, nil], regexp.match("a").to_a.first(3)
    assert_equal ["aa", "a", nil], regexp.match("aac").to_a.first(3)
    assert_equal ["ab", "b", nil], regexp.match("abc").to_a.first(3)
  end

  def test_absence_operator_keeps_captures_across_alternate_failed_suffixes
    pattern = "(?~((a|b)+)(?:c|d))"
    assert_absence_failed_probe_control(
      label: "alternate suffix failure at active bound",
      pattern: pattern,
      subject: "a",
      start: 0,
      expected_values: ["a", "a", nil],
      expected_char_ranges: [[0, 1], [0, 1], [nil, nil]],
      expected_byte_ranges: [[0, 1], [0, 1], [nil, nil]]
    )

    assert_absence_failed_probe_control(
      label: "alternate suffix failure before active bound",
      pattern: pattern,
      subject: "ax",
      start: 0,
      expected_values: ["ax", nil, nil],
      expected_char_ranges: [[0, 2], [nil, nil], [nil, nil]],
      expected_byte_ranges: [[0, 2], [nil, nil], [nil, nil]]
    )
  end

  def test_absence_operator_restores_nested_suffix_group_captures
    pattern = "(?~((a|bc)+)(d|e))"
    assert_absence_failed_probe_control(
      label: "nested suffix direct capture at active bound",
      pattern: pattern,
      subject: "bca",
      start: 0,
      expected_values: ["bca", "a", nil, nil],
      expected_char_ranges: [[0, 3], [2, 3], [nil, nil], [nil, nil]],
      expected_byte_ranges: [[0, 3], [2, 3], [nil, nil], [nil, nil]]
    )

    regexp = Onibi::Regexp.new(pattern)

    assert_equal ["bc", nil, nil, "d"], regexp.match("bcd").to_a.first(4)
    assert_equal ["babc", nil, nil, nil], regexp.match("babcd").to_a.first(4)
    assert_equal ["aa", "a", nil, nil], regexp.match("aad").to_a.first(4)
    assert_equal ["bca", "a", nil, nil], regexp.match("bca").to_a.first(4)

    variable = Onibi::Regexp.new("(?~((ab|a)+)(c|d))")
    assert_equal ["ab", nil, nil, "c"], variable.match("abc").to_a.first(4)
  end

  def test_absence_operator_keeps_a_capture_from_an_earlier_failed_sibling
    pattern = "(?~\\A((?:a|abz))c)"

    assert_absence_failed_probe_control(
      label: "direct close from an earlier failed sibling",
      pattern: pattern,
      subject: "abx",
      start: 0,
      expected_values: %w[abx a],
      expected_char_ranges: [[0, 3], [0, 1]],
      expected_byte_ranges: [[0, 3], [0, 1]]
    )
  end

  def test_absence_operator_keeps_unopened_fixed_repeat_capture_unset
    pattern = "(?~(a|b){3})"

    assert_absence_failed_probe_control(
      label: "fixed repeat capture has no start tag",
      pattern: pattern,
      subject: "xabab",
      start: 0,
      expected_values: ["xab", nil],
      expected_char_ranges: [[0, 3], [nil, nil]],
      expected_byte_ranges: [[0, 3], [nil, nil]]
    )
  end

  def test_absence_operator_clears_nullable_nested_captures
    regexp = Onibi::Regexp.new("(?~((a?|b)+))")

    assert_equal ["", nil, nil], regexp.match("").to_a
    assert_equal ["", nil, nil], regexp.match("b").to_a
    assert_equal %w[a a], regexp.match("baaa").to_a.first(2)
  end

  def test_absence_endpoint_matches_empty_input
    assert_absence_endpoint_control(
      label: "empty input",
      pattern: "(?~a)",
      subject: "",
      start: 0,
      expected_values: [""],
      expected_char_ranges: [[0, 0]],
      expected_byte_ranges: [[0, 0]],
      diagnostics: true
    )
  end

  def test_absence_endpoint_preserves_start_zero
    assert_absence_endpoint_control(
      label: "start zero",
      pattern: "(?~(?:b(?~(?=a))))",
      subject: "xba",
      start: 0,
      expected_values: ["xba"],
      expected_char_ranges: [[0, 3]],
      expected_byte_ranges: [[0, 3]],
      diagnostics: true
    )
  end

  def test_absence_endpoint_preserves_nonzero_search_start
    assert_absence_endpoint_control(
      label: "start one",
      pattern: "(?~(?:b(?~(?=a))))",
      subject: "xba",
      start: 1,
      expected_values: ["ba"],
      expected_char_ranges: [[1, 3]],
      expected_byte_ranges: [[1, 3]],
      diagnostics: false
    )
  end

  def test_absence_endpoint_retries_for_required_suffix
    assert_absence_endpoint_control(
      label: "required suffix",
      pattern: "(?~(?:b(?~(?=a))))a",
      subject: "ba",
      start: 0,
      expected_values: ["ba"],
      expected_char_ranges: [[0, 2]],
      expected_byte_ranges: [[0, 2]],
      diagnostics: true
    )
  end

  def test_absence_endpoint_keeps_match_reset_start_separate
    assert_absence_endpoint_control(
      label: "match reset",
      pattern: "(?~(?:b(?~(?=a))))\\K",
      subject: "ba",
      start: 0,
      expected_values: [""],
      expected_char_ranges: [[2, 2]],
      expected_byte_ranges: [[2, 2]],
      diagnostics: true
    )
  end

  def test_absence_endpoint_uses_utf8_character_boundaries
    assert_absence_endpoint_control(
      label: "UTF-8 boundaries",
      pattern: "(?~(?:λ(?~(?=α))))",
      subject: "λα",
      start: 0,
      expected_values: ["λα"],
      expected_char_ranges: [[0, 2]],
      expected_byte_ranges: [[0, 4]],
      diagnostics: true
    )
  end

  private

  def assert_absence_failed_probe_control(**control)
    label = control.fetch(:label)
    pattern = control.fetch(:pattern)
    subject = control.fetch(:subject)
    start = control.fetch(:start)
    expected_values = control.fetch(:expected_values)
    expected_char_ranges = control.fetch(:expected_char_ranges)
    expected_byte_ranges = control.fetch(:expected_byte_ranges)
    regexp = Onibi::Regexp.new(pattern)
    expected = ::Regexp.new(pattern).match(subject, start)
    actual = regexp.match(subject, start)

    assert_equal expected_values, expected.to_a, "#{label}: frozen MRI values"
    assert_equal expected_char_ranges, absence_match_char_ranges(expected),
                 "#{label}: frozen MRI character ranges"
    assert_equal expected_byte_ranges, absence_match_byte_ranges(expected),
                 "#{label}: frozen MRI byte ranges"
    assert_instance_of Onibi::MatchData, actual, "#{label}: native result type"
    assert_equal absence_match_snapshot(expected), absence_match_snapshot(actual),
                 label

    info = regexp.send(:__onibi_diagnostics__, subject)
    assert_equal 2, info[:exec_kind], "#{label}: DYNAMIC execution class"
    assert_operator info[:dynamic], :>, 0, "#{label}: DYNAMIC executor ran"
    assert_equal 0, info[:fallback], "#{label}: MRI fallback count"
    assert_equal 1, info[:status], "#{label}: diagnostic match status"
    assert_equal expected.bytebegin(0), info[:match_start],
                 "#{label}: diagnostic byte start"
    assert_equal expected.byteend(0), info[:match_end],
                 "#{label}: diagnostic byte end"
  end

  def assert_absence_endpoint_control(**control)
    label = control.fetch(:label)
    pattern = control.fetch(:pattern)
    subject = control.fetch(:subject)
    start = control.fetch(:start)
    expected_values = control.fetch(:expected_values)
    expected_char_ranges = control.fetch(:expected_char_ranges)
    expected_byte_ranges = control.fetch(:expected_byte_ranges)
    diagnostics = control.fetch(:diagnostics)
    onibi_regexp = Onibi::Regexp.new(pattern)
    expected = ::Regexp.new(pattern).match(subject, start)
    actual = onibi_regexp.match(subject, start)

    if expected.nil?
      assert_nil actual, label
      return
    end

    assert_equal expected_values, expected.to_a, "#{label}: frozen MRI values"
    assert_equal expected_char_ranges, absence_match_char_ranges(expected),
                 "#{label}: frozen MRI character ranges"
    assert_equal expected_byte_ranges, absence_match_byte_ranges(expected),
                 "#{label}: frozen MRI byte ranges"
    assert_instance_of Onibi::MatchData, actual, "#{label}: native result type"
    assert_equal absence_match_snapshot(expected), absence_match_snapshot(actual),
                 label

    return unless diagnostics

    info = onibi_regexp.send(:__onibi_diagnostics__, subject)
    assert_equal 2, info[:exec_kind], "#{label}: DYNAMIC execution class"
    assert_operator info[:dynamic], :>, 0, "#{label}: DYNAMIC executor ran"
    assert_equal 0, info[:fallback], "#{label}: MRI fallback count"
    assert_equal 1, info[:status], "#{label}: diagnostic match status"
    assert_equal expected.bytebegin(0), info[:match_start],
                 "#{label}: diagnostic byte start"
    assert_equal expected.byteend(0), info[:match_end],
                 "#{label}: diagnostic byte end"
    expected_capture_ranges = (1...expected_values.length).map do |index|
      expected.byteoffset(index).map { |position| position || -1 }
    end
    assert_equal expected_capture_ranges, info[:captures],
                 "#{label}: diagnostic capture byte ranges"
  end

  def absence_match_char_ranges(match)
    match.to_a.each_index.map { |index| match.offset(index) }
  end

  def absence_match_byte_ranges(match)
    match.to_a.each_index.map { |index| match.byteoffset(index) }
  end

  def absence_match_snapshot(match)
    {
      values: match.to_a,
      character_ranges: absence_match_char_ranges(match),
      byte_ranges: absence_match_byte_ranges(match)
    }
  end
end
