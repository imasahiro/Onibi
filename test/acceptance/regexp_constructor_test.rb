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

    assert_equal [], regexp.options
    assert_raises(ArgumentError) { Onibi::Regexp.compile("cat", ["unknown"]) }
  end

  def test_source_returns_the_original_pattern
    regexp = Onibi::Regexp.new("(?i:cat)")

    assert_equal "(?i:cat)", regexp.source
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
end
