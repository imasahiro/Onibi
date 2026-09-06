# frozen_string_literal: true

require "test_helper"

class TaggedNullableUtf8RegressionTest < Minitest::Test
  CASES = [
    ["ascii_exact_bound_2", "ASCII exact bound 2", "^(a??){2}x", "ax"],
    ["ascii_exact_bound_3", "ASCII exact bound 3", "^(a??){3}x", "ax"],
    ["two_byte_utf8_exact_bound_2", "two-byte UTF-8 exact bound 2", "^(é??){2}x", "éx"],
    ["two_byte_utf8_exact_bound_3", "two-byte UTF-8 exact bound 3", "^(é??){3}x", "éx"],
    ["three_byte_utf8_exact_bound_2", "three-byte UTF-8 exact bound 2", "^(あ??){2}x", "あx"],
    ["three_byte_utf8_exact_bound_3", "three-byte UTF-8 exact bound 3", "^(あ??){3}x", "あx"],
    ["outer_optional_scope", "outer optional scope", "^(?:(あ??){2})?x", "あx"],
    ["outer_alternative_scope", "outer alternative scope", "^(?:(あ??){2}z|(あ))x", "あx"]
  ].freeze

  CASES.each do |id, name, pattern, subject|
    define_method("test_#{id}") do
      expected = ::Regexp.new(pattern).match(subject)
      info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)

      assert expected, name
      assert info[:rseq], name
      assert_equal 1, info[:exec_kind], name
      assert_equal 1, info[:status], name
      assert_equal expected.bytebegin(0), info[:match_start], name
      assert_equal expected.byteend(0), info[:match_end], name
      assert_operator info[:tagged], :>, 0, name
      assert_equal 0, info[:regular], name
      assert_equal 0, info[:dynamic], name
      assert_equal 0, info[:dfs], name
      assert_equal 0, info[:fallback], name
      assert_equal capture_ranges(expected), info[:captures], name
    end
  end

  private

  def capture_ranges(match)
    (1...match.size).map do |index|
      [match.bytebegin(index) || -1, match.byteend(index) || -1]
    end
  end
end
