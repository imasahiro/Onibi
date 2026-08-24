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

  def test_non_ascii_compatible_pattern_rejects_other_input_encodings
    pattern = "a".encode(Encoding::UTF_16LE)
    [Encoding::UTF_8, Encoding::ASCII_8BIT].each do |encoding|
      input = "a".encode(encoding)
      assert_raises(Encoding::CompatibilityError) { Onibi::Regexp.new(pattern).match?(input) }
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

  def test_unicode_full_casefold_matches_mri_for_literals
    [["ß", "SS"], ["ſ", "S"], ["[ß]", "SS"], ["(?i:ss)", "ß"]].each do |pattern, input|
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
