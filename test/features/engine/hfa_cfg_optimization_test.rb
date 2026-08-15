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

  def test_compilation_unit_publishes_immutable_width_and_effect_facts
    unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
      Onibi::Parser.new("(?<x>a)?b+").parse, options: [], encoding: Encoding::UTF_8
    )

    facts = unit.facts
    optional = facts.operations.first
    repeated = facts.operations.last

    assert facts.frozen?
    assert facts.operations.frozen?
    assert optional.frozen?
    assert_equal true, optional.nullable
    assert_equal [0, 1], optional.width
    assert_includes optional.writes, :captures
    assert_equal ["a"], optional.first
    assert_equal ["a"], optional.last
    assert_equal [1, nil], repeated.width
    assert repeated.frozen?
    assert facts.blocks.all?(&:frozen?)
  end

  def test_compilation_unit_partitions_operations_into_effect_regions
    unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
      Onibi::Parser.new("a|ab|(?<x>c)\\k<x>").parse, options: [], encoding: Encoding::UTF_8
    )

    regions = unit.regions

    assert regions.frozen?
    assert regions.all?(&:frozen?)
    assert_equal(unit.cfg.operations.size, regions.sum { |region| region.operations.size })
    assert_equal unit.cfg.operations.map(&:object_id).sort,
                 regions.flat_map(&:operations).map(&:object_id).sort
    assert_equal unit.cfg.blocks.map(&:id).sort, regions.flat_map(&:blocks).sort
    assert(regions.any? { |region| region.kind == :regular_tagged })
    assert(regions.any? { |region| region.kind == :semantic })

    regular_unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
      Onibi::Parser.new("abc").parse, options: [], encoding: Encoding::UTF_8
    )
    assert(regular_unit.regions.any? { |region| region.kind == :regular_effect_free })
  end

  def test_compilation_unit_publishes_one_immutable_placeholder_component_graph
    unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
      Onibi::Parser.new("a|(?<x>b)+|\\k<x>").parse, options: [], encoding: Encoding::UTF_8
    )

    graph = unit.component_graph

    assert graph.frozen?
    assert graph.nodes.frozen?
    assert graph.nodes.all?(&:frozen?)
    assert_equal [:tail_nfa], graph.nodes.map(&:kind)
    assert_equal graph.nodes.fetch(0).id, graph.entry
    assert graph.edges.frozen?
    assert graph.accepts.frozen?
  end

  def test_position_nfa_preserves_mri_results_across_three_bitset_segments
    [511, 512, 513].each do |length|
      source = "a" * length
      onibi = Onibi::Regexp.new(source)
      mri = Regexp.new(source)
      input = "x#{source}y"

      assert_equal mri.match?(input), onibi.match?(input)
      assert_equal mri.match(input)&.to_a, onibi.match(input)&.to_a

      unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
        Onibi::Parser.new(source).parse, options: [], encoding: Encoding::UTF_8
      )
      nfa = unit.position_nfas.fetch(0)

      assert nfa.frozen?
      assert nfa.positions.all?(&:frozen?)
      assert_equal length, nfa.positions.length
      assert_equal [0], nfa.first
      assert_equal [length - 1], nfa.last
      assert_equal [1], nfa.follow.fetch(0)
      assert_equal [length - 1], nfa.reach.fetch("a").last(1)
      refute nfa.nullable
      assert_equal (length + 511) / 512, nfa.segments.length
    end
  end

  def test_head_dfa_budget_preserves_public_results_and_publishes_complete_rows
    [0, 1, 4_096].each do |row_budget|
      source = "ab|a"
      input = "za"
      onibi = Onibi::Regexp.new(source)
      mri = Regexp.new(source)

      assert_equal mri.match?(input), onibi.match?(input)
      assert_equal mri.match(input)&.to_a, onibi.match(input)&.to_a

      unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
        Onibi::Parser.new(source).parse, options: [], encoding: Encoding::UTF_8
      )
      dfa = unit.head_dfa(row_budget: row_budget)

      assert dfa.frozen?
      assert dfa.states.all?(&:frozen?)
      assert(dfa.states.all? { |state| state.transitions.length == dfa.alphabet.length })
      assert dfa.states.any?(&:border?) if row_budget < 4_096
    end
  end

  def test_border_execution_publishes_immutable_tail_activations
    unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
      Onibi::Parser.new("abc").parse, options: [], encoding: Encoding::UTF_8
    )

    activations = unit.tail_activations(input: "zabc")

    assert activations.frozen?
    assert activations.all?(&:frozen?)
    assert_equal [1], activations.map(&:start_offset).uniq
    assert_equal [4], activations.map(&:end_offset).uniq
  end

  def test_border_execution_deduplicates_overlapping_starts_without_losing_accepts
    source = "a|aa"
    input = "aa"
    onibi = Onibi::Regexp.new(source)
    mri = Regexp.new(source)
    assert_equal mri.match?(input), onibi.match?(input)
    assert_equal mri.match(input)&.to_a, onibi.match(input)&.to_a

    unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
      Onibi::Parser.new(source).parse, options: [], encoding: Encoding::UTF_8
    )
    activations = unit.tail_activations(input: input)

    assert_equal([[0, 0, 1], [0, 1, 2], [1, 0, 2]],
                 activations.map do |activation|
                   [activation.component_id, activation.start_offset,
                    activation.end_offset]
                 end)
    assert(activations.all? { |activation| activation.segments.all?(&:frozen?) })
  end

  def test_regexp_publishes_one_immutable_compilation_program
    regexp = Onibi::Regexp.new("abc")
    refute regexp.instance_variable_defined?(:@hfa_compilation_program)
    assert regexp.match?("abc")

    input = "zabcabc"
    mri = Regexp.new("abc")
    calls = [
      -> { mri.match?(input) },
      -> { mri.match(input)&.to_a },
      -> { input.scan(mri) },
      -> { input.gsub(mri, "X") }
    ]
    expected = calls.map(&:call)
    results = [
      -> { regexp.match?(input) },
      -> { regexp.match(input)&.to_a },
      -> { regexp.scan(input) },
      -> { regexp.gsub(input, "X") }
    ].map { |call| Thread.new(&call) }.map(&:value)
    assert_equal expected, results

    programs = 8.times.map do
      Thread.new { regexp.send(:hfa_compilation_program) }
    end.map(&:value)

    assert programs.all?(&:frozen?)
    assert_same programs.first, programs.drop(1).first
    assert programs.first.component_graph.frozen?
    assert programs.first.head_dfa.frozen?
  end

  def test_mandatory_string_extraction_respects_nullable_and_assertion_paths
    cases = {
      "header(?:alpha|bravo)" => [["header"], %w[alpha bravo]],
      "(?:alpha)?suffix" => [["suffix"]],
      "(?:alpha)*" => [],
      "(?=alpha)omega" => [["omega"]]
    }

    cases.each do |source, expected_literals|
      unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
        Onibi::Parser.new(source).parse, options: [], encoding: Encoding::UTF_8
      )
      actual = unit.mandatory_strings.map(&:literals)
      assert_equal expected_literals, actual

      onibi = Onibi::Regexp.new(source)
      mri = Regexp.new(source)
      ["#{source}x", "prefix#{source}", "nomatch"].each do |input|
        assert_equal mri.match?(input), onibi.match?(input)
        expected_match = mri.match(input)&.to_a
        actual_match = onibi.match(input)&.to_a
        expected_match.nil? ? assert_nil(actual_match) : assert_equal(expected_match, actual_match)
      end
    end
  end

  def test_string_events_are_monotonic_immutable_and_mri_safe
    source = "prefixalpha"
    input = "zprefixalphaprefixalpha"
    onibi = Onibi::Regexp.new(source)
    mri = Regexp.new(source)
    assert_equal mri.match?(input), onibi.match?(input)
    assert_equal input.scan(mri), onibi.scan(input)
    assert_equal input.gsub(mri, "X"), onibi.gsub(input, "X")

    unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
      Onibi::Parser.new(source).parse, options: [], encoding: Encoding::UTF_8
    )
    events = unit.string_events(input: input)

    assert events.frozen?
    assert events.all?(&:frozen?)
    assert_equal([[0, 1, 12, 0], [0, 12, 23, 0]],
                 events.map do |event|
                   [event.component_id, event.start_offset,
                    event.end_offset, event.alternative_id]
                 end)
    refute(events.any? { |event| event.respond_to?(:literal) })
  end

  def test_event_coordinator_enforces_inclusive_bounded_and_unbounded_windows
    source = "head(?:alpha|bravo)"
    input = "headalpha--headbravo"
    onibi = Onibi::Regexp.new(source)
    mri = Regexp.new(source)
    assert_equal mri.match(input)&.to_a, onibi.match(input)&.to_a

    unit = Onibi::HybridAutomata::Optimization::Pipeline.new([]).call(
      Onibi::Parser.new(source).parse, options: [], encoding: Encoding::UTF_8
    )
    events = unit.string_events(input: input)
    bounded = unit.coordinate_events(events: events, predecessor_end: 4,
                                     minimum_offset: 0, maximum_offset: 5)
    unbounded = unit.coordinate_events(events: events, predecessor_end: 4,
                                       minimum_offset: 0, maximum_offset: nil)

    assert bounded.frozen?
    assert bounded.all?(&:frozen?)
    assert(bounded.all? { |activation| activation.offset.between?(0, 5) })
    assert unbounded.length >= bounded.length
    assert_equal [0, 0], bounded.map(&:offset).minmax
  end
end
