# frozen_string_literal: true

require "test_helper"

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
end
