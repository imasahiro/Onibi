# frozen_string_literal: true

require_relative "../../test_helper"

class Predicate256TableBenchmarkTest < Minitest::Test
  def test_compiled_table_matches_source_predicate_for_all_bytes
    source = "\\x80-\\xFF".b
    predicate = Onibi::ClassPredicates.compiled(source)

    0.upto(255) do |byte|
      character = byte.chr(Encoding::ASCII_8BIT)
      expected = Onibi::ClassPredicates.match_source(source, character, false)
      assert_equal expected, predicate.matches?(character), "byte=#{byte}"
    end
  end
end
