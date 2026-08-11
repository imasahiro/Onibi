# frozen_string_literal: true

require "test_helper"

class PublicErrorsTest < Minitest::Test
  def test_invalid_pattern_type_raises_type_error
    error = assert_raises(TypeError) { Onibi::Regexp.new(1) }

    assert_includes error.message, "String"
  end

  def test_invalid_input_type_raises_type_error
    regexp = Onibi::Regexp.new("a")
    error = assert_raises(TypeError) { regexp.match?(1) }

    assert_includes error.message, "String"
  end

  def test_malformed_pattern_raises_namespaced_regexp_error
    error = assert_raises(Onibi::RegexpError) { Onibi::Regexp.new("[") }

    refute_empty error.message
  end

  def test_invalid_options_raise_argument_error
    error = assert_raises(ArgumentError) { Onibi::Regexp.new("a", :unsupported) }

    refute_empty error.message
  end
end
