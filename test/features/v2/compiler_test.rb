# frozen_string_literal: true

require "test_helper"

class V2CompilerTest < Minitest::Test
  def test_compile_returns_optimized_cfg
    parsed = Onibi::V2::Parser.parse("a|a")
    compiled = Onibi::V2::Compiler.compile(parsed)

    assert_instance_of Onibi::V2::Compiler::OptimizedCFG, compiled
    assert_equal Onibi::AST::Sequence.new([Onibi::AST::Literal.new("a")]), compiled.ast
    assert_equal [0, 0, [[0, [[:match_literal, Onibi::AST::Literal.new("a")]], :return, []]]], cfg_shape(compiled.graph)
    assert_includes compiled.applied_passes, :duplicate_literal_branch_elimination
  end

  def test_each_optimization_pass_publishes_the_expected_cfg
    expected = [0, 0, [[0, [[:match_literal, Onibi::AST::Literal.new("ab")]], :return, []]]]

    compiled = Onibi::V2::Compiler.compile(Onibi::V2::Parser.parse("ab"), passes: [:literal_coalescing])

    assert_equal expected, cfg_shape(compiled.graph)
    assert_equal [:literal_coalescing], compiled.applied_passes
  end

  def test_every_declared_optimization_pass_has_a_stable_cfg_output
    expected = [0, 0, [[0, [[:match_literal, Onibi::AST::Literal.new("a")]], :return, []]]]
    pass_names = Onibi::V2::Compiler::Optimization::Pipeline::DEFAULT_PASS_NAMES

    pass_names.each do |pass_name|
      compiled = Onibi::V2::Compiler.compile(Onibi::V2::Parser.parse("a"), passes: [pass_name])

      assert_equal expected, cfg_shape(compiled.graph), pass_name.to_s
      assert_equal [pass_name], compiled.applied_passes, pass_name.to_s
    end
  end

  def test_cfg_shape_compares_branch_structure_and_opcodes
    compiled = Onibi::V2::Compiler.compile(Onibi::V2::Parser.parse("a|b"))
    expected = [
      0, 1,
      [
        [0, [], :choice, [[2, :alternative, 0], [3, :alternative, 1]]],
        [1, [], :return, []],
        [2, [[:match_literal, Onibi::AST::Literal.new("a")]], :jump, [[1, :flow, 0]]],
        [3, [[:match_literal, Onibi::AST::Literal.new("b")]], :jump, [[1, :flow, 0]]]
      ]
    ]

    assert_equal expected, cfg_shape(compiled.graph)
  end

  def test_compiled_unit_keeps_source_ast_for_runtime_regressions
    compiled = Onibi::V2::Compiler.compile(Onibi::V2::Parser.parse("a*b"))
    program = compiled.runtime_program

    assert program.match?("b")
    assert program.match?("aaab")
    refute program.match?("aaa")
  end

  private

  def cfg_shape(graph)
    [graph.entry, graph.exit, graph.blocks.map do |block|
      [block.id, block.operations.map { |operation| [operation.opcode, operation.operand] },
       block.terminator.opcode, block.successors.map { |edge| [edge.target, edge.kind, edge.priority] }]
    end]
  end
end
