# frozen_string_literal: true

require_relative "../../test_helper"

class CodegenOptimizationPipelineTest < Minitest::Test
  def test_default_pipeline_coalesces_literals_and_prunes_branches_before_cfg_lowering
    ast = Onibi::Parser.new("(?!)|abc|abc").parse

    unit = Onibi::Codegen::Optimization::Pipeline.default.call(ast, options: [], encoding: Encoding::UTF_8)

    assert_equal 6, unit.applied_passes.length
    assert_optimized_literal(unit)
  end

  def test_cfg_preserves_alternation_priority_as_ordered_edges
    cfg = Onibi::Codegen::CFG::Lowerer.new.call(Onibi::Parser.new("a|ab").parse)

    assert_ordered_choice(cfg)
    assert cfg.frozen?
    assert cfg.blocks.all?(&:frozen?)
  end

  # rubocop:disable Metrics/AbcSize
  def test_cfg_operations_publish_explicit_state_tokens
    cfg = Onibi::Codegen::CFG::Lowerer.new.call(Onibi::Parser.new("(?<x>a)").parse)
    capture_operation = cfg.operations.find { |operation| operation.opcode == :match_group }

    refute_empty capture_operation.state_in
    refute_empty capture_operation.state_out
    refute_equal capture_operation.state_in[:captures], capture_operation.state_out[:captures]
    assert_equal :captures, capture_operation.state_out[:captures].domain
  end

  def test_cfg_regions_publish_aggregated_effect_summaries
    cfg = Onibi::Codegen::CFG::Lowerer.new.call(Onibi::Parser.new("(?<x>a)").parse)
    repeated_cfg = Onibi::Codegen::CFG::Lowerer.new.call(Onibi::Parser.new("a+").parse)

    assert_equal :captures, cfg.effect_summary.writes.fetch(:captures).first.domain
    assert_includes cfg.effect_summary.effects, :capture
    assert_includes repeated_cfg.effect_summary.effects, :repeat
    assert_equal cfg.blocks.map(&:effect_summary).flat_map(&:effects).uniq.sort,
                 cfg.effect_summary.effects.sort
  end

  def test_analyzer_publishes_capture_liveness_for_boolean_execution
    analysis = Onibi::Codegen::Analyzer.new.analyze(Onibi::Parser.new("(a)(b)\\1").parse)

    assert_equal [1, 2], analysis.capture_liveness.groups
    assert_equal [1], analysis.capture_liveness.semantic
    assert_equal [2], analysis.capture_liveness.dead_in_boolean
    assert_equal({ 1 => 0 }, analysis.capture_liveness.index_map)
  end

  def test_capture_liveness_keeps_all_captures_observable_for_match_results
    facts = Onibi::Codegen::Analyzer.new.analyze(Onibi::Parser.new("(a)(b)").parse).capture_liveness

    assert_equal [1, 2], facts.observable
    assert_empty facts.semantic
    assert_equal [1, 2], facts.dead_in_boolean
  end

  def test_analyzer_publishes_first_last_and_follow_for_sequence_boundaries
    ast = Onibi::Parser.new("abc").parse
    analysis = Onibi::Codegen::Analyzer.new.analyze(ast)
    parts = ast.parts
    facts = analysis.boundary_facts

    assert_equal ["a"], facts.first.map(&:value)
    assert_equal ["c"], facts.last.map(&:value)
    assert_equal [parts[1]], facts.follow.fetch(parts[0])
    assert_equal [parts[2]], facts.follow.fetch(parts[1])
    refute facts.nullable
  end

  def test_boundary_facts_preserve_nullable_and_width_information
    ast = Onibi::Parser.new("a*").parse
    analysis = Onibi::Codegen::Analyzer.new.analyze(ast)

    assert analysis.boundary_facts.nullable
    assert_equal 0, analysis.boundary_facts.width.minimum
    assert_nil analysis.boundary_facts.width.maximum
    assert_nil analysis.widths.fetch(ast).finite
  end

  # rubocop:enable Metrics/AbcSize
  def test_pipeline_can_disable_optimizations_without_disabling_cfg_construction
    ast = Onibi::Parser.new("abc").parse

    unit = Onibi::Codegen::Optimization::Pipeline.new([]).call(ast, options: [], encoding: Encoding::UTF_8)

    assert_empty unit.applied_passes
    literal_count = unit.cfg.operations.count { |operation| operation.opcode == :match_literal }
    assert_equal 3, literal_count
  end

  def test_pipeline_defers_cfg_lowering_until_the_graph_is_requested
    lowerer = Object.new
    calls = 0
    lowerer.define_singleton_method(:call) do |_ast|
      calls += 1
      :graph
    end

    unit = Onibi::Codegen::Optimization::Pipeline.new([], lowerer: lowerer).call(
      Onibi::Parser.new("abc").parse, options: [], encoding: Encoding::UTF_8
    )

    assert_equal 0, calls
    assert_equal :graph, unit.cfg
    assert_equal :graph, unit.cfg
    assert_equal 1, calls
  end

  def test_impossible_branch_pass_keeps_one_failure_when_every_branch_fails
    ast = Onibi::Parser.new("(?!)|(?!)").parse

    unit = Onibi::Codegen::Optimization::Pipeline.default.call(ast, options: [], encoding: Encoding::UTF_8)

    assert_instance_of Onibi::AST::Sequence, unit.ast
    assert_equal [:match_assertion], unit.cfg.operations.map(&:opcode)
  end

  def test_generated_program_exposes_the_optimized_cfg_and_pass_audit
    ast = Onibi::Parser.new("(?!)|abc|abc").parse

    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal [:match_literal], program.cfg.operations.map(&:opcode)
    assert_includes program.optimization_passes, :literal_coalescing
    assert_equal true, program.search("abc", 0, capture: false)
  end

  def test_ruby_generator_accepts_the_compilation_unit_boundary
    ast = Onibi::Parser.new("abc").parse
    unit = Onibi::Codegen::Optimization::Pipeline.default.call(ast, options: [], encoding: Encoding::UTF_8)

    source = Onibi::Codegen::RubyGenerator.compilation(unit)

    assert_includes source, 'input[position, 3] == "abc"'
  end

  def test_literal_coalescing_preserves_alternation_first_set_planning
    ast = Onibi::Parser.new("watson|sherlock|moriarty").parse

    program = Onibi::Codegen::GeneratedProgram.ast(ast)

    assert_equal :class_prefilter, program.search_plan.search_mode
  end

  def test_optimized_public_behavior_matches_mri
    pattern = "(?!)|abc|abc"
    input = "xxabc"
    expected = ::Regexp.new(pattern).match(input)
    actual = Onibi::Regexp.new(pattern).match(input)

    assert_equal [expected[0], expected.offset(0)], [actual[0], actual.offset(0)]
  end

  private

  def assert_ordered_choice(cfg)
    choice = cfg.blocks.find { |block| block.terminator.opcode == :choice }
    assert_equal [0, 1], choice.successors.map(&:priority)
    assert_equal %i[alternative alternative], choice.successors.map(&:kind)
  end

  def assert_optimized_literal(unit)
    assert_equal "abc", unit.ast.parts.fetch(0).value
    assert_equal [:match_literal], unit.cfg.operations.map(&:opcode)
  end
end
