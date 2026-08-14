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

  def test_unicode_literal_full_casefold_uses_hfa_for_ascii_input
    regexp = Onibi::Regexp.new("ſ", "i")

    regexp.stub(:codegen_match, ->(*) { flunk "Unicode full case-fold should use HFA" }) do
      assert_equal "S", regexp.match("S").to_s
    end

    regexp.stub(:codegen_match?, ->(*) { flunk "Unicode full case-fold match? should use HFA" }) do
      assert regexp.match?("S")
    end
  end
end
