# frozen_string_literal: true

require "test_helper"

class RegexpSyntaxSemanticsTest < Minitest::Test
  UNICODE_CLASS_RANGE_CASES = [
    ["original_braced_ignorecase", "[\\u{100}-\\u{200}]", ["IGNORECASE"],
     %w[s S], [true, true]],
    ["original_braced_sensitive", "[\\u{100}-\\u{200}]", [],
     %w[Ā Ȁ ā s], [true, true, true, false]],
    ["fixed_width_ignorecase", "[\\u0100-\\u0200]", ["IGNORECASE"],
     %w[s S], [true, true]],
    ["first_endpoint_braced_escape", "[\\u{100}-Ȁ]", ["IGNORECASE"],
     %w[s S], [true, true]],
    ["last_endpoint_braced_escape", "[Ā-\\u{200}]", ["IGNORECASE"],
     %w[s S], [true, true]],
    ["native_long_s_braced_range", "[\\u{17F}-\\u{17F}]", ["IGNORECASE"],
     %w[s S ſ], [true, true, true]],
    ["wide_literal_incomplete_fold", "[Ā-Ȁ]", ["IGNORECASE"],
     %w[s S], [true, true]],
    ["wide_escaped_incomplete_fold", "[\\u{100}-\\u{200}]", ["IGNORECASE"],
     %w[s S], [true, true]],
    ["multi_scalar_class_not_range", "[\\u{41 42}]", [],
     %w[A B C], [true, true, false]],
    ["multi_scalar_left_endpoint", "[\\u{41 42}-\\u{5A}]", [],
     ["A", "B", "C", "Z", "["], [true, true, true, true, false]],
    ["multi_scalar_right_endpoint", "[\\u{41}-\\u{42 43}]", [],
     %w[A B C D], [true, true, true, false]]
  ].freeze

  UNICODE_CLASS_SCALAR_BOUNDARY_CASES = [
    ["braced_minimum_scalar", "[\\u{0}]", [], ["\u0000", "\u0001"], [true, false]],
    ["fixed_width_minimum_scalar", "[\\u0000]", [], ["\u0000", "\u0001"],
     [true, false]],
    ["pre_surrogate_scalar", "[\\u{D7FF}]", [], ["\u{D7FF}", "\u{D7FE}"],
     [true, false]],
    ["post_surrogate_scalar", "[\\u{E000}]", [], ["\u{E000}", "\u{E001}"],
     [true, false]],
    ["fixed_width_bmp_maximum", "[\\uFFFF]", [], ["\uFFFF", "\uFFFE"],
     [true, false]],
    ["braced_unicode_maximum", "[\\u{10FFFF}]", [], ["\u{10FFFF}", "\u{10FFFE}"],
     [true, false]]
  ].freeze

  UNICODE_CLASS_RANGE_ROUTE_CASES = [
    ["native_long_s_braced_range", "[\\u{17F}-\\u{17F}]", ["IGNORECASE"],
     %w[s S ſ], :native],
    ["wide_literal_incomplete_fold", "[Ā-Ȁ]", ["IGNORECASE"],
     %w[s S], :input_ineligible],
    ["wide_escaped_incomplete_fold", "[\\u{100}-\\u{200}]", ["IGNORECASE"],
     %w[s S], :input_ineligible]
  ].freeze

  UNICODE_CLASS_RANGE_ERROR_CASES = [
    ["malformed_braced_escape", "[\\u{12Z}-\\u{200}]",
     "invalid Unicode list: /[\\u{12Z}-\\u{200}]/"],
    ["surrogate_scalar", "[\\u{D800}-Z]",
     "invalid Unicode range: /[\\u{D800}-Z]/"],
    ["surrogate_start_scalar", "[\\u{D800}]",
     "invalid Unicode range: /[\\u{D800}]/"],
    ["surrogate_end_scalar", "[\\u{DFFF}]",
     "invalid Unicode range: /[\\u{DFFF}]/"],
    ["fixed_width_surrogate_scalar", "[\\uD800]",
     "invalid Unicode range: /[\\uD800]/"],
    ["codepoint_above_unicode_max", "[\\u{110000}-Z]",
     "invalid Unicode range: /[\\u{110000}-Z]/"],
    ["scalar_above_unicode_max", "[\\u{110000}]",
     "invalid Unicode range: /[\\u{110000}]/"],
    ["braced_scalar_over_six_digits", "[\\u{1234567}]",
     "invalid Unicode range: /[\\u{1234567}]/"],
    ["fixed_width_escape_too_short", "[\\u000]",
     "invalid Unicode escape: /[\\u000]/"],
    ["descending_escaped_range", "[\\u{200}-\\u{100}]",
     "empty range in char class: /[\\u{200}-\\u{100}]/"]
  ].freeze

  UNICODE_ESCAPE_CLASS_ENCODING_CASES = [
    {
      label: "ascii_only_default_unicode_escape",
      pattern: "([\\u{100}])",
      source_encoding: "US-ASCII",
      options: [],
      expected_regexp: {
        encoding: "UTF-8", fixed_encoding: true, no_encoding: false, options: 16
      },
      subjects: [["Ā", "UTF-8", true], ["A", "UTF-8", false]]
    },
    {
      label: "ascii_only_fixed_encoding_conflict",
      pattern: "([\\u{100}])",
      source_encoding: "US-ASCII",
      options: ["FIXEDENCODING"],
      expected_error: {
        regexp_error: true,
        message: "incompatible character encoding: /([\\u{100}])/"
      }
    },
    {
      label: "shift_jis_non_ascii_fixed_encoding_conflict",
      pattern: "([\\u{100}])",
      source_encoding: "Shift_JIS",
      options: ["FIXEDENCODING"],
      expected_error: {
        regexp_error: true,
        message: "incompatible character encoding: /([\\u{100}])/"
      }
    },
    {
      label: "utf8_fixed_unicode_escape",
      pattern: "([\\u{100}])",
      source_encoding: "UTF-8",
      options: ["FIXEDENCODING"],
      expected_regexp: {
        encoding: "UTF-8", fixed_encoding: true, no_encoding: false, options: 16
      },
      subjects: [["Ā", "UTF-8", true], ["A", "UTF-8", false]]
    },
    {
      label: "noencoding_ascii_scalar",
      pattern: "([\\u{41}])",
      source_encoding: "US-ASCII",
      options: ["NOENCODING"],
      expected_regexp: {
        encoding: "US-ASCII", fixed_encoding: false, no_encoding: true, options: 32
      },
      subjects: [["A", "ASCII-8BIT", true], ["B", "ASCII-8BIT", false]]
    },
    {
      label: "noencoding_nonascii_scalar_conflict",
      pattern: "([\\u{100}])",
      source_encoding: "US-ASCII",
      options: ["NOENCODING"],
      expected_error: {
        regexp_error: true,
        message: "incompatible character encoding: /([\\u{100}])/"
      }
    }
  ].freeze

  UNICODE_CLASS_SYNTAX_IDENTITY_CASES = [
    ["two_escaped_ampersands", "[\\u{26}\\u{26}]", [], %w[& A], [true, false]],
    ["mixed_raw_escaped_ampersand", "[\\u{26}&]", [], %w[& A], [true, false]],
    ["escaped_hyphen_is_literal", "[A\\u{2D}Z]", [], %w[A - Z M],
     [true, true, true, false]],
    ["escaped_close_bracket_is_literal", "[\\u{5D}]", [], ["]", "["], [true, false]],
    ["escaped_caret_is_literal", "[\\u{5E}a]", [], %w[^ a b], [true, true, false]],
    ["escaped_backslash_is_literal", "[\\u{5C}]", [], ["\\", "/"], [true, false]],
    ["raw_intersection_syntax_control", "[a-z&&[^aeiou]]", [], %w[b a z e],
     [true, false, true, false]]
  ].freeze

  INCOMPLETE_CASEFOLD_CLASS_FLAG = 2
  def test_common_control_character_escapes_match_their_literal_characters
    { "n" => "\n", "r" => "\r", "t" => "\t", "f" => "\f", "v" => "\v", "a" => "\a",
      "e" => "\e" }.each do |escape, character|
      assert Onibi::Regexp.new("\\#{escape}").match?(character), escape
    end
  end

  def test_hex_and_unicode_escapes_match_literal_characters
    assert Onibi::Regexp.new("\\x41").match?("A")
    assert Onibi::Regexp.new("\\u0041").match?("A")
    assert Onibi::Regexp.new("\\u{1F600}").match?("😀")
    assert Onibi::Regexp.new("\\u{41 42}").match?("AB")
  end

  def test_octal_escapes_match_the_encoded_byte
    assert Onibi::Regexp.new("\\0").match?("\0")
    assert Onibi::Regexp.new("\\01").match?("\x01")
    assert Onibi::Regexp.new("\\10").match?("\b")
    assert Onibi::Regexp.new("\\80").match?("80")
    assert Onibi::Regexp.new("\\101").match?("A")
    assert Onibi::Regexp.new("\\141").match?("a")
  end

  def test_multi_digit_escape_uses_an_existing_capture_as_a_backreference
    pattern = "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)\\10"
    expected = ::Regexp.new(pattern).match("abcdefghijj").to_a

    assert_equal expected, Onibi::Regexp.new(pattern).match("abcdefghijj").to_a
  end

  def test_invalid_hex_and_unicode_escapes_raise_regexp_error
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\x") }
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\u12") }
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\u{}") }
  end

  def test_short_multibyte_hex_escape_matches_mri_error
    error = assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\xE9") }

    assert_equal "too short escaped multibyte character: /\\xE9/", error.message
  end

  def test_contiguous_utf8_hex_escapes_match_as_one_character
    regexp = Onibi::Regexp.new("\\xE3\\x81\\x82")
    us_ascii_regexp = Onibi::Regexp.new("\\xE3\\x81\\x82".encode(Encoding::US_ASCII))

    assert_equal Encoding::UTF_8, regexp.encoding
    assert regexp.fixed_encoding?
    assert regexp.match?("あ")
    assert us_ascii_regexp.match?("あ")
    assert us_ascii_regexp.match?("\xE3\x81\x82".b)
    refute regexp.match?("い")
    assert_raises(Encoding::CompatibilityError) { regexp.match?("\xE3\x81\x82".b) }
  end

  def test_contiguous_utf8_octal_escapes_match_as_one_character
    regexp = Onibi::Regexp.new("\\343\\201\\202")
    us_ascii_regexp = Onibi::Regexp.new("\\343\\201\\202".encode(Encoding::US_ASCII))

    assert regexp.match?("あ")
    assert us_ascii_regexp.match?("あ")
    refute regexp.match?("い")
  end

  def test_noencoding_property_does_not_match_non_ascii_binary_input
    regexp = Onibi::Regexp.new("\\p{Alpha}", Onibi::Regexp::NOENCODING)

    refute regexp.match?("\xFF".b)
  end

  def test_noencoding_negated_property_matches_non_ascii_binary_input
    regexp = Onibi::Regexp.new("\\p{^Alpha}", Onibi::Regexp::NOENCODING)

    assert regexp.match?("\xFF".b)
  end

  def test_non_utf8_casefold_does_not_apply_unicode_expansions
    pattern = "ss".encode(Encoding::EUC_JP)
    input = "ß".encode(Encoding::EUC_JP)
    regexp = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE)

    refute regexp.match?(input)
  end

  def test_ascii8bit_casefold_keeps_non_ascii_bytes_exact
    pattern = "\x80".b
    regexp = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE)

    assert regexp.match?("\x80".b)
    refute regexp.match?("\x81".b)
  end

  def test_non_utf8_character_classes_use_unicode_codepoints
    [Encoding::EUC_JP, Encoding::Windows_31J].each do |encoding|
      range = Onibi::Regexp.new("[Α-Ω]".encode(encoding), Onibi::Regexp::IGNORECASE)
      property = Onibi::Regexp.new("[\\p{Greek}]".encode(encoding))

      assert range.match?("α".encode(encoding))
      assert property.match?("Α".encode(encoding))
    end
  end

  def test_ignorecase_closes_unicode_range_casefolds
    regexp = Onibi::Regexp.new("[\\u{100}-\\u{200}]", Onibi::Regexp::IGNORECASE)

    assert regexp.match?("s")
    assert regexp.match?("S")
  end

  def test_unicode_escaped_class_ranges_match_mri
    failures = []

    UNICODE_CLASS_RANGE_CASES.each do |test_case|
      compare_unicode_class_range_results(failures, *test_case)
    end

    assert_empty failures, failures.join("\n")
  end

  def test_unicode_class_scalar_boundaries_match_mri
    failures = []

    UNICODE_CLASS_SCALAR_BOUNDARY_CASES.each do |test_case|
      compare_unicode_class_range_results(failures, *test_case)
    end

    assert_empty failures, failures.join("\n")
  end

  def test_unicode_class_scalar_boundaries_use_native_execution
    failures = []

    UNICODE_CLASS_SCALAR_BOUNDARY_CASES.each do |test_case|
      label, pattern, option_names, subjects = test_case
      compare_unicode_class_scalar_boundary_route(
        failures, label, pattern, option_names, [subjects.first]
      )
    end

    assert_empty failures, failures.join("\n")
  end

  def test_unicode_escaped_class_range_routes_preserve_fold_policy
    failures = []

    UNICODE_CLASS_RANGE_ROUTE_CASES.each do |test_case|
      compare_unicode_class_range_route(failures, *test_case)
    end

    assert_empty failures, failures.join("\n")
  end

  def test_unicode_escaped_class_range_errors_match_mri
    failures = []

    UNICODE_CLASS_RANGE_ERROR_CASES.each do |label, pattern, expected_message|
      mri_error = regexp_error_snapshot(::Regexp, pattern)
      expected = { regexp_error: true, message: expected_message }
      failures << "#{label}: frozen MRI error changed" unless mri_error == expected

      onibi_error = regexp_error_snapshot(Onibi::Regexp, pattern)
      failures << "#{label}: Onibi error differs from MRI" unless onibi_error == mri_error
    end

    assert_empty failures, failures.join("\n")
  end

  def test_unicode_escaped_class_encoding_matches_mri
    failures = []

    UNICODE_ESCAPE_CLASS_ENCODING_CASES.each do |test_case|
      compare_unicode_class_encoding_case(failures, test_case)
    end

    assert_empty failures, failures.join("\n")
  end

  def test_unicode_escaped_class_scalars_keep_literal_syntax_identity
    failures = []

    UNICODE_CLASS_SYNTAX_IDENTITY_CASES.each do |test_case|
      compare_unicode_class_range_results(failures, *test_case)
    end

    assert_empty failures, failures.join("\n")
  end

  def test_ignorecase_range_does_not_fold_turkish_dotless_i
    regexp = Onibi::Regexp.new("[A-ê]", Onibi::Regexp::IGNORECASE)

    refute regexp.match?("ı")
  end

  def test_ignorecase_range_closes_folds_of_codepoints_inside_range
    regexp = Onibi::Regexp.new("[ẞ-龠]", Onibi::Regexp::IGNORECASE)

    assert regexp.match?("Ω")
    assert regexp.match?("ω")
  end

  def test_ignorecase_intersection_folds_negated_class_operands
    greek = Onibi::Regexp.new("[\\p{Greek}&&[^\\p{Lower}]]", Onibi::Regexp::IGNORECASE)
    alpha = Onibi::Regexp.new("[\\p{Alpha}&&[^a-z]]", Onibi::Regexp::IGNORECASE)

    assert greek.match?("Α")
    assert greek.match?("α")
    assert alpha.match?("a")
    assert alpha.match?("A")

    vowels = Onibi::Regexp.new("[[a-z]&&[^aeiou]]", Onibi::Regexp::IGNORECASE)
    refute vowels.match?("a")
    assert vowels.match?("b")

    opposite_case = Onibi::Regexp.new("[a-z&&[^A-Z]]", Onibi::Regexp::IGNORECASE)
    assert opposite_case.match?("a")
    assert opposite_case.match?("A")
  end

  def test_ignorecase_intersection_compiles_before_casefold
    regexp = Onibi::Regexp.new("[a-z&&A-Z]", Onibi::Regexp::IGNORECASE)

    refute regexp.match?("a")
    refute regexp.match?("A")
  end

  def test_ignorecase_property_intersection_closes_fold_groups
    ascii = Onibi::Regexp.new("[\\p{Upper}&&[^A-Z]]", Onibi::Regexp::IGNORECASE)
    greek = Onibi::Regexp.new("[\\p{Upper}&&[^Α-Ω]]", Onibi::Regexp::IGNORECASE)

    refute ascii.match?("A")
    assert ascii.match?("K")
    assert ascii.match?("Ω")
    refute greek.match?("Α")
    assert greek.match?("Ω")
  end

  def test_ascii8bit_property_uses_byte_semantics
    regexp = Onibi::Regexp.new("\\p{Alpha}".b)

    refute regexp.match?("\xC3".b)
    assert regexp.match?("A".b)
  end

  def test_noencoding_multibyte_escape_is_fixed_binary
    regexp = Onibi::Regexp.new("\\xC3\\xA9", Onibi::Regexp::NOENCODING)

    assert regexp.fixed_encoding?
    assert regexp.match?("\xC3\xA9".b)
    assert_raises(Encoding::CompatibilityError) { regexp.match?("é") }
  end

  def test_non_utf8_multibyte_escape_preserves_pattern_encoding
    pattern = "\\xC3\\xA9".encode(Encoding::EUC_JP)
    regexp = Onibi::Regexp.new(pattern)

    assert_equal Encoding::EUC_JP, regexp.encoding
    assert regexp.fixed_encoding?
    refute regexp.match?("é".encode(Encoding::EUC_JP))
  end

  def test_non_utf8_casefold_does_not_apply_unicode_case_mapping
    pattern = "é".encode(Encoding::EUC_JP)
    regexp = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE)

    refute regexp.match?("É".encode(Encoding::EUC_JP))
  end

  def test_trailing_escape_error_matches_mri
    error = assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("\\") }

    assert_equal "too short escape sequence: /\\/", error.message
  end

  def test_character_classes_decode_literal_escape_sequences
    assert Onibi::Regexp.new("[\\x41]").match?("A")
    assert Onibi::Regexp.new("[\\n]").match?("\n")
    assert Onibi::Regexp.new("[\\u{1F600}]").match?("😀")
  end

  def test_control_escapes_match_control_characters
    assert Onibi::Regexp.new("\\cA").match?("\x01")
    assert Onibi::Regexp.new("\\C-A").match?("\x01")
  end

  def test_dot_excludes_newline_unless_multiline_is_enabled
    refute Onibi::Regexp.new(".").match?("\n")
    assert Onibi::Regexp.new(".", ["multiline"]).match?("\n")
  end

  def test_line_anchors_are_line_anchors_regardless_of_multiline_option
    regexp = Onibi::Regexp.new("^cat$", ["multiline"])

    assert regexp.match?("dog\ncat\nbird")
    assert regexp.match?("cat\ndog")
  end

  def test_absolute_anchors_distinguish_final_newline
    assert Onibi::Regexp.new("\\Acat\\Z").match?("cat\n")
    refute Onibi::Regexp.new("\\Acat\\z").match?("cat\n")
    refute Onibi::Regexp.new("\\Acat\\Z").match?("xcat\n")
  end

  def test_open_upper_bound_quantifier_defaults_to_zero_minimum
    regexp = Onibi::Regexp.new("\\Aa{,3}\\z")

    assert regexp.match?("")
    assert regexp.match?("aaa")
    refute regexp.match?("aaaa")
  end

  private

  def compare_unicode_class_range_results(failures, label, class_pattern, option_names,
                                          subjects, expected_matches)
    pattern = "(#{class_pattern})"
    mri_options = option_bits(option_names, ::Regexp)
    onibi_options = option_bits(option_names, Onibi::Regexp)
    mri_regexp = ::Regexp.new(pattern, mri_options)

    begin
      onibi_regexp = Onibi::Regexp.new(pattern, onibi_options)
    rescue StandardError => e
      failures << "#{label}: Onibi compile raised #{e.class}: #{e.message}"
      subjects.each_index do |index|
        compare_unicode_class_range_subject(
          failures, label, mri_regexp, nil, subjects[index], expected_matches[index]
        )
      end
      return
    end

    subjects.each_index do |index|
      compare_unicode_class_range_subject(
        failures, label, mri_regexp, onibi_regexp, subjects[index], expected_matches[index]
      )
    end
  rescue StandardError => e
    failures << "#{label}: MRI compile raised #{e.class}: #{e.message}"
  end

  def compare_unicode_class_range_subject(failures, label, mri_regexp, onibi_regexp,
                                          subject, expected_match)
    mri_result = unicode_class_match_snapshot(mri_regexp, subject)
    failures << "#{label}: frozen MRI result changed for #{subject.inspect}" unless
      mri_result.fetch(:match_q) == expected_match
    return unless onibi_regexp

    onibi_result = unicode_class_match_snapshot(onibi_regexp, subject)
    failures << "#{label}: Onibi differs from MRI for #{subject.inspect}" unless
      onibi_result == mri_result
  rescue StandardError => e
    failures << "#{label}: #{e.class} for #{subject.inspect}: #{e.message}"
  end

  def compare_unicode_class_encoding_case(failures, test_case)
    label = test_case.fetch(:label)
    source_encoding = Encoding.find(test_case.fetch(:source_encoding))
    pattern = test_case.fetch(:pattern).dup.force_encoding(source_encoding)
    mri_options = option_bits(test_case.fetch(:options), ::Regexp)
    onibi_options = option_bits(test_case.fetch(:options), Onibi::Regexp)
    expected_error = test_case[:expected_error]
    mri_error = regexp_error_snapshot(::Regexp, pattern, mri_options)

    if expected_error
      failures << "#{label}: frozen MRI error changed" unless mri_error == expected_error
      onibi_error = regexp_error_snapshot(Onibi::Regexp, pattern, onibi_options)
      failures << "#{label}: Onibi error differs from MRI: #{onibi_error.inspect}" unless
        onibi_error == mri_error
      return
    end

    failures << "#{label}: MRI compile raised #{mri_error.inspect}" if mri_error[:regexp_error]
    return if mri_error[:regexp_error]

    mri_regexp = ::Regexp.new(pattern, mri_options)
    begin
      onibi_regexp = Onibi::Regexp.new(pattern, onibi_options)
    rescue StandardError => e
      failures << "#{label}: Onibi compile raised #{e.class}: #{e.message}"
      test_case.fetch(:subjects).each do |value, encoding_name, expected_match|
        subject = value.dup.force_encoding(Encoding.find(encoding_name))
        compare_unicode_class_range_subject(
          failures, label, mri_regexp, nil, subject, expected_match
        )
      end
      return
    end
    mri_metadata = regexp_encoding_snapshot(mri_regexp, ::Regexp)
    expected_metadata = test_case.fetch(:expected_regexp)
    failures << "#{label}: frozen MRI encoding changed" unless mri_metadata == expected_metadata

    onibi_metadata = regexp_encoding_snapshot(onibi_regexp, Onibi::Regexp)
    failures << "#{label}: Onibi encoding differs from MRI: #{onibi_metadata.inspect}" unless
      onibi_metadata == mri_metadata

    test_case.fetch(:subjects).each do |value, encoding_name, expected_match|
      subject = value.dup.force_encoding(Encoding.find(encoding_name))
      compare_unicode_class_range_subject(
        failures, label, mri_regexp, onibi_regexp, subject, expected_match
      )
    end
  rescue StandardError => e
    failures << "#{label}: #{e.class}: #{e.message}"
  end

  def regexp_encoding_snapshot(regexp, regexp_class)
    {
      encoding: regexp.encoding.name,
      fixed_encoding: regexp.fixed_encoding?,
      no_encoding: (regexp.options & regexp_class.const_get(:NOENCODING)) != 0,
      options: regexp.options
    }
  end

  def compare_unicode_class_range_route(failures, label, pattern, option_names,
                                        subjects, expected_route)
    onibi_options = option_bits(option_names, Onibi::Regexp)
    subjects.each do |subject|
      compare_unicode_class_range_route_subject(
        failures, label, pattern, onibi_options, subject, expected_route
      )
    end
  end

  def compare_unicode_class_range_route_subject(failures, label, pattern, options,
                                                subject, expected_route)
    regexp = Onibi::Regexp.new(pattern, options)
    diagnostics = regexp.send(:__onibi_diagnostics__, subject)
    expected = if expected_route == :native
                 {
                   rseq: true, regular_capable: true, exec_kind: 0,
                   regular: 1, tagged: 0, dynamic: 0, fallback: 0,
                   fallback_reason: :none, compile_error_kind: :ok,
                   unsupported_reason: :none, executor_error_kind: :none,
                   class_kinds: [:codepoint_ranges], class_flags: [0]
                 }
               else
                 {
                   rseq: true, regular_capable: true, exec_kind: 0,
                   regular: 0, tagged: 0, dynamic: 0, fallback: 1,
                   fallback_reason: :input_ineligible, compile_error_kind: :ok,
                   unsupported_reason: :none, executor_error_kind: :none,
                   class_kinds: [:codepoint_ranges],
                   class_flags: [INCOMPLETE_CASEFOLD_CLASS_FLAG]
                 }
               end
    expected.each do |key, value|
      failures << "#{label}: #{key} differs for #{subject.inspect}" unless
        diagnostics.fetch(key) == value
    end
  rescue StandardError => e
    failures << "#{label}: #{e.class} for #{subject.inspect}: #{e.message}"
  end

  def compare_unicode_class_scalar_boundary_route(failures, label, pattern, option_names,
                                                  subjects)
    regexp = Onibi::Regexp.new(pattern, option_bits(option_names, Onibi::Regexp))
    subjects.each do |subject|
      diagnostics = regexp.send(:__onibi_diagnostics__, subject)
      expected = {
        rseq: true, regular_capable: true, exec_kind: 0,
        regular: 1, tagged: 0, dynamic: 0, fallback: 0,
        fallback_reason: :none, compile_error_kind: :ok,
        unsupported_reason: :none, executor_error_kind: :none
      }
      expected.each do |key, value|
        failures << "#{label}: #{key} differs for #{subject.inspect}" unless
          diagnostics.fetch(key) == value
      end
    rescue StandardError => e
      failures << "#{label}: #{e.class} for #{subject.inspect}: #{e.message}"
    end
  rescue StandardError => e
    failures << "#{label}: #{e.class}: #{e.message}"
  end

  def option_bits(option_names, regexp_class)
    option_names.reduce(0) do |bits, name|
      bits | regexp_class.const_get(name)
    end
  end

  def unicode_class_match_snapshot(regexp, subject)
    match = regexp.match(subject)
    {
      match_q: regexp.match?(subject),
      values: match&.to_a,
      character_ranges: match && match.to_a.each_index.map do |index|
        [match.begin(index), match.end(index)]
      end,
      byte_ranges: match && match.to_a.each_index.map do |index|
        match.byteoffset(index)
      end
    }
  end

  def regexp_error_snapshot(regexp_class, pattern, options = nil)
    regexp_class.new(pattern, options)
    { regexp_error: false, message: nil }
  rescue StandardError => e
    { regexp_error: e.is_a?(::RegexpError), message: e.message }
  end
end
