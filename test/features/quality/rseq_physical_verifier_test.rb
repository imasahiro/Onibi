# frozen_string_literal: true

require "test_helper"

class RseqPhysicalVerifierTest < Minitest::Test
  def test_rejects_bad_section_layout
    assert_invalid("a", :section_order)
    assert_invalid("a", :section_alignment)
    assert_invalid("a", :section_overflow)
  end

  def test_rejects_bad_state_and_edge_references
    assert_invalid("a", :state_edge_range)
    assert_invalid("a", :start_edge_count)
    assert_invalid("a", :state_opcode)
    assert_invalid("a", :state_any_payload)
    assert_invalid("a", :edge_destination)
  end

  def test_rejects_action_boundaries_and_termination
    error = assert_invalid("(a)", :action_boundary)
    assert_match(/action offset/, error.message)
    assert_invalid("(a)", :action_termination)
  end

  def test_rejects_each_action_operand_form
    cases = %i[
      action_capture action_match_reset action_position action_subprogram
      action_test_capture action_counter_set action_counter_add
      action_counter_test action_progress
    ]

    cases.each do |scenario|
      error = assert_invalid("(a)", scenario)
      assert_match(/capture test/, error.message) if scenario == :action_test_capture
    end
  end

  def test_rejects_bad_class_and_literal_descriptors
    assert_invalid("[a]", :class_descriptor)
    assert_invalid("\\p{Alpha}", :class_ctype)
    assert_invalid("[\\p{Alpha}a]", :mixed_ctype)
    assert_invalid("a", :literal_descriptor)
  end

  def test_rejects_bad_subprogram_contracts
    assert_invalid("a", :root_entry)
    assert_invalid("(?=a)b", :subprogram_range)
    assert_invalid("(?=a)b", :subprogram_flags)
    assert_invalid("(?=a)b", :subprogram_effects)
    assert_invalid("(?=a)b", :subprogram_entry)
    assert_invalid("(?<=a)b", :subprogram_width)
    assert_invalid("(?=a)b", :subprogram_options)
    assert_invalid("(?=a)b", :subprogram_encoding)
  end

  def test_rejects_inconsistent_feature_and_executor_metadata
    assert_invalid("(a)", :features)
    assert_invalid("(?=a)", :zero_width_only)
    assert_invalid("a", :exec_kind)
    assert_invalid("a", :first_bitmap)
    assert_invalid("abc", :prefix)
  end

  def test_zero_width_feature_uses_only_root_reachable_states
    regexp = Onibi::Regexp.new("(?=a)")

    assert regexp.send(:__onibi_diagnostics__, "a").fetch(:rseq)
  end

  def test_counter_count_is_the_exact_referenced_resource_range
    assert_invalid("a", :counter_count_none)
    assert_invalid("(?:a|)*b(?:c|)*d", :progress_counter_count)
  end

  def test_verifier_uses_owned_input_sized_work_arrays
    source = File.read(File.expand_path("../../../ext/onibi/rseq_runtime.c", __dir__))

    refute_includes source, "alloca(header->capture_count)"
    assert_match(/semantic_captures =.*?onibi_owned_realloc/m, source)
    assert_match(/root_worklist = onibi_owned_realloc/m, source)
  end

  def test_generated_program_stays_verified_for_each_execution_class
    ["a", "(?=a)b", "(?<x>a)\\g<x>"].each do |pattern|
      regexp = Onibi::Regexp.new(pattern)
      assert regexp.send(:__onibi_diagnostics__, "aa").fetch(:rseq), pattern
    end
  end

  private

  def assert_invalid(pattern, scenario)
    regexp = Onibi::Regexp.new(pattern)
    assert_raises(ArgumentError, "#{pattern}: #{scenario}") do
      regexp.send(:__onibi_rseq_verifier_diagnostics__, scenario)
    end
  end
end
