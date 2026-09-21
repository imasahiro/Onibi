# frozen_string_literal: true

require "test_helper"

class GsubMutationTest < Minitest::Test
  class ToSMutation
    def initialize(subject, mode)
      @subject = subject
      @mode = mode
    end

    def to_s
      case @mode
      when :append
        @subject << "x"
      when :clear
        @subject.clear
      when :replace_diff
        @subject.replace("zz")
      when :replace_same
        @subject.replace("z")
      when :setbyte
        @subject.setbyte(0, "z".ord)
      when :encoding
        @subject.force_encoding(Encoding::BINARY)
      end
      "T"
    end

    def to_str
      raise "to_str must not be called"
    end
  end

  def test_length_mutations_match_mri_before_native_range_reuse
    {
      append: ->(subject) { subject << "x" },
      clear: lambda(&:clear),
      replace_diff: ->(subject) { subject.replace("z") }
    }.each do |mutation, operation|
      ["a", ""].each do |pattern|
        expected = observe(:mri, pattern, "aa", &operation)
        actual = observe(:onibi, pattern, "aa", &operation)
        assert_equal expected, actual, "#{mutation} pattern=#{pattern.inspect}"
      end
    end
  end

  def test_same_length_byte_and_buffer_mutations_match_mri
    {
      setbyte: ->(subject) { subject.setbyte(0, "z".ord) },
      replace_same: ->(subject) { subject.replace("zz") }
    }.each do |mutation, operation|
      ["a", ""].each do |pattern|
        expected = observe(:mri, pattern, "aa", &operation)
        actual = observe(:onibi, pattern, "aa", &operation)
        assert_equal expected, actual, "#{mutation} pattern=#{pattern.inspect}"
      end
    end
  end

  def test_same_length_encoding_change_matches_mri
    expected = observe(:mri, "a", "aa") do |subject, _value|
      subject.force_encoding(Encoding::BINARY)
    end
    actual = observe(:onibi, "a", "aa") do |subject, _value|
      subject.force_encoding(Encoding::BINARY)
    end
    assert_equal expected, actual
  end

  def test_multibyte_encoding_change_keeps_mri_error_behavior
    expected = observe(:mri, "é", "éé") do |subject, _value|
      subject.force_encoding(Encoding::BINARY)
    end
    actual = observe(:onibi, "é", "éé") do |subject, _value|
      subject.force_encoding(Encoding::BINARY)
    end
    assert_equal expected, actual
  end

  def test_frozen_subjects_keep_mri_mutation_errors
    regexp = Onibi::Regexp.new("a")
    input = "aa".freeze # rubocop:disable Style/RedundantFreeze
    assert_equal "XX", regexp.gsub(input) { "X" }
    assert_predicate input, :frozen?

    error = assert_raises(FrozenError) do
      regexp.gsub(input) do
        input << "x"
        "X"
      end
    end
    assert_equal "can't modify frozen String: \"aa\"", error.message
  end

  def test_block_result_to_s_mutations_are_checked_before_range_reuse
    {
      append: "string modified",
      clear: "string modified",
      replace_diff: "string modified"
    }.each do |mutation, message|
      input = +"a"
      error = assert_raises(RuntimeError) do
        Onibi::Regexp.new("a").gsub(input) do
          ToSMutation.new(input, mutation)
        end
      end
      assert_equal message, error.message, mutation
    end
  end

  def test_block_mutation_is_checked_after_result_conversion
    input = +"a"
    error = assert_raises(RuntimeError) do
      Onibi::Regexp.new("a").gsub(input) do
        input << "x"
        nil
      end
    end
    assert_equal "string modified", error.message
  end

  def test_same_length_to_s_mutations_remain_supported
    {
      replace_same: %w[T z UTF-8],
      setbyte: %w[T z UTF-8],
      encoding: %w[T a ASCII-8BIT]
    }.each do |mutation, expected|
      input = +"a"
      result = Onibi::Regexp.new("a").gsub(input) do
        ToSMutation.new(input, mutation)
      end
      assert_equal expected[0], result, mutation
      assert_equal expected[1], input, mutation
      assert_equal expected[2], input.encoding.name, mutation
    end
  end

  private

  def observe(engine, pattern, source)
    input = source.dup
    result = if engine == :mri
               input.gsub(::Regexp.new(pattern)) { |value| yield(input, value) }
             else
               Onibi::Regexp.new(pattern).gsub(input) { |value| yield(input, value) }
             end
    {
      status: "ok",
      result: result,
      result_encoding: result.encoding.name,
      source: input.bytes,
      source_encoding: input.encoding.name
    }
  rescue Exception => e # rubocop:disable Lint/RescueException
    {
      status: "error",
      error_class: e.class.name,
      message: e.message,
      source: input.bytes,
      source_encoding: input.encoding.name
    }
  end
end
