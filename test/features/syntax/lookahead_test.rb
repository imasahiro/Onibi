# frozen_string_literal: true

require "test_helper"

class LookaheadTest < Minitest::Test
  def test_positive_lookahead_asserts_without_consuming
    match = Onibi::Regexp.new("a(?=b)").match("ab")

    assert_equal "a", match[0]
  end

  def test_negative_lookahead_rejects_the_asserted_suffix
    regexp = Onibi::Regexp.new("a(?!b)")

    assert_equal "a", regexp.match("ac")[0]
    assert_nil regexp.match("ab")
  end

  def test_positive_lookbehind_asserts_without_consuming
    match = Onibi::Regexp.new("(?<=a)b").match("ab")

    assert_equal "b", match[0]
  end

  def test_word_boundary_lookbehind_keeps_zero_width_bytecode_width
    pattern = "(?<=\\b)\\w\\w"
    input = "ab"
    expected = ::Regexp.new(pattern, ::Regexp::IGNORECASE).match(input)
    actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && expected.offset(0), actual && actual.offset(0)
  end

  def test_lookbehind_fold_overlap_can_feed_a_character_class
    pattern = "(?<=ß)[s]\\w"
    input = "ßss"
    expected = ::Regexp.new(pattern, ::Regexp::IGNORECASE).match(input)
    actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && expected.offset(0), actual && actual.offset(0)
  end

  def test_negative_lookbehind_rejects_the_asserted_prefix
    regexp = Onibi::Regexp.new("(?<!a)b")

    assert_equal "b", regexp.match("cb")[0]
    assert_nil regexp.match("ab")
  end

  def test_lookbehind_rejects_a_variable_width_body
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?<=a+)b") }
  end

  def test_lookbehind_accepts_finite_alternation_widths
    pattern = "(?<=a|bc)c"
    input = "bcc"

    assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
  end

  def test_ignorecase_lookbehind_uses_casefold_consumption_width
    pattern = "(?i:(?<=ß)c)"
    input = "SSc"

    assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    assert Onibi::Regexp.new(pattern).match?(input)
  end

  def test_ignorecase_lookbehind_tracks_class_and_quantifier_widths
    [["(?i:(?<=[ß])x)", "SSx"], ["(?i:(?<=[ß])x)", "ßx"],
     ["(?i:(?<=[ß]{1})x)", "SSx"], ["(?i:(?<=[ß]{1})x)", "ßx"]].each do |pattern, input|
      assert_equal Regexp.new(pattern).match?(input), Onibi::Regexp.new(pattern).match?(input)
    end

    pattern = "(?i:(?<=[aß])x)"
    assert_equal Regexp.new(pattern).match?("aßx"), Onibi::Regexp.new(pattern).match?("aßx")
  end

  def test_ignorecase_lookbehind_preserves_fold_overlap_for_literals
    [["(?<=ß)ss", "ßss"], ["(?<=ß).", "ßa"], ["(?<=ffi)ﬃ", "ﬃffi"]].each do |pattern, input|
      expected = Regexp.new(pattern, Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_reverse_fold_lookbehind_can_end_at_input_boundary
    source = "(?<=ss)ß"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßß")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßß")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_lookbehind_alternation
    source = "(?<=ss|ß)ß"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßß")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßß")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_lookbehind_fixed_quantifier_branch
    source = "(?<=s{2}|ß)ß"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßß")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßß")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_overlap_does_not_skip_same_width_literal
    source = "(?<=s{2}|ß)ss"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßß")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßß")

    assert_nil expected
    assert_nil actual
  end

  def test_ignorecase_reverse_fold_literal_matches_before_absolute_end
    source = "ss\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ß")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ß")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_alternate_fold_literal_matches_before_absolute_end
    source = "σ\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("σς")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("σς")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_greek_optional_keeps_alternate_before_absolute_end
    source = "σ?\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("σς")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("σς")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_greek_backreference_keeps_alternate_capture
    source = "(σ)\\1\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ςσ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ςσ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_long_s_fixed_repeat_stops_before_absolute_end
    source = "s{2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("sſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("sſ")

    assert_nil expected
    assert_nil actual
  end

  def test_ignorecase_long_s_reverse_literal_run_stops_before_absolute_end
    source = "ss\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_nil expected
    assert_nil actual
  end

  def test_ignorecase_long_s_class_repeat_stops_before_absolute_end
    source = "[s]{2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_nil expected
    assert_nil actual
  end

  def test_ignorecase_alternate_long_s_class_repeat_stops_at_anchor
    source = "[ſ]{2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_nil expected
    assert_nil actual
  end

  def test_atomic_simple_fold_alternation_end_bound_matches_mri
    cases = [
      ["target omitted origin", "(?>ſ|s)\\z", "ſ",
       Onibi::Regexp::IGNORECASE, :omitted, nil, 17, :native],
      ["target zero origin", "(?>ſ|s)\\z", "ſ",
       Onibi::Regexp::IGNORECASE, 0, nil, 17, :native],
      ["target longer subject", "(?>ſ|s)\\z", "xſ",
       Onibi::Regexp::IGNORECASE, :omitted, nil, 17, :native],
      ["target interior origin", "(?>ſ|s)\\z", "xſ",
       Onibi::Regexp::IGNORECASE, 1, nil, 17, :native],
      ["target end origin", "(?>ſ|s)\\z", "xſ",
       Onibi::Regexp::IGNORECASE, 2, nil, 17, :native],
      ["target empty subject", "(?>ſ|s)\\z", "",
       Onibi::Regexp::IGNORECASE, :omitted, nil, 17, :native],
      ["target explicit fixed encoding", "(?>ſ|s)\\z", "ſ",
       Onibi::Regexp::IGNORECASE | Onibi::Regexp::FIXEDENCODING,
       :omitted, nil, 17, :native],
      ["target option off", "(?>ſ|s)\\z", "ſ", 0,
       :omitted,
       { values: ["ſ"], character_spans: [[0, 1]], byte_spans: [[0, 2]] },
       16, :native],
      ["leading absolute start", "\\A(?>ſ|s)\\z", "ſ",
       Onibi::Regexp::IGNORECASE, :omitted,
       { values: ["ſ"], character_spans: [[0, 1]], byte_spans: [[0, 2]] },
       17, :native],
      ["swapped branches", "(?>s|ſ)\\z", "ſ",
       Onibi::Regexp::IGNORECASE, :omitted, nil, 17, :native],
      ["equivalent uppercase fold", "(?>S|ſ)\\z", "ſ",
       Onibi::Regexp::IGNORECASE, :omitted, nil, 17, :native],
      ["equal one-byte width", "(?>ſ|s)\\z", "xs",
       Onibi::Regexp::IGNORECASE, :omitted,
       { values: ["s"], character_spans: [[1, 2]], byte_spans: [[1, 2]] },
       17, :native],
      ["equal two-byte width", "(?>σ|ς)\\z", "xς",
       Onibi::Regexp::IGNORECASE, :omitted,
       { values: ["ς"], character_spans: [[1, 2]], byte_spans: [[1, 3]] },
       17, :native],
      ["mixed-width maximum", "(?>ſ|σ)\\z", "xſ",
       Onibi::Regexp::IGNORECASE, 1,
       { values: ["ſ"], character_spans: [[1, 2]], byte_spans: [[1, 3]] },
       17, :native],
      ["scoped-option fallback", "(?i:ſ|s)\\z", "ſ",
       Onibi::Regexp::IGNORECASE, :omitted, nil, 17, :fallback]
    ]
    failures = []

    cases.each do |row|
      label, source, subject, options, origin, frozen_mri, effective_options, route_kind = row
      mri_regexp = ::Regexp.new(source, options)
      onibi_regexp = Onibi::Regexp.new(source, options)
      mri_match = if origin == :omitted
                    mri_regexp.match(subject)
                  else
                    mri_regexp.match(subject, origin)
                  end
      onibi_match = if origin == :omitted
                      onibi_regexp.match(subject)
                    else
                      onibi_regexp.match(subject, origin)
                    end
      mri_row = match_observation(mri_match, subject)
      onibi_row = match_observation(onibi_match, subject)
      failures << "#{label}: MRI changed to #{mri_row.inspect}" if mri_row != frozen_mri
      if mri_regexp.options != effective_options
        failures << "#{label}: MRI options=#{mri_regexp.options}, " \
                    "expected #{effective_options}"
      end
      if onibi_row != mri_row
        failures << "#{label}: MRI=#{mri_row.inspect}, " \
                    "Onibi=#{onibi_row.inspect}"
      end

      diagnostics = onibi_regexp.send(:__onibi_diagnostics__, subject)
      if route_kind == :fallback
        unless diagnostics.fetch(:fallback) == 1 &&
               diagnostics.fetch(:fallback_reason) == :input_ineligible
          failures << "#{label}: route=#{diagnostics.inspect}"
        end
      elsif !diagnostics.fetch(:rseq) || diagnostics.fetch(:exec_kind).nil? ||
            diagnostics.fetch(:fallback) != 0 ||
            diagnostics.fetch(:fallback_reason) != :none
        # The end bound can reject a candidate before DYNAMIC runs.
        failures << "#{label}: route=#{diagnostics.inspect}"
      end
      if diagnostics.fetch(:unsupported_reason) != :none ||
         diagnostics.fetch(:executor_error_kind) != :none
        failures << "#{label}: route error=#{diagnostics.inspect}"
      end
    rescue StandardError => e
      failures << "#{label}: #{e.class}: #{e.message}"
    end

    assert_empty failures, failures.join("\n")
  end

  def test_ignorecase_long_s_optional_class_stops_before_absolute_end
    source = "[s]?\\z"
    subject = "ſ"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(subject)
    regexp = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE)
    actual = regexp.match(subject)

    assert_equal [""], expected&.to_a
    assert_equal [1, 1], [expected.begin(0), expected.end(0)]
    assert_equal [2, 2], expected.byteoffset(0)
    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
    assert_equal expected && expected.byteoffset(0),
                 actual && actual.byteoffset(0)
    assert_native_route(regexp, subject, source)
  end

  def test_ignorecase_optional_singleton_class_end_matrix_matches_mri
    cases = [
      ["long-s", "[s]?\\z", "ſ", Onibi::Regexp::IGNORECASE],
      ["long-s-fixed", "[s]?\\z", "ſ",
       Onibi::Regexp::IGNORECASE | Onibi::Regexp::FIXEDENCODING],
      ["kelvin-k", "[k]?\\z", "K", Onibi::Regexp::IGNORECASE],
      ["kelvin-upper-k-fixed", "[K]?\\z", "K",
       Onibi::Regexp::IGNORECASE | Onibi::Regexp::FIXEDENCODING],
      ["ascii-positive", "[a]?\\z", "a", Onibi::Regexp::IGNORECASE],
      ["ascii-nonmatch", "[a]?\\z", "b", Onibi::Regexp::IGNORECASE],
      ["empty-subject", "[s]?\\z", "", Onibi::Regexp::IGNORECASE],
      ["multiline-subject", "[s]?\\z", "line\nſ",
       Onibi::Regexp::IGNORECASE],
      ["anchored-full-character", "\\A[s]?\\z", "ſ",
       Onibi::Regexp::IGNORECASE],
      ["option-off", "[s]?\\z", "ſ", 0],
      ["standalone-class", "[s]", "ſ", Onibi::Regexp::IGNORECASE],
      ["backreference-end-bound", "(s)\\1\\z", "ss",
       Onibi::Regexp::IGNORECASE],
      ["lookahead-origin-bound", "(?=\\z).*", "x",
       Onibi::Regexp::MULTILINE]
    ]
    ascii_source = "[s]?\\z".dup.force_encoding(Encoding::US_ASCII)
    ascii_subject = "s".dup.force_encoding(Encoding::US_ASCII)
    cases << ["ascii-source", ascii_source, ascii_subject,
              Onibi::Regexp::IGNORECASE]
    cases << ["ascii-source-fixed", ascii_source, ascii_subject,
              Onibi::Regexp::IGNORECASE | Onibi::Regexp::FIXEDENCODING]

    cases.each do |label, source, subject, options|
      expected = ::Regexp.new(source, options).match(subject)
      regexp = Onibi::Regexp.new(source, options)
      actual = regexp.match(subject)

      assert_equal expected&.to_a, actual&.to_a, label
      expected_ranges = expected&.to_a&.each_index&.map do |index|
        [expected.begin(index), expected.end(index)]
      end
      actual_ranges = actual&.to_a&.each_index&.map do |index|
        [actual.begin(index), actual.end(index)]
      end
      assert_equal expected_ranges, actual_ranges, label

      expected_byte_ranges = expected&.to_a&.each_index&.map do |index|
        expected.byteoffset(index)
      end
      actual_byte_ranges = actual&.to_a&.each_index&.map do |index|
        actual.byteoffset(index)
      end
      assert_equal expected_byte_ranges, actual_byte_ranges, label
      assert_native_route(regexp, subject, label)
    end
  end

  def test_ignorecase_optional_singleton_class_end_keeps_match_offsets
    source = "[s]?\\z"
    options = Onibi::Regexp::IGNORECASE
    regexp = Onibi::Regexp.new(source, options)
    cases = [
      ["omitted", "ſ", nil],
      ["zero", "ſ", 0],
      ["nonzero", "aſ", 1],
      ["end", "aſ", 2]
    ]

    cases.each do |label, subject, offset|
      expected_regexp = ::Regexp.new(source, ::Regexp::IGNORECASE)
      expected = if offset.nil?
                   expected_regexp.match(subject)
                 else
                   expected_regexp.match(subject, offset)
                 end
      actual = offset.nil? ? regexp.match(subject) : regexp.match(subject, offset)

      assert_equal expected&.to_a, actual&.to_a, label
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)], label
      assert_equal expected && expected.byteoffset(0),
                   actual && actual.byteoffset(0), label
      assert_native_route(regexp, subject, label)
    end
  end

  def test_ignorecase_posix_optional_class_keeps_single_source_width
    source = "[[:alpha:]]?\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ss")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ss")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_unicode_property_optional_class_keeps_fold_width
    source = "[\\p{L}]?\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ss")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ss")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_posix_fixed_repeat_keeps_source_width_at_anchor
    source = "[[:alpha:]]{2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ffi")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ffi")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_posix_class_keeps_source_width_at_anchor
    source = "[[:alpha:]]\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("SS")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("SS")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_alternate_reverse_fold_is_not_accepted_at_anchor
    source = "(ſ|s)\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_expanded_lookbehind_preserves_mri_zero_width_tail
    source = "(?<=ß)\\p{L}"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßa")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßa")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_literal_is_not_accepted_at_anchor
    [["ſ\\z", "ſ"], ["K\\z", "K"], ["(a|ſ)\\z", "ſ"]].each do |source, input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_posix_alternation_keeps_source_width_at_anchor
    source = "(a|[[:alpha:]])\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("SS")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("SS")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_posix_optional_can_expand_a_non_ascii_source_at_anchor
    source = "[[:alpha:]]?\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_property_alternation_keeps_expanded_width_at_anchor
    ["(a|\\p{L})\\z", "(\\p{L}|a)\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("SS")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("SS")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_reverse_fold_lookbehind_keeps_zero_width_tail
    ["(?<=ss)\\p{L}", "(?<=ss)."].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ßa")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ßa")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_nested_posix_repeat_keeps_codepoint_width_at_anchor
    ["(?:[[:alpha:]]){2}\\z", "(?:[[:alpha:]]){2}$"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ffi")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ffi")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_property_capture_backreference_keeps_fold_origin
    source = "(\\p{L}|ß)\\1\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_expanded_lookbehind_rejects_direct_tail_before_input
    [["(?<=a|ß)x", "ßx"], ["(?<!a|ß)x", "ßx"]].each do |source, input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_expanded_lookbehind_does_not_match_direct_tail
    [["(?<=ß)ß", "ßa"], ["(?<=ß)a", "ßa"], ["(?<=ss)a", "ßa"]].each do |source, input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_lookbehind_prefers_expanded_overlap_at_later_position
    source = "(?<=ss|s)s"
    input = "ßss"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_lookbehind_uses_branch_fold_width
    [["(?<=ss|a)a", "ßa"], ["(?<=ss|a)a", "ßaa"],
     ["(?<=s|ß)a*", "ßss"],
     ["(?<=ß|ffi)ffi", "ﬃffi"], ["(?<=ß|ffi)ffi", "ßffi"],
     ["(?<=ffi|ß)a*", "ßffi"], ["(?<=a|ß)a?", "ßs"],
     ["(?<=ß|ﬃ)ﬃ", "ﬃffi"], ["(?<=ﬃ)ﬃ", "ﬃffi"],
     ["(?<=ss)a", "ßaa"]].each do |source, input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_lookbehind_overlap_limits_following_quantifier
    [["(?<=ß)a*", "ßaa"], ["(?<=ß)a+", "ßaa"], ["(?<=ß)a?", "ßß"]].each do |source, input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)
      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end

    [["(?<=ß)a{0,2}", "ßaaa"], ["(?<=ß)a{1,2}", "ßaa"]].each do |source, input|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)
      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_reverse_fold_anchor_boundary_through_wrappers
    ["(?>ſ|s)\\z", "(?i:ſ|s)\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſ")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſ")

      if expected.nil?
        assert_nil actual&.to_a
        assert_nil actual && [actual.begin(0), actual.end(0)]
      else
        assert_equal expected.to_a, actual&.to_a
        assert_equal [expected.begin(0), expected.end(0)],
                     actual && [actual.begin(0), actual.end(0)]
      end
    end
  end

  def test_ignorecase_property_alternation_keeps_width_with_absolute_start
    source = "\\A(?:\\p{L}|a)\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("SS")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("SS")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_posix_capture_backreference_keeps_identical_long_s
    source = "([[:alpha:]])\\1\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_property_quantifier_backreference_keeps_nonempty_capture
    ["(\\p{L}+?)\\1\\z", "(\\p{L}*)\\1\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_alternating_and_unbounded_captures_keep_fold_origin
    ["(s|ß)\\1\\z", "(s)*\\1\\z", "(s)+\\1\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_greek_direct_capture_backreference_matches_mri_end_range
    source_scalar = "\u{1F80}"
    normalized_scalar = "\u{1F00}\u03B9"
    variant_scalar = "\u{1F08}\u03B9"
    source = "(?i:(?<p>#{source_scalar}))\\k<p>\\z"
    long_subject = "abcdefghij#{normalized_scalar * 2}"

    normalized_match = {
      values: [normalized_scalar * 2, normalized_scalar],
      character_spans: [[0, 4], [0, 2]],
      byte_spans: [[0, 10], [0, 5]]
    }
    four_byte_prefix_match = {
      values: [normalized_scalar * 2, normalized_scalar],
      character_spans: [[1, 5], [1, 3]],
      byte_spans: [[4, 14], [4, 9]]
    }
    long_subject_match = {
      values: [normalized_scalar * 2, normalized_scalar],
      character_spans: [[10, 14], [10, 12]],
      byte_spans: [[10, 20], [10, 15]]
    }
    absolute_start_match = {
      values: [source_scalar * 2, source_scalar],
      character_spans: [[0, 2], [0, 1]],
      byte_spans: [[0, 6], [0, 3]]
    }
    insensitive_reference_match = {
      values: [normalized_scalar + variant_scalar, normalized_scalar],
      character_spans: [[0, 4], [0, 2]],
      byte_spans: [[0, 10], [0, 5]]
    }
    sharp_s = "\u00DF"
    sharp_s_source = "(?i:(?<p>#{sharp_s}))\\k<p>\\z"
    sharp_s_match = {
      values: [sharp_s * 2, sharp_s],
      character_spans: [[0, 2], [0, 1]],
      byte_spans: [[0, 4], [0, 2]]
    }
    insensitive_reference_source =
      "(?i:(?<p>#{source_scalar})\\k<p>)\\z"
    cases = [
      ["short source", source, source_scalar * 2, :omitted, nil],
      ["normalized source", source, normalized_scalar * 2, :omitted,
       normalized_match],
      ["four-byte prefix", source,
       "😀#{normalized_scalar * 2}", :omitted, four_byte_prefix_match],
      ["ten-byte prefix from zero", source, long_subject, 0,
       long_subject_match],
      ["positive origin before candidate", source, long_subject, 9,
       long_subject_match],
      ["negative origin at candidate", source, long_subject, -4,
       long_subject_match],
      ["origin at subject end", source, long_subject, 14, nil],
      ["origin beyond subject end", source, long_subject, 15, nil],
      ["leading absolute start", "\\A#{source}", source_scalar * 2, 0,
       absolute_start_match],
      ["sensitive reference control", source,
       normalized_scalar + variant_scalar, :omitted, nil],
      ["insensitive reference control", insensitive_reference_source,
       normalized_scalar + variant_scalar, :omitted,
       insensitive_reference_match],
      ["sharp-s control", sharp_s_source, sharp_s * 2, 0, sharp_s_match]
    ]
    failures = []

    cases.each do |label, pattern, subject, origin, frozen_mri|
      mri_regexp = ::Regexp.new(pattern)
      onibi_regexp = Onibi::Regexp.new(pattern)
      expected = if origin == :omitted
                   mri_regexp.match(subject)
                 else
                   mri_regexp.match(subject, origin)
                 end
      actual = if origin == :omitted
                 onibi_regexp.match(subject)
               else
                 onibi_regexp.match(subject, origin)
               end
      expected_row = match_observation(expected, subject)
      actual_row = match_observation(actual, subject)
      if expected_row != frozen_mri
        failures << "#{label}: MRI=#{expected_row.inspect}, " \
                    "frozen=#{frozen_mri.inspect}"
      end
      if actual_row != expected_row
        failures << "#{label}: MRI=#{expected_row.inspect}, " \
                    "Onibi=#{actual_row.inspect}"
      end

      expected_bytes = expected&.to_a&.each_index&.map do |index|
        expected.byteoffset(index)
      end
      actual_bytes = actual&.to_a&.each_index&.map do |index|
        actual.byteoffset(index)
      end
      frozen_bytes = frozen_mri&.fetch(:byte_spans)
      if expected_bytes != frozen_bytes
        failures << "#{label}: MRI byte offsets=#{expected_bytes.inspect}, " \
                    "frozen=#{frozen_bytes.inspect}"
      end
      if actual_bytes != expected_bytes
        failures << "#{label}: Onibi byte offsets=#{actual_bytes.inspect}, " \
                    "MRI=#{expected_bytes.inspect}"
      end

      diagnostics = onibi_regexp.send(:__onibi_diagnostics__, subject)
      if !diagnostics.fetch(:rseq) || diagnostics.fetch(:exec_kind) != 2 ||
         diagnostics.fetch(:fallback) != 0 ||
         diagnostics.fetch(:fallback_reason) != :none ||
         diagnostics.fetch(:unsupported_reason) != :none ||
         diagnostics.fetch(:executor_error_kind) != :none
        failures << "#{label}: native route=#{diagnostics.inspect}"
      end
      failures << "#{label}: native DYNAMIC did not run" if
        frozen_mri && diagnostics.fetch(:dynamic).zero?
      failures << "#{label}: MRI minimum distance must reject before DYNAMIC" if
        label == "short source" && !diagnostics.fetch(:dynamic).zero?
    rescue StandardError => e
      failures << "#{label}: #{e.class}: #{e.message}"
    end

    assert_empty failures, failures.join("\n")
  end

  def test_ignorecase_greek_numeric_backreference_matches_mri_short_source
    source_scalar = "\u{1F80}"
    pattern = "(?i:(#{source_scalar}))\\1\\z"
    subject = source_scalar * 2
    expected = ::Regexp.new(pattern).match(subject)
    onibi_regexp = Onibi::Regexp.new(pattern)
    actual = onibi_regexp.match(subject)
    failures = []

    expected_row = match_observation(expected, subject)
    actual_row = match_observation(actual, subject)
    failures << "MRI=#{expected_row.inspect}, frozen=nil" unless
      expected_row.nil?
    failures << "MRI=#{expected_row.inspect}, Onibi=#{actual_row.inspect}" if
      actual_row != expected_row

    expected_bytes = expected&.to_a&.each_index&.map do |index|
      expected.byteoffset(index)
    end
    actual_bytes = actual&.to_a&.each_index&.map do |index|
      actual.byteoffset(index)
    end
    failures << "MRI byte offsets=#{expected_bytes.inspect}, frozen=nil" unless
      expected_bytes.nil?
    if actual_bytes != expected_bytes
      failures << "Onibi byte offsets=#{actual_bytes.inspect}, " \
                  "MRI=#{expected_bytes.inspect}"
    end

    diagnostics = onibi_regexp.send(:__onibi_diagnostics__, subject)
    if !diagnostics.fetch(:rseq) || diagnostics.fetch(:exec_kind) != 2 ||
       diagnostics.fetch(:fallback) != 0 ||
       diagnostics.fetch(:fallback_reason) != :none ||
       diagnostics.fetch(:unsupported_reason) != :none ||
       diagnostics.fetch(:executor_error_kind) != :none
      failures << "native route=#{diagnostics.inspect}"
    end
    failures << "MRI minimum distance must reject before DYNAMIC" unless
      diagnostics.fetch(:dynamic).zero?

    assert_empty failures, failures.join("\n")
  end

  def test_ignorecase_reverse_literal_repeat_rejects_folded_capture_backreference
    source = "(ſ)+\\1\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("SS")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("SS")

    if expected.nil?
      assert_nil actual&.to_a
      assert_nil actual && [actual.begin(0), actual.end(0)]
    else
      assert_equal expected.to_a, actual&.to_a
      assert_equal [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_reverse_literal_repeat_matches_mri_end_distance_cases
    ignorecase = ::Regexp::IGNORECASE
    onibi_ignorecase = Onibi::Regexp::IGNORECASE
    fixed = ::Regexp::FIXEDENCODING
    onibi_fixed = Onibi::Regexp::FIXEDENCODING
    cases = [
      ["short subject", "(ſ)+\\1\\z", "SS", nil, ignorecase,
       onibi_ignorecase],
      ["three-byte subject", "(ſ)+\\1\\z", "SSS", 0, ignorecase,
       onibi_ignorecase],
      ["short origin zero", "(ſ)+\\1\\z", "xSS", 0, ignorecase,
       onibi_ignorecase],
      ["range equality origin", "(ſ)+\\1\\z", "xSS", 1, ignorecase,
       onibi_ignorecase],
      ["end origin", "(ſ)+\\1\\z", "xSS", 3, ignorecase,
       onibi_ignorecase],
      ["long subject origin zero", "(ſ)+\\1\\z", "xSSS", 0, ignorecase,
       onibi_ignorecase],
      ["long subject origin one", "(ſ)+\\1\\z", "xSSS", 1, ignorecase,
       onibi_ignorecase],
      ["empty subject", "(ſ)+\\1\\z", "", 0, ignorecase,
       onibi_ignorecase],
      ["absolute start short subject", "\\A(ſ)+\\1\\z", "SS", 0,
       ignorecase, onibi_ignorecase],
      ["absolute start nonzero origin", "\\A(ſ)+\\1\\z", "xSSS", 1,
       ignorecase, onibi_ignorecase],
      ["ASCII source control", "(S)+\\1\\z", "SS", 0, ignorecase,
       onibi_ignorecase],
      ["fixed encoding control", "(ſ)+\\1\\z", "SSS", 0,
       ignorecase | fixed, onibi_ignorecase | onibi_fixed],
      ["single capture long-s control", "(?i:(ſ))\\1\\z", "SS", 0,
       0, 0],
      ["sharp-s control", "(?i:(ß))\\1\\z", "ßß", 0, 0, 0]
    ]
    failures = []

    cases.each do |label, source, subject, origin, mri_options, onibi_options|
      mri_regexp = ::Regexp.new(source, mri_options)
      onibi_regexp = Onibi::Regexp.new(source, onibi_options)
      expected = if origin.nil?
                   mri_regexp.match(subject)
                 else
                   mri_regexp.match(subject, origin)
                 end
      actual = if origin.nil?
                 onibi_regexp.match(subject)
               else
                 onibi_regexp.match(subject, origin)
               end
      expected_row = match_observation(expected, subject)
      actual_row = match_observation(actual, subject)
      unless expected_row == actual_row
        failures << "#{label}: MRI=#{expected_row.inspect}, " \
                    "Onibi=#{actual_row.inspect}"
      end

      diagnostics = onibi_regexp.send(:__onibi_diagnostics__, subject)

      # The end-distance check rejects these subjects before the DYNAMIC VM.
      early_rejection = ["short subject", "empty subject"].include?(label)
      if early_rejection
        failures << "#{label}: native RSeq was not selected" unless
          diagnostics.fetch(:rseq) && diagnostics.fetch(:exec_kind)
        failures << "#{label}: expected rejection before DYNAMIC" unless
          diagnostics.fetch(:dynamic).zero?
      elsif diagnostics.fetch(:dynamic).zero?
        failures << "#{label}: native DYNAMIC did not run"
      end
      if diagnostics.fetch(:fallback) != 0 ||
         diagnostics.fetch(:fallback_reason) != :none ||
         diagnostics.fetch(:unsupported_reason) != :none ||
         diagnostics.fetch(:executor_error_kind) != :none
        failures << "#{label}: route diagnostics=#{diagnostics.inspect}"
      end
      if ["short subject", "short origin zero", "end origin",
          "empty subject", "absolute start nonzero origin"].include?(label) &&
         !expected.nil?
        failures << "#{label}: frozen MRI result must be nil"
      end
      if label == "range equality origin" &&
         (expected.nil? || expected.begin(0) != 1 || expected.end(0) != 3)
        failures << "#{label}: frozen MRI character range must be [1, 3]"
      end
    rescue StandardError => e
      failures << "#{label}: #{e.class}: #{e.message}"
    end

    assert_empty failures, failures.join("\n")
  end

  def test_ignorecase_reverse_fold_literal_run_can_end_at_line_anchor
    source = "ss$"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_forward_fold_literal_can_end_at_absolute_anchor
    source = "K\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("k")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("k")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_reverse_fold_quantifier_keeps_source_width_at_absolute_anchor
    source = "s{1,2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_optional_literal_capture_keeps_fold_candidate
    ["(ss?)\\1\\z", "(s?s)\\1\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_reverse_fold_repeat_restarts_at_source_boundary
    ["s{1,2}\\z", "ſ{1,2}\\z"].each do |source|
      %w[ſſ sſ ſs].each do |input|
        expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match(input)
        actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match(input)

        assert_equal expected&.to_a, actual&.to_a
        assert_equal expected && [expected.begin(0), expected.end(0)],
                     actual && [actual.begin(0), actual.end(0)]
      end
    end
  end

  def test_ignorecase_split_literal_repeat_rejects_reverse_fold_boundary
    source = "ss{1,2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_bounded_repeat_capture_keeps_backreference_candidate
    ["(ſ{1,2})\\1\\z", "(s{1,2})\\1\\z"].each do |source|
      expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("ſſ")
      actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("ſſ")

      assert_equal expected&.to_a, actual&.to_a
      assert_equal expected && [expected.begin(0), expected.end(0)],
                   actual && [actual.begin(0), actual.end(0)]
    end
  end

  def test_ignorecase_optional_forward_fold_keeps_zero_width_at_absolute_anchor
    source = "k?\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("K")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("K")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_kelvin_bounded_repeat_rejects_reverse_source_at_anchor
    source = "k{1,2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("K")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("K")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_ignorecase_greek_bounded_repeat_keeps_fold_source_width
    source = "σ{1,2}\\z"
    expected = ::Regexp.new(source, ::Regexp::IGNORECASE).match("Σ")
    actual = Onibi::Regexp.new(source, Onibi::Regexp::IGNORECASE).match("Σ")

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && [expected.begin(0), expected.end(0)],
                 actual && [actual.begin(0), actual.end(0)]
  end

  def test_lookbehind_rejects_nested_variable_width_alternation
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?<=a(?:b|cd))x") }
  end

  def test_lookbehind_rejects_variable_width_linebreak_escape
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?<=\\R).") }
  end

  private

  def assert_native_route(regexp, subject, label)
    info = regexp.send(:__onibi_diagnostics__, subject)

    assert info.fetch(:rseq), label
    refute_nil info.fetch(:exec_kind), label
    assert_equal 0, info.fetch(:fallback), label
    assert_equal :none, info.fetch(:fallback_reason), label
    assert_equal :none, info.fetch(:unsupported_reason), label
    assert_equal :none, info.fetch(:executor_error_kind), label
  end

  def match_observation(match, subject)
    return nil unless match

    character_spans = (0...match.length).map do |index|
      first = match.begin(index)
      last = match.end(index)
      first.nil? ? nil : [first, last]
    end
    byte_spans = character_spans.map do |span|
      span && [subject[0...span[0]].bytesize,
               subject[0...span[1]].bytesize]
    end
    {
      values: match.to_a,
      character_spans: character_spans,
      byte_spans: byte_spans
    }
  end
end
