# frozen_string_literal: true

require "test_helper"
require "timeout"

class TaggedNfaLoweringTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)

  def nfa(pattern)
    Onibi::Regexp.new(pattern).send(:__onibi_nfa_diagnostics__)
  end

  def first_consuming_value(graph, edge)
    consume = graph[:edges].find do |candidate|
      candidate[:from] == edge[:to] && candidate[:kind] == :consume
    end
    graph[:states].find { |state| state[:id] == consume[:to] }[:value]
  end

  def eliminated(pattern)
    nfa(pattern).fetch(:eliminated)
  end

  def destination_values(graph, edges)
    values = graph[:states].to_h { |state| [state[:id], state[:value]] }
    edges.map { |edge| values.fetch(edge[:to]) }
  end

  def test_capture_actions_are_epsilon_transitions_before_elimination
    edges = nfa("(a)")[:edges]
    open_edge = edges.find { |edge| edge[:actions] == [:capture_open] }
    close_edge = edges.find { |edge| edge[:actions] == [:capture_close] }

    refute_nil open_edge
    refute_nil close_edge
    assert_equal :epsilon, open_edge[:kind]
    assert_equal :epsilon, close_edge[:kind]
    assert_equal(-1, open_edge[:from])
  end

  def test_assertion_is_an_ordered_epsilon_transition
    edges = nfa("^a")[:edges]
    start_edge = edges.find { |edge| edge[:from] == -1 }

    assert_equal :epsilon, start_edge[:kind]
    assert_equal [:assert_position], start_edge[:actions]
    assert_equal(-1, start_edge[:from])
  end

  def test_zero_width_action_order_is_stable
    first = nfa("(^a)")[:edges].find { |edge| edge[:from] == -1 }
    second = nfa("(^a)")[:edges].find { |edge| edge[:from] == -1 }

    assert_equal %i[capture_open assert_position], first[:actions]
    assert_equal first, second
  end

  def test_alternative_priority_is_visible_and_stable
    first = nfa("a|b")
    second = nfa("a|b")
    starts = first[:edges].select { |edge| edge[:from] == -1 }
    ordered_values = starts.map { |edge| first_consuming_value(first, edge) }

    assert_equal ["a".ord, "b".ord], ordered_values
    assert_equal first[:edges], second[:edges]
  end

  def test_action_free_nullable_paths_are_epsilon_transitions
    optional = nfa("a?")
    empty_group = nfa("(?:)")
    star = nfa("a*")

    [optional, empty_group, star].each do |graph|
      bypass = graph[:edges].find do |edge|
        edge[:from] == -1 && edge[:to] == graph[:accept]
      end
      refute_nil bypass
      assert_equal :epsilon, bypass[:kind]
      assert_empty bypass[:actions]
    end

    loop_edge = star[:edges].find do |edge|
      edge[:from] >= 0 && edge[:kind] == :epsilon && edge[:actions].empty? &&
        star[:states][edge[:to]][:kind] == :epsilon
    end
    refute_nil loop_edge
  end

  def test_empty_alternative_bypass_has_an_epsilon_boundary
    graph = nfa("(?:a|)b")
    b_state = graph[:states].find { |state| state[:value] == "b".ord }
    into_b = graph[:edges].select do |edge|
      edge[:to] == b_state[:id] && edge[:kind] == :consume
    end
    bypass = graph[:edges].find do |edge|
      edge[:from] == -1 && into_b.any? { |consume| consume[:from] == edge[:to] }
    end

    refute_nil bypass
    assert_equal :epsilon, bypass[:kind]
    assert_empty bypass[:actions]
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

    assert_equal ["a".ord, "b".ord],
                 destination_values(greedy, greedy[:start_edges])
    assert_equal ["b".ord, "a".ord],
                 destination_values(lazy, lazy[:start_edges])

    greedy_loop = greedy[:edges].find { |edge| edge[:from].zero? && edge[:to].zero? }
    lazy_loop = lazy[:edges].find { |edge| edge[:from].zero? && edge[:to].zero? }
    greedy_ops = greedy_loop[:action_program].map { |action| action[:op] }
    lazy_ops = lazy_loop[:action_program].map { |action| action[:op] }
    assert_equal [:progress], greedy_ops
    assert_equal [:progress], lazy_ops
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

    assert_equal [[], [[:capture_close, 1]], [[:capture_close, 3]]],
                 programs.sort_by(&:length)
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
