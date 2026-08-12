# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenBooleanMatcherTest < Minitest::Test
  def test_boolean_surface_uses_generated_program_without_capture_result
    ast = Onibi::Parser.new("a+").parse
    matcher = Onibi::Codegen::BooleanMatcher.new(ast)

    assert matcher.match?("aaa")
    refute matcher.match?("bbb")
  end

  def test_captureless_boolean_program_does_not_allocate_capture_array
    ast = Onibi::Parser.new("a+").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    refute_includes program.source, "Array.new(0)"
    assert program.search("aaa", 0, capture: false)
  end

  def test_boolean_execution_skips_capture_array_for_capturing_pattern
    ast = Onibi::Parser.new("(a+)").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_includes program.source, "capture ? Array.new(1) : nil"
    assert program.search("aaa", 0, capture: false)
  end
end
