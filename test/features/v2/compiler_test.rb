# frozen_string_literal: true

require "test_helper"

class V2CompilerTest < Minitest::Test
  def test_compile_returns_optimized_cfg
    parsed = Onibi::V2::Parser.parse("a|a")
    compiled = Onibi::V2::Compiler.compile(parsed)

    assert_instance_of Onibi::V2::Compiler::OptimizedCFG, compiled
    assert_instance_of Onibi::AST::Sequence, compiled.ast
    assert_equal ["a"], compiled.ast.parts.map(&:value)
    assert_instance_of Onibi::HybridAutomata::CFG::Graph, compiled.graph
    assert_includes compiled.applied_passes, :duplicate_literal_branch_elimination
  end
end
