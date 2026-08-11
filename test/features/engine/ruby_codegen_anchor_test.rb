# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenAnchorTest < Minitest::Test
  def test_generated_anchors_and_word_boundary
    ast = Onibi::Parser.new("\\Afoo\\z").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal true, program.search("foo", 0, capture: false)
    assert_equal false, program.search("xfoo", 0, capture: false)
  end

  def test_generated_multiline_anchors_and_boundary
    ast = Onibi::Parser.new("^foo$").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast, options: ["multiline"])

    assert_equal true, program.search("x\nfoo\ny", 2, capture: false)
    boundary = Onibi::Codegen::GeneratedProgram.ast(Onibi::Parser.new("\\bfoo\\b").parse)
    assert_equal true, boundary.search(" foo ", 1, capture: false)
  end

  def test_scoped_ignorecase_option_reaches_nested_emitter
    ast = Onibi::Parser.new("(?i:a)").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal true, program.search("A", 0, capture: false)
  end
end
