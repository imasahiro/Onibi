# frozen_string_literal: true

require_relative "../../test_helper"

class CompositePredicateMetadataTest < Minitest::Test
  def test_intersection_metadata_records_immutable_leaf_sources
    metadata = Onibi::ClassPredicates.compiled("a-z&&[^aeiou]").metadata

    assert_equal :intersection, metadata.kind
    assert_equal ["a-z", "[^aeiou]"], metadata.leaves
    assert metadata.leaves.frozen?
  end

  def test_ascii_intersection_metadata_composes_a_bitmap
    predicate = Onibi::ClassPredicates.compiled("a-z&&[^aeiou]")
    metadata = predicate.metadata

    assert metadata.ascii_applicable
    assert_equal 256, metadata.ascii_bitmap_bits
    assert bit_set?(metadata.ascii_bitmap, "b".ord)
    refute bit_set?(metadata.ascii_bitmap, "a".ord)
    assert_bitmap_matches(predicate, metadata.ascii_bitmap)
  end

  def test_unicode_and_posix_metadata_record_leaf_predicate_names
    unicode = Onibi::ClassPredicates.compiled("\\p{Letter}").metadata
    posix = Onibi::ClassPredicates.compiled("[:digit:]").metadata

    assert_equal "Letter", unicode.unicode_property
    assert_equal "Digit", posix.posix_property
  end

  def test_ignorecase_metadata_records_expansion_mode
    ascii = Onibi::ClassPredicates.compiled("a", ignorecase: true).metadata
    full_fold = Onibi::ClassPredicates.compiled("ß", ignorecase: true).metadata

    assert_equal :simple_casefold, ascii.ignorecase_expansion
    assert_equal :full_fold, full_fold.ignorecase_expansion
  end

  private

  def bit_set?(bitmap, byte)
    ((bitmap >> byte) & 1) == 1
  end

  def assert_bitmap_matches(predicate, bitmap)
    0.upto(255) do |byte|
      assert_equal predicate.matches_byte?(byte), bit_set?(bitmap, byte), "byte=#{byte}"
    end
  end
end
