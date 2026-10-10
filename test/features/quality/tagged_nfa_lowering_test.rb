# frozen_string_literal: true

require "test_helper"
require "timeout"

class TaggedNfaLoweringTest < Minitest::Test
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
end
