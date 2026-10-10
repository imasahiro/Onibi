# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "test_helper"

class MatchDataValuesAtTest < Minitest::Test
  class LegacySelector
    def initialize(events:, descriptor:)
      @events = events
      @label = descriptor.fetch(:label)
      @modes = descriptor.fetch(:modes)
      @integer = descriptor[:integer]
      @string = descriptor[:string]
      @bad_value = descriptor[:bad_value]
      @has_bad_value = descriptor.fetch(:has_bad_value, false)
      @error = descriptor[:error]
    end

    def to_int
      record("to_int")
      raise @error if @error
      return @bad_value if @has_bad_value

      @integer
    end

    def to_str
      raise NoMethodError, "to_str is not enabled" unless @modes.include?("to_str")

      record("to_str")
      @string
    end

    def to_i
      record("to_i")
      @integer
    end

    def inspect
      "#<API03LegacySelector #{@label}>"
    end

    private

    def record(method)
      @events << { "label" => @label, "method" => method }
    end
  end

  class PlainSelector
    def initialize(label)
      @label = label
    end

    def inspect
      "#<API03PlainSelector #{@label}>"
    end
  end

  module ExactSelectors
    class Base
      attr_reader :kind, :definition

      def initialize(events:, kind:, definition:, label:)
        @events = events
        @kind = kind
        @definition = definition
        @label = label
        @calls = Hash.new(0)
      end

      def convert(method)
        call_index = @calls[method]
        @calls[method] += 1
        @events << {
          "label" => @label,
          "kind" => @kind.to_s,
          "method" => method,
          "call_index" => call_index
        }

        raise @definition["exception"] if method == "to_int" && @definition["exception"]

        return @definition.fetch("values").fetch(call_index) if method == "to_int" && @definition.key?("values")

        @definition.fetch(method, @definition["value"])
      end

      def inspect
        "#<API03Selector #{@kind}:#{@label}>"
      end
    end

    class OnlyToInt < Base
      def to_int
        convert("to_int")
      end
    end

    class OnlyToStr < Base
      def to_str
        convert("to_str")
      end
    end

    class OnlyToI < Base
      def to_i
        convert("to_i")
      end
    end

    class DualIntStr < Base
      def to_int
        convert("to_int")
      end

      def to_str
        convert("to_str")
      end
    end

    class DualIntI < Base
      def to_int
        convert("to_int")
      end

      def to_i
        convert("to_i")
      end
    end

    class WrongInt < Base
      def to_int
        convert("to_int")
      end
    end

    class RaisesInt < Base
      def to_int
        convert("to_int")
      end
    end

    class OrderedFirst < Base
      def to_int
        convert("to_int")
      end
    end

    class OrderedSecond < Base
      def to_int
        convert("to_int")
      end
    end

    class StatefulTwice < Base
      def to_int
        convert("to_int")
      end
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
    ["values_at_omitted", "ascii_optional_empty", []],
    ["values_at_nil", "ascii_optional_empty", [nil]],
    ["values_at_full_zero", "ascii_optional_empty", [0]],
    ["values_at_word_one", "ascii_optional_empty", [1]],
    ["values_at_empty_two", "ascii_optional_empty", [2]],
    ["values_at_unmatched_three", "ascii_optional_empty", [3]],
    ["values_at_positive_out_of_range", "ascii_optional_empty", [4]],
    ["values_at_negative_last", "ascii_optional_empty", [-1]],
    ["values_at_negative_full", "ascii_optional_empty", [-4]],
    ["values_at_negative_out_of_range", "ascii_optional_empty", [-5]],
    ["values_at_oversized_positive", "ascii_optional_empty",
     [{ integer: "1208925819614629174706176" }]],
    ["values_at_oversized_negative", "ascii_optional_empty",
     [{ integer: "-1208925819614629174706176" }]],
    ["values_at_float", "ascii_optional_empty", [1.75]],
    ["values_at_known_string_name", "ascii_optional_empty", ["word"]],
    ["values_at_known_symbol_name", "ascii_optional_empty", [:empty]],
    ["values_at_unknown_string_name", "ascii_optional_empty", ["missing"]],
    ["values_at_unknown_symbol_name", "ascii_optional_empty", [:missing]],
    ["values_at_to_str_name", "ascii_optional_empty",
     [{ to_str: { value: "word", event: "values-name" } }]],
    ["values_at_inclusive_range", "ascii_optional_empty",
     [{ range: { begin: 1, end: 3, exclude_end: false } }]],
    ["values_at_exclusive_range", "ascii_optional_empty",
     [{ range: { begin: 1, end: 3, exclude_end: true } }]],
    ["values_at_negative_range", "ascii_optional_empty",
     [{ range: { begin: -3, end: -1, exclude_end: false } }]],
    ["values_at_truncated_range", "ascii_optional_empty",
     [{ range: { begin: 2, end: 9, exclude_end: false } }]],
    ["values_at_endless_range", "ascii_optional_empty",
     [{ range: { begin: 1, end: nil, exclude_end: false } }]],
    ["values_at_beginless_range", "ascii_optional_empty",
     [{ range: { begin: nil, end: 2, exclude_end: false } }]],
    ["values_at_float_range", "ascii_optional_empty",
     [{ range: { begin: 1.2, end: 2, exclude_end: false } }]],
    ["values_at_mixed_order", "ascii_optional_empty",
     [0, :empty, { range: { begin: 1, end: 3, exclude_end: true } }, -1]],
    ["values_at_to_int_order", "ascii_optional_empty",
     [
       { to_int: { value: 1, event: "first" } },
       { to_int: { value: 2, event: "second" } }
     ]],
    ["values_at_shared_to_int_twice", "ascii_optional_empty",
     [{ shared_to_int: "shared-index" }, { shared_to_int: "shared-index" }]],
    ["values_at_to_int_wrong_return", "ascii_optional_empty",
     [{ bad_to_int: "2" }]],
    ["values_at_to_int_raises", "ascii_optional_empty",
     [{ raise_to_int: { class: "RuntimeError", message: "selector failure",
                        event: "values-index" } }]],
    ["values_at_to_i_only", "ascii_optional_empty", [{ to_i_only: 1 }]],
    ["values_at_uncoercible_object", "ascii_optional_empty",
     [{ plain_object: "selector" }]],
    ["values_at_duplicate_last_unmatched", "duplicate_last_unmatched", [:dup]],
    ["values_at_duplicate_all_unmatched", "duplicate_all_unmatched", ["dup"]],
    ["values_at_duplicate_mixed", "duplicate_last_unmatched",
     [
       { range: { begin: 0, end: 2, exclude_end: false } },
       :dup
     ]],
    ["values_at_utf8_multibyte", "utf8_multibyte",
     [0, :kana, 2, { range: { begin: 1, end: 2, exclude_end: false } }]],
    ["values_at_windows31j_multibyte", "windows31j_multibyte", [:kana, 1]],
    ["values_at_binary_byte", "binary_byte", [0, 1, 2]]
  ].freeze

  CORRECTED_CASES = [
    ["only_to_int", [{ kind: :only_to_int }]],
    ["only_to_str", [{ kind: :only_to_str }]],
    ["only_to_i", [{ kind: :only_to_i }]],
    ["dual_int_str", [{ kind: :dual_int_str }]],
    ["dual_int_i", [{ kind: :dual_int_i }]],
    ["wrong_int", [{ kind: :wrong_int }]],
    ["raises_int", [{ kind: :raises_int }]],
    ["ordered_first", [{ kind: :ordered_first }, { kind: :ordered_second }]],
    ["ordered_second", [{ kind: :ordered_second }]],
    ["stateful_twice",
     [
       { kind: :stateful_twice, shared: "stateful_twice" },
       { kind: :stateful_twice, shared: "stateful_twice" }
     ]]
  ].freeze

  CORRECTED_DEFINITIONS = {
    only_to_int: { "methods" => ["to_int"], "value" => 1 },
    only_to_str: { "methods" => ["to_str"], "value" => "word" },
    only_to_i: { "methods" => ["to_i"], "value" => 1 },
    dual_int_str: { "methods" => %w[to_int to_str], "to_int" => 1,
                    "to_str" => "word" },
    dual_int_i: { "methods" => %w[to_int to_i], "to_int" => 2, "to_i" => 1 },
    wrong_int: { "methods" => ["to_int"], "value" => "2" },
    raises_int: { "methods" => ["to_int"], "exception" => "selector failure" },
    ordered_first: { "methods" => ["to_int"], "value" => 1 },
    ordered_second: { "methods" => ["to_int"], "value" => 2 },
    stateful_twice: { "methods" => ["to_int"], "values" => [1, 2] }
  }.freeze

  EXACT_SELECTOR_CLASSES = {
    only_to_int: ExactSelectors::OnlyToInt,
    only_to_str: ExactSelectors::OnlyToStr,
    only_to_i: ExactSelectors::OnlyToI,
    dual_int_str: ExactSelectors::DualIntStr,
    dual_int_i: ExactSelectors::DualIntI,
    wrong_int: ExactSelectors::WrongInt,
    raises_int: ExactSelectors::RaisesInt,
    ordered_first: ExactSelectors::OrderedFirst,
    ordered_second: ExactSelectors::OrderedSecond,
    stateful_twice: ExactSelectors::StatefulTwice
  }.freeze

  BOUNDARY_CASES = [
    ["values_at_inclusive_endless_range", "utf8_multibyte",
     [{ range: { begin: 1, end: nil, exclude_end: false } }]],
    ["values_at_exclusive_endless_range", "utf8_multibyte",
     [{ range: { begin: 1, end: nil, exclude_end: true } }]],
    ["values_at_beginless_exclusive_range", "utf8_multibyte",
     [{ range: { begin: nil, end: 2, exclude_end: true } }]],
    ["values_at_range_subclass_overrides", "utf8_multibyte",
     [{ range_subclass: { begin: 1, end: 2, exclude_end: false } }]],
    ["values_at_range_below_zero", "ascii_optional_empty",
     [{ range: { begin: -6, end: -3, exclude_end: false } }]],
    ["values_at_reversed_range", "ascii_optional_empty",
     [{ range: { begin: 3, end: 1, exclude_end: false } }]],
    ["values_at_bignum_range_end", "ascii_optional_empty",
     [{ range: { begin: 0, end: { integer: "1208925819614629174706176" },
                 exclude_end: false } }]],
    ["values_at_stops_after_conversion_error", "ascii_optional_empty",
     [
       { to_int: { value: 1, event: "before-error" } },
       { raise_to_int: { class: "RuntimeError", message: "selector failure",
                         event: "raising-selector" } },
       { to_int: { value: 2, event: "after-error" } }
     ]]
  ].freeze

  class CompactingSelector
    def initialize(match_data, events)
      @match_data = match_data
      @events = events
    end

    def to_int
      @events << "to_int"
      @match_data.values_at(2)
      GC.start
      GC.compact
      1
    end
  end

  class RangeWithRaisingAccessors < Range
    {
      begin: "Range#begin",
      end: "Range#end",
      exclude_end?: "Range#exclude_end?"
    }.each do |method_name, label|
      define_method(method_name) do
        raise NoMethodError, "#{label} override called"
      end
    end
  end

  def test_values_at_matches_mri_for_frozen_api03_cases
    cases = ORIGINAL_CASES.map { |id, fixture_id, args| [id, fixture_id, args] }
    CORRECTED_CASES.each do |id, args|
      cases << ["corrected_#{id}", "ascii_optional_empty", args]
    end
    BOUNDARY_CASES.each do |id, fixture_id, args|
      cases << [id, fixture_id, args]
    end

    rows = cases.map do |id, fixture_id, argument_specs|
      pattern, subject, encoding, options = fixture(fixture_id)
      mri_match = ::Regexp.new(pattern, options).match(subject)
      onibi_regexp = Onibi::Regexp.new(pattern, options)
      onibi_match = onibi_regexp.match(subject)
      diagnostics = onibi_regexp.send(:__onibi_diagnostics__, subject)
      raw = onibi_match.send(:__onibi_match_data_diagnostics__)
      events_mri = []
      events_onibi = []
      mri_args = build_arguments(argument_specs, events_mri)
      onibi_args = build_arguments(argument_specs, events_onibi)
      mri_result = observe { mri_match.public_send(:values_at, *mri_args) }
      onibi_result = observe { onibi_match.public_send(:values_at, *onibi_args) }

      {
        "id" => id,
        "fixture" => fixture_id,
        "pattern_bytes" => pattern.b.bytes,
        "subject_bytes" => subject.b.bytes,
        "encoding" => encoding,
        "options" => options,
        "selectors" => evidence_shape(argument_specs),
        "mri" => mri_result,
        "onibi" => onibi_result,
        "mri_conversion_events" => events_mri,
        "onibi_conversion_events" => events_onibi,
        "native_diagnostics" => diagnostics,
        "raw_matchdata" => raw
      }
    end

    write_evidence(rows)
    assert_equal 56, rows.length
    mismatches = rows.filter_map do |row|
      row["id"] unless row["mri"] == row["onibi"] &&
                       row["mri_conversion_events"] == row["onibi_conversion_events"]
    end
    rows.each do |row|
      assert_equal true, row["native_diagnostics"][:rseq], row["id"]
      assert_equal 0, row["native_diagnostics"][:fallback], row["id"]
    end
    assert_empty mismatches, JSON.generate(mismatches)
  end

  def test_values_at_reads_the_frozen_snapshot_after_subject_mutation
    subject = String.new("xxéyzz")
    regexp = Onibi::Regexp.new("(?<word>é)(?<tail>y)?")
    match_data = regexp.match(subject)
    subject.replace("changed")
    GC.start
    GC.compact

    values = match_data.values_at(1, 2, 0)
    assert_equal %w[é y éy], values
    assert_equal [Encoding::UTF_8] * 3, values.map(&:encoding)
    refute values.any?(&:frozen?)
    diagnostics = regexp.send(:__onibi_diagnostics__, "xxéyzz")
    assert_equal true, diagnostics[:rseq]
    assert_equal 0, diagnostics[:fallback]
  end

  def test_values_at_reacquires_snapshot_after_reentrant_conversion_and_compaction
    events = []
    regexp = Onibi::Regexp.new("\\A(?<word>a)(?<empty>)(?<optional>b)?\\z")
    match_data = regexp.match("a")
    selector = CompactingSelector.new(match_data, events)

    assert_equal ["a", "a", ""], match_data.values_at(0, selector, 2)
    assert_equal ["to_int"], events
    diagnostics = regexp.send(:__onibi_diagnostics__, "a")
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

  def build_arguments(specs, events)
    shared = {}
    specs.each_with_index.map do |spec, index|
      build_argument(spec, events, shared, index)
    end
  end

  def build_argument(spec, events, shared, index)
    return spec unless spec.is_a?(Hash)

    return Integer(spec.fetch(:integer), 10) if spec.key?(:integer)
    return Float(spec.fetch(:float)) if spec.key?(:float)
    return spec.fetch(:symbol).to_sym if spec.key?(:symbol)

    if spec.key?(:range)
      descriptor = spec.fetch(:range)
      first = if descriptor[:begin].nil?
                nil
              else
                build_argument(descriptor[:begin], events, shared, index)
              end
      last = if descriptor[:end].nil?
               nil
             else
               build_argument(descriptor[:end], events, shared, index)
             end
      return Range.new(first, last, descriptor.fetch(:exclude_end, false))
    end

    if spec.key?(:range_subclass)
      descriptor = spec.fetch(:range_subclass)
      return RangeWithRaisingAccessors.new(
        descriptor.fetch(:begin), descriptor.fetch(:end),
        descriptor.fetch(:exclude_end, false)
      )
    end

    if spec.key?(:to_int)
      value = spec.fetch(:to_int)
      return LegacySelector.new(
        events: events,
        descriptor: { label: value.fetch(:event), modes: ["to_int"],
                      integer: value.fetch(:value) }
      )
    end

    if spec.key?(:to_str)
      value = spec.fetch(:to_str)
      return LegacySelector.new(
        events: events,
        descriptor: { label: value.fetch(:event), modes: ["to_str"],
                      string: value.fetch(:value) }
      )
    end

    if spec.key?(:bad_to_int)
      return LegacySelector.new(
        events: events,
        descriptor: { label: "bad-to-int", modes: ["to_int"],
                      bad_value: spec.fetch(:bad_to_int), has_bad_value: true }
      )
    end

    if spec.key?(:raise_to_int)
      value = spec.fetch(:raise_to_int)
      return LegacySelector.new(
        events: events,
        descriptor: {
          label: value.fetch(:event), modes: ["to_int"],
          error: Object.const_get(value.fetch(:class)).new(value.fetch(:message))
        }
      )
    end

    if spec.key?(:to_i_only)
      return LegacySelector.new(
        events: events,
        descriptor: { label: "to-i-only", modes: [], integer: spec.fetch(:to_i_only) }
      )
    end

    return PlainSelector.new(spec.fetch(:plain_object)) if spec.key?(:plain_object)

    if spec.key?(:shared_to_int)
      label = spec.fetch(:shared_to_int)
      return shared.fetch(label) if shared.key?(label)

      shared[label] = LegacySelector.new(
        events: events,
        descriptor: { label: label, modes: ["to_int"], integer: 1 }
      )
      return shared.fetch(label)
    end

    if spec.key?(:kind)
      kind = spec.fetch(:kind)
      return shared.fetch(spec.fetch(:shared)) if spec.key?(:shared) && shared.key?(spec.fetch(:shared))

      selector_class = EXACT_SELECTOR_CLASSES.fetch(kind)
      selector = selector_class.new(
        events: events,
        kind: kind,
        definition: CORRECTED_DEFINITIONS.fetch(kind),
        label: "#{kind}@#{index}"
      )
      shared[spec.fetch(:shared)] = selector if spec.key?(:shared)
      return selector
    end

    raise ArgumentError, "unknown frozen selector descriptor"
  end

  def observe
    ["value", value_shape(yield)]
  rescue StandardError => e
    message = e.message
    ["error", e.class.name, message,
     message.encoding.name, message.b.bytes]
  end

  def value_shape(value)
    case value
    when String
      ["String", value.b.bytes, value.encoding.name, value.frozen?]
    when Array
      value.map { |item| value_shape(item) }
    when Symbol
      ["Symbol", value.to_s]
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
        result[key.to_s] = evidence_shape(item)
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
    path = ENV["ONIBI_API03_RESULTS_PATH"]
    return unless path

    source_files = %w[
      ext/onibi/match_data.c
      ext/onibi/onibi_init.c
      ext/onibi/onibi_matchdata_internal.h
      test/features/captures/match_data_values_at_test.rb
    ]
    source_hashes = source_files.to_h do |relative|
      [relative, Digest::SHA256.file(File.join(PROJECT_ROOT, relative)).hexdigest]
    end
    extension = $LOADED_FEATURES.find do |feature|
      feature.end_with?(".#{RbConfig::CONFIG["DLEXT"]}") && feature.include?("onibi")
    end
    artifact = {
      "runtime" => RUBY_DESCRIPTION,
      "argv" => [RbConfig.ruby, $PROGRAM_NAME, *ARGV],
      "source_hashes" => source_hashes,
      "extension_path" => extension,
      "extension_sha256" => (Digest::SHA256.file(extension).hexdigest if extension && File.file?(extension)),
      "results" => rows.map do |row|
        row.merge(
          "native_diagnostics" => evidence_shape(row.fetch("native_diagnostics")),
          "raw_matchdata" => evidence_shape(row.fetch("raw_matchdata"))
        )
      end
    }
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(artifact)}\n")
  end
end
