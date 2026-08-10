# frozen_string_literal: true

require "test_helper"

class RegexpUtilityTest < Minitest::Test
  def test_escape_quotes_regexp_metacharacters
    assert_equal "a\\.b\\[c\\]\\ \\(x\\)\\\\", Onibi::Regexp.escape("a.b[c] (x)\\")
  end

  def test_escape_quotes_spaces_and_comments
    assert_equal "a\\ b\\#", Onibi::Regexp.escape("a b#")
  end
end
