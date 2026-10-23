# frozen_string_literal: true

require "test_helper"

class GirStateIdContractTest < Minitest::Test
  EXTENSION_ROOT = File.expand_path("../../../ext/onibi", __dir__)

  def test_gir_builder_uses_a_fixed_width_id_and_reserved_sentinel
    header = source("onibi_gir_internal.h")
    gir = source("gir.c")
    nfa = source("nfa.c")
    rseq = source("rseq.c")

    assert_includes header, "typedef uint32_t OnibiGirStateId;"
    assert_includes header, "#define ONIBI_GIR_STATE_NONE UINT32_MAX"
    assert_includes gir, "OnibiGirStateId id;"
    assert_includes gir, "OnibiGirStateId from;"
    assert_includes gir, "OnibiGirStateId to;"
    assert_includes gir, "OnibiGirStateId next_id;"
    assert_includes nfa, "const OnibiGirStateId *state_map;"
    assert_includes rseq, "OnibiGirStateId from;"
    assert_includes rseq, "OnibiGirStateId to;"

    refute_match(/\blong\s+(?:id|from|to|next_id|accept|root_entry);/, gir)
    refute_match(/\blong\s+(?:from|to);/, rseq)
  end

  def test_gir_boundaries_check_the_reserved_id_before_narrowing
    gir = source("gir.c")
    nfa = source("nfa.c")
    rseq = source("rseq.c")

    gir_helper = gir[/static OnibiStateId
onibi_gir_state_id_to_rseq_state_id.*?^}/m]
    nfa_helper = nfa[/static OnibiNfaStateId
onibi_gir_state_id_to_nfa_state_id.*?^}/m]

    refute_nil gir_helper
    refute_nil nfa_helper
    assert_includes gir_helper, "id == ONIBI_GIR_STATE_NONE"
    assert_includes gir_helper, "return (OnibiStateId)id;"
    assert_includes nfa_helper, "id == ONIBI_GIR_STATE_NONE"
    assert_includes nfa_helper, "(uint64_t)id >= (uint64_t)state_count"
    assert_includes nfa_helper, "return (OnibiNfaStateId)id;"
    assert_includes rseq, "onibi_gir_state_id_to_rseq_state_id(record->to)"
  end

  def test_start_edges_use_the_initialized_sentinel
    [source("gir.c"), source("nfa.c"), source("rseq.c"),
     source("diagnostics.c")].each do |text|
      refute_match(/\.from\s*=\s*-1|\{\s*-1\s*,/, text)
    end

    assert_includes source("nfa.c"), "ONIBI_GIR_STATE_NONE};"
    assert_includes source("rseq.c"),
                    "(OnibiRSeqEdgeEntry){ONIBI_GIR_STATE_NONE, edge->to"
  end

  def test_subprogram_builder_records_keep_the_serialized_layout
    gir = source("gir.c")

    assert_includes gir, "OnibiGirStateId entry;"
    assert_includes gir, "OnibiGirStateId accept;"
    assert_includes gir, "sizeof(OnibiRSeqSubprogramEntry) == 36"
  end

  private

  def source(name)
    File.read(File.join(EXTENSION_ROOT, name))
  end
end
