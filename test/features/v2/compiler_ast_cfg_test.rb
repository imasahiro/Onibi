# frozen_string_literal: true

require "test_helper"

class V2CompilerAstCfgTest < Minitest::Test
  NOOP_PASS = :pure_failure_memoization

  def test_each_ast_node_kind_lowers_to_the_expected_cfg_opcode
    nodes = [
      [Onibi::AST::Literal.new("a"), :match_literal],
      [Onibi::AST::CharacterClass.new("a-z"), :match_class],
      [Onibi::AST::Escape.new(:digit), :match_escape],
      [Onibi::AST::Property.new("Alpha", false), :match_property],
      [Onibi::AST::Any.new("."), :match_any],
      [Onibi::AST::Anchor.new(:anchor_start), :test_anchor],
      [Onibi::AST::Group.new(sequence("a"), 1, true, nil), :match_group],
      [Onibi::AST::Assertion.new(sequence("a"), :positive), :match_assertion],
      [Onibi::AST::OptionGroup.new(sequence("a"), true, false, true), :match_option_group],
      [Onibi::AST::AtomicGroup.new(sequence("a")), :match_atomic_group],
      [quantifier, :match_quantifier],
      [Onibi::AST::Backreference.new(1, false), :match_backreference],
      [Onibi::AST::Conditional.new(1, sequence("a"), sequence("b")), :match_conditional],
      [Onibi::AST::SubexpressionCall.new(1, false), :match_subexpression_call],
      [Onibi::AST::Absence.new(sequence("a")), :match_absence]
    ]

    nodes.each do |node, opcode|
      graph = compile(node).graph

      assert_equal [opcode], graph.operations.map(&:opcode), node.class.name
      assert_equal node, graph.operations.first.operand, node.class.name
      assert_equal :return, graph.blocks.fetch(graph.exit).terminator.opcode, node.class.name
    end
  end

  def test_composite_ast_preserves_operation_order_and_effect_state
    ast = sequence(
      "a",
      Onibi::AST::Group.new(sequence("b"), 1, true, "word"),
      Onibi::AST::Assertion.new(sequence("c"), :positive),
      quantifier,
      Onibi::AST::Backreference.new(1, false),
      Onibi::AST::SubexpressionCall.new(1, false),
      Onibi::AST::Absence.new(sequence("d"))
    )
    graph = compile(ast).graph

    assert_equal %i[match_literal match_group match_assertion match_quantifier
                    match_backreference match_subexpression_call match_absence],
                 graph.operations.map(&:opcode)
    assert_equal %i[captures checkpoints cursor], graph.effect_summary.reads.keys.sort
    assert_includes graph.effect_summary.writes.keys, :captures
    assert_includes graph.effect_summary.writes.keys, :checkpoints
  end

  def test_alternation_ast_creates_ordered_choice_edges_and_dominators
    ast = Onibi::AST::Alternation.new([sequence("ab"), sequence("cd")])
    graph = compile(ast).graph
    choice = graph.blocks.fetch(graph.entry)

    assert_equal :choice, choice.terminator.opcode
    assert_equal [[2, :alternative, 0], [3, :alternative, 1]], edge_shape(choice)
    assert_equal [0], graph.dominators.fetch(graph.entry)
    assert_equal [0, 2], graph.dominators.fetch(2)
    assert_equal [0, 3], graph.dominators.fetch(3)
    assert_equal [0, 1], graph.dominators.fetch(graph.exit)
    literals = graph.blocks.filter_map do |block|
      operation = block.operations.first
      operation.operand.value if operation&.opcode == :match_literal
    end
    assert_equal %w[ab cd], literals
  end

  def test_encoding_inference_walks_nested_ast_nodes
    literal = Onibi::AST::Literal.new("é".encode(Encoding::EUC_JP))
    ast = Onibi::AST::Sequence.new([
                                     Onibi::AST::Quantifier.new(literal, :+, 1, nil, :greedy)
                                   ])

    assert_equal Encoding::EUC_JP, compile(ast).encoding
  end

  def test_literal_coalescing_rewrites_nested_group_ast
    ast = Onibi::AST::Group.new(sequence("a", "b"), 1, true, "word")
    compiled = Onibi::V2::Compiler.compile(ast, passes: [:literal_coalescing])
    expected = Onibi::AST::Group.new(sequence("ab"), 1, true, "word")

    assert_equal expected, compiled.ast
    assert_equal expected, compiled.graph.operations.first.operand
  end

  def test_optimization_passes_transform_direct_ast_features
    cases = [
      [
        :impossible_branch_elimination,
        Onibi::AST::Alternation.new([sequence(Onibi::AST::Assertion.new(sequence, :negative)), sequence("a")]),
        sequence("a")
      ],
      [
        :duplicate_literal_branch_elimination,
        Onibi::AST::Alternation.new([sequence("a"), sequence("a")]),
        sequence("a")
      ],
      [
        :redundant_predicate_elimination,
        sequence(assertion("a"), assertion("a"), "b"),
        sequence(assertion("a"), "b")
      ],
      [
        :branch_threading,
        Onibi::AST::Alternation.new([sequence("a", "b"), sequence("a", "c")]),
        Onibi::AST::Sequence.new([
                                   Onibi::AST::Literal.new("a"),
                                   Onibi::AST::Alternation.new([sequence("b"), sequence("c")])
                                 ])
      ],
      [
        :auto_possessification,
        sequence(quantifier, "b"),
        sequence(quantifier(mode: :possessive), "b")
      ],
      [
        :dead_checkpoint_elimination,
        sequence(quantifier(kind: :bounded, minimum: 2, maximum: 2)),
        sequence(quantifier(kind: :bounded, minimum: 2, maximum: 2, mode: :possessive))
      ],
      [
        :loop_idiom_recognition,
        sequence("z", quantifier),
        sequence("z", quantifier(mode: :possessive))
      ]
    ]

    cases.each do |pass_name, ast, expected|
      compiled = Onibi::V2::Compiler.compile(ast, passes: [pass_name])

      assert_equal expected, compiled.ast, pass_name.to_s
      assert compiled.graph.operations.any? || compiled.graph.blocks.any?, pass_name.to_s
    end
  end

  private

  def compile(ast)
    Onibi::V2::Compiler.compile(ast, passes: [NOOP_PASS])
  end

  def sequence(*values)
    parts = values.map { |value| value.is_a?(String) ? Onibi::AST::Literal.new(value) : value }
    Onibi::AST::Sequence.new(parts)
  end

  def quantifier(kind: :+, minimum: 1, maximum: nil, mode: :greedy)
    quantifier_with(kind, minimum, maximum, mode)
  end

  def quantifier_with(kind, minimum, maximum, mode)
    Onibi::AST::Quantifier.new(Onibi::AST::Literal.new("x"), kind, minimum, maximum, mode)
  end

  def assertion(value)
    Onibi::AST::Assertion.new(sequence(value), :positive)
  end

  def edge_shape(block)
    block.successors.map { |edge| [edge.target, edge.kind, edge.priority] }
  end
end
