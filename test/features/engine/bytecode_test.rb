# frozen_string_literal: true

require "test_helper"

class BytecodeTest < Minitest::Test
  def test_public_construction_compiles_core_patterns_to_thompson_instructions
    regexp = Onibi::Regexp.new("a(b|c)*")
    program = regexp.instance_variable_get(:@bytecode)

    refute_empty program.instructions
    assert_includes program.opcodes, :char
    assert_includes program.opcodes, :split
    assert_includes program.opcodes, :save_start
    assert_equal :match, program.instructions.last.opcode
  end
end
