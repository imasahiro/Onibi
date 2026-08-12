# frozen_string_literal: true

require_relative "../../test_helper"

class CompositePredicateMetadataBenchmarkTest < Minitest::Test
  def test_composite_metadata_does_not_change_matching_semantics
    patterns = ["a-z&&[^aeiou]", "\\p{Letter}", "[:digit:]"]
    input = "b7漢"

    patterns.each do |pattern|
      expected = ::Regexp.new("[#{pattern}]").match?(input)
      actual = Onibi::Regexp.new("[#{pattern}]").match?(input)
      assert_equal expected, actual, pattern
    end
  end
end
