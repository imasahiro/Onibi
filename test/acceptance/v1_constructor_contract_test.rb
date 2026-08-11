# frozen_string_literal: true

require "test_helper"

class V1ConstructorContractTest < Minitest::Test
  def test_constructor_option_forms_match_mri_observations
    [[nil, 0], [Onibi::Regexp::IGNORECASE, ::Regexp::IGNORECASE],
     [true, ::Regexp::IGNORECASE], [false, 0], ["i", ::Regexp::IGNORECASE],
     [:i, ::Regexp::IGNORECASE]].each do |option, expected_options|
      expected = option.nil? ? ::Regexp.new("cat") : ::Regexp.new("cat", option)
      actual = option.nil? ? Onibi::Regexp.new("cat") : Onibi::Regexp.new("cat", option)

      assert_equal expected_options, actual.options, option.inspect
      assert_equal expected.source, actual.source, option.inspect
      assert_equal expected.to_s, actual.to_s, option.inspect
      assert_equal expected.inspect, actual.inspect, option.inspect
    end
  end

  def test_scoped_inline_modes_match_mri_introspection_without_leaking_to_outer_options
    ["(?i:cat)", "(?m:.)", "(?x:a b)"].each do |source|
      expected = ::Regexp.new(source)
      actual = Onibi::Regexp.new(source)

      assert_equal expected.source, actual.source, source
      assert_equal expected.options, actual.options, source
      assert_equal expected.casefold?, actual.casefold?, source
      assert_equal expected.encoding, actual.encoding, source
      assert_equal expected.fixed_encoding?, actual.fixed_encoding?, source
    end
  end

  def test_utility_formatting_matches_mri_for_literal_sources
    ["a.b", "a/b", "a b#"].each do |literal|
      assert_equal ::Regexp.escape(literal), Onibi::Regexp.escape(literal), literal
      assert_equal ::Regexp.quote(literal), Onibi::Regexp.quote(literal), literal
    end
  end
end
