# frozen_string_literal: true

require "test_helper"

class PatternCommentTest < Minitest::Test
  def test_pattern_comments_are_ignored
    assert_mri_match_results("(?# greeting)cat", %w[cat dog])
  end

  def test_pattern_comments_do_not_create_captures
    match = Onibi::Regexp.new("(?# greeting)(cat)").match("cat")

    assert_equal %w[cat cat], match.to_a
    assert_mri_match_results("(?# greeting)(cat)", ["cat"])

    numbered = Onibi::Regexp.new("(?# greeting)(c)(at)").match("cat")

    assert_equal %w[cat c at], numbered.to_a
    assert_mri_match_results("(?# greeting)(c)(at)", ["cat"])
  end

  def test_unterminated_pattern_comments_raise_regexp_error
    assert_raises(RegexpError) { Regexp.new("(?# comment") }
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?# comment") }
  end

  def test_pattern_comment_delimiters_follow_mri_escaping
    assert_mri_match_results("a(?#x(y)z", %w[az a(yz])
    assert_mri_match_results('a(?#x\)y)z', %w[az ay)z])
  end

  def test_pattern_comments_do_not_change_quantifiers_or_alternation
    subjects = %w[b ab aaab c]

    assert_mri_match_results("a(?# repeat)*b", subjects)
    assert_mri_match_results("a*(?# repeat)b", subjects)
    assert_mri_match_results("a(?# branch)|b", %w[a b c])
  end

  def test_pattern_comments_do_not_change_inline_options
    assert_mri_match_results("(?# before)(?i)a", %w[a A])
    assert_mri_match_results("(?i)(?# after)(a)", %w[a A])
    assert_mri_match_results("(?# before)(?i:a)", %w[a A])
  end

  def test_pattern_comments_leave_escaped_openers_and_classes_unchanged
    assert_mri_match_results('\\(\\?#', ["(?#", "x(?#"])
    assert_mri_match_results('[\\(]', ["(", ")"])
  end

  def test_pattern_comments_preserve_extended_mode_and_utf8_captures
    pattern = "(?# # ignored\n )(é)"

    assert_mri_match_results(
      pattern,
      ["é"],
      onibi_options: ["extended"],
      mri_options: Regexp::EXTENDED
    )

    shift_jis_pattern = "(?#ソ)(cat)".encode(Encoding::Shift_JIS)

    assert_mri_match_results(shift_jis_pattern, ["cat"])
  end

  private

  def assert_mri_match_results(pattern, subjects, onibi_options: nil, mri_options: 0)
    expected_regexp = Regexp.new(pattern, mri_options)
    actual_regexp = if onibi_options
                      Onibi::Regexp.new(pattern, onibi_options)
                    else
                      Onibi::Regexp.new(pattern)
                    end

    subjects.each do |subject|
      expected = expected_regexp.match(subject)
      actual = actual_regexp.match(subject)

      if expected
        refute_nil actual
        assert_equal expected.to_a, actual.to_a
        assert_equal [expected.begin(0), expected.end(0)],
                     [actual.begin(0), actual.end(0)]
      else
        assert_nil actual
      end
    end
  end
end
