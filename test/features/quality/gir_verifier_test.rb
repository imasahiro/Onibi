# frozen_string_literal: true

require "test_helper"

class GirVerifierTest < Minitest::Test
  FAILURE_CASES = {
    state_ids: "state IDs are not contiguous",
    state_opcode_payload: "state opcode payload is invalid",
    edge_state_range: "edge state is out of range",
    edge_order: "ordered edges are not preserved",
    action_opcode: "action opcode is invalid",
    action_opcode_payload: "match-reset payload is invalid",
    capture_slot: "capture slot is invalid",
    capture_close_unused_payload: "capture-close payload is invalid",
    counter_slot: "counter slot is invalid",
    capture_count: "capture count exceeds the operand limit",
    counter_count: "counter count exceeds the operand limit",
    subprogram_reference: "subprogram reference is invalid",
    semantic_capture_reference: "semantic capture reference is invalid",
    repeat_progress: "repeat progress is invalid",
    start_edge: "start edge is invalid",
    accept_state: "accept state has an outgoing edge",
    lookaround_subprogram: "lookaround subprogram is invalid",
    atomic_subprogram: "atomic subprogram is invalid",
    absence_subprogram: "absence subprogram is invalid",
    resolved_options: "option environment is unresolved"
  }.freeze

  FAILURE_CASES.each do |scenario, message|
    define_method("test_verifier_rejects_#{scenario}") do
      error = assert_raises(Onibi::RegexpError) do
        verifier_diagnostic(scenario)
      end

      assert_equal "GIR verification failed: #{message}", error.message
    end
  end

  def test_current_physical_action_limits_do_not_narrow
    result = verifier_diagnostic(:physical_limits)

    assert_equal 65_535, result.fetch(:capture_slot)
    assert_equal 65_535, result.fetch(:counter_slot)
  end

  def test_rseq_serialization_preserves_maximum_action_operands
    result = verifier_diagnostic(:action_operand_limits)

    assert_equal 65_535, result.fetch(:capture_boundary_slot)
    assert_equal 32_767, result.fetch(:capture_reference)
    assert_equal 65_535, result.fetch(:counter_slot)
    assert_equal 4_294_967_295, result.fetch(:counter_value)
    assert_equal 8, result.fetch(:position_assertion)
    assert_equal 10, result.fetch(:semantic_assertion_kind)
    assert_equal 65_535, result.fetch(:assertion_width)
    assert_equal 4_294_967_294, result.fetch(:subprogram_id)
    assert_equal 4, result.fetch(:subprogram_op)
  end

  def test_capture_producer_rejects_the_first_value_above_its_limit
    error = assert_raises(Onibi::RegexpError) do
      verifier_diagnostic(:capture_operand_overflow)
    end

    assert_equal "capture slot exceeds the GIR operand limit", error.message
  end

  def test_counter_producer_rejects_the_first_value_above_its_limit
    error = assert_raises(Onibi::RegexpError) do
      verifier_diagnostic(:counter_operand_overflow)
    end

    assert_equal "counter slot exceeds the GIR operand limit", error.message
  end

  def test_assertion_producer_rejects_the_first_width_above_its_limit
    error = assert_raises(Onibi::RegexpError) do
      verifier_diagnostic(:assertion_operand_overflow)
    end

    assert_equal "assertion width exceeds the GIR operand limit", error.message
  end

  def test_assertion_producer_rejects_the_first_kind_above_its_limit
    error = assert_raises(Onibi::RegexpError) do
      verifier_diagnostic(:assertion_kind_overflow)
    end

    assert_equal "assertion kind exceeds the GIR operand limit", error.message
  end

  def test_subprogram_producer_rejects_the_reserved_id
    error = assert_raises(Onibi::RegexpError) do
      verifier_diagnostic(:subprogram_operand_overflow)
    end

    assert_equal "subprogram count exceeds the GIR operand limit", error.message
  end

  def test_counter_producer_rejects_the_first_value_above_uint32
    error = assert_raises(Onibi::RegexpError) do
      verifier_diagnostic(:counter_value_overflow)
    end

    assert_equal "counter value exceeds the GIR operand limit", error.message
  end

  def test_verification_precedes_classification_optimization_and_publication
    source = File.read(File.join(PROJECT_ROOT, "ext/onibi/compiler.c"))
    compile = source[/static VALUE\nonibi_compiler_compile_body.*?^}/m]

    refute_nil compile
    assert_operator compile.index("onibi_compiler_pass_verify_gir"), :<,
                    compile.index("onibi_compiler_pass_classify")
    assert_operator compile.index("onibi_compiler_pass_classify"), :<,
                    compile.index("onibi_compiler_pass_optimize")
    assert_operator compile.index("onibi_compiler_pass_optimize"), :<,
                    compile.index("onibi_compiler_pass_publish")
  end

  def test_rseq_lowering_accepts_only_published_verified_gir
    source = File.read(File.join(PROJECT_ROOT, "ext/onibi/rseq.c"))
    lower = source[/static VALUE\nonibi_rseq_lower_body.*?^}/m]

    refute_nil lower
    assert_includes lower, "onibi_compiled_get(compiled)"
    assert_includes lower, "RSeq lowering requires immutable GIR"
  end

  def test_typed_gir_records_contain_no_ruby_semantic_object
    source = File.read(File.join(PROJECT_ROOT, "ext/onibi/gir.c"))
    records = %w[OnibiGAction OnibiGirStateEntry OnibiGirEdgeEntry OnibiGIRView]

    records.each do |name|
      declaration = source[/typedef struct \{.*?\} #{name};/m]

      refute_nil declaration, name
      refute_match(/\bVALUE\b/, declaration, name)
    end
  end

  def test_verifier_uses_owned_indexes_without_full_vector_rescans
    source = File.read(File.join(PROJECT_ROOT, "ext/onibi/gir.c"))

    assert_includes source, "onibi_gir_verify_edge_index_insert"
    assert_includes source, "physical_subprogram_references"
    assert_includes source, "semantic_subprogram_references"
    assert_includes source, "progress_slot_states"
    assert_includes source, "rb_ensure(onibi_gir_verify_body"
    assert_includes source, "onibi_allocation_owner_cleanup"
    refute_includes source, "onibi_gir_state_references_subprogram"
    refute_includes source, "onibi_gir_progress_slot_p"
  end

  def test_progress_slot_owner_cleans_up_after_verifier_failure
    regexp = Onibi::Regexp.new("(?:(?:a|))*")
    result = regexp.send(:__onibi_compile_failure_diagnostics__, 5)

    assert result.fetch(:raised)
    assert_equal result.fetch(:allocations_before), result.fetch(:allocations_after)
  end

  def test_production_gir_variants_pass_verification
    patterns = [
      "a", "(a)", "a{2,3}", "(a)\\1", "(?<x>a)\\g<x>",
      "(?>a)", "(?~a)", "(?=a)b", "(a)(?(1)b|c)"
    ]

    patterns.each do |pattern|
      regexp = Onibi::Regexp.new(pattern)
      result = regexp.send(:__onibi_compile_failure_diagnostics__, 5)

      assert result.fetch(:raised), pattern
      assert_equal result.fetch(:allocations_before), result.fetch(:allocations_after), pattern
    end
  end

  private

  def verifier_diagnostic(scenario)
    @regexp ||= Onibi::Regexp.new("a")
    @regexp.send(:__onibi_gir_verifier_diagnostics__, scenario)
  end
end
