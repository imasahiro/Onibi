# frozen_string_literal: true

require "digest"
require "json"
require "rbconfig"
require "test_helper"

class MatchDataMatchTest < Minitest::Test
  class Selector
    def initialize(events, method_name, value = nil, error = nil, values: nil)
      @events = events
      @method_name = method_name
      @value = value
      @error = error
      @values = values
      @call_count = 0
    end

    def convert(method_name)
      @events << method_name
      raise @error if @error

      if @values
        value = @values.fetch(@call_count)
        @call_count += 1
        return value
      end

      @value
    end
  end

  class ToIntOnly < Selector
    def to_int
      convert("to_int")
    end
  end

  class ToStrOnly < Selector
    def to_str
      convert("to_str")
    end
  end

  class ToIOnly < Selector
    def to_i
      convert("to_i")
    end
  end

  class ToIntAndToStr < Selector
    def to_int
      convert("to_int")
    end

    def to_str
      convert("to_str")
    end
  end

  class ToIntAndToI < Selector
    def to_int
      convert("to_int")
    end

    def to_i
      convert("to_i")
    end
  end

  class WrongToInt < Selector
    def to_int
      convert("to_int")
    end
  end

  class RaisingToInt < Selector
    def to_int
      convert("to_int")
    end
  end

  FIXTURES = {
    "ascii_optional_empty" => [
      "\\A(?<word>a)(?<empty>)(?<optional>b)?\\z", "a", "UTF-8", 0
    ],
    "duplicate_last_unmatched" => [
      "\\A(?<dup>A)(?<dup>B)?\\z", "A", "UTF-8", 0
    ],
    "duplicate_all_unmatched" => [
      "\\A(?<dup>A)?(?<dup>B)?\\z", "", "UTF-8", 0
    ],
    "utf8_multibyte" => [
      "\\A(?<kana>あ)(?<tail>β*)\\z", "あββ", "UTF-8", 0
    ],
    "windows31j_multibyte" => [
      [
        [92, 65, 40, 63, 60, 107, 97, 110, 97, 62, 130, 160, 41,
         40, 63, 60, 116, 97, 105, 108, 62, 130, 162, 63, 41, 92, 122],
        [130, 160]
      ],
      nil,
      "Windows-31J",
      0
    ],
    "binary_byte" => [
      "\\A(?<byte>.)(?<empty>)\\z", "\xFF".b, "ASCII-8BIT", 0
    ]
  }.freeze

  ORIGINAL_CASES = [
    ["match_omitted", "ascii_optional_empty", []],
    ["match_nil", "ascii_optional_empty", [nil]],
    ["match_full_zero", "ascii_optional_empty", [0]],
    ["match_word_one", "ascii_optional_empty", [1]],
    ["match_empty_two", "ascii_optional_empty", [2]],
    ["match_unmatched_three", "ascii_optional_empty", [3]],
    ["match_positive_out_of_range", "ascii_optional_empty", [4]],
    ["match_negative_last", "ascii_optional_empty", [-1]],
    ["match_negative_full", "ascii_optional_empty", [-4]],
    ["match_negative_out_of_range", "ascii_optional_empty", [-5]],
    ["match_oversized_positive", "ascii_optional_empty", [2**80]],
    ["match_oversized_negative", "ascii_optional_empty", [-(2**80)]],
    ["match_float", "ascii_optional_empty", [1.75]],
    ["match_to_int", "ascii_optional_empty", [{ selector: :to_int, value: 2 }]],
    ["match_to_i_only", "ascii_optional_empty", [{ selector: :to_i, value: 1 }]],
    ["match_to_int_wrong_return", "ascii_optional_empty",
     [{ selector: :wrong_to_int, value: "2" }]],
    ["match_to_int_raises", "ascii_optional_empty",
     [{ selector: :raising_to_int, error: RuntimeError.new("selector failure") }]],
    ["match_named_string", "ascii_optional_empty", ["word"]],
    ["match_named_symbol", "ascii_optional_empty", [:word]],
    ["match_unknown_name_string", "ascii_optional_empty", ["missing"]],
    ["match_unknown_name_symbol", "ascii_optional_empty", [:missing]],
    ["match_to_str_name", "ascii_optional_empty",
     [{ selector: :to_str, value: "word" }]],
    ["match_duplicate_last_unmatched", "duplicate_last_unmatched", [:dup]],
    ["match_duplicate_all_unmatched", "duplicate_all_unmatched", ["dup"]],
    ["match_range_inclusive", "ascii_optional_empty", [1..3]],
    ["match_range_exclusive", "ascii_optional_empty", [1...3]],
    ["match_extra_argument", "ascii_optional_empty", [1, 2]],
    ["match_utf8_name", "utf8_multibyte", [:kana]],
    ["match_utf8_tail", "utf8_multibyte", [2]],
    ["match_windows31j_name", "windows31j_multibyte", [:kana]],
    ["match_binary_capture", "binary_byte", [1]]
  ].freeze

  CORRECTED_CASES = [
    ["only_to_int", { selector: :to_int, value: 1 }],
    ["only_to_str", { selector: :to_str, value: "word" }],
    ["only_to_i", { selector: :to_i, value: 1 }],
    ["dual_int_str", { selector: :to_int_and_to_str, value: 1, other: "word" }],
    ["dual_int_i", { selector: :to_int_and_to_i, value: 2, other: 1 }],
    ["wrong_int", { selector: :wrong_to_int, value: "2" }],
    ["raises_int", { selector: :raising_to_int, error: RuntimeError.new("selector failure") }],
    ["ordered_first", { selector: :to_int, value: 1 }],
    ["ordered_second", { selector: :to_int, value: 2 }],
    ["stateful_twice", { selector: :stateful_to_int, values: [1, 2] }]
  ].freeze

  def test_public_match_matches_mri_for_frozen_api02_cases
    rows = []
    cases = ORIGINAL_CASES.map { |id, fixture, args| [id, fixture, args] }
    CORRECTED_CASES.each do |id, selector|
      cases << ["corrected_#{id}", "ascii_optional_empty", [selector]]
    end

    cases.each do |id, fixture_id, selector_specs|
      pattern, subject, encoding, options = fixture(fixture_id)
      mri_regexp = ::Regexp.new(pattern, options)
      mri_match = mri_regexp.match(subject)
      onibi_regexp = Onibi::Regexp.new(pattern, options)
      onibi_match = onibi_regexp.match(subject)
      diagnostics = onibi_regexp.send(:__onibi_diagnostics__, subject)
      raw = onibi_match.send(:__onibi_match_data_diagnostics__)
      events_mri = []
      events_onibi = []
      mri_args = selectors(selector_specs, events_mri)
      onibi_args = selectors(selector_specs, events_onibi)
      mri_result = observe { mri_match.public_send(:match, *mri_args) }
      onibi_result = observe { onibi_match.public_send(:match, *onibi_args) }
      rows << {
        "id" => id,
        "fixture" => fixture_id,
        "pattern_bytes" => pattern.b.bytes,
        "subject_bytes" => subject.b.bytes,
        "encoding" => encoding,
        "options" => options,
        "selectors" => selector_specs.map { |spec| selector_record(spec) },
        "mri" => mri_result,
        "onibi" => onibi_result,
        "mri_conversion_events" => events_mri,
        "onibi_conversion_events" => events_onibi,
        "native_diagnostics" => diagnostics,
        "raw_matchdata" => raw
      }
    end

    write_evidence(rows)
    refute_empty rows
    rows.each do |row|
      assert_equal row["mri"], row["onibi"], row["id"]
      assert_equal row["mri_conversion_events"], row["onibi_conversion_events"], row["id"]
      assert_equal true, row["native_diagnostics"][:rseq], row["id"]
      assert_equal 0, row["native_diagnostics"][:fallback], row["id"]
    end
  end

  def test_match_reads_the_frozen_snapshot_after_subject_mutation
    subject = String.new("xxéyy")
    regexp = Onibi::Regexp.new("(?<word>é)")
    match_data = regexp.match(subject)
    subject.replace("changed")
    GC.start
    GC.compact

    assert_equal "é", match_data.match(1)
    assert_equal Encoding::UTF_8, match_data.match(1).encoding
    diagnostics = regexp.send(:__onibi_diagnostics__, "xxéyy")
    assert_equal true, diagnostics[:rseq]
    assert_equal 0, diagnostics[:fallback]
  end

  def fixture(id)
    pattern, subject, encoding, options = FIXTURES.fetch(id)
    encoding = Encoding.find(encoding)
    if pattern.is_a?(Array)
      pattern_bytes, subject_bytes, = pattern
      pattern = pattern_bytes.pack("C*").force_encoding(encoding)
      subject = subject_bytes.pack("C*").force_encoding(encoding)
    else
      pattern = pattern.dup.force_encoding(encoding)
      subject = subject.dup.force_encoding(encoding)
    end
    [pattern, subject, encoding.name, options]
  end

  def selectors(specs, events)
    specs.map do |spec|
      next spec unless spec.is_a?(Hash) && spec.key?(:selector)

      case spec.fetch(:selector)
      when :to_int
        ToIntOnly.new(events, "to_int", spec[:value])
      when :stateful_to_int
        ToIntOnly.new(events, "to_int", nil, nil, values: spec[:values])
      when :to_str
        ToStrOnly.new(events, "to_str", spec[:value])
      when :to_i
        ToIOnly.new(events, "to_i", spec[:value])
      when :to_int_and_to_str
        ToIntAndToStr.new(events, "to_int", spec[:value]).tap do |object|
          object.define_singleton_method(:to_str) do
            events << "to_str"
            spec[:other]
          end
        end
      when :to_int_and_to_i
        ToIntAndToI.new(events, "to_int", spec[:value]).tap do |object|
          object.define_singleton_method(:to_i) do
            events << "to_i"
            spec[:other]
          end
        end
      when :wrong_to_int
        WrongToInt.new(events, "to_int", spec[:value])
      when :raising_to_int
        RaisingToInt.new(events, "to_int", nil, spec[:error])
      else
        raise ArgumentError, "unknown selector descriptor"
      end
    end
  end

  def selector_record(spec)
    case spec
    when Hash
      spec.each_with_object({}) do |(key, value), result|
        result[key.to_s] = selector_record(value)
      end
    when Array
      spec.map { |value| selector_record(value) }
    when Symbol
      spec.to_s
    when Exception
      { "class" => spec.class.name, "message" => spec.message }
    else
      spec
    end
  end

  def observe
    [:value, value_shape(yield)]
  rescue StandardError => e
    [:error, e.class.name, e.message, e.message.encoding.name, e.message.b.bytes]
  end

  def value_shape(value)
    case value
    when String
      ["String", value.b.bytes, value.encoding.name, value.frozen?]
    else
      value
    end
  end

  def evidence_shape(value)
    case value
    when String
      {
        "class" => "String",
        "encoding" => value.encoding.name,
        "bytes" => value.b.bytes,
        "frozen" => value.frozen?
      }
    when Array
      value.map { |item| evidence_shape(item) }
    when Hash
      value.each_with_object({}) do |(key, item), result|
        key_text = if key.is_a?(String)
                     key.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
                   else
                     key.to_s
                   end
        result[key_text] = evidence_shape(item)
      end
    when Symbol
      value.to_s
    when Numeric, TrueClass, FalseClass, NilClass
      value
    else
      { "class" => value.class.name }
    end
  end

  def write_evidence(rows)
    path = ENV["ONIBI_API02_RESULTS_PATH"]
    return unless path

    source_hashes = %w[
      ext/onibi/match_data.c ext/onibi/onibi_init.c
      ext/onibi/onibi_matchdata_internal.h
      test/features/captures/match_data_match_test.rb
    ].to_h do |relative|
      [relative, Digest::SHA256.file(File.join(PROJECT_ROOT, relative)).hexdigest]
    end
    artifact = {
      "runtime" => RUBY_DESCRIPTION,
      "argv" => [RbConfig.ruby, $PROGRAM_NAME, *ARGV],
      "source_hashes" => source_hashes,
      "results" => rows.map do |row|
        row.merge(
          "native_diagnostics" => evidence_shape(row.fetch("native_diagnostics")),
          "raw_matchdata" => evidence_shape(row.fetch("raw_matchdata"))
        )
      end
    }
    File.write(path, "#{JSON.pretty_generate(artifact)}\n")
  end
end
