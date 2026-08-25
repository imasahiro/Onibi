# frozen_string_literal: true

require "test_helper"

class RegexpUtilityTest < Minitest::Test
  UNSAFE_PATTERNS = [
    "(?<word>a)\\k<word>", "(?~a)"
  ].freeze
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
    error = assert_raises(TypeError) { Onibi::Regexp.escape(nil) }
    assert_equal "no implicit conversion of nil into String", error.message
    assert_raises(TypeError) { Onibi::Regexp.escape(1) }
  end

  def test_escape_rejects_non_string_to_str_results_like_mri
    value = Object.new
    value.define_singleton_method(:to_str) { nil }

    error = assert_raises(TypeError) { Onibi::Regexp.escape(value) }
    assert_equal "can't convert Object to String (Object#to_str gives NilClass)", error.message
  end

  def test_escape_reports_boolean_conversion_errors_like_mri
    assert_equal "no implicit conversion of true into String",
                 assert_raises(TypeError) { Onibi::Regexp.escape(true) }.message
    assert_equal "no implicit conversion of false into String",
                 assert_raises(TypeError) { Onibi::Regexp.escape(false) }.message
  end

  def test_quote_is_an_alias_for_escape
    assert_equal Onibi::Regexp.escape("a+b"), Onibi::Regexp.quote("a+b")
    assert_equal Onibi::Regexp.escape(:word), Onibi::Regexp.quote(:word)
  end

  def test_last_match_matches_mri_and_match_question_does_not_change_it
    regexp = Onibi::Regexp.new("(a)")

    Onibi::Regexp.new("never").match("x")
    assert_nil Onibi::Regexp.last_match
    matched = regexp.match("a")
    assert_equal matched, Onibi::Regexp.last_match
    assert_equal "a", Onibi::Regexp.last_match(0)
    assert_equal "a", Onibi::Regexp.last_match(1)

    regexp.match?("b")
    assert_equal matched, Onibi::Regexp.last_match
    assert_nil regexp.match("b")
    assert_nil Onibi::Regexp.last_match
  end

  def test_try_convert_handles_to_regexp_contract
    regexp = Onibi::Regexp.new("a")
    convertible = Object.new
    convertible.define_singleton_method(:to_regexp) { regexp }
    invalid = Object.new
    invalid.define_singleton_method(:to_regexp) { "not a regexp" }

    assert_same regexp, Onibi::Regexp.try_convert(regexp)
    native = ::Regexp.new("a")
    assert_same native, Onibi::Regexp.try_convert(native)
    assert_same regexp, Onibi::Regexp.try_convert(convertible)
    assert_nil Onibi::Regexp.try_convert(Object.new)
    assert_raises(TypeError) { Onibi::Regexp.try_convert(invalid) }
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

  def test_union_accepts_a_single_array_of_patterns
    regexp = Onibi::Regexp.union(["a.b", "cat"])

    assert_equal "a\\.b|cat", regexp.source
    assert regexp.match?("a.b")
    assert regexp.match?("cat")
  end

  def test_union_rejects_symbol_mixed_with_multiple_patterns
    assert_raises(TypeError) { Onibi::Regexp.union("a", :foo) }
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

  def test_union_embeds_each_compiled_pattern_scope
    regexp = Onibi::Regexp.union(::Regexp.new("a", ::Regexp::IGNORECASE), ::Regexp.new("b"))

    assert_equal "(?i-mx:a)|(?-mix:b)", regexp.source
    assert_equal 0, regexp.options
  end

  def test_union_to_s_keeps_scopes_outside_the_outer_wrapper
    expected = ::Regexp.union(::Regexp.new("a", ::Regexp::IGNORECASE), ::Regexp.new("b"))
    actual = Onibi::Regexp.union(::Regexp.new("a", ::Regexp::IGNORECASE), ::Regexp.new("b"))

    assert_equal expected.to_s, actual.to_s
  end

  def test_to_s_escapes_slashes_inside_scoped_modifiers
    regexp = Onibi::Regexp.new("(?imx:a/b)")

    assert_equal "(?mix:a\\/b)", regexp.to_s
  end

  def test_to_s_escapes_slashes_in_plain_patterns
    assert_equal "(?-mix:a\\/b)", Onibi::Regexp.new("a/b").to_s
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

  def test_union_keeps_mri_binary_encoding_selection
    ascii_binary = Onibi::Regexp.union("a".b, "b".b)
    assert_equal Regexp.union("a".b, "b".b).encoding, ascii_binary.encoding
    assert_equal Regexp.union("a".b, "b".b).options, ascii_binary.options

    mixed = Onibi::Regexp.union("a".b, "é")
    expected = Regexp.union("a".b, "é")
    assert_equal expected.encoding, mixed.encoding
    assert_equal expected.options, mixed.options
    assert_equal expected.inspect, mixed.inspect
  end

  def test_linear_time_reports_conservative_pattern_safety
    assert Onibi::Regexp.linear_time?("a*")
    assert Onibi::Regexp.linear_time?(::Regexp.new("a*"))
    refute Onibi::Regexp.linear_time?("(a*)\\1")
    assert Onibi::Regexp.linear_time?("(?=a)b")
    refute Onibi::Regexp.linear_time?("(?~a)")
  end

  def test_linear_time_rejects_each_supported_non_linear_syntax_family
    UNSAFE_PATTERNS.each do |pattern|
      refute Onibi::Regexp.linear_time?(pattern), "expected #{pattern} to be unsafe"
    end
  end
end
