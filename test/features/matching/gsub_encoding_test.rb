# frozen_string_literal: true

require "test_helper"

class GsubEncodingTest < Minitest::Test
  def test_explicit_replacements_match_mri_for_ascii_compatible_encodings
    cases = [
      ["UTF-8 subject", "xay".encode("UTF-8"), "a", "R".encode("US-ASCII")],
      ["US-ASCII subject", "xay".encode("US-ASCII"), "a", "R".encode("US-ASCII")],
      ["binary subject", "xay".b, "a", "R".b],
      ["Windows-31J subject", "xay".encode("Windows-31J"), "a",
       "R".encode("US-ASCII")],
      ["UTF-8 replacement", "xay".encode("US-ASCII"), "a", "é".encode("UTF-8")],
      ["binary with UTF-8 replacement", "xay".b, "a", "é".encode("UTF-8")],
      ["Windows-31J replacement", "xay".encode("UTF-8"), "a",
       "あ".encode("Windows-31J")],
      ["empty replacement", "éaø", "a", "".encode("Windows-31J")],
      ["no match", "xyz".encode("UTF-8"), "q", "あ".encode("Windows-31J")],
      ["all subject replaced", "a".encode("US-ASCII"), "a", "é".encode("UTF-8")]
    ]

    cases.each do |label, source, pattern, replacement|
      assert_native_path(source, pattern)
      expected = observe_explicit(:mri, source, pattern, replacement: replacement)
      actual = observe_explicit(:onibi, source, pattern, replacement: replacement)
      assert_equal expected, actual, label
    end
  end

  def test_utf16le_replacement_uses_mri_compatibility_rules
    compatible = assert_explicit_match("é", "é", "é".encode("UTF-16LE"))
    assert_equal "UTF-16LE", compatible.fetch(:result).fetch(:encoding)
    assert_equal [233, 0], compatible.fetch(:result).fetch(:bytes)
    assert compatible.fetch(:result).fetch(:valid_encoding)

    error = assert_explicit_match("xay", "a", "é".encode("UTF-16LE"))
    assert_equal :error, error.fetch(:status)
    assert_equal "Encoding::CompatibilityError", error.fetch(:exception_class)
    assert_equal "incompatible character encodings: UTF-8 and UTF-16LE",
                 error.fetch(:exception_message)
  end

  def test_unmatched_ranges_and_capture_bytes_keep_their_source_encoding
    prefix_error = assert_explicit_match("éa", "a", "あ".encode("Windows-31J"))
    assert_equal :error, prefix_error.fetch(:status)
    assert_equal "incompatible character encodings: UTF-8 and Windows-31J",
                 prefix_error.fetch(:exception_message)

    suffix_error = assert_explicit_match("aé", "a", "あ".encode("Windows-31J"))
    assert_equal :error, suffix_error.fetch(:status)
    assert_equal "incompatible character encodings: Windows-31J and UTF-8",
                 suffix_error.fetch(:exception_message)

    source = "é"
    replacement = "left-\\1-right".encode("Windows-31J")
    captured = assert_explicit_match(source, "(é)", replacement)
    assert_equal "UTF-8", captured.fetch(:result).fetch(:encoding)
    assert_equal "left-é-right".bytes, captured.fetch(:result).fetch(:bytes)
    assert captured.fetch(:result).fetch(:valid_encoding)
  end

  def test_all_replaced_repeated_and_zero_width_matches_adopt_replacement_encoding
    all_replaced = assert_explicit_match("é", "é", "あ".encode("Windows-31J"))
    assert_equal "Windows-31J", all_replaced.fetch(:result).fetch(:encoding)
    assert_equal "あ".encode("Windows-31J").bytes,
                 all_replaced.fetch(:result).fetch(:bytes)

    ["a", "(?=a)"].each do |pattern|
      result = assert_explicit_match("aa", pattern, "あ".encode("Windows-31J"))
      assert_equal "Windows-31J", result.fetch(:result).fetch(:encoding), pattern
      assert result.fetch(:result).fetch(:valid_encoding), pattern
    end

    yielded = assert_block_match("aa", "(?=a)") do |_events, _input, _match, _index|
      "あ".encode("Windows-31J")
    end
    assert_equal 2, yielded.fetch(:yield_count)
    assert_equal "Windows-31J", yielded.fetch(:result).fetch(:encoding)
  end

  def test_block_results_and_mixed_encodings_match_mri_yield_order
    result = assert_block_match("xay", "a") do |events, _input, _match, index|
      string_return("あ".encode("Windows-31J"), events, index)
    end
    assert_equal "Windows-31J", result.fetch(:result).fetch(:encoding)
    assert_equal [[:yield, [97], "UTF-8"], [:to_s, 1]], result.fetch(:events)

    mixed_cases = [
      ["aa", ["é".encode("UTF-8"), "あ".encode("Windows-31J")],
       "incompatible character encodings: UTF-8 and Windows-31J", 2],
      ["aa", ["あ".encode("Windows-31J"), "é".encode("UTF-8")],
       "incompatible character encodings: Windows-31J and UTF-8", 2],
      ["aaé", ["あ".encode("Windows-31J")],
       "incompatible character encodings: Windows-31J and UTF-8", 2],
      ["éaa", ["あ".encode("Windows-31J")],
       "incompatible character encodings: UTF-8 and Windows-31J", 1]
    ]
    mixed_cases.each do |source, values, message, expected_yields|
      actual = assert_block_match(source, "a") do |_events, _input, _match, index|
        string_return(values.fetch([index - 1, values.length - 1].min))
      end
      assert_equal :error, actual.fetch(:status)
      assert_equal "Encoding::CompatibilityError", actual.fetch(:exception_class)
      assert_equal message, actual.fetch(:exception_message)
      assert_equal expected_yields, actual.fetch(:yield_count)
      yield_events = actual.fetch(:events).count { |event| event.first == :yield }
      assert_equal expected_yields, yield_events
    end
  end

  def test_block_conversion_precedes_middle_range_encoding_errors
    assert_native_path("aéa", "a")
    expected_events = [[:yield, 1], [:to_s, 1], [:yield, 2], [:to_s, 2]]

    normal = assert_middle_gap_match(:normal)
    assert_equal :error, normal.fetch(:status)
    assert_equal "Encoding::CompatibilityError", normal.fetch(:exception_class)
    assert_equal "incompatible character encodings: Windows-31J and UTF-8",
                 normal.fetch(:exception_message)
    assert_equal expected_events, normal.fetch(:events)

    raised = assert_middle_gap_match(:raise)
    assert_equal "RuntimeError", raised.fetch(:exception_class)
    assert_equal "conversion wins", raised.fetch(:exception_message)
    assert_equal expected_events, raised.fetch(:events)

    mutated = assert_middle_gap_match(:mutate)
    assert_equal "RuntimeError", mutated.fetch(:exception_class)
    assert_equal "string modified", mutated.fetch(:exception_message)
    assert_equal expected_events, mutated.fetch(:events)

    thrown = assert_middle_gap_match(:throw)
    assert_equal :ok, thrown.fetch(:status)
    assert_equal "exit wins".bytes, thrown.fetch(:result).fetch(:bytes)
    assert_equal expected_events, thrown.fetch(:events)
  end

  def test_replacement_expansion_errors_precede_output_encoding_errors
    cases = [
      ["éa", "(?<x>a)", "あ\\k<bad>", "IndexError",
       "undefined group name reference: bad"],
      ["éa", "(a)", "あ\\k<bad>", "IndexError",
       "undefined group name reference: bad"],
      ["éa", "(a)", "あ\\1\\k<bad>", "IndexError",
       "undefined group name reference: bad"],
      ["é", "(é)", "あ\\1\\k<bad>", "Encoding::CompatibilityError",
       "incompatible character encodings: Windows-31J and UTF-8"]
    ]

    cases.each do |source, pattern, text, exception_class, message|
      result = assert_explicit_match(source, pattern, text.encode("Windows-31J"))
      assert_equal :error, result.fetch(:status)
      assert_equal exception_class, result.fetch(:exception_class)
      assert_equal message, result.fetch(:exception_message)
    end
  end

  def test_invalid_bytes_and_both_string_coercion_paths_match_mri
    invalid = "\xFF".b.force_encoding(Encoding::UTF_8)
    invalid_result = assert_explicit_match("a", "a", invalid)
    assert_equal [255], invalid_result.fetch(:result).fetch(:bytes)
    assert_equal "UTF-8", invalid_result.fetch(:result).fetch(:encoding)
    refute invalid_result.fetch(:result).fetch(:valid_encoding)

    converted = assert_explicit_match("xay", "a", replacement_factory: lambda do |events, _input|
      object = Object.new
      object.define_singleton_method(:to_str) do
        events << [:to_str]
        "あ".encode("Windows-31J")
      end
      object.define_singleton_method(:to_s) { raise "to_s must not run" }
      object
    end)
    assert_equal [[:to_str]], converted.fetch(:events)
    assert_equal "Windows-31J", converted.fetch(:result).fetch(:encoding)

    converted_block = assert_block_match("xay", "a") do |events, _input, _match, index|
      string_return("é".encode("UTF-8"), events, index)
    end
    assert_equal [[:yield, [97], "UTF-8"], [:to_s, 1]],
                 converted_block.fetch(:events)
    assert_equal "UTF-8", converted_block.fetch(:result).fetch(:encoding)
  end

  def test_mutation_and_coercion_errors_precede_append_errors
    mutation = assert_block_match("éa", "a") do |_events, input, _match, _index|
      input << "x"
      "あ".encode("Windows-31J")
    end
    assert_equal "RuntimeError", mutation.fetch(:exception_class)
    assert_equal "string modified", mutation.fetch(:exception_message)
    assert_equal 1, mutation.fetch(:yield_count)

    block_coercion = assert_block_match("éa", "a") do |events, _input, _match, _index|
      object = Object.new
      object.define_singleton_method(:to_s) do
        events << [:to_s]
        raise "block conversion failed"
      end
      object
    end
    assert_equal "RuntimeError", block_coercion.fetch(:exception_class)
    assert_equal "block conversion failed", block_coercion.fetch(:exception_message)
    assert_equal [[:yield, [97], "UTF-8"], [:to_s]], block_coercion.fetch(:events)

    explicit_coercion = assert_explicit_match(
      "éa", "a", replacement_factory: lambda do |events, _input|
        object = Object.new
        object.define_singleton_method(:to_str) do
          events << [:to_str]
          raise "replacement conversion failed"
        end
        object
      end
    )
    assert_equal "RuntimeError", explicit_coercion.fetch(:exception_class)
    assert_equal "replacement conversion failed",
                 explicit_coercion.fetch(:exception_message)
    assert_equal [[:to_str]], explicit_coercion.fetch(:events)
    assert_equal 0, explicit_coercion.fetch(:yield_count)
  end

  def test_encoding_error_releases_capture_ranges_for_a_later_call
    regexp = Onibi::Regexp.new("(a)")
    replacement = "あ".encode("Windows-31J")
    error = assert_raises(Encoding::CompatibilityError) do
      regexp.gsub("éa", replacement)
    end
    assert_equal "incompatible character encodings: UTF-8 and Windows-31J",
                 error.message

    GC.start
    assert_equal "X", regexp.gsub("a", "X")
  end

  private

  def assert_explicit_match(source, pattern, replacement = nil, replacement_factory: nil)
    assert_native_path(source, pattern)
    expected = observe_explicit(
      :mri,
      source,
      pattern,
      replacement: replacement,
      replacement_factory: replacement_factory
    )
    actual = observe_explicit(
      :onibi,
      source,
      pattern,
      replacement: replacement,
      replacement_factory: replacement_factory
    )
    assert_equal expected, actual
    actual
  end

  def assert_block_match(source, pattern, &block_factory)
    assert_native_path(source, pattern)
    expected = observe_block(:mri, source, pattern, &block_factory)
    actual = observe_block(:onibi, source, pattern, &block_factory)
    assert_equal expected, actual
    actual
  end

  def assert_middle_gap_match(mode)
    expected = observe_middle_gap(:mri, mode)
    actual = observe_middle_gap(:onibi, mode)
    assert_equal expected, actual, mode
    actual
  end

  def assert_native_path(source, pattern)
    diagnostics = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, source.dup)
    assert diagnostics.fetch(:rseq), pattern
    assert_equal 0, diagnostics.fetch(:fallback), pattern
    assert_equal :none, diagnostics.fetch(:fallback_reason), pattern
  end

  def observe_explicit(engine, source, pattern, replacement:, replacement_factory: nil)
    input = source.dup
    events = []
    regexp = engine == :mri ? ::Regexp.new(pattern) : Onibi::Regexp.new(pattern)
    yield_count = 0
    argument = if replacement_factory
                 replacement_factory.call(events, input)
               else
                 replacement.dup
               end
    result = if engine == :mri
               input.gsub(regexp, argument)
             else
               regexp.gsub(input, argument)
             end
    success_record(input, result, yield_count, events)
  rescue StandardError => e
    error_record(input, e, yield_count, events)
  end

  def observe_block(engine, source, pattern)
    input = source.dup
    events = []
    regexp = engine == :mri ? ::Regexp.new(pattern) : Onibi::Regexp.new(pattern)
    yield_count = 0
    block = proc do |match|
      yield_count += 1
      events << [:yield, match.bytes, match.encoding.name]
      yield(events, input, match, yield_count)
    end
    result = if engine == :mri
               input.gsub(regexp, &block)
             else
               regexp.gsub(input, &block)
             end
    success_record(input, result, yield_count, events)
  rescue StandardError => e
    error_record(input, e, yield_count, events)
  end

  def observe_middle_gap(engine, mode)
    input = +"aéa"
    events = []
    regexp = engine == :mri ? /a/ : Onibi::Regexp.new("a")
    yield_count = 0
    block = proc do |_match|
      yield_count += 1
      index = yield_count
      events << [:yield, index]
      object = Object.new
      object.define_singleton_method(:to_s) do
        events << [:to_s, index]
        if index == 2
          raise "conversion wins" if mode == :raise

          input << "x" if mode == :mutate
          throw :done, "exit wins" if mode == :throw
        end
        "あ".encode("Windows-31J")
      end
      object
    end
    result = catch(:done) do
      if engine == :mri
        input.gsub(regexp, &block)
      else
        regexp.gsub(input, &block)
      end
    end
    success_record(input, result, yield_count, events)
  rescue StandardError => e
    error_record(input, e, yield_count, events)
  end

  def success_record(input, result, yield_count, events)
    {
      status: :ok,
      result: string_record(result),
      input_after: string_record(input),
      yield_count: yield_count,
      events: events
    }
  end

  def error_record(input, error, yield_count, events)
    {
      status: :error,
      exception_class: error.class.name,
      exception_message: error.message,
      input_after: string_record(input),
      yield_count: yield_count,
      events: events
    }
  end

  def string_record(string)
    {
      bytes: string.bytes,
      encoding: string.encoding.name,
      valid_encoding: string.valid_encoding?
    }
  end

  def string_return(value, events = nil, index = nil)
    object = Object.new
    object.define_singleton_method(:to_s) do
      events << [:to_s, index] if events
      value
    end
    object
  end
end
