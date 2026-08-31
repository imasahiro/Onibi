# frozen_string_literal: true

require "test_helper"

class RegularFastCaptureTest < Minitest::Test
  def assert_regular_capture(pattern, subject)
    regexp = Onibi::Regexp.new(pattern)
    info = regexp.send(:__onibi_diagnostics__, subject)
    expected = Regexp.new(pattern).match(subject)

    assert_equal 0, info[:exec_kind], pattern
    assert_operator info[:regular], :>, 0, pattern
    assert_equal 0, info[:dfs], pattern
    assert_equal 0, info[:fallback], pattern
    assert_equal expected.nil? ? 0 : 1, info[:status], pattern

    if expected
      expected_ranges = expected.captures.each_index.map do |index|
        range = expected.offset(index + 1)
        range.all?(&:nil?) ? [-1, -1] : range
      end
      assert_equal [expected.begin(0), expected.end(0)],
                   [info[:match_start], info[:match_end]], pattern
      assert_equal expected_ranges, info[:captures], pattern
    end

    actual = regexp.match(subject)
    if expected
      assert_equal expected.offset(0), actual.offset(0), pattern
      assert_equal expected.captures, actual.captures, pattern
    else
      assert_nil actual, pattern
    end
    info
  end

  def test_c1_one_capture
    assert_regular_capture("(a)", "a")
    assert_regular_capture("(a)", "ba")
    assert_regular_capture("(a)", "b")
  end

  def test_c2_nested_capture
    assert_regular_capture("((a)b)", "zab")
  end

  def test_c3_optional_unset_capture
    assert_regular_capture("(a)?b", "ab")
    assert_regular_capture("(a)?b", "b")
  end

  def test_c4_alternation_with_different_captures
    assert_regular_capture("(a)|(b)", "a")
    assert_regular_capture("(a)|(b)", "b")
  end

  def test_c5_alternation_priority_inside_capture
    assert_regular_capture("(a|ab)", "ab")
  end

  def test_c6_greedy_capture
    assert_regular_capture("(a*)", "aaa")
    assert_regular_capture("(a*)", "")
    assert_regular_capture("(a*)", "b")
  end

  def test_c7_lazy_capture
    assert_regular_capture("(a*?)a", "aaa")
  end

  def test_c8_repeated_capture
    assert_regular_capture("(a)+", "aaa")
  end

  def test_repeated_alternation_keeps_the_first_capture_history
    assert_regular_capture("(a|ab)+", "ab")
  end

  def test_c9_empty_capture
    assert_regular_capture("()", "")
    assert_regular_capture("(a?)", "")
  end

  def test_c10_capture_plus_following_literal
    assert_regular_capture("([a-z]+)-[0-9]+", "xx item-2026 yy")
  end

  def test_nullable_capture_after_a_consuming_capture
    assert_regular_capture("([ab]+)(b?)", "a")
    assert_regular_capture("([ab]+)(b?)", "ab")
  end

  def test_tag_history_grows_for_long_repeated_capture
    subject = "a" * 1000
    info = assert_regular_capture("(a)+", subject)

    assert_operator info[:tag_events], :>, 256
    assert_equal [[999, 1000]], info[:captures]
  end

  def test_match_p_creates_no_output_capture_tags
    regexp = Onibi::Regexp.new("((a)+)")
    info = regexp.send(:__onibi_match_p_diagnostics__, "a" * 1000)

    assert_equal 1, info[:status]
    assert_equal 0, info[:tag_events]
  end
end
