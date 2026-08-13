# frozen_string_literal: true

require_relative "../../test_helper"

class CodegenOptimizationPipelineTest < Minitest::Test
  def test_default_pipeline_coalesces_literals_and_prunes_branches_before_cfg_lowering
    ast = Onibi::Parser.new("(?!)|abc|abc").parse

    unit = Onibi::Codegen::Optimization::Pipeline.default.call(ast, options: [], encoding: Encoding::UTF_8)

    assert_equal %i[impossible_branch_elimination duplicate_literal_branch_elimination literal_coalescing],
                 unit.applied_passes
    assert_optimized_literal(unit)
  end

  def test_cfg_preserves_alternation_priority_as_ordered_edges
    cfg = Onibi::Codegen::CFG::Lowerer.new.call(Onibi::Parser.new("a|ab").parse)

    assert_ordered_choice(cfg)
    assert cfg.frozen?
    assert cfg.blocks.all?(&:frozen?)
  end

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
