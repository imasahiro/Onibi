# frozen_string_literal: true

require_relative "../../test_helper"

class CfgBlockCoalescingTest < Minitest::Test
  def test_lowerer_coalesces_a_straight_line_literal_run
    ast = Onibi::Parser.new("abc").parse
    graph = Onibi::HybridAutomata::CFG::Lowerer.new.call(ast)

    assert_equal 1, graph.blocks.length
    assert_equal 3, graph.operations.length
    assert_equal :return, graph.blocks.first.terminator.opcode
  end

  def test_coalescing_does_not_merge_alternation_control_blocks
    ast = Onibi::Parser.new("a|b").parse
    graph = Onibi::HybridAutomata::CFG::Lowerer.new.call(ast)

    assert_operator graph.blocks.length, :>, 1
    assert(graph.blocks.any? { |block| block.terminator.opcode == :choice })
  end
end
