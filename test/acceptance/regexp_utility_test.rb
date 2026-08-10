# frozen_string_literal: true

require "test_helper"

class RegexpUtilityTest < Minitest::Test
  def test_escape_quotes_regexp_metacharacters
    assert_equal "a\\.b\\[c\\]\\ \\(x\\)\\\\", Onibi::Regexp.escape("a.b[c] (x)\\")
  end

  def test_escape_quotes_spaces_and_comments
    assert_equal "a\\ b\\#", Onibi::Regexp.escape("a b#")
  end

  def test_escape_quotes_hyphens_and_control_whitespace
    assert_equal "\\-", Onibi::Regexp.escape("-")
    assert_equal "\\t\\n\\v\\f\\r", Onibi::Regexp.escape("\t\n\v\f\r")
  end

  def test_escape_uses_us_ascii_for_ascii_only_input
    escaped = Onibi::Regexp.escape("a".encode(Encoding::EUC_JP))

    assert_equal Encoding::US_ASCII, escaped.encoding
  end

  def test_escape_matches_ruby_input_coercion_errors
    assert_equal "a", Onibi::Regexp.escape(:a)
    assert_raises(TypeError) { Onibi::Regexp.escape(nil) }
    assert_raises(TypeError) { Onibi::Regexp.escape(1) }
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

  def test_union_preserves_compiled_pattern_options
    regexp = Onibi::Regexp.union(::Regexp.new("cat", ::Regexp::IGNORECASE))

    assert regexp.match?("CAT")
  end

  def test_union_preserves_compiled_multiline_and_extended_options
    multiline = Onibi::Regexp.union(::Regexp.new(".", ::Regexp::MULTILINE))
    extended = Onibi::Regexp.union(::Regexp.new("a b", ::Regexp::EXTENDED))
    combined = Onibi::Regexp.union(::Regexp.new("a b", ::Regexp::IGNORECASE | Regexp::EXTENDED))

    assert multiline.match?("\n")
    assert extended.match?("ab")
    assert combined.match?("AB")
  end

  def test_union_preserves_compiled_noencoding_option
    regexp = Onibi::Regexp.union(::Regexp.new("a", ::Regexp::NOENCODING))

    assert_equal Onibi::Regexp::NOENCODING, regexp.options
    assert_equal Encoding::US_ASCII, regexp.encoding
  end

  def test_union_preserves_compiled_fixed_encoding_option
    regexp = Onibi::Regexp.union(::Regexp.new("a", ::Regexp::FIXEDENCODING))

    assert_equal Onibi::Regexp::FIXEDENCODING, regexp.options
    assert_equal Encoding::UTF_8, regexp.encoding
  end

  def test_union_reconciles_noencoding_with_string_alternatives
    noencoding = ::Regexp.new("a", ::Regexp::NOENCODING)

    ascii = Onibi::Regexp.union(noencoding, "a")
    assert_equal 0, ascii.options
    refute ascii.fixed_encoding?

    binary = Onibi::Regexp.union(noencoding, "é".b)
    assert_equal Onibi::Regexp::FIXEDENCODING, binary.options
    assert_equal Encoding::ASCII_8BIT, binary.encoding
    assert binary.fixed_encoding?
  end

  def test_linear_time_reports_conservative_pattern_safety
    assert Onibi::Regexp.linear_time?("a*")
    assert Onibi::Regexp.linear_time?(::Regexp.new("a*"))
    refute Onibi::Regexp.linear_time?("(a*)\\1")
    refute Onibi::Regexp.linear_time?("(?=a)b")
  end
end
