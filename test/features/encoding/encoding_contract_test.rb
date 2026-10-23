# frozen_string_literal: true

require "test_helper"
require "yaml"

class EncodingContractTest < Minitest::Test
  MATRIX = :encoding
  REQUIRED_ENCODINGS = %w[ASCII-8BIT EUC-JP US-ASCII UTF-8 Windows-31J].freeze
  NON_ASCII_COMPATIBLE_ENCODINGS = [
    Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE
  ].freeze

  def test_matrix_covers_ascii_compatible_pairs_including_us_ascii
    matrix = TestFixtures.load(MATRIX)
    ascii_pairs = matrix.fetch("cases").select do |fixture|
      fixture.fetch("pattern") == "a" && fixture.fetch("input") == "a"
    end

    assert_equal REQUIRED_ENCODINGS.sort, matrix.fetch("encodings").sort
    assert_equal REQUIRED_ENCODINGS.length**2, ascii_pairs.length
  end

  def test_non_ascii_compatible_pattern_encoding_is_preserved
    [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
      pattern = "a".encode(encoding)
      input = "a".encode(encoding)
      mri = Regexp.new(pattern)
      onibi = Onibi::Regexp.new(pattern)

      assert_equal mri.encoding, onibi.encoding
      assert_equal mri.match?(input), onibi.match?(input)
    end
  end

  def test_non_ascii_compatible_unicode_literals_keep_vm_match_offsets
    [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
      pattern = "(あ+)".encode(encoding)
      input = "xああ".encode(encoding)
      mri = Regexp.new(pattern).match(input)
      onibi = Onibi::Regexp.new(pattern).match(input)

      assert_equal [mri.to_a, mri.offset(0), mri.offset(1)],
                   [onibi.to_a, onibi.offset(0), onibi.offset(1)]
    end
  end

  def test_non_ascii_compatible_unicode_literals_honor_ignorecase
    [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
      pattern = "a".encode(encoding)
      input = "A".encode(encoding)

      expected = Regexp.new(pattern, Regexp::IGNORECASE).match?(input)
      actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match?(input)

      assert_equal expected, actual, encoding.name
    end
  end

  def test_non_ascii_compatible_unicode_classes_honor_ignorecase
    [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
      pattern = "[\\p{Upper}&&[^A-Z]]".encode(encoding)
      input = "K".encode(encoding)

      expected = Regexp.new(pattern, Regexp::IGNORECASE).match?(input)
      actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match?(input)

      assert_equal expected, actual, encoding.name
    end
  end

  def test_non_ascii_compatible_pattern_rejects_other_input_encodings
    pattern = "a".encode(Encoding::UTF_16LE)
    [Encoding::UTF_8, Encoding::ASCII_8BIT].each do |encoding|
      input = "a".encode(encoding)
      assert_raises(Encoding::CompatibilityError) { Onibi::Regexp.new(pattern).match?(input) }
    end
  end

  def test_ascii_pattern_rejects_non_ascii_compatible_input
    [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
      input = "a".encode(encoding)

      assert_raises(Encoding::CompatibilityError) { Onibi::Regexp.new(".").match?(input) }
    end
  end

  def test_non_ascii_compatible_character_classes_compare_codepoints
    [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
      ["[あ]", "\\d"].each do |source|
        pattern = source.encode(encoding)
        input = (source == "\\d" ? "1" : "あ").encode(encoding)
        mri = Regexp.new(pattern).match?(input)
        onibi = Onibi::Regexp.new(pattern).match?(input)

        assert_equal mri, onibi
      end
    end
  end

  def test_non_ascii_compatible_class_tokens_use_codepoint_boundaries
    cases = [
      ["[ś]", %w[ś], %w[Š A]],
      ["[ŝ]", %w[ŝ], %w[Ŝ A]],
      ["[ĭ-ŝ]", %w[ĭ Ŕ ŝ], %w[Ť A]],
      ["[Ş]", %w[Ş], %w[ş A]],
      ["[Ħ&&[^Ŝ]]", %w[Ħ], %w[Ŝ A]],
      ["[Ŝ]", %w[Ŝ], %w[ŝ A]],
      ["[ÿ-Ā]", %w[ÿ Ā], %w[A ŷ]]
    ]

    [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
      cases.each do |source, matching_inputs, nonmatching_inputs|
        regexp = Regexp.new(source.encode(encoding))
        onibi = Onibi::Regexp.new(source.encode(encoding))

        (matching_inputs + nonmatching_inputs).each do |input|
          assert_equal regexp.match?(input.encode(encoding)),
                       onibi.match?(input.encode(encoding)),
                       "#{encoding.name} #{source.inspect} #{input.inspect}"
        end
      end
    end
  end

  def test_mixed_class_programs_match_mri_with_same_native_route
    programs = [
      ["class_ascii_tail", "(?<glyph>[あ])x", [["あx", nil], ["いx", nil], ["zあx", 1]]],
      ["escaped_punctuation", '(?<glyph>[あ])\\-\\]', [["あ-]", nil], ["あ--", nil]]],
      ["control_octal_hex", '(?<glyph>[あ])\\n\\101\\x42', [["あ\nAB", nil], ["あ\nAC", nil]]],
      ["named_backreference", '(?<unit>[あ])\\k<unit>', [["ああ", nil], ["あい", nil]]],
      ["named_subexpression_call", '(?<unit>[あ])\\g<unit>', [["ああ", nil], ["あい", nil]]],
      ["anchors_and_dot", '\\A(?<head>x)(?<glyph>[あ]).\\z', [["xあ😀", nil], ["xあ\n", nil]]],
      ["lookahead", '\\A(?<head>x)(?<glyph>[あ])(?=y)', [["xあy", nil], ["xあz", nil]]],
      ["lookbehind", "(?<=(?<head>x))(?<glyph>[あ])", [["xあy", nil], ["zあy", nil]]],
      ["extended_comment", "(?x:(?<head>x) [あ] # skip\n \\k<head>)", [["xあx", nil], ["xあy", nil]]],
      ["pattern_comment", "(?<head>x)(?#skip)[あ]", [["xあ", nil], ["yあ", nil]]],
      ["nonbmp_before_named_class", "😀(?<kana>[あ])", [["x😀あ", 1], ["😀あ", 0]]],
      ["nonbmp_and_property_name", '(?<face>😀)(?<kana>\\p{Hiragana}+)[a-z]', [["x😀あいx", 1], ["😀カx", 0]]],
      ["unicode_capture_name", "(?<顔>😀)[あ]", [["😀あ", nil], ["x😀あ", nil]]],
      ["suffix_search", "[あ](?<tail>x)", [["zあxzあx", 0], ["zあxzあx", 3]]]
    ]

    programs.each do |name, pattern_source, inputs|
      inputs.each do |input_text, start|
        utf8_pattern = pattern_source.encode(Encoding::UTF_8)
        utf8_input = input_text.encode(Encoding::UTF_8)
        expected = match_signature(::Regexp, utf8_pattern, utf8_input, start)
        actual = match_signature(Onibi::Regexp, utf8_pattern, utf8_input, start)
        assert_equal expected, actual, "#{name} UTF-8 control"
        utf8_route = route_signature(utf8_pattern, utf8_input)

        NON_ASCII_COMPATIBLE_ENCODINGS.each do |encoding|
          pattern = pattern_source.encode(encoding)
          input = input_text.encode(encoding)
          expected = match_signature(::Regexp, pattern, input, start)
          actual = match_signature(Onibi::Regexp, pattern, input, start)

          assert_equal expected, actual, "#{name} #{encoding.name}"
          next if expected.key?(:error_class)

          route = route_signature(pattern, input)
          assert_equal utf8_route.slice(:fallback, :exec_kind, :rseq),
                       route.slice(:fallback, :exec_kind, :rseq),
                       "#{name} route in #{encoding.name}"
          assert_operator route.fetch(:native_runs), :>, 0
        end
      end
    end
  end

  def test_non_ascii_compatible_class_repeats_match_mri
    programs = [
      ["exact_repeat", '\\A[あ]{2}\\z', %w[ああ あ あああ]],
      ["bounded_repeat", '\\A[あ]{2,3}\\z', %w[ああ あああ あ ああああ]],
      ["open_upper_repeat", '\\A[あ]{2,}\\z', %w[ああ あああ あ]]
    ]

    programs.each do |name, pattern_source, input_texts|
      input_texts.each do |input_text|
        utf8_pattern = pattern_source.encode(Encoding::UTF_8)
        utf8_input = input_text.encode(Encoding::UTF_8)
        expected = match_signature(::Regexp, utf8_pattern, utf8_input, nil)
        actual = match_signature(Onibi::Regexp, utf8_pattern, utf8_input, nil)
        assert_equal expected, actual, "#{name} UTF-8 control"
        utf8_route = route_signature(utf8_pattern, utf8_input)

        NON_ASCII_COMPATIBLE_ENCODINGS.each do |encoding|
          pattern = pattern_source.encode(encoding)
          input = input_text.encode(encoding)
          expected = match_signature(::Regexp, pattern, input, nil)
          actual = match_signature(Onibi::Regexp, pattern, input, nil)

          assert_equal expected, actual, "#{name} #{encoding.name}"
          assert_equal utf8_route, route_signature(pattern, input),
                       "#{name} route in #{encoding.name}"
        end
      end
    end
  end

  def test_non_ascii_compatible_named_capture_and_property_slices_match_mri
    programs = [
      ["named_property", '(?<kana>\\p{Hiragana}+)', %w[あい カ]],
      ["named_capture_condition", "(?<unit>[あ])?(?(<unit>)x|y)", %w[あx y]]
    ]

    programs.each do |name, pattern_source, input_texts|
      utf8_pattern = pattern_source.encode(Encoding::UTF_8)

      NON_ASCII_COMPATIBLE_ENCODINGS.each do |encoding|
        pattern = pattern_source.encode(encoding)
        input_texts.each do |input_text|
          input = input_text.encode(encoding)
          utf8_input = input_text.encode(Encoding::UTF_8)
          expected_utf8 = match_signature(::Regexp, utf8_pattern, utf8_input, nil)
          actual_utf8 = match_signature(Onibi::Regexp, utf8_pattern, utf8_input, nil)

          assert_equal expected_utf8, actual_utf8, "#{name} UTF-8 control"
          utf8_route = route_signature(utf8_pattern, utf8_input)
          expected = match_signature(::Regexp, pattern, input, nil)
          actual = match_signature(Onibi::Regexp, pattern, input, nil)
          route = route_signature(pattern, input)

          assert_equal expected, actual, "#{name} #{encoding.name} #{input_text.inspect}"
          assert_equal utf8_route.slice(:status, :fallback, :exec_kind, :rseq),
                       route.slice(:status, :fallback, :exec_kind, :rseq),
                       "#{name} route in #{encoding.name}"
          assert_operator route.fetch(:native_runs), :>, 0
        end
      end
    end
  end

  def test_named_match_data_lookup_preserves_source_encoded_names
    names = %w[unit 顔]
    encodings = [Encoding::UTF_8, *NON_ASCII_COMPATIBLE_ENCODINGS]

    encodings.each do |encoding|
      names.each do |capture_name|
        source = "(?<#{capture_name}>[あ])".encode(encoding)
        input = "あ".encode(encoding)
        mri_regexp = ::Regexp.new(source)
        onibi_regexp = Onibi::Regexp.new(source)
        mri = mri_regexp.match(input)
        onibi = onibi_regexp.match(input)

        assert_instance_of Onibi::MatchData, onibi
        assert_equal encoded_strings(mri_regexp.names), encoded_strings(onibi_regexp.names)
        assert_equal encoded_named_capture_indexes(mri_regexp.named_captures),
                     encoded_named_capture_indexes(onibi_regexp.named_captures)
        assert_equal encoded_strings(mri.names), encoded_strings(onibi.names)
        assert_equal encoded_named_captures(mri.named_captures),
                     encoded_named_captures(onibi.named_captures)
        assert_equal encoded_named_captures(mri.named_captures(symbolize_names: true)),
                     encoded_named_captures(onibi.named_captures(symbolize_names: true))

        route = route_signature(source, input)
        assert_operator route.fetch(:native_runs), :>, 0, "#{capture_name} #{encoding.name}"

        name = mri.names.fetch(0)
        utf8_name = name.encode(Encoding::UTF_8)
        selectors = [name, utf8_name, name.b, name.to_sym, utf8_name.to_sym]
        %i[[] begin end offset byteoffset match_length].each do |method|
          selectors.each do |selector|
            expected = named_access_signature(mri, method, selector)
            actual = named_access_signature(onibi, method, selector)

            assert_equal expected, actual,
                         "#{method} #{selector.inspect} #{capture_name} #{encoding.name}"
          end
        end
      end
    end
  end

  def test_duplicate_unmatched_and_missing_encoded_names_match_mri
    [Encoding::UTF_8, *NON_ASCII_COMPATIBLE_ENCODINGS].each do |encoding|
      duplicate_source = "(?<dup>[あ])?(?<dup>[い])?".encode(encoding)
      %w[あい あ い].each do |input_text|
        input = input_text.encode(encoding)
        mri = ::Regexp.new(duplicate_source).match(input)
        onibi_regexp = Onibi::Regexp.new(duplicate_source)
        onibi = onibi_regexp.match(input)

        assert_instance_of Onibi::MatchData, onibi
        assert_equal encoded_named_captures(mri.named_captures),
                     encoded_named_captures(onibi.named_captures)
        name = mri.names.fetch(0)
        [name, name.to_sym].each do |selector|
          assert_equal named_access_signature(mri, :[], selector),
                       named_access_signature(onibi, :[], selector),
                       "duplicate #{selector.inspect} #{encoding.name}"
        end
        route = route_signature(duplicate_source, input)
        assert_operator route.fetch(:native_runs), :>, 0, "duplicate #{encoding.name}"
      end

      unmatched_source = "(?<unit>[あ])?い".encode(encoding)
      input = "い".encode(encoding)
      mri = ::Regexp.new(unmatched_source).match(input)
      onibi = Onibi::Regexp.new(unmatched_source).match(input)
      assert_instance_of Onibi::MatchData, onibi
      assert_equal encoded_named_captures(mri.named_captures),
                   encoded_named_captures(onibi.named_captures)

      missing = "missing".encode(encoding)
      selectors = [missing, missing.encode(Encoding::UTF_8), missing.to_sym]
      selectors.each do |selector|
        assert_equal named_access_signature(mri, :[], selector),
                     named_access_signature(onibi, :[], selector),
                     "missing #{selector.inspect} #{encoding.name}"
      end
      route = route_signature(unmatched_source, input)
      assert_operator route.fetch(:native_runs), :>, 0, "unmatched #{encoding.name}"
    end
  end

  def test_non_ascii_compatible_numbered_capture_slices_keep_syntax
    programs = [
      ["numbered_backreference", '([あ])\\1', %w[ああ あい]],
      ["numbered_subroutine_call", '([あ])\\g<1>', %w[ああ あ]],
      ["numbered_capture_condition", "([あ])?(?(1)x|y)", %w[あx y]]
    ]

    programs.each do |name, pattern_source, input_texts|
      utf8_pattern = pattern_source.encode(Encoding::UTF_8)

      NON_ASCII_COMPATIBLE_ENCODINGS.each do |encoding|
        pattern = pattern_source.encode(encoding)
        input_texts.each do |input_text|
          input = input_text.encode(encoding)
          utf8_input = input_text.encode(Encoding::UTF_8)
          expected_utf8 = match_signature(::Regexp, utf8_pattern, utf8_input, nil)
          actual_utf8 = match_signature(Onibi::Regexp, utf8_pattern, utf8_input, nil)

          assert_equal expected_utf8, actual_utf8, "#{name} UTF-8 control"
          utf8_route = route_signature(utf8_pattern, utf8_input)
          expected = match_signature(::Regexp, pattern, input, nil)
          actual = match_signature(Onibi::Regexp, pattern, input, nil)
          route = route_signature(pattern, input)

          assert_equal expected, actual, "#{name} #{encoding.name} #{input_text.inspect}"
          assert_equal utf8_route.slice(:status, :fallback, :exec_kind, :rseq),
                       route.slice(:status, :fallback, :exec_kind, :rseq),
                       "#{name} route in #{encoding.name}"
          assert_operator route.fetch(:native_runs), :>, 0
        end
      end
    end
  end

  def test_mixed_width_nested_class_ranges_match_mri
    programs = [
      ["nested_without_trailing_literal", "[a-[b]]", %w[a b c]],
      ["nested_with_trailing_literal", "[a-[b]c]", %w[a b c d]],
      ["mixed_width_range_endpoints", "[Ā-[a]😀]", %w[a ÿ Ā ā あ 😀 😁]],
      ["mixed_width_range_without_trailing_literal", "[Ā-[a]]", %w[a Ā 😀]]
    ]

    programs.each do |name, pattern_source, input_texts|
      input_texts.each do |input_text|
        NON_ASCII_COMPATIBLE_ENCODINGS.each do |encoding|
          pattern = pattern_source.encode(encoding)
          input = input_text.encode(encoding)
          expected = match_signature(::Regexp, pattern, input, nil)
          actual = match_signature(Onibi::Regexp, pattern, input, nil)

          assert_equal expected, actual, "#{name} #{encoding.name} #{input_text.inspect}"
          route = route_signature(pattern, input)
          assert route.fetch(:rseq),
                 "#{name} must compile RSeq in #{encoding.name}"
          assert_equal 0, route.fetch(:fallback),
                       "#{name} must not use runtime fallback in #{encoding.name}"
          assert_operator route.fetch(:native_runs), :>, 0,
                          "#{name} must enter a native VM in #{encoding.name}"
        end
      end
    end
  end

  def test_non_ascii_compatible_rendering_preserves_to_s_encoding
    [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
      pattern = "あ".encode(encoding)
      mri = Regexp.new(pattern)
      onibi = Onibi::Regexp.new(pattern)

      assert_equal mri.to_s, onibi.to_s
      assert_equal mri.to_s.encoding, onibi.to_s.encoding
      assert_equal mri.inspect, onibi.inspect
    end
  end

  def test_non_ascii_compatible_inspect_preserves_ascii_code_units
    [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
      pattern = "a|é".encode(encoding)

      assert_equal Regexp.new(pattern).inspect, Onibi::Regexp.new(pattern).inspect
      assert_equal Regexp.union([pattern, "b".encode(encoding)]).inspect,
                   Onibi::Regexp.union([pattern, "b".encode(encoding)]).inspect
    end
  end

  def test_ascii_compatible_inspect_preserves_unicode_source
    ["é", "[あ]"].each do |pattern|
      assert_equal Regexp.new(pattern).inspect, Onibi::Regexp.new(pattern).inspect
    end
  end

  def test_non_utf8_ascii_compatible_inspect_uses_mri_hex_escapes
    [Encoding::EUC_JP, Encoding::Windows_31J].each do |encoding|
      pattern = "あ".encode(encoding)

      assert_equal Regexp.new(pattern).inspect, Onibi::Regexp.new(pattern).inspect
    end
  end

  def test_escape_preserves_ascii_metacharacter_rules_for_non_ascii_compatible_strings
    [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
      pattern = "a.b あ".encode(encoding)

      assert_equal Regexp.escape(pattern), Onibi::Regexp.escape(pattern)
    end
  end

  def test_union_preserves_non_ascii_compatible_pattern_encoding
    [Encoding::UTF_16LE, Encoding::UTF_16BE, Encoding::UTF_32LE, Encoding::UTF_32BE].each do |encoding|
      patterns = %w[あ い].map { |value| value.encode(encoding) }
      mri = Regexp.union(patterns)
      onibi = Onibi::Regexp.union(patterns)

      assert_equal mri.source.encoding, onibi.source.encoding
      assert_equal mri.match?(patterns.last), onibi.match?(patterns.last)
      assert_equal mri.to_s, onibi.to_s
    end
  end

  def test_union_rejects_mixed_ascii_incompatible_encodings
    pattern = "あ".encode(Encoding::UTF_16LE)

    assert_raises(ArgumentError) { Onibi::Regexp.union(pattern, "a") }
  end

  def test_unicode_full_casefold_matches_mri_for_literals
    [["ß", "SS"], ["ſ", "S"], ["[ß]", "SS"], ["(?i:ss)", "ß"]].each do |pattern, input|
      expected = ::Regexp.new(pattern, ::Regexp::IGNORECASE).match(input)&.to_a
      actual = Onibi::Regexp.new(pattern, ::Regexp::IGNORECASE).match(input)&.to_a

      assert_equal expected, actual, "#{pattern.inspect} against #{input.inspect}"
    end
  end

  def test_unicode_full_casefold_keeps_literal_runs_across_quantifiers
    pattern = "ffi.*ffi"
    input = "ﬃﬃ"

    expected = ::Regexp.new(pattern, ::Regexp::IGNORECASE).match(input)
    actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [expected&.to_a, expected&.offset(0)], [actual&.to_a, actual&.offset(0)]
  end

  def test_unicode_full_casefold_respects_sharp_s_literal_boundaries
    pattern = "sß"
    input = "ßS"

    expected = ::Regexp.new(pattern, ::Regexp::IGNORECASE).match(input)
    actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [expected&.to_a, expected&.offset(0)], [actual&.to_a, actual&.offset(0)]
  end

  def test_unicode_full_casefold_joins_character_class_and_literal_runs
    pattern = "[f]fi"
    input = "ﬃ"

    expected = ::Regexp.new(pattern, ::Regexp::IGNORECASE).match(input)
    actual = Onibi::Regexp.new(pattern, Onibi::Regexp::IGNORECASE).match(input)

    assert_equal [expected&.to_a, expected&.offset(0)], [actual&.to_a, actual&.offset(0)]
  end

  def test_unicode_literal_full_casefold_runs_in_the_vm_for_ascii_input
    regexp = Onibi::Regexp.new("ſ", "i")

    assert_equal "S", regexp.match("S").to_s

    assert regexp.match?("S")
  end

  def test_inline_casefold_applies_to_quantified_unicode_literals
    pattern = "(?i)(?:ß){1,2}"
    %w[ss SS aßss ssß ssss].each do |input|
      expected = ::Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected&.to_a, actual&.to_a, [input, expected, actual]
      assert_equal expected && expected.offset(0), actual && actual.offset(0), input
    end
  end

  def test_inline_casefold_applies_to_fixed_repeated_character_classes
    pattern = "(?i)(?:[s]){2}s"
    input = "ßss"
    expected = ::Regexp.new(pattern).match(input)
    actual = Onibi::Regexp.new(pattern).match(input)

    assert_equal expected&.to_a, actual&.to_a
    assert_equal expected && expected.offset(0), actual && actual.offset(0)
  end

  def test_ascii_compatible_literal_skips_redundant_encoding_validation
    input = ValidationTrackingString.new("needle")

    assert Onibi::Regexp.new("needle").match?(input)
    assert_equal 0, input.valid_encoding_calls
  end

  class ValidationTrackingString < String
    attr_reader :valid_encoding_calls

    def initialize(value)
      super
      @valid_encoding_calls = 0
    end

    def valid_encoding?
      @valid_encoding_calls += 1
      super
    end
  end

  private

  def encoded_strings(values)
    values.map { |value| [value.encoding.name, value.b] }
  end

  def encoded_named_capture_indexes(captures)
    captures.map do |name, indices|
      [[name.encoding.name, name.b], indices]
    end
  end

  def encoded_named_captures(captures)
    captures.map do |name, value|
      encoded_name = if name.is_a?(Symbol)
                       [:symbol, name.to_s.encoding.name, name.to_s.b]
                     else
                       [:string, name.encoding.name, name.b]
                     end
      encoded_value = value && [value.encoding.name, value.b]
      [encoded_name, encoded_value]
    end
  end

  def named_access_signature(match, method, selector)
    value = method == :[] ? match[selector] : match.public_send(method, selector)
    if value.is_a?(String)
      [:value, value.encoding.name, value.b]
    else
      [:value, value]
    end
  rescue StandardError => e
    [:error, e.class.name, e.message.encoding.name, e.message.b]
  end

  def match_signature(regexp_class, source, input, start)
    regexp = regexp_class.new(source)
    match = start.nil? ? regexp.match(input) : regexp.match(input, start)
    result = if match
               {
                 matched: true,
                 captures: match.to_a.map { |value| value && [value.encoding.name, value.b] },
                 offsets: (0...match.length).map { |index| match.offset(index) },
                 byte_offsets: (0...match.length).map { |index| match.byteoffset(index) },
                 named_values: match.named_captures.transform_values do |value|
                   value && [value.encoding.name, value.b]
                 end
               }
             else
               { matched: false }
             end
    { encoding: regexp.encoding.name, names: regexp.names,
      named_captures: regexp.named_captures, result: result }
  rescue StandardError => e
    error_class = if e.is_a?(::RegexpError) || e.instance_of?(::Onibi::RegexpError)
                    "RegexpError"
                  else
                    e.class.name
                  end
    { error_class: error_class, error_encoding: e.message.encoding.name,
      error_bytes: e.message.b }
  end

  def route_signature(source, input)
    regexp = Onibi::Regexp.new(source)
    info = regexp.send(:__onibi_diagnostics__, input)
    native_runs = info.values_at(:regular, :tagged, :dynamic).sum
    {
      status: info[:status], fallback: info[:fallback], exec_kind: info[:exec_kind],
      rseq: info[:rseq], native_runs: native_runs
    }
  end
end
