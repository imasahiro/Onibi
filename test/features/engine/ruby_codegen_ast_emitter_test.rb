# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenAstEmitterTest < Minitest::Test
  def test_generated_ast_matches_literal_sequence_and_alternation
    ast = Onibi::Parser.new("ab|aあ").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal true, program.search("ab", 0, capture: false)
    assert_equal true, program.search("aあ", 0, capture: false)
    assert_equal false, program.search("ac", 0, capture: false)
  end

  def test_generated_ast_handles_dot_class_and_property_without_pattern_relexing
    ast = Onibi::Parser.new(".[a-z]\\d").parse
    source = Onibi::Codegen::RubyGenerator.ast(ast)
    program = Onibi::Codegen::GeneratedProgram.new(source)

    assert_equal true, program.search("ab7", 0, capture: false)
    assert_equal false, program.search("a-7", 0, capture: false)
  end

  def test_active_ignorecase_option_reaches_generated_literal_predicate
    ast = Onibi::Parser.new("Ab").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast, options: ["ignorecase"])

    assert_equal true, program.search("aB", 0, capture: false)
  end

  def test_generated_source_scales_with_sequence_length
    ast = Onibi::Parser.new("a" * 40).parse
    source = Onibi::Codegen::RubyGenerator.ast(ast)

    assert_operator source.length, :<, 40 * 400
  end

  def test_straight_line_literals_are_coalesced_into_one_comparison
    ast = Onibi::Parser.new("abcdefgh").parse
    source = Onibi::Codegen::RubyGenerator.ast(ast)

    assert_equal 1, source.scan("input[position,").length
    assert_includes source, '== "abcdefgh"'
  end

  def test_generated_source_shares_repeated_fixed_literals
    prefix = "abcdefghij" * 2
    ast = Onibi::Parser.new("#{prefix}[a]|#{prefix}[b]").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast, optimizations: [])

    assert_includes program.source, "ONIBI_LITERAL_VALUES"
    assert_equal 1, program.source.scan(prefix.dump).length
    assert_equal 2, program.source.scan("== ONIBI_LITERAL_VALUES").length
  end

  def test_ascii_single_literal_is_inlined_as_a_byte_comparison
    program = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("a").parse)

    assert_includes program.source, "getbyte"
    assert program.search("a", 0, capture: false)
    refute program.search("b", 0, capture: false)
  end
end
