# frozen_string_literal: true

require "test_helper"

class RegularFastAsciiTest < Minitest::Test
  def diagnostics(pattern, subject, options = nil)
    regexp = options.nil? ? Onibi::Regexp.new(pattern) : Onibi::Regexp.new(pattern, options)
    [regexp, regexp.send(:__onibi_diagnostics__, subject)]
  end

  def assert_regular_case(pattern, subject, options = nil)
    regexp, info = diagnostics(pattern, subject, options)
    expected = Regexp.new(pattern, options || 0).match(subject)
    expected_range = expected ? [expected.begin(0), expected.end(0)] : nil

    assert info[:rseq], pattern
    assert info[:regular_capable], pattern
    assert_equal 0, info[:exec_kind], pattern
    assert_equal 0, info[:dfs], pattern
    assert_equal 0, info[:fallback], pattern
    assert_equal expected_range, [info[:match_start], info[:match_end]], pattern
    assert_equal !expected.nil?, regexp.match?(subject), pattern
  end

  def test_regular_literal_uses_ordered_frontier
    regexp, info = diagnostics("a", "ba")
    assert info[:rseq]
    assert info[:regular_capable]
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

  def test_empty_and_literal_features_stay_regular
    assert_regular_case("", "x")
    assert_regular_case("a", "ba")
    assert_regular_case("abc", "xxabcxx")
    assert_regular_case("\\.", "x.x")
  end

  def test_alternation_and_non_capture_features_stay_regular
    assert_regular_case("a|b", "zb")
    assert_regular_case("a|ab", "ab")
    assert_regular_case("ab|a", "ab")
    assert_regular_case("(?:ab|cd)", "zcd")
  end

  def test_quantifier_features_stay_regular
    assert_regular_case("a?", "")
    assert_regular_case("a*", "aaa")
    assert_regular_case("a+", "aaa")
    assert_regular_case("a*?", "aaa")
    assert_regular_case("a+?", "aaa")
  end

  def test_small_bounded_repeats_stay_regular
    assert_regular_case("a{0}", "aaa")
    assert_regular_case("a{1}", "aaa")
    assert_regular_case("a{2,4}", "aaaa")
    assert_regular_case("a{0,8}", "aaaa")
  end

  def test_class_features_stay_regular
    assert_regular_case("[abc]", "z b")
    assert_regular_case("[a-z]", "z")
    assert_regular_case("[^a]", "z")
    assert_regular_case("[a-z&&[^aeiou]]", "z")
  end

  def test_shorthand_features_stay_regular
    assert_regular_case("\\d", "7")
    assert_regular_case("\\D", "A")
    assert_regular_case("\\w", "_")
    assert_regular_case("\\W", "-")
    assert_regular_case("\\s", " ")
    assert_regular_case("\\S", "x")
    assert_regular_case("\\h", "A")
    assert_regular_case("\\H", "x")
  end

  def test_posix_ascii_features_stay_regular
    assert_regular_case("[[:digit:]]+", "x123y")
    assert_regular_case("[[:alpha:]]+", "xAbY")
    assert_regular_case("[[:alnum:]]+", "xA7")
    assert_regular_case("[[:space:]]+", "x \ty")
    assert_regular_case("[[:word:]]+", "x_a7")
  end

  def test_pathological_regular_repeat_stays_off_dfs
    assert_regular_case("(a|aa)*b", "#{"a" * 50}b")
    _regexp, info = diagnostics("(a|aa)*b", "a" * 50)
    assert_equal 0, info[:status]
    assert_equal 0, info[:dfs]
    assert_equal 0, info[:fallback]
  end

  def test_ignorecase_ascii_stays_regular
    regexp, info = diagnostics("abc", "xxABC", Onibi::Regexp::IGNORECASE)
    assert_equal 0, info[:exec_kind]
    assert_equal 0, info[:dfs]
    assert_equal [2, 5], [info[:match_start], info[:match_end]]
    assert regexp.match?("xxABC")
  end
end
