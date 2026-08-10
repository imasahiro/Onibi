# frozen_string_literal: true

require "test_helper"

class RegexpConstructorTest < Minitest::Test
  def test_new_and_compile_create_equivalent_regexp_instances
    from_new = Onibi::Regexp.new("cat", ["ignorecase"])
    from_compile = Onibi::Regexp.compile("cat", ["ignorecase"])

    assert_instance_of Onibi::Regexp, from_compile
    assert_equal from_new.match?("CAT"), from_compile.match?("CAT")
  end

  def test_default_options_are_stable_and_invalid_options_fail
    regexp = Onibi::Regexp.new("cat")

    assert_equal 0, regexp.options
    assert_equal Onibi::Regexp::IGNORECASE, Onibi::Regexp.new("cat", ["ignorecase"]).options
    assert_raises(ArgumentError) { Onibi::Regexp.compile("cat", ["unknown"]) }
  end

  def test_extended_integer_flag_enables_extended_mode
    regexp = Onibi::Regexp.new("a b # comment\n c", Onibi::Regexp::EXTENDED)

    assert_equal Onibi::Regexp::EXTENDED, regexp.options
    assert regexp.match?("abc")
  end

  def test_source_returns_the_original_pattern
    regexp = Onibi::Regexp.new("(?i:cat)")

    assert_equal "(?i:cat)", regexp.source
  end

  def test_source_uses_us_ascii_for_non_fixed_ascii_patterns
    regexp = Onibi::Regexp.new("cat")

    assert_equal Encoding::US_ASCII, regexp.source.encoding
  end

  def test_casefold_reports_the_ignorecase_option
    assert Onibi::Regexp.new("cat", ["ignorecase"]).casefold?
    refute Onibi::Regexp.new("cat").casefold?
  end

  def test_equal_regexps_have_equal_object_semantics
    first = Onibi::Regexp.new("cat", ["ignorecase"])
    second = Onibi::Regexp.new("cat", ["ignorecase"])
    different = Onibi::Regexp.new("dog", ["ignorecase"])

    assert_equal first, second
    assert first.eql?(second)
    assert_equal first.hash, second.hash
    refute_equal first, different
  end

  def test_to_s_reports_explicit_mode_scope
    regexp = Onibi::Regexp.new("cat", ["ignorecase"])

    assert_equal "(?i-mx:cat)", regexp.to_s
  end

  def test_to_s_and_inspect_use_ruby_mode_flag_order
    regexp = Onibi::Regexp.new("cat", Onibi::Regexp::IGNORECASE |
      Onibi::Regexp::MULTILINE | Onibi::Regexp::EXTENDED)

    assert_equal "(?mix:cat)", regexp.to_s
    assert_equal "/cat/mix", regexp.inspect
  end

  def test_inspect_uses_regexp_literal_format
    regexp = Onibi::Regexp.new("cat", ["ignorecase"])

    assert_equal "/cat/i", regexp.inspect
  end

  def test_new_accepts_an_existing_onibi_regexp
    original = Onibi::Regexp.new("cat", ["ignorecase"])
    copy = Onibi::Regexp.new(original)

    assert_equal original.source, copy.source
    assert_equal original.options, copy.options
    assert copy.match?("CAT")
  end

  def test_compile_accepts_an_existing_onibi_regexp
    original = Onibi::Regexp.new("cat", ["ignorecase"])

    assert Onibi::Regexp.compile(original).match?("CAT")
  end

  def test_new_accepts_a_builtin_regexp_by_source_and_options
    original = ::Regexp.new("cat", ::Regexp::IGNORECASE)

    copy = Onibi::Regexp.new(original)

    assert_equal ::Regexp::IGNORECASE, copy.options
    assert copy.match?("CAT")
  end

  def test_timeout_has_class_default_and_instance_override
    original = Onibi::Regexp.timeout
    Onibi::Regexp.timeout = 0.25

    assert_equal 0.25, Onibi::Regexp.timeout
    regexp = Onibi::Regexp.new("cat", timeout: 0.5)
    assert_equal 0.5, regexp.timeout
  ensure
    Onibi::Regexp.timeout = original
  end

  def test_copy_preserves_or_overrides_instance_timeout
    original = Onibi::Regexp.new("cat", timeout: 0.5)

    assert_equal 0.5, Onibi::Regexp.new(original).timeout
    assert_equal 0.2, Onibi::Regexp.new(original, timeout: 0.2).timeout
    assert_equal 0.2, Onibi::Regexp.compile(original, timeout: 0.2).timeout
  end

  def test_timeout_rejects_zero_and_negative_values
    assert_raises(ArgumentError) { Onibi::Regexp.timeout = 0 }
    assert_raises(ArgumentError) { Onibi::Regexp.timeout = -0.1 }
    assert_raises(ArgumentError) { Onibi::Regexp.new("cat", timeout: 0) }
    assert_raises(ArgumentError) { Onibi::Regexp.new("cat", timeout: -0.1) }
  end
end
