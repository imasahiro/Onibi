# frozen_string_literal: true

require "test_helper"

class GsubPrecedenceTest < Minitest::Test
  class ReplacementToStr
    attr_reader :events

    def initialize(events)
      @events = events
    end

    def to_str
      @events << :to_str
      "R"
    end

    def to_s
      @events << :to_s
      "wrong"
    end
  end

  def test_explicit_string_replacement_suppresses_a_side_effecting_block
    cases = [
      ["a", "aba", "RbR"],
      ["z", "aba", "aba"],
      ["", "ab", "RaRbR"],
      ["[éあ]", "xéあy", "xRRy"]
    ]

    cases.each do |pattern, source, expected|
      yielded = []
      actual = Onibi::Regexp.new(pattern).gsub(source, "R") do |value|
        yielded << value
        raise "replacement block must not run"
      end

      assert_equal expected, actual, pattern
      assert_empty yielded, pattern
    end
  end

  def test_explicit_replacement_expands_captures_without_mri_rematch
    original_gsub = String.instance_method(:gsub)
    String.define_method(:gsub) do |*|
      raise "native replacement must not rematch through String#gsub"
    end

    yielded = []
    actual = Onibi::Regexp.new("([ab])-([ab])").gsub("a-b", '\\2-\\1') do |value|
      yielded << value
      raise "replacement block must not run"
    end

    assert_equal "b-a", actual
    assert_empty yielded
  ensure
    String.define_method(:gsub, original_gsub) if original_gsub
  end

  def test_explicit_fallback_replacement_suppresses_the_block
    source = "éあ"
    yielded = []
    actual = Onibi::Regexp.new("\\X").gsub(source, "R") do |value|
      yielded << value
      raise "fallback replacement block must not run"
    end

    expected = source.gsub(/\X/, "R")
    assert_equal expected, actual
    assert_empty yielded

    diagnostics = Onibi::Regexp.new("\\X").send(:__onibi_diagnostics__, source)
    refute diagnostics.fetch(:rseq)
    assert_equal 1, diagnostics.fetch(:fallback)
    assert_equal :grapheme, diagnostics.fetch(:fallback_reason)
  end

  def test_native_and_fallback_execution_classes_remain_explicit
    [["a", "aba"], ["z", "aba"], ["", "aba"],
     ["[éあ]", "xéあy"]].each do |pattern, source|
      diagnostics = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, source)
      assert diagnostics.fetch(:rseq), pattern
      assert_equal 0, diagnostics.fetch(:fallback), pattern
      assert_equal :none, diagnostics.fetch(:fallback_reason), pattern
    end

    diagnostics = Onibi::Regexp.new("\\X").send(:__onibi_diagnostics__, "éあ")
    refute diagnostics.fetch(:rseq)
    assert_equal 1, diagnostics.fetch(:fallback)
    assert_equal :grapheme, diagnostics.fetch(:fallback_reason)
  end

  def test_explicit_replacement_coercion_runs_and_does_not_yield
    coercion_events = []
    yielded = []
    replacement = ReplacementToStr.new(coercion_events)
    actual = Onibi::Regexp.new("a").gsub("aba", replacement) do |value|
      yielded << value
      raise "coercion block must not run"
    end

    assert_equal "RbR", actual
    assert_equal [:to_str], coercion_events
    assert_empty yielded
  end

  def test_explicit_invalid_replacements_keep_mri_errors_and_block_suppression
    [nil, Object.new].each do |replacement|
      expected = observe_error(:mri, "a", "a", replacement)
      actual = observe_error(:onibi, "a", "a", replacement)
      assert_equal expected, actual, replacement.inspect
    end
  end

  def test_omitted_replacement_still_uses_block_conversion
    value = Object.new
    value.define_singleton_method(:to_s) { "T" }
    expected = "a".gsub(/a/) { value }
    actual = Onibi::Regexp.new("a").gsub("a") { value }

    assert_equal expected, actual
  end

  private

  def observe_error(engine, pattern, source, replacement)
    yielded = []
    regexp = engine == :mri ? ::Regexp.new(pattern) : Onibi::Regexp.new(pattern)
    result = if engine == :mri
               source.gsub(regexp, replacement) do
                 yielded << :yield
                 "X"
               end
             else
               regexp.gsub(source, replacement) do
                 yielded << :yield
                 "X"
               end
             end
    { status: :ok, result: result, yielded: yielded }
  rescue Exception => e # rubocop:disable Lint/RescueException
    { status: :error, error_class: e.class.name, message: e.message,
      yielded: yielded }
  end
end
