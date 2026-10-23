# frozen_string_literal: true

require "test_helper"

class OneDigitHexTest < Minitest::Test
  MATCH_CASES = [
    ["one-digit-at-end", "\\x4", [0x04], "UTF-8"],
    ["one-digit-before-literal", "\\x4Z", [0x04, 0x5A], "UTF-8"],
    ["one-letter-hex-digit", "\\xAZ", [0x0A, 0x5A], "UTF-8"],
    ["lowercase-one-hex-digit", "\\xaZ", [0x0A, 0x5A], "UTF-8"],
    ["one-digit-f-hex", "\\xFZ", [0x0F, 0x5A], "UTF-8"],
    ["one-digit-miss", "\\x4Z", [0x05, 0x5A], "UTF-8"],
    ["one-digit-before-nonhex", "\\x4G", [0x04, 0x47], "UTF-8"],
    ["one-digit-before-underscore", "\\x4_", [0x04, 0x5F], "UTF-8"],
    ["greedy-two-hex-digits", "\\x4A", [0x4A], "UTF-8"],
    ["greedy-two-digits-before-literal", "\\x4AZ", [0x4A, 0x5A], "UTF-8"],
    ["greedy-two-digits-do-not-split", "\\x4AZ", [0x04, 0x41, 0x5A], "UTF-8"],
    ["third-hex-character-is-literal", "\\x41F", [0x41, 0x46], "UTF-8"],
    ["two-digit-at-end", "\\x41", [0x41], "UTF-8"],
    ["one-digit-A-at-end", "\\xA", [0x0A], "UTF-8"],
    ["one-digit-quantifier", "\\x4+", [0x04, 0x04, 0x04], "UTF-8"],
    ["one-digit-quantifier-suffix", "\\x4+Z", [0x04, 0x04, 0x5A], "UTF-8"],
    ["two-digit-quantifier", "\\x41+Z", [0x41, 0x41, 0x5A], "UTF-8"],
    ["one-digit-before-escaped-dot", "\\x4\\.", [0x04, 0x2E], "UTF-8"],
    ["one-digit-before-open-group", "\\x4(Z)", [0x04, 0x5A], "UTF-8"],
    ["one-digit-before-close-group", "(\\x4)Z", [0x04, 0x5A], "UTF-8"],
    ["one-digit-class-at-end", "[\\x4]", [0x04], "UTF-8"],
    ["one-digit-class-before-literal", "[\\xa]Z", [0x0A, 0x5A], "UTF-8"],
    ["two-digit-class-before-literal", "[\\x41]Z", [0x41, 0x5A], "UTF-8"],
    ["negated-one-digit-class", "[^\\x4]Z", [0x41, 0x5A], "UTF-8"],
    ["binary-one-digit", "\\x4Z", [0x04, 0x5A], "ASCII-8BIT"],
    ["windows31j-one-digit", "\\x4Z", [0x04, 0x5A], "Windows-31J"],
    ["eucjp-one-digit", "\\xaZ", [0x0A, 0x5A], "EUC-JP"]
  ].freeze

  INVALID_CASES = [
    ["empty escape", "\\x", "UTF-8"],
    ["non-hex first digit", "\\xG", "UTF-8"],
    ["empty escape in class", "[\\x]", "UTF-8"]
  ].freeze

  def test_one_digit_and_greedy_two_digit_hex_match_mri_on_native_rseq
    MATCH_CASES.each do |label, pattern_source, subject_bytes, encoding_name|
      encoding = Encoding.find(encoding_name)
      pattern = pattern_source.b.force_encoding(encoding)
      subject = subject_bytes.pack("C*").force_encoding(encoding)

      expected = ::Regexp.new(pattern).match(subject)
      regexp = Onibi::Regexp.new(pattern)
      diagnostics = regexp.send(:__onibi_diagnostics__, subject)

      assert diagnostics[:rseq], label
      assert_equal 0, diagnostics[:fallback], label
      assert_equal(expected ? 1 : 0, diagnostics[:status], label)
      assert_equal raw_registers(expected), diagnostics[:raw_registers], label if expected
    end
  end

  def test_malformed_hex_escapes_keep_mri_errors
    INVALID_CASES.each do |label, pattern_source, encoding_name|
      pattern = pattern_source.b.force_encoding(Encoding.find(encoding_name))

      mri_error = assert_raises(::RegexpError, label) do
        ::Regexp.new(pattern)
      end
      onibi_error = assert_raises(::RegexpError, label) do
        Onibi::Regexp.new(pattern)
      end

      assert_equal "RegexpError", mri_error.class.name, label
      assert_equal "Onibi::RegexpError", onibi_error.class.name, label
      assert_equal mri_error.message, onibi_error.message, label
    end
  end

  private

  def raw_registers(match)
    (0...match.length).map do |index|
      first = match.bytebegin(index)
      last = match.byteend(index)
      first && last ? [first, last] : [-1, -1]
    end
  end
end
