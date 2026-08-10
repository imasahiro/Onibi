# frozen_string_literal: true

require "test_helper"

class RegexpUtilityTest < Minitest::Test
  def test_escape_quotes_regexp_metacharacters
    assert_equal "a\\.b\\[c\\]\\ \\(x\\)\\\\", Onibi::Regexp.escape("a.b[c] (x)\\")
  end

  def test_escape_quotes_spaces_and_comments
    assert_equal "a\\ b\\#", Onibi::Regexp.escape("a b#")
  end

  def test_union_escapes_string_patterns_and_matches_each_alternative
    regexp = Onibi::Regexp.union("a.b", "cat")

    assert_equal "a\\.b|cat", regexp.source
    assert regexp.match?("a.b")
    assert regexp.match?("cat")
    refute regexp.match?("dog")
  end

  def test_union_of_no_patterns_never_matches
    refute Onibi::Regexp.union.match?("")
    refute Onibi::Regexp.union.match?("anything")
  end

  def test_union_accepts_compiled_regexp_patterns
    regexp = Onibi::Regexp.union(::Regexp.new("a|b"), "cat")

    assert regexp.match?("b")
    assert regexp.match?("cat")
    refute regexp.match?("dog")
  end
end
