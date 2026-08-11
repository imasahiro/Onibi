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
end
