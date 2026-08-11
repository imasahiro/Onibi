# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenBackreferenceTest < Minitest::Test
  def test_generated_numbered_backreference
    ast = Onibi::Parser.new("(a)\\1").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal true, program.search("aa", 0, capture: false)
    assert_equal false, program.search("ab", 0, capture: false)
  end

  def test_generated_capture_conditional
    ast = Onibi::Parser.new("(a)?(?(1)b|c)").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal true, program.search("ab", 0, capture: false)
    assert_equal true, program.search("c", 0, capture: false)
  end
end
