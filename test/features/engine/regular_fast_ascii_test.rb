# frozen_string_literal: true

require "test_helper"

class RegularFastAsciiTest < Minitest::Test
  def diagnostics(pattern, subject, options = nil)
    regexp = options.nil? ? Onibi::Regexp.new(pattern) : Onibi::Regexp.new(pattern, options)
    [regexp, regexp.send(:__onibi_diagnostics__, subject)]
  end

  def test_regular_literal_uses_ordered_frontier
    regexp, info = diagnostics("a", "ba")
    assert info[:rseq]
    assert_equal 0, info[:exec_kind]
    assert_equal 0, info[:dfs]
    assert_equal 1, info[:match_start]
    assert_equal 2, info[:match_end]
    assert regexp.match?("ba")
  end

  def test_regular_capture_does_not_enter_dfs
    regexp, info = diagnostics("(a)", "a")
    assert_equal 0, info[:exec_kind]
    assert_equal 0, info[:dfs]
    assert_equal 0, info[:fallback]
    assert_equal 0, info[:semantic_capture_count]
    assert_equal [[0, 1]], info[:captures]
    assert_operator info[:tag_events], :>, 0
    assert_equal 0, regexp.send(:__onibi_match_p_diagnostics__, "a")[:tag_events]
  end

  def test_any_respects_multiline_option
    _plain, plain_info = diagnostics(".", "\n")
    _multi, multi_info = diagnostics(".", "\n", Onibi::Regexp::MULTILINE)
    assert_equal 0, plain_info[:status]
    assert_equal 1, multi_info[:status]
    assert_equal 0, plain_info[:dfs]
    assert_equal 0, multi_info[:dfs]
  end

  def test_lazy_repeat_keeps_first_accept
    _regexp, info = diagnostics("a+?", "aaa")
    assert_equal [0, 1], [info[:match_start], info[:match_end]]
    assert_equal 0, info[:dfs]
  end

  def test_repeated_capture_matches_mri_range
    _regexp, info = diagnostics("(a)+", "aaa")
    assert_equal [[2, 3]], info[:captures]
  end

  def test_optional_capture_can_be_unset
    _regexp, info = diagnostics("(a)?b", "b")
    assert_equal [[-1, -1]], info[:captures]
  end

  def test_ascii_feature_matrix_stays_regular_and_matches_mri
    cases = [
      ["", "x"], ["abc", "xxabcxx"], ["\\.", "x.x"],
      ["(?:ab|cd)", "zcd"], ["[abc]", "z b"], ["[a-z]", "z"],
      ["[^a]", "z"], ["\\d", "7"], ["\\D", "A"],
      ["\\w", "_"], ["\\W", "-"], ["\\s", " "], ["\\S", "x"],
      ["\\h", "A"], ["\\H", "x"], ["[[:digit:]]+", "x123y"],
      ["[[:alpha:]]+", "xAbY"], ["[[:alnum:]]+", "xA7"],
      ["[[:space:]]+", "x \ty"], ["[[:word:]]+", "x_a7"],
      ["a{0}", "aaa"], ["a{1}", "aaa"], ["a{2,4}", "aaaa"]
    ]
    cases.each do |pattern, subject|
      regexp, info = diagnostics(pattern, subject)
      expected = Regexp.new(pattern).match(subject)
      expected_range = expected ? [expected.begin(0), expected.end(0)] : nil
      assert info[:rseq], pattern
      assert_equal 0, info[:exec_kind], pattern
      assert_equal 0, info[:dfs], pattern
      assert_equal 0, info[:fallback], pattern
      assert_equal expected_range, [info[:match_start], info[:match_end]], pattern
      assert_equal !expected.nil?, regexp.match?(subject), pattern
    end
  end

  def test_ignorecase_ascii_stays_regular
    regexp, info = diagnostics("abc", "xxABC", Onibi::Regexp::IGNORECASE)
    assert_equal 0, info[:exec_kind]
    assert_equal 0, info[:dfs]
    assert_equal [2, 5], [info[:match_start], info[:match_end]]
    assert regexp.match?("xxABC")
  end
end
