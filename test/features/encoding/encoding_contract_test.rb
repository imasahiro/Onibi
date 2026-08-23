# frozen_string_literal: true

require "test_helper"
require "yaml"

class EncodingContractTest < Minitest::Test
  MATRIX = :encoding
  REQUIRED_ENCODINGS = %w[ASCII-8BIT EUC-JP US-ASCII UTF-8 Windows-31J].freeze

  def test_matrix_covers_ascii_compatible_pairs_including_us_ascii
    matrix = TestFixtures.load(MATRIX)
    ascii_pairs = matrix.fetch("cases").select do |fixture|
      fixture.fetch("pattern") == "a" && fixture.fetch("input") == "a"
    end

    assert_equal REQUIRED_ENCODINGS.sort, matrix.fetch("encodings").sort
    assert_equal REQUIRED_ENCODINGS.length**2, ascii_pairs.length
  end

  def test_unicode_full_casefold_matches_mri_for_literals
    [["ß", "SS"], ["ſ", "S"], ["[ß]", "SS"]].each do |pattern, input|
      expected = ::Regexp.new(pattern, ::Regexp::IGNORECASE).match(input)&.to_a
      actual = Onibi::Regexp.new(pattern, ::Regexp::IGNORECASE).match(input)&.to_a

      assert_equal expected, actual, "#{pattern.inspect} against #{input.inspect}"
    end
  end

  def test_unicode_literal_full_casefold_runs_in_the_vm_for_ascii_input
    regexp = Onibi::Regexp.new("ſ", "i")

    assert_equal "S", regexp.match("S").to_s

    assert regexp.match?("S")
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
end
