# frozen_string_literal: true

require_relative "../../test_helper"

class HfaCfgOptimizationTest < Minitest::Test
  def test_default_pipeline_coalesces_literals_and_prunes_branches_before_hfa_lowering
    ast = Onibi::Parser.new("(?!)|abc|abc").parse

    unit = Onibi::HybridAutomata::Optimization::Pipeline.default.call(
      ast, options: [], encoding: Encoding::UTF_8
    )

    assert_equal 11, unit.applied_passes.length
    assert_equal "abc", unit.ast.parts.fetch(0).value
    assert_equal [:match_literal], unit.cfg.operations.map(&:opcode)
  end

  # rubocop:disable Metrics/AbcSize
  def test_cfg_preserves_alternation_priority_as_ordered_edges
    cfg = Onibi::HybridAutomata::CFG::Lowerer.new.call(Onibi::Parser.new("a|ab").parse)
    choice = cfg.blocks.find { |block| block.terminator.opcode == :choice }

    assert_equal [0, 1], choice.successors.map(&:priority)
    assert_equal %i[alternative alternative], choice.successors.map(&:kind)
    assert cfg.frozen?
    assert cfg.blocks.all?(&:frozen?)
  end

  def test_cfg_operations_publish_capture_state_tokens
    cfg = Onibi::HybridAutomata::CFG::Lowerer.new.call(Onibi::Parser.new("(?<x>a)").parse)
    capture_operation = cfg.operations.find { |operation| operation.opcode == :match_group }

    refute_empty capture_operation.state_in
    refute_empty capture_operation.state_out
    refute_equal capture_operation.state_in[:captures], capture_operation.state_out[:captures]
    assert_equal :captures, capture_operation.state_out[:captures].domain
  end

  def test_pipeline_can_disable_optimizations_without_disabling_cfg_construction
    unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
      Onibi::Parser.new("abc").parse, options: [], encoding: Encoding::UTF_8
    )

    assert_empty unit.applied_passes
    literal_count = unit.cfg.operations.count do |operation|
      operation.opcode == :match_literal
    end
    assert_equal 3, literal_count
  end

  def test_pipeline_defers_cfg_lowering_until_the_graph_is_requested
    lowerer = Object.new
    calls = 0
    lowerer.define_singleton_method(:call) do |_ast|
      calls += 1
      :graph
    end

    unit = Onibi::HybridAutomata::Optimization::Pipeline.new([], lowerer: lowerer).call(
      Onibi::Parser.new("abc").parse, options: [], encoding: Encoding::UTF_8
    )

    assert_equal 0, calls
    assert_equal :graph, unit.cfg
    assert_equal :graph, unit.cfg
    assert_equal 1, calls
  end

  def test_cfg_regions_publish_aggregated_effect_summaries
    cfg = Onibi::HybridAutomata::CFG::Lowerer.new.call(Onibi::Parser.new("(?<x>a)").parse)
    repeated_cfg = Onibi::HybridAutomata::CFG::Lowerer.new.call(Onibi::Parser.new("a+").parse)

    assert_equal :captures, cfg.effect_summary.writes.fetch(:captures).first.domain
    assert_includes cfg.effect_summary.effects, :capture
    assert_includes repeated_cfg.effect_summary.effects, :repeat
  end
  # rubocop:enable Metrics/AbcSize
end
