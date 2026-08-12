# frozen_string_literal: true

require_relative "../../test_helper"

class DirectPredicateTableBenchmarkTest < Minitest::Test
  def test_direct_table_and_helper_produce_equivalent_cursors
    input = "abcxyz"
    predicate = Onibi::ClassPredicates.compiled("a-z")
    table = predicate.ascii_table

    input.length.times do |position|
      expected = Onibi::Codegen::Casefold.class_candidates(input, position, predicate, false)
      byte = input.getbyte(position)
      actual = byte && table[byte] ? position + 1 : nil

      assert_equal expected, actual
    end
  end
end
