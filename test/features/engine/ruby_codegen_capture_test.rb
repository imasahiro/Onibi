# frozen_string_literal: true

require_relative "../../test_helper"

class RubyCodegenCaptureTest < Minitest::Test
  def test_generated_capture_offsets_are_returned_without_public_objects
    ast = Onibi::Parser.new("(a)(?<word>b)").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal [0, 2, [[0, 1], [1, 2]]], program.search("ab", 0, capture: true)
  end

  def test_non_capture_group_does_not_add_capture_slot
    ast = Onibi::Parser.new("(?:a)b").parse
    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal [0, 2, []], program.search("ab", 0, capture: true)
  end
end
