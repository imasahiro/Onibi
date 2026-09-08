# frozen_string_literal: true

require "test_helper"
require "timeout"

class TaggedNfaLoweringTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)

  def nfa(pattern)
    Onibi::Regexp.new(pattern).send(:__onibi_nfa_diagnostics__)
  end

  def eliminated(pattern)
    nfa(pattern).fetch(:eliminated)
  end

  def destination_values(graph, edges)
    values = graph[:states].to_h { |state| [state[:id], state[:value]] }
    edges.map { |edge| values.fetch(edge[:to]) }
  end

  def ordered_entry_paths(graph, terminal_kinds: [:consume])
    states = graph[:states].to_h { |state| [state[:id], state] }
    paths = []
    walk = lambda do |from, actions, visited|
      graph[:edges].each do |edge|
        next unless edge[:from] == from

        destination = states.fetch(edge[:to])
        combined = actions + edge[:actions]
        if edge[:kind] == :consume
          next unless terminal_kinds.include?(destination[:kind])

          paths << { state: destination, actions: combined }
        elsif terminal_kinds.include?(destination[:kind])
          paths << { state: destination, actions: combined }
        elsif !visited.include?(destination[:id])
          walk.call(destination[:id], combined, visited | [destination[:id]])
        end
      end
    end
    walk.call(-1, [], [-1])
    paths
  end

  def epsilon_path_actions(graph, start, target)
    paths = []
    walk = lambda do |from, actions, visited|
      graph[:edges].each do |edge|
        next unless edge[:from] == from && edge[:kind] == :epsilon

        combined = actions + edge[:actions]
        if edge[:to] == target
          paths << combined
        elsif !visited.include?(edge[:to])
          walk.call(edge[:to], combined, visited | [edge[:to]])
        end
      end
    end
    walk.call(start, [], [start])
    paths
  end

  def action_free_cycle_with_epsilon_and_consume?(graph)
    walk = lambda do |state, active, edge_kinds|
      graph[:edges].any? do |edge|
        next false unless edge[:from] == state && edge[:actions].empty?

        next_kinds = edge_kinds + [edge[:kind]]
        cycle_start = active.index(edge[:to])
        if cycle_start
          cycle_kinds = next_kinds.drop(cycle_start)
          next cycle_kinds.include?(:epsilon) && cycle_kinds.include?(:consume)
        end
        next false if active.include?(edge[:to])

        walk.call(edge[:to], active + [edge[:to]], next_kinds)
      end
    end
    walk.call(-1, [-1], [])
  end

  def test_capture_actions_are_epsilon_transitions_before_elimination
    graph = nfa("(a)")
    edges = graph[:edges]
    open_edge = edges.find { |edge| edge[:actions] == [:capture_open] }
    close_edge = edges.find { |edge| edge[:actions] == [:capture_close] }

    refute_nil open_edge
    refute_nil close_edge
    assert_equal :epsilon, open_edge[:kind]
    assert_equal :epsilon, close_edge[:kind]

    entry = ordered_entry_paths(graph).fetch(0)
    assert_equal [:capture_open], entry[:actions]
    assert_equal [:capture_close],
                 epsilon_path_actions(graph, entry[:state][:id], graph[:accept]).fetch(0)
  end

  def test_assertion_is_an_ordered_epsilon_transition
    graph = nfa("^a")
    start_edge = graph[:edges].find do |edge|
      edge[:actions] == [:assert_position]
    end

    assert_equal :epsilon, start_edge[:kind]
    assert_equal [:assert_position], start_edge[:actions]
    assert_equal [:assert_position], ordered_entry_paths(graph).fetch(0)[:actions]
  end

  def test_zero_width_action_order_is_stable
    first = ordered_entry_paths(nfa("(^a)")).fetch(0)
    second = ordered_entry_paths(nfa("(^a)")).fetch(0)

    assert_equal %i[capture_open assert_position], first[:actions]
    assert_equal first[:actions], second[:actions]
  end

  def test_alternative_priority_is_visible_and_stable
    first = nfa("a|b")
    second = nfa("a|b")
    ordered_values = ordered_entry_paths(first).map { |path| path[:state][:value] }

    assert_equal ["a".ord, "b".ord], ordered_values
    assert_equal first[:edges], second[:edges]
  end

  def test_action_free_nullable_paths_are_epsilon_transitions
    optional = nfa("a?")
    empty_group = nfa("(?:)")
    star = nfa("a*")

    [optional, empty_group, star].each do |graph|
      nullable_paths = epsilon_path_actions(graph, -1, graph[:accept])
      refute_empty nullable_paths
      assert nullable_paths.any?(&:empty?)
    end

    assert action_free_cycle_with_epsilon_and_consume?(star)
  end

  def test_nullable_cycle_requires_connected_epsilon_boundary
    consuming_self_loop = {
      states: [{ id: 0, kind: :consume }],
      edges: [
        { from: -1, to: 0, kind: :consume, actions: [] },
        { from: 0, to: 0, kind: :consume, actions: [] }
      ]
    }
    disconnected_epsilon_cycle = {
      states: [{ id: 0, kind: :epsilon }, { id: 1, kind: :epsilon }],
      edges: [
        { from: 0, to: 1, kind: :epsilon, actions: [] },
        { from: 1, to: 0, kind: :epsilon, actions: [] }
      ]
    }

    refute action_free_cycle_with_epsilon_and_consume?(consuming_self_loop)
    refute action_free_cycle_with_epsilon_and_consume?(disconnected_epsilon_cycle)
    assert action_free_cycle_with_epsilon_and_consume?(nfa("a*"))
  end

  def test_empty_alternative_bypass_has_an_epsilon_boundary
    graph = nfa("(?:a|)b")
    entries = ordered_entry_paths(graph)
    values = entries.map { |path| path[:state][:value] }

    assert_equal ["a".ord, "b".ord], values
    assert_empty entries.fetch(1)[:actions]
  end

  def test_eliminated_nullable_paths_match_mri
    cases = [
      ["a?", ""],
      ["a?", "a"],
      ["(?:)", "x"],
      ["a*", "aaa"],
      ["(?:a|)b", "b"],
      ["(?:a|)b", "ab"]
    ]

    cases.each do |pattern, input|
      expected = Regexp.new(pattern).match(input)
      actual = Onibi::Regexp.new(pattern).match(input)

      assert_equal expected.to_a, actual.to_a, pattern
      assert_equal [expected.begin(0), expected.end(0)],
                   [actual.begin(0), actual.end(0)], pattern
    end
  end

  def test_consuming_edges_are_native_nfa_records
    edges = nfa("ab")[:edges]
    transition = edges.find { |edge| edge[:kind] == :consume }
    source = File.read(File.join(ROOT, "ext/onibi/compiler.c"))
    nfa_source = File.read(File.join(ROOT, "ext/onibi/nfa.c"))

    assert_equal :consume, transition[:kind]
    assert_empty transition[:actions]
    refute_includes source, "Convert mutable GIR edges"
    refute_match(/builder->edges\.entries.*ONIBI_NFA_CONSUME/m, source)
    assert_includes nfa_source, "OnibiNfaStateVector states"
    assert_includes nfa_source, "edge->kind == ONIBI_NFA_CONSUME"
  end

  def test_elimination_keeps_nested_alternative_priority
    first = eliminated("(?:a|ab)|b")
    second = eliminated("(?:a|ab)|b")

    assert_equal ["a".ord, "a".ord, "b".ord],
                 destination_values(first, first[:start_edges])
    assert_equal first[:start_edges], second[:start_edges]

    expected = Regexp.new("(?:a|ab)|b").match("ab")
    actual = Onibi::Regexp.new("(?:a|ab)|b").match("ab")
    assert_equal [expected.to_a, expected.begin(0), expected.end(0)],
                 [actual.to_a, actual.begin(0), actual.end(0)]
  end

  def test_greedy_and_lazy_nullable_repeat_edges_keep_priority
    greedy = eliminated("(?:a|)*b")
    lazy = eliminated("(?:a|)*?b")

    assert_equal ["a".ord, "b".ord, "b".ord],
                 destination_values(greedy, greedy[:start_edges])
    assert_equal ["b".ord, "a".ord, "b".ord],
                 destination_values(lazy, lazy[:start_edges])

    greedy_loop = greedy[:edges].find do |edge|
      edge[:from] == edge[:to] &&
        edge[:action_program].any? { |action| action[:op] == :null_enter }
    end
    lazy_loop = lazy[:edges].find do |edge|
      edge[:from] == edge[:to] &&
        edge[:action_program].any? { |action| action[:op] == :null_enter }
    end
    greedy_ops = greedy_loop[:action_program].map { |action| action[:op] }
    lazy_ops = lazy_loop[:action_program].map { |action| action[:op] }
    expected_loop_ops =
      %i[null_continue counter_increment test_counter_lt null_enter]
    assert_equal expected_loop_ops, greedy_ops
    assert_equal expected_loop_ops, lazy_ops
  end

  def test_duplicate_empty_paths_emit_one_first_priority_edge
    first = eliminated("(?:||)a")
    second = eliminated("(?:||)a")

    assert_equal ["a".ord], destination_values(first, first[:start_edges])
    assert_equal first[:start_edges], second[:start_edges]
  end

  def test_elimination_concatenates_actions_in_semantic_path_order
    graph = eliminated("((^a))")
    start_program = graph[:start_edges].fetch(0).fetch(:action_program)
    accept_program = graph[:edges].fetch(0).fetch(:action_program)
    start_ops = start_program.map { |action| action[:op] }
    start_slots = start_program.map { |action| action[:slot] }
    accept_ops = accept_program.map { |action| action[:op] }
    accept_slots = accept_program.map { |action| action[:slot] }

    assert_equal %i[capture_open capture_open assert_position],
                 start_ops
    assert_equal [0, 2, nil], start_slots
    assert_equal %i[capture_close capture_close], accept_ops
    assert_equal [3, 1], accept_slots
  end

  def test_distinct_action_programs_to_one_destination_remain
    graph = eliminated("a(?:(b?)|(c?))d")
    d_state = graph[:states].find { |state| state[:value] == "d".ord }
    incoming = graph[:edges].select { |edge| edge[:to] == d_state[:id] }
    programs = incoming.map do |edge|
      edge[:action_program].map { |action| [action[:op], action[:slot]] }
    end

    expected = [
      [[:capture_open, 0], [:capture_close, 1]],
      [[:capture_open, 2], [:capture_close, 3]],
      [[:capture_close, 1]],
      [[:capture_close, 3]]
    ]
    assert_equal expected.sort_by(&:to_s), programs.sort_by(&:to_s)
    assert_equal programs.length, programs.uniq.length
  end

  def test_nullable_cycles_compile_and_match_mri
    cases = [
      ["(?:a|)*", "aaa"],
      ["(?:(a|)*)", "aa"],
      ["(?:|a)*?b", "aaab"]
    ]

    Timeout.timeout(2) do
      cases.each do |pattern, input|
        expected = Regexp.new(pattern).match(input)
        actual = Onibi::Regexp.new(pattern).match(input)

        assert_equal expected.to_a, actual.to_a, pattern
        assert_equal [expected.begin(0), expected.end(0)],
                     [actual.begin(0), actual.end(0)], pattern
      end
    end
  end

  def test_elimination_uses_source_adjacency_and_keyed_dedup
    source = File.read(File.join(ROOT, "ext/onibi/nfa.c"))
    closure_start = source.index("/* Traverse ordered epsilon paths")
    closure_end = source.index("typedef struct {", closure_start)
    closure_source = source[closure_start...closure_end]

    assert_includes source, "OnibiNfaAdjacencyRange"
    assert_includes source, "adjacency->edge_indices"
    assert_includes source, "onibi_nfa_dedup_find"
    assert_match(/epsilon (?:"\s*")?cycle has no progress action/, source)
    refute_includes source, "onibi_nfa_edge_seen"
    refute_includes closure_source, "closure->nfa->edges.count"
  end

  def test_eliminated_gir_has_no_epsilon_states
    %w[a (a?) (?:a|)*b].each do |pattern|
      kinds = eliminated(pattern)[:states].map { |state| state[:kind] }.uniq
      assert_empty kinds - %i[consume accept]
    end
  end
end
