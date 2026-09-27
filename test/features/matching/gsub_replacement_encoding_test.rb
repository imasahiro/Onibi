# frozen_string_literal: true

require "test_helper"

class GsubReplacementEncodingTest < Minitest::Test
  def test_encoded_escape_characters_expand_at_character_boundaries
    cases = [
      ["Windows-31J trail byte before digit", "a", "(a)",
       "表1".encode("Windows-31J"), 0],
      ["Windows-31J trail byte before real escape", "a", "(a)",
       "表\\1".encode("Windows-31J"), 0],
      ["UTF-16LE numbered capture", "a", "(a)", "\\1".encode("UTF-16LE"), 0],
      ["UTF-16BE numbered capture", "a", "(a)", "\\1".encode("UTF-16BE"), 0],
      ["UTF-16LE whole match", "a", "(a)", "\\&".encode("UTF-16LE"), 0],
      ["UTF-16LE escaped backslash", "a", "(a)", "\\\\".encode("UTF-16LE"), 0],
      ["UTF-16LE unknown escape", "a", "(a)", "\\q".encode("UTF-16LE"), 0],
      ["UTF-16LE trailing backslash", "a", "(a)", "x\\".encode("UTF-16LE"), 0],
      ["UTF-32LE numbered capture", "a", "(a)", "\\1".encode("UTF-32LE"), 0],
      ["whole match", "xay", "(a)", "\\0", 0],
      ["last capture", "xay", "(a)", "\\+", 0],
      ["pre-match", "xay", "(a)", "\\`", 0],
      ["post-match", "xay", "(a)", "\\'", 0],
      ["ASCII named capture", "a", "(?<word>a)", "\\k<word>", 0],
      ["UTF-8 control", "xay", "(a)", "R".encode("UTF-8"), 0],
      ["US-ASCII control", "xay".encode("US-ASCII"), "(a)",
       "R".encode("US-ASCII"), 0],
      ["ASCII-8BIT control", "xay".b, "(a)", "R".b, 0],
      ["unmatched capture", "a", "(a)(b)?", "\\2x", 0],
      ["ten-group numeric tail", "abcdefghij", "(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)",
       "\\10", 0],
      ["no match skips expansion", "x", "(a)", "\\1".encode("UTF-16LE"), 0]
    ]

    cases.each do |label, source, pattern, replacement, expected_gsub_calls|
      assert_explicit_matches_mri(label, source, pattern, replacement,
                                  expected_gsub_calls: expected_gsub_calls)
    end
  end

  def test_capture_and_literal_order_matches_mri_encoding_errors
    cases = [
      ["capture only", "a", "(a)", "\\1".encode("UTF-16LE"),
       { status: :ok, encoding: "UTF-8", bytes: [97] }],
      ["literal before capture", "a", "(a)", "X\\1".encode("UTF-16LE"),
       { status: :error, exception_class: "Encoding::CompatibilityError",
         exception_message: "incompatible character encodings: UTF-16LE and UTF-8" }],
      ["capture before literal", "a", "(a)", "\\1X".encode("UTF-16LE"),
       { status: :error, exception_class: "Encoding::CompatibilityError",
         exception_message: "incompatible character encodings: BINARY (ASCII-8BIT) and UTF-16LE" }],
      ["numeric tail", "a", "(a)", "\\10".encode("UTF-16LE"),
       { status: :error, exception_class: "Encoding::CompatibilityError",
         exception_message: "incompatible character encodings: BINARY (ASCII-8BIT) and UTF-16LE" }],
      ["UTF-32LE capture then literal", "a", "(a)", "\\1X".encode("UTF-32LE"),
       { status: :error, exception_class: "Encoding::CompatibilityError",
         exception_message: "incompatible character encodings: BINARY (ASCII-8BIT) and UTF-32LE" }]
    ]

    cases.each do |label, source, pattern, replacement, expected|
      actual = assert_explicit_matches_mri(label, source, pattern, replacement,
                                           expected_gsub_calls: 0)
      assert_equal expected.fetch(:status), actual.fetch(:status), label
      if expected.fetch(:status) == :ok
        assert_equal expected.fetch(:encoding), actual.fetch(:result).fetch(:encoding), label
        assert_equal expected.fetch(:bytes), actual.fetch(:result).fetch(:bytes), label
      else
        assert_equal expected.fetch(:exception_class), actual.fetch(:exception_class), label
        assert_equal expected.fetch(:exception_message), actual.fetch(:exception_message), label
      end
    end
  end

  def test_named_lookup_keeps_the_existing_mri_fallback_boundary
    utf16 = ["UTF-16LE named capture", "UTF-16LE"]
    utf16be = ["UTF-16BE named capture", "UTF-16BE"]
    [[*utf16, "\\k<word>"], [*utf16be, "\\k<word>"]].each do |label, encoding, text|
      replacement = text.encode(encoding)
      actual = assert_explicit_matches_mri(
        label, "a", "(?<word>a)", replacement, expected_gsub_calls: 1
      )
      assert_equal :error, actual.fetch(:status)
      assert_equal "IndexError", actual.fetch(:exception_class)
      assert_equal "undefined group name reference: word",
                   actual.fetch(:exception_message)
    end

    missing = assert_explicit_matches_mri(
      "missing named capture", "a", "(?<word>a)", "\\k<missing>",
      expected_gsub_calls: 1
    )
    assert_equal "undefined group name reference: missing",
                 missing.fetch(:exception_message)
  end

  def test_malformed_replacement_bytes_stay_literal
    cases = [
      ["invalid UTF-8", "a", "(a)", "\xFF".b.force_encoding("UTF-8")],
      ["invalid byte before UTF-8 escape", "a", "(a)",
       [255, 92, 49].pack("C*").force_encoding("UTF-8")],
      ["truncated UTF-16LE backslash", "a", "(a)",
       [92].pack("C*").force_encoding("UTF-16LE")],
      ["truncated UTF-16LE escape", "a", "(a)",
       [92, 0, 49].pack("C*").force_encoding("UTF-16LE")]
    ]

    cases.each do |label, source, pattern, replacement|
      assert_explicit_matches_mri(label, source, pattern, replacement,
                                  expected_gsub_calls: 0)
    end
  end

  def test_to_str_runs_once_and_does_not_change_the_subject
    expected_events = [:to_str]
    expected = observe_mri_with_replacement_factory do |events|
      replacement_object(events)
    end
    actual, gsub_calls, diagnostics = observe_onibi_with_replacement_factory do |events|
      replacement_object(events)
    end

    assert_equal expected.fetch(:record), actual.fetch(:record)
    assert_equal expected_events, expected.fetch(:events)
    assert_equal expected_events, actual.fetch(:events)
    assert_equal 0, gsub_calls
    assert_native_diagnostics(diagnostics)
    assert_equal string_record("a"), expected.fetch(:record).fetch(:input_after)
    assert_equal string_record("a"), actual.fetch(:record).fetch(:input_after)
  end

  private

  def assert_explicit_matches_mri(label, source, pattern, replacement,
                                  expected_gsub_calls:)
    expected = observe_mri(source, pattern, replacement)
    actual, gsub_calls, diagnostics = observe_onibi(source, pattern, replacement)
    assert_equal expected, actual, label
    assert_native_diagnostics(diagnostics)
    assert_equal expected_gsub_calls, gsub_calls, label
    actual
  end

  def observe_mri(source, pattern, replacement)
    input = source.dup
    before = string_record(input)
    replacement_copy = replacement.dup
    begin
      result = input.gsub(::Regexp.new(pattern), replacement_copy)
      {
        status: :ok,
        result: string_record(result),
        input_before: before,
        input_after: string_record(input),
        replacement: string_record(replacement_copy)
      }
    rescue StandardError => e
      {
        status: :error,
        exception_class: e.class.name,
        exception_message: e.message,
        input_before: before,
        input_after: string_record(input),
        replacement: string_record(replacement_copy)
      }
    end
  end

  def observe_onibi(source, pattern, replacement)
    input = source.dup
    before = string_record(input)
    replacement_copy = replacement.dup
    regexp = Onibi::Regexp.new(pattern)
    diagnostics = regexp.send(:__onibi_diagnostics__, input.dup)
    gsub_calls = 0
    record = nil
    trace = TracePoint.new(:c_call) do |event|
      gsub_calls += 1 if event.method_id == :gsub && event.defined_class == String
    end

    begin
      trace.enable do
        result = regexp.gsub(input, replacement_copy)
        record = {
          status: :ok,
          result: string_record(result),
          input_before: before,
          input_after: string_record(input),
          replacement: string_record(replacement_copy)
        }
      rescue StandardError => e
        record = {
          status: :error,
          exception_class: e.class.name,
          exception_message: e.message,
          input_before: before,
          input_after: string_record(input),
          replacement: string_record(replacement_copy)
        }
      end
    ensure
      trace.disable if trace.enabled?
    end
    [record, gsub_calls, diagnostics]
  end

  def observe_mri_with_replacement_factory
    input = "a"
    events = []
    replacement = yield(events)
    result = input.gsub(::Regexp.new("(a)"), replacement)
    { record: { status: :ok, result: string_record(result),
                input_before: string_record("a"), input_after: string_record(input) },
      events: events }
  end

  def observe_onibi_with_replacement_factory
    input = "a"
    events = []
    replacement = yield(events)
    regexp = Onibi::Regexp.new("(a)")
    diagnostics = regexp.send(:__onibi_diagnostics__, input.dup)
    gsub_calls = 0
    result = nil
    trace = TracePoint.new(:c_call) do |event|
      gsub_calls += 1 if event.method_id == :gsub && event.defined_class == String
    end
    begin
      trace.enable do
        result = regexp.gsub(input, replacement)
      end
    ensure
      trace.disable if trace.enabled?
    end
    record = { status: :ok, result: string_record(result),
               input_before: string_record("a"), input_after: string_record(input) }
    [{ record: record, events: events }, gsub_calls, diagnostics]
  end

  def replacement_object(events)
    object = Object.new
    object.define_singleton_method(:to_str) do
      events << :to_str
      "\\1".encode("UTF-16LE")
    end
    object.define_singleton_method(:to_s) { raise "to_s must not run" }
    object
  end

  def assert_native_diagnostics(diagnostics)
    assert diagnostics.fetch(:rseq)
    assert_equal 0, diagnostics.fetch(:fallback)
    assert_equal :none, diagnostics.fetch(:fallback_reason)
  end

  def string_record(string)
    { bytes: string.bytes, encoding: string.encoding.name,
      valid_encoding: string.valid_encoding? }
  end
end
