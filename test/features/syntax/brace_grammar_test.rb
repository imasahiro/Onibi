# frozen_string_literal: true

require "test_helper"

class BraceGrammarTest < Minitest::Test
  CASES = [
    { id: "open", pattern: "a{", subject: "a{", options: 0, expect_error: false },
    { id: "open-no-match", pattern: "a{", subject: "a", options: 0, expect_error: false },
    { id: "open-count", pattern: "a{2", subject: "a{2", options: 0, expect_error: false },
    { id: "open-comma", pattern: "a{2,", subject: "a{2,", options: 0, expect_error: false },
    { id: "open-with-active-plus", pattern: "a{b+", subject: "a{bbb", options: 0, expect_error: false },
    { id: "open-before-alternation", pattern: "a{|b", subject: "a{", options: 0, expect_error: false },
    { id: "unmatched-close", pattern: "}", subject: "}", options: 0, expect_error: false },
    { id: "leading-open", pattern: "{", subject: "{", options: 0, expect_error: false },
    { id: "leading-numeric-braces", pattern: "{2}", subject: "{2}", options: 0, expect_error: true },
    { id: "double-close", pattern: "a}}", subject: "a}}", options: 0, expect_error: false },
    { id: "empty-body", pattern: "a{}", subject: "a{}", options: 0, expect_error: false },
    { id: "empty-bounds", pattern: "a{,}", subject: "a{,}", options: 0, expect_error: false },
    { id: "empty-lower-bad-upper", pattern: "a{,x}", subject: "a{,x}", options: 0, expect_error: false },
    { id: "nonnumeric-body", pattern: "a{x}", subject: "a{x}", options: 0, expect_error: false },
    { id: "nonnumeric-upper", pattern: "a{2,x}", subject: "a{2,x}", options: 0, expect_error: false },
    { id: "active-plus-in-invalid-body", pattern: "a{b+}", subject: "a{bbb}", options: 0, expect_error: false },
    { id: "plus-spelling-not-literal", pattern: "a{b+}", subject: "a{b+}", options: 0, expect_error: false },
    { id: "active-star-in-invalid-body", pattern: "a{b*}", subject: "a{bbb}", options: 0, expect_error: false },
    { id: "active-capture-in-invalid-body", pattern: "a{(b+)}", subject: "a{bbb}", options: 0, expect_error: false },
    { id: "active-capture-miss", pattern: "a{(b+)}", subject: "a{b+}", options: 0, expect_error: false },
    { id: "open-invalid-body", pattern: "a{b+", subject: "a{bbb", options: 0, expect_error: false },
    { id: "valid-lower-open", pattern: "a{,2}", subject: "aa", options: 0, expect_error: false },
    { id: "valid-lower-open-empty", pattern: "a{,2}", subject: "", options: 0, expect_error: false },
    { id: "valid-lower-open-no-match", pattern: "a{,2}", subject: "aaa", options: 0, expect_error: false },
    { id: "valid-upper-open", pattern: "a{2,}", subject: "aaa", options: 0, expect_error: false },
    { id: "valid-upper-open-no-match", pattern: "a{2,}", subject: "a", options: 0, expect_error: false },
    { id: "valid-exact", pattern: "a{2}", subject: "aa", options: 0, expect_error: false },
    { id: "valid-exact-no-match", pattern: "a{2}", subject: "a", options: 0, expect_error: false },
    { id: "invalid-descending-range", pattern: "a{2,1}", subject: "aa", options: 0, expect_error: true },
    { id: "fixed-optional-suffix", pattern: "a{2}?", subject: "", options: 0, expect_error: false },
    { id: "lazy-equal-range-suffix", pattern: "a{2,2}?", subject: "aa", options: 0, expect_error: false },
    { id: "repeat-limit-100000", pattern: "a{100000}", subject: "a", options: 0, expect_error: false },
    { id: "repeat-limit-100001", pattern: "a{100001}", subject: "a", options: 0, expect_error: true },
    { id: "repeat-count-overflow", pattern: "a{999999999999999999999999999999999}", subject: "a", options: 0, expect_error: true },
    { id: "nested-open", pattern: "a{{", subject: "a{{", options: 0, expect_error: false },
    { id: "nested-interval", pattern: "a{{2}}", subject: "a{{{", options: 0, expect_error: false },
    { id: "repeat-then-close", pattern: "a{2}}", subject: "aa}", options: 0, expect_error: false },
    { id: "repeat-then-open", pattern: "a{2}{", subject: "aa{", options: 0, expect_error: false },
    { id: "escaped-open", pattern: "a\\{", subject: "a{", options: 0, expect_error: false },
    { id: "escaped-close", pattern: "a\\}", subject: "a}", options: 0, expect_error: false },
    { id: "escaped-pair", pattern: "a\\{2\\}", subject: "a{2}", options: 0, expect_error: false },
    { id: "class-open-brace", pattern: "[{}]", subject: "{", options: 0, expect_error: false },
    { id: "class-close-brace", pattern: "[{}]", subject: "}", options: 0, expect_error: false },
    { id: "class-brace-repeat", pattern: "[{}]+", subject: "{{", options: 0, expect_error: false },
    { id: "alternation-open-side", pattern: "a{|b}", subject: "a{", options: 0, expect_error: false },
    { id: "alternation-close-side", pattern: "a{|b}", subject: "b}", options: 0, expect_error: false },
    { id: "alternation-miss", pattern: "a{|b}", subject: "b{", options: 0, expect_error: false },
    { id: "quantifier-after-literal-close", pattern: "a{b+}?", subject: "a{bbb}", options: 0, expect_error: false },
    { id: "quantifier-can-drop-literal-close", pattern: "a{b+}?", subject: "a{bbb", options: 0, expect_error: false },
    { id: "quantifier-after-invalid-close", pattern: "a{2,x}+", subject: "a{2,x}}", options: 0, expect_error: false },
    { id: "bare-N-open", pattern: "\\N{", subject: "N{", options: 0, expect_error: false },
    { id: "bare-N-open-no-match", pattern: "\\N{", subject: "Nfoo{", options: 0, expect_error: false },
    { id: "bare-N-uplus-spelling", pattern: "\\N{U+0061}", subject: "N{U+0061}", options: 0, expect_error: false },
    { id: "bare-N-uplus-active-plus", pattern: "\\N{U+0061}", subject: "N{UU0061}", options: 0, expect_error: false },
    { id: "bare-N-name-spelling", pattern: "\\N{LATIN SMALL LETTER A}", subject: "N{LATIN SMALL LETTER A}", options: 0, expect_error: false },
    { id: "bare-N-escaped-open", pattern: "\\N\\{", subject: "N{", options: 0, expect_error: false },
    { id: "utf8-open", pattern: "é{", subject: "é{", options: 0, expect_error: false },
    { id: "utf8-open-no-match", pattern: "é{", subject: "é", options: 0, expect_error: false },
    { id: "utf8-valid-repeat", pattern: "é{2}", subject: "éé", options: 0, expect_error: false },
    { id: "utf8-nonnumeric-active-plus", pattern: "é{é+}", subject: "é{éé}", options: 0, expect_error: false },
    { id: "utf8-byte-capture", pattern: "é{(b+)}", subject: "é{bbb}", options: 0, expect_error: false },
    { id: "extended-valid-spaces", pattern: "(?x)a{ 2 }", subject: "aa", options: ::Regexp::EXTENDED, expect_error: false },
    { id: "extended-invalid-active-plus", pattern: "(?x)a{ b+ }", subject: "a{bbb}", options: 0, expect_error: false },
    { id: "extended-valid-comment", pattern: "(?x)a{2 # bound\n}", subject: "aa", options: ::Regexp::EXTENDED, expect_error: false },
    { id: "extended-invalid-comment-active-plus", pattern: "(?x)a{b+ # body\n}", subject: "a{bbb}", options: 0, expect_error: false },
    { id: "extended-utf8-repeat", pattern: "(?x)é{ 2 }", subject: "éé", options: ::Regexp::EXTENDED, expect_error: false },
    { id: "fixed-optional-suffix-exact", pattern: "a{2}?", subject: "aa", options: 0, expect_error: false },
    { id: "nonnumeric-close-plus-one", pattern: "a{x}+", subject: "a{x}", options: 0, expect_error: false },
    { id: "nonnumeric-close-plus-many", pattern: "a{x}+", subject: "a{x}}", options: 0, expect_error: false },
    { id: "nonnumeric-close-optional-omitted", pattern: "a{x}?", subject: "a{x", options: 0, expect_error: false },
    { id: "nonnumeric-close-optional-present", pattern: "a{x}?", subject: "a{x}", options: 0, expect_error: false },
    { id: "open-brace-followed-by-plus", pattern: "a{+", subject: "a{{{", options: 0, expect_error: false },
    { id: "extended-spaces-literal", pattern: "(?x)a{ 2 }", subject: "a{2}", options: ::Regexp::EXTENDED, expect_error: false },
    { id: "extended-spaces-no-repeat", pattern: "(?x)a{ 2 }", subject: "aa", options: ::Regexp::EXTENDED, expect_error: false },
    { id: "extended-comment-literal", pattern: "(?x)a{2 # bound\n}", subject: "a{2}", options: ::Regexp::EXTENDED, expect_error: false },
    { id: "extended-comment-no-repeat", pattern: "(?x)a{2 # bound\n}", subject: "aa", options: ::Regexp::EXTENDED, expect_error: false },
    { id: "extended-invalid-close-plus", pattern: "(?x)a{x # body\n}+", subject: "a{x}", options: 0, expect_error: false },
    { id: "extended-invalid-close-plus-many", pattern: "(?x)a{x # body\n}+", subject: "a{x}}", options: 0, expect_error: false }
  ].freeze

  def test_brace_matrix_matches_mri_with_native_ranges
    CASES.each do |entry|
      pattern = entry.fetch(:pattern)
      subject = entry.fetch(:subject)
      options = entry.fetch(:options)
      label = [entry.fetch(:id), pattern.bytes, subject.bytes]

      if entry.fetch(:expect_error)
        expected_error = assert_raises(::RegexpError) do
          ::Regexp.new(pattern, options)
        end
        actual_error = assert_raises(Onibi::RegexpError) do
          Onibi::Regexp.new(pattern, options)
        end
        assert_equal expected_error.message, actual_error.message, label
        next
      end

      expected = ::Regexp.new(pattern, options).match(subject)
      actual = Onibi::Regexp.new(pattern, options)
      info = actual.send(:__onibi_diagnostics__, subject)
      actual_match = actual.match(subject)

      assert info[:rseq], label
      assert_equal 0, info[:fallback], label
      assert_equal expected.nil? ? 0 : 1, info[:status], label
      if expected
        refute_nil actual_match, label
        assert_equal expected.captures, actual_match.captures, label
        assert_equal raw_ranges(expected), info[:raw_registers], label
        assert_equal raw_ranges(expected), raw_ranges(actual_match), label
      else
        assert_nil actual_match, label
      end
    end
  end

  private

  def raw_ranges(match)
    (0...match.length).map do |index|
      start = match.bytebegin(index)
      finish = match.byteend(index)
      [start || -1, finish || -1]
    end
  end
end
