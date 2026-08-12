# frozen_string_literal: true

require_relative "../../test_helper"

class PredicateBitmapTest < Minitest::Test
  def test_simple_ascii_metadata_contains_a_256_bit_bitmap
    predicate = Onibi::ClassPredicates.compiled("a-cx")
    bitmap = predicate.metadata.ascii_bitmap

    assert_equal 256, predicate.metadata.ascii_bitmap_bits
    assert_equal predicate.matches_byte?("a".ord), bit_set?(bitmap, "a".ord)
    assert_equal predicate.matches_byte?("z".ord), bit_set?(bitmap, "z".ord)
  end

  def test_bitmap_matches_compiled_table_for_every_ascii_byte
    predicate = Onibi::ClassPredicates.compiled("a-cx-z")
    bitmap = predicate.metadata.ascii_bitmap

    0.upto(255) do |byte|
      assert_equal predicate.matches_byte?(byte), ((bitmap >> byte) & 1) == 1, "byte=#{byte}"
    end
  end

  private

  def bit_set?(bitmap, byte)
    ((bitmap >> byte) & 1) == 1
  end
end
