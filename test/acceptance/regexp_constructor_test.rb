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
end
