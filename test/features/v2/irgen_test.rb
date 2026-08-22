# frozen_string_literal: true

require "test_helper"

class V2IRGenTest < Minitest::Test
  def test_dfa_lowers_to_yarv_ir
    parsed = Onibi::V2::Parser.parse("a")
    cfg = Onibi::V2::Compiler.compile(parsed).graph
    tnfa = Onibi::V2::Automata::GlushkovTNFA.from_cfg(cfg)
    dfa = Onibi::V2::Automata::DFA.from_tnfa(tnfa)
    program = Onibi::V2::IRGen::YARVIR.generate(dfa)

    assert_instance_of Onibi::V2::IRGen::YARVIR::Program, program
    assert_equal :start, program.instructions.first.opcode
    assert_includes program.instructions.map(&:opcode), :match
    assert_equal :accept, program.instructions.last.opcode
    match_operands = program.instructions.select { |instruction| instruction.opcode == :match }.map(&:operand)
    assert_equal [[:match_literal, Onibi::AST::Literal.new("a")]], match_operands
  end

  def test_ir_contains_state_id_jump_for_dfa_edge
    parsed = Onibi::V2::Parser.parse("a.")
    cfg = Onibi::V2::Compiler.compile(parsed).graph
    tnfa = Onibi::V2::Automata::GlushkovTNFA.from_cfg(cfg)
    dfa = Onibi::V2::Automata::DFA.from_tnfa(tnfa)
    program = Onibi::V2::IRGen::YARVIR.generate(dfa)

    jumps = program.instructions.select { |instruction| instruction.opcode == :jump }
    assert_equal [1], jumps.map(&:operand)
  end
end
