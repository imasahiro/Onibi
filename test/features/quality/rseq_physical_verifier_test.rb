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

  def test_rejects_bad_backreference_descriptors
    %i[backref_descriptor_empty backref_descriptor_offset
       backref_descriptor_list_range backref_descriptor_flags
       backref_descriptor_capture backref_state_flags].each do |scenario|
      assert_invalid("(a)\\1", scenario)
    end
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

  def test_rejects_physical_nullable_owner_contract_violations
    scenarios = %i[
      nullable_owner_range nullable_owner_overlap nullable_owner_wrong_base
      nullable_counter_alias nullable_progress_alias
    ]

    scenarios.each do |scenario|
      pattern = "(?:a|)*b"
      pattern = "(?:a|)*b(?:c|)*d" if scenario == :nullable_owner_overlap
      assert_invalid(pattern, scenario)
    end
  end

  def test_rejects_physical_nullable_initialization_violations
    %i[nullable_uninitialized_all nullable_uninitialized_one_path
       nullable_completed_read].each do |scenario|
      regexp = Onibi::Regexp.new("(?:(a|))*b")
      error = assert_raises(ArgumentError) do
        regexp.send(:__onibi_rseq_verifier_diagnostics__, scenario)
      end
      assert_equal "Onibi RSeq nullable owner is not initialized", error.message
    end
  end

  def test_physical_nullable_verifier_handles_bounded_branching
    regexp = Onibi::Regexp.new("(?:(a?|b?|c?|d?)){9}")

    assert regexp.send(:__onibi_rseq_verifier_diagnostics__,
                       :nullable_bounded_branching)
  end

  def test_physical_nullable_verifier_keeps_owner_facts_compact
    pattern = "(?:a|)*b{2,100}c{2,100}d{2,100}"
    regexp = Onibi::Regexp.new(pattern)
    diagnostics = regexp.send(:__onibi_diagnostics__, "")
    owner_bases = diagnostics.fetch(:actions).filter_map do |op, _flags, base|
      base if op == 10
    end.uniq

    assert_equal 1, owner_bases.length
    assert_operator diagnostics.fetch(:counter_count), :>=, 6
    assert regexp.send(:__onibi_rseq_verifier_diagnostics__,
                       :nullable_compact_facts)
  end

  def test_valid_physical_nullable_owner_flows_remain_verified
    ["(?:a|)*b", "(?:(a|))*b", "(?:(a?|b?)){9}"].each do |pattern|
      regexp = Onibi::Regexp.new(pattern)
      assert regexp.send(:__onibi_diagnostics__, "aa").fetch(:rseq), pattern
    end
  end

  def test_physical_nullable_verifier_uses_bounded_owner_facts
    source = File.read(File.expand_path("../../../ext/onibi/rseq_runtime.c", __dir__))

    assert_includes source, "nullable->owner_count + bit_count - 1U"
    assert_includes source, "nullable->outgoing_heads"
    assert_includes source, "nullable->incoming_heads"
    assert_includes source, "nullable->worklist"
    assert_includes source, "Onibi RSeq nullable reachability queue is too large"
    assert_includes source, "Onibi RSeq nullable worklist is too large"
    refute_match(/for \(uint32_t state = 0; state < header->state_count; state\+\+\).*?
                 view->edges/mx, source)
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
