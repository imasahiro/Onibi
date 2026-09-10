# frozen_string_literal: true

require_relative "../../test_helper"

class RSeqSubprogramRepresentationTest < Minitest::Test
  ASSERT_SUBPROGRAM = 4
  RS_CALL = 6
  RS_ATOMIC = 7
  RS_ABSENT = 8

  def diagnostics(pattern, subject = "abc")
    Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, subject)
  end

  def test_lookaround_actions_reference_serialized_subprograms
    ["(?=a)b", "(?!a)b", "(?<=a)b", "(?<!a)b"].each do |pattern|
      info = diagnostics(pattern)
      action_index = info[:actions].index { |action| action[0] == ASSERT_SUBPROGRAM }
      refute_nil action_index, pattern

      subprogram_id = info[:action_arg32][action_index]
      assert_operator subprogram_id, :>, 0, pattern
      assert_operator subprogram_id, :<, info[:subprograms].length, pattern

      descriptor = info[:subprograms][subprogram_id]
      assert_operator descriptor[:entry_edge_count], :>, 0, pattern
      assert_operator descriptor[:entry_edge_base], :<, info[:edges].length, pattern
    end
  end

  def test_lookbehind_widths_are_character_widths_in_priority_order
    info = diagnostics("(?<=a|bc)x")
    descriptor = info[:subprograms].find { |entry| entry[:kind] == 3 }

    assert_equal [1, 2], info[:lookbehind_widths]
    assert_equal 0, descriptor[:width_base]
    assert_equal 2, descriptor[:width_count]
    assert_equal 2, descriptor[:entry_edge_count]
  end

  def test_assertion_capture_effects_are_explicit
    positive = diagnostics("(?=(a))a")[:subprograms].find { |entry| entry[:kind] == 2 }
    negative = diagnostics("(?!(a))b")[:subprograms].find { |entry| entry[:kind] == 2 }

    assert_equal 3, positive[:effects]
    assert_equal 0, negative[:effects]
  end

  def test_state_subprogram_references_resolve_by_kind
    cases = {
      "(?<x>a)\\g<x>" => [RS_CALL, 1, 0],
      "(?>a|ab)b" => [RS_ATOMIC, 4, 1],
      "(?~a)b" => [RS_ABSENT, 5, 2]
    }

    cases.each do |pattern, (state_op, kind, flags)|
      info = diagnostics(pattern)
      state_index = info[:states].index { |state| state[0] == state_op }
      refute_nil state_index, pattern

      subprogram_id = info[:state_payloads][state_index]
      descriptor = info[:subprograms][subprogram_id]
      assert_equal kind, descriptor[:kind], pattern
      assert_equal flags, descriptor[:flags], pattern
      assert_operator descriptor[:entry_edge_count], :>, 0, pattern
    end
  end

  def test_call_entry_actions_survive_physical_lowering
    info = diagnostics("(?<x>a)\\g<x>", "aa")
    call = info[:subprograms].find { |entry| entry[:kind] == 1 }
    entry_edge = info[:edges][call[:entry_edge_base]]

    assert_operator entry_edge[1], :>, 0
    action_index = (entry_edge[1] / 8) - 1
    assert_equal [1, 0, 0], info[:actions][action_index]
  end

  def test_called_subprogram_keeps_definition_site_options
    cases = [
      ["(?i:(?<x>a))(?-i:\\g<x>)", "AA", 1],
      ["(?-i:(?<x>a))(?i:\\g<x>)", "aA", 0]
    ]

    cases.each do |pattern, subject, expected_options|
      info = diagnostics(pattern, subject)
      call = info[:subprograms].find { |entry| entry[:kind] == 1 }
      assert_equal expected_options, call[:options], pattern
      assert_equal 2, call[:encoding_index], pattern

      expected = Regexp.new(pattern).match(subject)&.to_a
      actual = Onibi::Regexp.new(pattern).match(subject)&.to_a
      expected.nil? ? assert_nil(actual, pattern) : assert_equal(expected, actual, pattern)
    end
  end
end
