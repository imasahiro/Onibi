# frozen_string_literal: true

require_relative "../../test_helper"

class PredicateNormalizerBenchmarkTest < Minitest::Test
  def test_normalized_metadata_preserves_ascii_predicate_results
    source = "a-cx-z"
    predicate = Onibi::ClassPredicates.compiled(source)

    0.upto(127) do |byte|
      character = byte.chr(Encoding::ASCII)
      expected = Onibi::ClassPredicates.match_source(source, character, false)
      assert_equal expected, predicate.matches_byte?(byte), "byte=#{byte}"
    end
  end
end
