# frozen_string_literal: true

require "test_helper"

class EscapeCursorTest < Minitest::Test
  CURSOR_CASES = [
    ["hex-two-literal-match", "\\x41Z", "AZ", "UTF-8"],
    ["hex-two-literal-miss", "\\x41Z", "A", "UTF-8"],
    ["hex-two-before-brace", "\\x32}", "2}", "UTF-8"],
    ["hex-two-before-open-group", "\\x41(X)", "AX", "UTF-8"],
    ["hex-two-before-close-group", "(\\x41)Z", "AZ", "UTF-8"],
    ["hex-two-inside-capture", "(\\x41Z)", "AZ", "UTF-8"],
    ["hex-two-before-plus", "\\x41+", "AAA", "UTF-8"],
    ["hex-two-before-escaped-dot-wrong", "\\x41\\.", "AB", "UTF-8"],
    ["hex-two-before-newline-escape", "\\x41\\n", "A\n", "UTF-8"],
    ["hex-two-before-newline-escape-wrong", "\\x41\\n", "An", "UTF-8"],
    ["hex-run-before-literal", "\\x41\\x42Z", "ABZ", "UTF-8"],
    ["hex-run-before-literal-miss", "\\x41\\x42Z", "AB", "UTF-8"],
    ["three-hex-run-before-literal", "\\x41\\x42\\x43Z", "ABCZ", "UTF-8"],
    ["control-before-literal", "\\cAZ", "\x01Z", "UTF-8"],
    ["control-before-plus", "\\cA+", "\x01\x01\x01", "UTF-8"],
    ["octal-before-literal", "\\101Z", "AZ", "UTF-8"],
    ["octal-before-plus", "\\101+", "AAA", "UTF-8"],
    ["zero-octal-before-literal", "\\07Z", "\x07Z", "UTF-8"],
    ["octal-run-before-literal", "\\101\\102Z", "ABZ", "UTF-8"],
    [
      "multi-digit-backref-before-literal",
      "(A)(B)(C)(D)(E)(F)(G)(H)(I)(J)\\10Z",
      "ABCDEFGHIJJZ",
      "UTF-8"
    ],
    ["utf8-hex-run-before-literal", "\\xC3\\xA9Z", "\xC3\xA9Z", "UTF-8"],
    ["utf8-hex-run-before-literal-miss", "\\xC3\\xA9Z", "\xC3\xA9", "UTF-8"],
    [
      "windows31j-hex-run-before-literal",
      "\\x82\\xA0Z",
      "\x82\xA0Z",
      "Windows-31J"
    ],
    ["eucjp-hex-run-before-literal", "\\xA4\\xA2Z", "\xA4\xA2Z", "EUC-JP"],
    ["hex-two-before-plus-short", "\\x41+", "A", "UTF-8"],
    ["hex-two-before-escaped-dot", "\\x41\\.", "A.", "UTF-8"],
    ["hex-two-at-end", "\\x41", "A", "UTF-8"],
    ["hex-two-at-end-wrong", "\\x41", "B", "UTF-8"],
    ["hex-run-at-end", "\\x41\\x42", "AB", "UTF-8"],
    ["control-at-end", "\\cA", "\x01", "UTF-8"],
    ["control-hyphen-before-literal", "\\C-AZ", "\x01Z", "UTF-8"],
    ["simple-escape-before-literal", "\\nZ", "\nZ", "UTF-8"],
    ["octal-at-end", "\\101", "A", "UTF-8"],
    ["octal-run-at-end", "\\101\\102", "AB", "UTF-8"],
    ["one-digit-backref-control", "(A)\\1Z", "AAZ", "UTF-8"],
    ["property-before-literal", "\\p{Alpha}Z", "AZ", "UTF-8"],
    ["utf8-hex-run-at-end", "\\xC3\\xA9", "\xC3\xA9", "UTF-8"],
    ["windows31j-hex-run-at-end", "\\x82\\xA0", "\x82\xA0", "Windows-31J"],
    ["eucjp-hex-run-at-end", "\\xA4\\xA2", "\xA4\xA2", "EUC-JP"],
    [
      "extended-space-is-ignored",
      "\\A\\x41\\x42 Z\\z",
      "ABZ",
      "UTF-8",
      ::Regexp::EXTENDED
    ]
  ].freeze

  def test_escape_cursor_matrix_matches_mri_on_native_rseq
    CURSOR_CASES.each do |label, pattern_source, subject_source, encoding_name, options|
      encoding = Encoding.find(encoding_name)
      pattern = pattern_source.dup.force_encoding(encoding)
      subject = subject_source.dup.force_encoding(encoding)
      options ||= 0

      expected = ::Regexp.new(pattern, options).match(subject)
      regexp = Onibi::Regexp.new(pattern, options)
      diagnostics = regexp.send(:__onibi_diagnostics__, subject)

      assert diagnostics[:rseq], label
      assert_equal 0, diagnostics[:fallback], label
      assert_equal(expected ? 1 : 0, diagnostics[:status], label)
      assert_equal raw_registers(expected), diagnostics[:raw_registers], label if expected
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
