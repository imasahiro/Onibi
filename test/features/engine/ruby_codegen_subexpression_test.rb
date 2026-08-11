# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenSubexpressionTest < Minitest::Test
  def test_generated_named_subexpression_call
    ast = Onibi::Parser.new("(?<x>a)\\g<x>").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal true, program.search("aa", 0, capture: false)
    assert_equal false, program.search("ab", 0, capture: false)
  end

  def test_generated_absence_stops_when_body_matches
    ast = Onibi::Parser.new("(?~a)b").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal false, program.search("b", 0, capture: false)
    assert_equal true, program.search("ab", 0, capture: false)
  end
end
