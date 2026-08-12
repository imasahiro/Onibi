# frozen_string_literal: true

require_relative "../../test_helper"

class CompiledClassPredicateTest < Minitest::Test
  def test_compiled_predicate_is_immutable_and_matches_ascii_ranges
    predicate = Onibi::ClassPredicates.compiled("a-z")

    assert predicate.frozen?
    assert predicate.matches?("m")
    refute predicate.matches?("7")
  end

  def test_compiled_predicate_exposes_immutable_normalized_metadata
    metadata = Onibi::ClassPredicates.compiled("a-cx").metadata

    assert_equal :ascii, metadata.kind
    assert_equal ["x"], metadata.literals
    assert_equal [%w[a c]], metadata.ranges
    assert metadata.ascii_applicable
    assert_raises(FrozenError) { metadata.literals << "z" }
  end

  def test_normalizer_keeps_intersections_and_properties_as_composite
    intersection = Onibi::ClassPredicates.compiled("a-z&&[^aeiou]").metadata
    property = Onibi::ClassPredicates.compiled("\\p{Letter}").metadata

    assert_equal :composite, intersection.kind
    assert_equal :composite, property.kind
    refute intersection.ascii_applicable
    refute property.ascii_applicable
  end

  def test_compiled_predicate_preserves_intersection_and_ignorecase
    intersection = Onibi::ClassPredicates.compiled("a-z&&[^aeiou]")
    folded = Onibi::ClassPredicates.compiled("a", ignorecase: true)

    assert intersection.matches?("b")
    refute intersection.matches?("a")
    assert folded.matches?("A")
  end

  def test_compiled_predicate_uses_a_256_byte_ascii_table
    predicate = Onibi::ClassPredicates.compiled("\\x80-\\xFF".b)

    assert_equal 256, predicate.ascii_table_length
    assert predicate.matches?("\xFF".b)
    refute predicate.matches?("\x7F".b)
  end

  def test_compiled_predicate_matches_ascii_bytes_without_character_allocation
    predicate = Onibi::ClassPredicates.compiled("a-z")

    assert predicate.matches_byte?("m".ord)
    refute predicate.matches_byte?("7".ord)
  end

  def test_regexp_matching_remains_mri_equivalent
    pattern = "[a-z&&[^aeiou]]+"
    input = "rhythms 123"

    expected = ::Regexp.new(pattern).match(input)
    actual = Onibi::Regexp.new(pattern).match(input)
    assert_equal [expected&.[](0), expected&.offset(0)], [actual&.[](0), actual&.offset(0)]
  end

  def test_generated_class_predicate_returns_cursor_without_candidate_array
    assert_equal 1, Onibi::Codegen::Casefold.class_candidates("a", 0, "a-z", false)
    assert_nil Onibi::Codegen::Casefold.class_candidates("1", 0, "a-z", false)
  end

  def test_generated_class_predicate_uses_compiled_table_leaf
    ast = Onibi::Parser.new("[a-z]").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_includes program.source, "TableRegistry.fetch"
    refute_includes program.source, "ClassPredicates.matches?"
    predicate = Onibi::ClassPredicates.compiled("a-z")
    assert_equal 1, Onibi::Codegen::Casefold.class_candidates("a", 0, predicate, false)
  end

  def test_generated_class_predicate_references_a_registered_table_id
    ast = Onibi::Parser.new("[a-z]").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_includes program.source, "TableRegistry.fetch"
    refute_includes program.source, 'compiled("a-z"'
  end

  def test_generated_program_hoists_repeated_class_predicates
    ast = Onibi::Parser.new("[a-z]+[a-z]+[0-9]").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal 2, program.source.scan("TableRegistry.fetch").length
    assert_includes program.source, "ONIBI_CLASS_PREDICATES"
  end
end
