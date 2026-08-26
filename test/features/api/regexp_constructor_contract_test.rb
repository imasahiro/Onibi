# frozen_string_literal: true

require "test_helper"

class RegexpConstructorContractTest < Minitest::Test
  def test_constructor_option_forms_match_mri_observations
    [[nil, 0], [Onibi::Regexp::IGNORECASE, ::Regexp::IGNORECASE],
     [true, ::Regexp::IGNORECASE], [false, 0], ["i", ::Regexp::IGNORECASE],
     [:i, ::Regexp::IGNORECASE]].each do |option, expected_options|
      expected = option.nil? ? ::Regexp.new("cat") : ::Regexp.new("cat", option)
      actual = option.nil? ? Onibi::Regexp.new("cat") : Onibi::Regexp.new("cat", option)

      assert_equal expected_options, actual.options, option.inspect
      assert_regexp_observations(expected, actual, option.inspect)
    end
  end

  def test_integer_options_ignore_legacy_bits_like_mri
    [8, 64, 128].each do |legacy_bit|
      expected = ::Regexp.new("cat", legacy_bit)
      actual = Onibi::Regexp.new("cat", legacy_bit)

      assert_equal expected.options, actual.options, legacy_bit
      assert_equal expected.to_s, actual.to_s, legacy_bit
    end

    assert_equal ::Regexp.new("cat", -1).options, Onibi::Regexp.new("cat", -1).options
  end

  def test_scoped_inline_modes_match_mri_introspection_without_leaking_to_outer_options
    ["(?i:cat)", "(?m:.)", "(?x:a b)"].each do |source|
      expected = ::Regexp.new(source)
      actual = Onibi::Regexp.new(source)

      assert_regexp_observations(expected, actual, source)
      assert_equal expected.casefold?, actual.casefold?, source
      assert_equal expected.fixed_encoding?, actual.fixed_encoding?, source
    end
  end

  def test_utility_formatting_matches_mri_for_literal_sources
    ["a.b", "a/b", "a b#"].each do |literal|
      assert_equal ::Regexp.escape(literal), Onibi::Regexp.escape(literal), literal
      assert_equal ::Regexp.quote(literal), Onibi::Regexp.quote(literal), literal
    end
  end

  private

  def assert_regexp_observations(expected, actual, label)
    assert_equal expected.source, actual.source, label
    assert_equal expected.to_s, actual.to_s, label
    assert_equal expected.inspect, actual.inspect, label
    assert_equal expected.encoding, actual.encoding, label
  end
end
