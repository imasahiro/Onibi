# frozen_string_literal: true

require "test_helper"

class EncodedCaptureNameTest < Minitest::Test
  UTF8 = Encoding::UTF_8
  WINDOWS_31J = Encoding.find("Windows-31J")

  def test_named_groups_keep_name_bytes_through_native_references
    cases = [
      ["word-name", :angle, nil, UTF8],
      ["a b", :angle, :quote, UTF8],
      ["a.b", :angle, :angle, UTF8],
      ["a\nb", :angle, :quote, UTF8],
      ["a'b", :angle, :angle, UTF8],
      ["a>b", :quote, :quote, UTF8],
      ["_name", :quote, :angle, UTF8],
      ["名", :angle, :angle, UTF8],
      ["a名", :quote, :quote, UTF8],
      ["a\\b", :angle, :angle, UTF8],
      ["😀x", :quote, :angle, UTF8],
      ["名", :angle, :quote, WINDOWS_31J],
      ["―x", :quote, :angle, WINDOWS_31J]
    ]

    cases.each do |name, group_form, reference_form, encoding|
      pattern = named_pattern(name, group_form, encoding,
                              reference_form: reference_form)
      source = "zaa".encode(encoding)
      assert_mri_match(pattern, source, name)
    end
  end

  def test_duplicate_names_keep_ordered_capture_registers
    pattern = "(?<value>a)(?'value'b)\\k<value>"
    source = "zabb"

    assert_mri_match(pattern, source, "duplicate names")
    assert_equal "b", Onibi::Regexp.new(pattern).match(source)["value"]
  end

  def test_escaped_name_spellings_match_mri
    patterns = [
      "(?<a\\u0062>a)\\k<a\\x62>",
      "(?<a\\x62>a)\\k<a\\u{0062}>",
      "(?'a\\u002dword'a)\\k'a\\x2dword'",
      "(?<a\\u{00E9}>a)\\k<aé>",
      "(?<a\\xC3\\xA9>a)\\k<aé>",
      "(?<a\\x6>a)\\k<a\\x06>",
      "(?<a\\x06>a)\\k<a\\x6>",
      "(?<a\\x6g>a)\\k<a\\x06g>",
      "(?<a\\x6g>a)\\k<a\\x6g>",
      "(?<a\\xA>a)\\k<a\\x0A>",
      "(?'a\\x6'a)\\k'a\\x06'",
      "(?<a\\x6>a)\\k'a\\x06'",
      "(?<名a>a)\\k<\\u{540D}a>",
      "(?<\\u{540D}a>a)\\k<名a>",
      "(?<\\u{540D}a>a)\\k<\\u540Da>",
      "(?<\\u{1F600}x>a)\\k<😀x>"
    ]

    patterns.each do |pattern|
      assert_mri_match(pattern, "aa", pattern)
    end

    windows_pattern = "(?'\\u{540D}a'a)\\k'\\u540Da'".encode(WINDOWS_31J)
    assert_mri_match(windows_pattern, "aa".encode(WINDOWS_31J),
                     "Windows-31J Unicode escape")
    windows_emoji_pattern = "(?<\\u{1F600}a>a)\\k<\\u{1f600}a>".encode(WINDOWS_31J)
    assert_mri_match(windows_emoji_pattern, "aa".encode(WINDOWS_31J),
                     "Windows-31J supplementary Unicode escape")
    windows_hex_pattern = "(?<a\\x82\\xA0>a)\\k<aあ>".encode(WINDOWS_31J)
    assert_mri_match(windows_hex_pattern, "aa".encode(WINDOWS_31J),
                     "Windows-31J hex bytes")
    windows_trail_pattern = "(?<a\\x81\\x5c>a)\\k<a―>".encode(WINDOWS_31J)
    assert_mri_match(windows_trail_pattern, "aa".encode(WINDOWS_31J),
                     "Windows-31J escaped trail byte")

    duplicate = "(?<a\\u0062>a)(?<a\\x62>b)\\k<a\\u{0062}>"
    assert_mri_match(duplicate, "zabb", "duplicate escaped name")
    assert_equal({ "a\\x62" => [1, 2] },
                 Onibi::Regexp.new(duplicate).named_captures)

    unicode_duplicate = "(?<\\u{540D}a>a)(?<名a>b)\\k<\\u540Da>"
    assert_mri_match(unicode_duplicate, "zabb", "Unicode duplicate name")
    assert_equal [1, 2],
                 Onibi::Regexp.new(unicode_duplicate).named_captures.values.first

    doubled_slash = "a\\\\u0062"
    doubled_pattern = "(?<#{doubled_slash}>a)\\k<#{doubled_slash}>"
    assert_mri_match(doubled_pattern, "aa", "doubled backslash")
  end

  def test_control_escape_names_match_mri
    patterns = [
      ["(?<a\\cA>a)\\k<a\\x01>", UTF8],
      ["(?<a\\x01>a)\\k<a\\C-A>", UTF8],
      ["(?'a\\c\\n'a)\\k'a\\x0A'", UTF8],
      ["(?<a\\c\\x06>a)\\k<a\\x06>", UTF8]
    ]

    patterns.each do |pattern, encoding|
      assert_mri_match(pattern.encode(encoding), "aa".encode(encoding), pattern)
    end
  end

  def test_meta_escape_names_match_mri_in_compatible_encodings
    binary_patterns = [
      "(?<a\\M-a>a)\\k<a\\xE1>".b,
      "(?<a\\xE1>a)\\k<a\\M-a>".b,
      "(?'a\\C-\\M-a'a)\\k<a\\M-\\C-A>".b,
      "(?<a\\M-C\\xA9>a)\\k<aé>".encode(UTF8),
      "(?'a\\M-\\x02\\xA0'a)\\k'aあ'".encode(WINDOWS_31J),
      "(?<a\\M-\\cA\\x5c>a)\\k<a―>".encode(WINDOWS_31J)
    ]
    encodings = [Encoding::BINARY, Encoding::BINARY, Encoding::BINARY,
                 UTF8, WINDOWS_31J, WINDOWS_31J]

    binary_patterns.zip(encodings).each do |pattern, encoding|
      assert_mri_match(pattern, "aa".encode(encoding), pattern)
    end
  end

  def test_mixed_byte_escape_spellings_compose_as_encoded_names
    cases = [
      ["UTF-8 two-byte meta pair", UTF8, "\\M-C\\M-)", "é"],
      ["UTF-8 hex/meta pair", UTF8, "\\xC3\\M-)", "é"],
      ["UTF-8 meta/hex pair", UTF8, "\\M-C\\xA9", "é"],
      ["UTF-8 three-byte control/meta", UTF8,
       "\\xE3\\M-\\cA\\M-\\C-B", "あ"],
      ["UTF-8 four-byte control/meta", UTF8,
       "\\M-p\\M-\\c_\\M-\\C-X\\M-\\0", "😀"],
      ["Windows-31J control/meta pair", WINDOWS_31J,
       "\\M-\\C-B\\M- ", "あ"],
      ["Windows-31J escaped backslash trail", WINDOWS_31J,
       "\\M-\\cA\\\\", "―"]
    ]

    cases.each do |label, encoding, spelling, character|
      escaped_name = "a".encode(encoding) + spelling.encode(encoding)
      literal_name = "a".encode(encoding) + character.encode(encoding)
      [
        [escaped_name, literal_name, "escaped group"],
        [literal_name, escaped_name, "escaped reference"]
      ].each do |group_name, reference_name, direction|
        pattern = "(?<".encode(encoding) + group_name +
                  ">z)\\k<".encode(encoding) + reference_name +
                  ">".encode(encoding)
        assert_mri_match(pattern, "zz".encode(encoding),
                         "#{label}: #{direction}")
      end
    end
  end

  def test_duplicate_control_meta_names_keep_register_order
    pattern = "(?<a\\cA>a)(?'a\\x01'b)\\k<a\\C-A>"
    source = "zabb"
    regexp = Onibi::Regexp.new(pattern)
    assert_mri_match(pattern, source, "duplicate control/meta name")
    assert_equal [1, 2], regexp.named_captures.values.first
    assert_equal "b", regexp.match(source)["a\\x01"]
  end

  def test_control_meta_named_call_resolves_natively
    pattern = "(?<a\\cA>a)\\g<a\\x01>"
    assert_mri_match(pattern, "aa", "control/meta named call")
  end

  def test_control_meta_named_replacements_use_native_lookup
    binary_replacement = "<\\k<a".b + "\xE1".b + ">>".b
    cases = [
      ["(?<a\\cA>a)", "za", "<\\k<a\\x01>>"],
      ["(?<a\\M-a>a)".b, "za".b, binary_replacement],
      ["(?'a\\M-\\x02\\xA0'a)".encode(WINDOWS_31J),
       "za".encode(WINDOWS_31J), "<\\k<aあ>>".encode(WINDOWS_31J)]
    ]

    cases.each do |pattern, source, replacement|
      regexp = Onibi::Regexp.new(pattern)
      assert_native_route(regexp, source)
      expected = source.gsub(::Regexp.new(pattern), replacement)
      actual, error, gsub_calls = with_string_gsub_count do
        regexp.gsub(source, replacement)
      end

      assert_nil error
      assert_equal expected, actual
      assert_equal expected.encoding, actual.encoding
      assert_equal 0, gsub_calls
    end
  end

  def test_escaped_named_subroutine_call_resolves_natively
    pattern = "(?'a\\u0062'a)\\g'a\\x62'"
    source = "aa"
    regexp = Onibi::Regexp.new(pattern)
    assert_native_route(regexp, source)

    assert ::Regexp.new(pattern).match(source)
    assert regexp.match(source)
  end

  def test_named_replacements_match_mri_without_string_gsub
    cases = [
      ["word", :angle, UTF8, UTF8],
      ["_name", :quote, UTF8, Encoding::BINARY],
      ["名", :angle, UTF8, UTF8],
      ["a\\b", :quote, UTF8, UTF8],
      ["名", :quote, WINDOWS_31J, WINDOWS_31J],
      ["―x", :angle, WINDOWS_31J, WINDOWS_31J]
    ]

    cases.each do |name, form, pattern_encoding, replacement_encoding|
      pattern = named_pattern(name, form, pattern_encoding)
      source = "za".encode(pattern_encoding)
      replacement = "<\\k<#{name}>>".encode(replacement_encoding)
      regexp = Onibi::Regexp.new(pattern)
      mri = ::Regexp.new(pattern)
      assert_native_route(regexp, source)
      expected = source.gsub(mri, replacement)
      actual, error, gsub_calls = with_string_gsub_count do
        regexp.gsub(source, replacement)
      end

      assert_nil error, name
      assert_equal expected, actual, name
      assert_equal expected.encoding, actual.encoding, name
      assert_equal 0, gsub_calls, name
    end

    pattern = "(?<value>a)(?'value'b)"
    source = "zab"
    replacement = "<\\k<value>>"
    regexp = Onibi::Regexp.new(pattern)
    assert_equal({ "value" => [1, 2] }, regexp.named_captures)
    assert_native_route(regexp, source)
    expected = source.gsub(::Regexp.new(pattern), replacement)
    actual, error, gsub_calls = with_string_gsub_count do
      regexp.gsub(source, replacement)
    end

    assert_nil error
    assert_equal expected, actual
    assert_equal "z<b>", actual
    assert_equal 0, gsub_calls
  end

  def test_escaped_capture_name_replacement_uses_native_lookup
    pattern = "(?<a\\u0062>a)"
    source = "za"
    replacement = "<\\k<a\\x62>>"
    regexp = Onibi::Regexp.new(pattern)
    mri = ::Regexp.new(pattern)
    assert_native_route(regexp, source)

    expected = source.gsub(mri, replacement)
    actual, error, gsub_calls = with_string_gsub_count do
      regexp.gsub(source, replacement)
    end

    assert_nil error
    assert_equal expected, actual
    assert_equal "z<a>", actual
    assert_equal 0, gsub_calls

    one_digit_pattern = "(?<a\\x6>a)"
    one_digit_replacement = "<\\k<a\\x06>>"
    one_digit_regexp = Onibi::Regexp.new(one_digit_pattern)
    one_digit_mri = ::Regexp.new(one_digit_pattern)
    assert_native_route(one_digit_regexp, source)

    one_digit_expected = source.gsub(one_digit_mri, one_digit_replacement)
    one_digit_actual, one_digit_error, one_digit_gsub_calls =
      with_string_gsub_count do
        one_digit_regexp.gsub(source, one_digit_replacement)
      end

    assert_nil one_digit_error
    assert_equal one_digit_expected, one_digit_actual
    assert_equal 0, one_digit_gsub_calls
  end

  def test_missing_and_incompatible_replacement_names_keep_mri_errors
    cases = [
      ["(?<word>a)", "za", "<\\k<missing>>"],
      ["(?<a\\u0062>a)", "za", "<\\k<a\\u0062>>"],
      ["(?<名>a)", "za", "<\\k<名>>".b],
      ["(?<名>a)", "za", "<\\k<名>>".encode(WINDOWS_31J)],
      ["(?<名>a)".encode(WINDOWS_31J), "za".encode(WINDOWS_31J),
       "<\\k<名>>"]
    ]

    cases.each do |pattern, source, replacement|
      regexp = Onibi::Regexp.new(pattern)
      assert_native_route(regexp, source)
      mri = ::Regexp.new(pattern)
      _result, expected_error, = with_string_gsub_count do
        source.gsub(mri, replacement)
      end
      assert_instance_of IndexError, expected_error

      _result, actual_error, gsub_calls = with_string_gsub_count do
        regexp.gsub(source, replacement)
      end
      assert_instance_of IndexError, actual_error
      assert_equal expected_error.message, actual_error.message
      assert_equal 1, gsub_calls
    end
  end

  def test_explicit_matcher_fallback_still_uses_mri_gsub
    pattern = "(?<word>\\X)"
    source = "é"
    replacement = "<\\k<word>>"
    regexp = Onibi::Regexp.new(pattern)
    diagnostics = regexp.send(:__onibi_diagnostics__, source)

    refute diagnostics.fetch(:rseq)
    assert_equal 1, diagnostics.fetch(:fallback)
    assert_equal :grapheme, diagnostics.fetch(:fallback_reason)
    expected = source.gsub(::Regexp.new(pattern), replacement)
    actual, error, gsub_calls = with_string_gsub_count do
      regexp.gsub(source, replacement)
    end

    assert_nil error
    assert_equal expected, actual
    assert_equal 1, gsub_calls
  end

  def test_encoded_named_subroutine_call_resolves_native
    name = "名"
    pattern = named_pattern(name, :quote, UTF8, call_form: :quote)
    source = "zaa"
    mri = ::Regexp.new(pattern)
    onibi = Onibi::Regexp.new(pattern)
    assert_native_route(onibi, source)

    expected = mri.match(source)
    actual = onibi.match(source)
    assert_equal [1, 3], [expected.bytebegin(0), expected.byteend(0)]
    assert_equal [1, 3], [actual.bytebegin(0), actual.byteend(0)]
    assert_equal expected[1], actual[1]
    assert_equal [expected.bytebegin(1), expected.byteend(1)],
                 [actual.bytebegin(1), actual.byteend(1)]
  end

  def test_ascii_named_call_capture_range_matches_mri_on_current_ruby
    pattern = "(?<word>a)\\g<word>"
    source = "zaa"
    mri = ::Regexp.new(pattern)
    onibi = Onibi::Regexp.new(pattern)
    assert_native_route(onibi, source)

    expected = mri.match(source)
    actual = onibi.match(source)
    assert_equal [1, 3], [expected.bytebegin(0), expected.byteend(0)]
    assert_equal [1, 3], [actual.bytebegin(0), actual.byteend(0)]
    expected_capture = [expected.bytebegin(1), expected.byteend(1)]
    actual_capture = [actual.bytebegin(1), actual.byteend(1)]
    assert_equal [2, 3], expected_capture
    assert_equal expected_capture, actual_capture
  end

  def test_invalid_names_and_encodings_match_mri_errors
    invalid_patterns = [
      "(?<>a)",
      "(?<a\\x>a)",
      "(?<a\\c\\u0041>a)",
      "(?<a\\c\\cA>a)",
      "(?''a)",
      "(?<1word>a)",
      "(?'1word'a)",
      "(?<-word>a)",
      "(?'-word'a)",
      "(?<１word>a)",
      "(?'１word'a)"
    ]
    invalid_patterns.each do |pattern|
      expected = assert_raises(::RegexpError) { ::Regexp.new(pattern) }
      actual = assert_raises(Onibi::RegexpError) { Onibi::Regexp.new(pattern) }
      assert_equal expected.message.bytes, actual.message.bytes, pattern
    end

    invalid_utf8 = "(?<".b + "\xff".b + ">a)".b
    invalid_utf8.force_encoding(UTF8)
    invalid_windows = "(?<".b + "\x81".b + ">a)".b
    invalid_windows.force_encoding(WINDOWS_31J)
    invalid_utf8_quote = "(?'".b + "\xff".b + "'a)".b
    invalid_utf8_quote.force_encoding(UTF8)
    invalid_windows_quote = "(?'".b + "\x81".b + "'a)".b
    invalid_windows_quote.force_encoding(WINDOWS_31J)
    [invalid_utf8, invalid_windows, invalid_utf8_quote,
     invalid_windows_quote].each do |pattern|
      expected = assert_raises(::RegexpError) { ::Regexp.new(pattern) }
      actual = assert_raises(Onibi::RegexpError) { Onibi::Regexp.new(pattern) }
      assert_equal expected.message.bytes, actual.message.bytes, pattern.bytes
    end
  end

  private

  def named_pattern(name, group_form, encoding, reference_form: nil,
                    call_form: nil)
    encoded_name = name.encode(encoding)
    group_open, group_close = if group_form == :angle
                                ["(?<", ">a)"]
                              else
                                ["(?'", "'a)"]
                              end
    pattern = group_open.encode(encoding) + encoded_name +
              group_close.encode(encoding)

    if reference_form
      open, close = if reference_form == :angle
                      ["\\k<", ">"]
                    else
                      ["\\k'", "'"]
                    end
      pattern += open.encode(encoding) + encoded_name + close.encode(encoding)
    end

    if call_form
      open, close = if call_form == :angle
                      ["\\g<", ">"]
                    else
                      ["\\g'", "'"]
                    end
      pattern += open.encode(encoding) + encoded_name + close.encode(encoding)
    end
    pattern
  end

  def assert_mri_match(pattern, source, label)
    mri = ::Regexp.new(pattern)
    onibi = Onibi::Regexp.new(pattern)
    assert_native_route(onibi, source)
    assert_equal name_snapshot(mri.names), name_snapshot(onibi.names), label
    assert_equal capture_name_snapshot(mri.named_captures),
                 capture_name_snapshot(onibi.named_captures), label

    expected = mri.match(source)
    actual = onibi.match(source)
    assert_equal match_snapshot(expected), match_snapshot(actual), label
    assert_equal source.scan(mri), onibi.scan(source), label
  end

  def assert_native_route(regexp, source)
    diagnostics = regexp.send(:__onibi_diagnostics__, source)
    assert diagnostics.fetch(:rseq)
    assert_equal 0, diagnostics.fetch(:fallback)
    assert_equal :none, diagnostics.fetch(:fallback_reason)
  end

  def name_snapshot(names)
    names.map { |name| [name.bytes, name.encoding.name] }
  end

  def capture_name_snapshot(captures)
    captures.map do |name, registers|
      [name.bytes, name.encoding.name, registers]
    end
  end

  def match_snapshot(match)
    return nil unless match

    (0...match.length).map do |index|
      value = match[index]
      [match.bytebegin(index), match.byteend(index), value&.bytes,
       value&.encoding&.name]
    end
  end

  def with_string_gsub_count
    count = 0
    trace = TracePoint.new(:c_call) do |event|
      count += 1 if event.defined_class == String && event.method_id == :gsub
    end
    result = nil
    error = nil
    trace.enable do
      result = yield
    rescue StandardError => e
      error = e
    end
    [result, error, count]
  ensure
    trace&.disable
  end
end
