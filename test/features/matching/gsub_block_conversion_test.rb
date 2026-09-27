# frozen_string_literal: true

require "test_helper"

class GsubBlockConversionTest < Minitest::Test
  class OnlyToS
    def to_s
      "only-to-s"
    end
  end

  class BothConversions
    def to_s
      "to-s"
    end

    def to_str
      raise "to_str must not be called"
    end
  end

  class StringSubclass < String
    def to_s
      "overridden-to-s"
    end
  end

  class NonStringToS
    def to_s
      17
    end
  end

  class RaisingToS
    def initialize(message)
      @message = message
    end

    def to_s
      raise @message
    end
  end

  class OrderedToS
    def initialize(subject, events, action)
      @subject = subject
      @events = events
      @action = action
    end

    def to_s
      @events << :to_s_enter
      case @action
      when :mutate
        @subject << "x"
        @events << :mutate
      when :mutate_then_raise
        @subject << "x"
        @events << :mutate
        raise "to_s failed"
      when :raise
        raise "to_s failed"
      end
      @events << :to_s_exit
      "T"
    end
  end

  def test_native_block_results_follow_mri_to_s_conversion
    false_label = "false"
    values = {
      nil: nil,
      integer: 17,
      false_label => false,
      only_to_s: OnlyToS.new,
      both_conversions: BothConversions.new,
      string_subclass: StringSubclass.new("subclass"),
      non_string_to_s: NonStringToS.new
    }

    values.each do |label, value|
      expected = observe(:mri, "a", value)
      actual = observe(:onibi, "a", value)
      assert_equal expected, actual, label
    end
  end

  def test_conversion_exceptions_match_mri_for_native_and_fallback
    value = RaisingToS.new("to_s failed")

    expected_native = observe(:mri, "a", value)
    actual_native = observe(:onibi, "a", value)
    assert_equal expected_native, actual_native

    expected_fallback = observe(:mri, "\\X", value, source: "é")
    actual_fallback = observe(:onibi, "\\X", value, source: "é")
    assert_equal expected_fallback, actual_fallback
  end

  def test_native_and_fallback_diagnostics_remain_explicit
    native = Onibi::Regexp.new("a").send(:__onibi_diagnostics__, "a")
    assert native.fetch(:rseq)
    assert_equal 0, native.fetch(:fallback)
    assert_equal :none, native.fetch(:fallback_reason)

    fallback = Onibi::Regexp.new("\\X").send(:__onibi_diagnostics__, "é")
    refute fallback.fetch(:rseq)
    assert_equal 1, fallback.fetch(:fallback)
    assert_equal :grapheme, fallback.fetch(:fallback_reason)
  end

  def test_returned_bytes_and_encoding_match_mri_for_native_results
    cases = [
      ["UTF-8", "a".encode(Encoding::UTF_8), "é".encode(Encoding::UTF_8)],
      ["ASCII-8BIT", "a".b, "\xFF".b]
    ]

    cases.each do |label, source, returned|
      value = Class.new do
        define_method(:to_s) { returned }
      end.new
      expected = observe(:mri, "a", value, source: source)
      actual = observe(:onibi, "a", value, source: source)
      assert_equal expected.fetch(:result_bytes), actual.fetch(:result_bytes), label
      assert_equal expected.fetch(:result_encoding), actual.fetch(:result_encoding), label
    end
  end

  def test_conversion_callbacks_run_before_length_check
    cases = [
      ["block mutation then conversion raise", ->(subject) { subject << "x" }, :raise],
      ["block mutation then conversion return", ->(subject) { subject << "x" }, :return],
      ["conversion mutation then return", nil, :mutate],
      ["conversion mutation then raise", nil, :mutate_then_raise]
    ]

    cases.each do |label, block_mutation, conversion_action|
      expected = observe_order(:mri, block_mutation, conversion_action)
      actual = observe_order(:onibi, block_mutation, conversion_action)
      assert_equal expected, actual, label
    end
  end

  private

  def observe(engine, pattern, value, source: "a")
    input = source.dup
    result = if engine == :mri
               input.gsub(::Regexp.new(pattern)) { value }
             else
               Onibi::Regexp.new(pattern).gsub(input) { value }
             end
    {
      status: "ok",
      result: result,
      result_bytes: result.bytes,
      result_encoding: result.encoding.name
    }
  # This probe records every exception class for MRI differential checks.
  rescue Exception => e # rubocop:disable Lint/RescueException
    {
      status: "error",
      error_class: e.class.name,
      message: e.message
    }
  end

  def observe_order(engine, block_mutation, conversion_action)
    input = +"a"
    events = []
    value = OrderedToS.new(input, events, conversion_action)
    operation = proc do
      events << :block
      block_mutation&.call(input)
      value
    end
    result = if engine == :mri
               input.gsub(/a/, &operation)
             else
               Onibi::Regexp.new("a").gsub(input, &operation)
             end
    {
      status: "ok",
      result: result,
      input: input,
      events: events
    }
  # This probe records every exception class for MRI differential checks.
  rescue Exception => e # rubocop:disable Lint/RescueException
    {
      status: "error",
      error_class: e.class.name,
      message: e.message,
      input: input,
      events: events
    }
  end
end
