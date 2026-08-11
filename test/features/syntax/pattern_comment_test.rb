# frozen_string_literal: true

require "test_helper"

class PatternCommentTest < Minitest::Test
  def test_pattern_comments_are_ignored
    regexp = Onibi::Regexp.new("(?# greeting)cat")

    assert regexp.match?("cat")
  end

  def test_pattern_comments_do_not_create_captures
    match = Onibi::Regexp.new("(?# greeting)(cat)").match("cat")

    assert_equal %w[cat cat], match.to_a
  end

  def test_unterminated_pattern_comments_raise_regexp_error
    assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("(?# comment") }
  end
end
