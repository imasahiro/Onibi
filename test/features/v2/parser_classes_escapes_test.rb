# frozen_string_literal: true

require "test_helper"

class V2ParserClassesEscapesTest < Minitest::Test
  def test_character_classes_have_exact_source_values
    expected = Onibi::AST::Sequence.new([
                                          Onibi::AST::CharacterClass.new("a-z"),
                                          Onibi::AST::CharacterClass.new("^0-9"),
                                          Onibi::AST::CharacterClass.new("[:digit:]")
                                        ])

    assert_equal expected, Onibi::V2::Parser.parse("[a-z][^0-9][[:digit:]]").ast
  end

  def test_escape_nodes_have_exact_kinds
    expected = Onibi::AST::Sequence.new([
                                          Onibi::AST::Escape.new(:digit),
                                          Onibi::AST::Escape.new(:not_digit),
                                          Onibi::AST::Escape.new(:linebreak),
                                          Onibi::AST::Escape.new(:word_boundary)
                                        ])

    assert_equal expected, Onibi::V2::Parser.parse("\\d\\D\\R\\b").ast
  end

  def test_boundary_and_match_position_escapes_have_exact_kinds
    expected = Onibi::AST::Sequence.new([
                                          Onibi::AST::Escape.new(:not_word_boundary),
                                          Onibi::AST::Escape.new(:start_match),
                                          Onibi::AST::Escape.new(:match_reset)
                                        ])

    assert_equal expected, Onibi::V2::Parser.parse("\\B\\G\\K").ast
  end

  def test_property_and_encoded_escape_nodes_have_exact_values
    expected = Onibi::AST::Sequence.new([
                                          Onibi::AST::Property.new("Alpha", false),
                                          Onibi::AST::Literal.new("A"),
                                          Onibi::AST::Literal.new("A"),
                                          Onibi::AST::Literal.new("A")
                                        ])

    assert_equal expected, Onibi::V2::Parser.parse("\\p{Alpha}\\u0041\\x41\\101").ast
  end
end
