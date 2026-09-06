# frozen_string_literal: true

require "test_helper"

class FixedIntervalOptionalSuffixTest < Minitest::Test
  BOUNDS = [2, 9].freeze

  def test_optional_exact_and_lazy_exact_consumption_match_mri
    BOUNDS.each do |count|
      assert_native_match("\\Aa{#{count}}?\\z", "")
      assert_native_match("\\Aa{#{count}}?\\z", "a" * count)
      assert_native_match("\\Aa{#{count},#{count}}?\\z", "")
      assert_native_match("\\Aa{#{count},#{count}}?\\z", "a" * count)
    end
  end

  def test_optional_exact_and_lazy_exact_suffix_paths_match_mri
    BOUNDS.each do |count|
      optional = "\\Aa{#{count}}?b\\z"
      lazy_exact = "\\Aa{#{count},#{count}}?b\\z"

      ["b", "#{"a" * count}b", "#{"a" * count}c"].each do |subject|
        assert_native_match(optional, subject)
        assert_native_match(lazy_exact, subject)
      end
    end
  end

  def test_optional_exact_and_lazy_exact_nullable_captures_match_mri
    BOUNDS.each do |count|
      atom = "あ"
      optional = "\\A(#{atom}?){#{count}}?\\z"
      lazy_exact = "\\A(#{atom}?){#{count},#{count}}?\\z"
      optional_with_suffix = "\\A(#{atom}?){#{count}}?#{atom}\\z"
      lazy_exact_with_suffix = "\\A(#{atom}?){#{count},#{count}}?#{atom}\\z"

      ["", atom].each do |subject|
        assert_native_match(optional, subject)
        assert_native_match(lazy_exact, subject)
      end
      [atom, atom * 2].each do |subject|
        assert_native_match(optional_with_suffix, subject)
        assert_native_match(lazy_exact_with_suffix, subject)
      end
    end
  end

  private

  def assert_native_match(pattern, subject)
    expected = ::Regexp.new(pattern).match(subject)
    info = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)
    label = [pattern, subject]

    assert info[:rseq], label
    assert_equal 1, info[:exec_kind], label
    assert_equal expected.nil? ? 0 : 1, info[:status], label
    if expected
      assert_equal expected.bytebegin(0), info[:match_start], label
      assert_equal expected.byteend(0), info[:match_end], label
      assert_equal capture_ranges(expected), info[:captures], label
    end
    assert_operator info[:tagged], :>, 0, label
    assert_equal 0, info[:regular], label
    assert_equal 0, info[:dynamic], label
    assert_equal 0, info[:dfs], label
    assert_equal 0, info[:fallback], label
  end

  def capture_ranges(match)
    (1...match.size).map do |index|
      [match.bytebegin(index) || -1, match.byteend(index) || -1]
    end
  end
end
