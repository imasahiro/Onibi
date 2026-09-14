# frozen_string_literal: true

require "test_helper"

class NfaStateIdContractTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  CONVERSION_HELPERS = %w[
    onibi_nfa_state_id_to_gir_id
    onibi_gir_id_to_nfa_state_id
    onibi_gir_state_id_to_nfa_state_id
    onibi_gir_state_id_from_long
  ].freeze

  def test_nfa_uses_a_fixed_width_id_and_reserved_sentinel
    header = File.read(File.join(ROOT, "ext", "onibi", "onibi_nfa_internal.h"))
    nfa = File.read(File.join(ROOT, "ext", "onibi", "nfa.c"))

    assert_includes header, "typedef uint32_t OnibiNfaStateId;"
    assert_includes header, "#define ONIBI_NFA_STATE_NONE UINT32_MAX"
    assert_includes header, "typedef ONIBI_VECTOR(OnibiNfaStateId)"
    assert_includes header, "ONIBI_VECTOR_DEFINE(onibi_nfa_state_id_vector"
    refute_includes nfa, "typedef long OnibiNfaStateId;"
    assert_includes nfa, "OnibiNfaStateIdVector starts;"
    assert_includes nfa, "OnibiNfaStateId accept;"
  end

  def test_nfa_gir_boundaries_check_before_narrowing
    sources = %w[nfa.c gir.c compiler.c].to_h do |name|
      [name, File.read(File.join(ROOT, "ext", "onibi", name))]
    end
    source = sources.fetch("nfa.c")

    assert_match(
      /onibi_gir_id_to_nfa_state_id\(long id, size_t state_count\).*?\n\}/m,
      source
    )
    assert_includes source, "onibi_nfa_state_id_to_gir_id"
    assert_includes source, "onibi_gir_state_id_to_nfa_state_id"
    assert_includes source, "onibi_gir_state_id_from_long"
    gir = File.read(File.join(ROOT, "ext", "onibi", "gir.c"))
    refute_includes gir, "ONIBI_VECTOR_DEFINE(onibi_nfa_state_id_vector"
    assert_match(
      /if \(id < 0 \|\| \(uint64_t\)id >= \(uint64_t\)state_count/,
      source
    )
    assert_match(
      /if \(id == ONIBI_NFA_STATE_NONE \|\| \(uint64_t\)id >=/,
      source
    )

    checked_sources = sources.values.join("\n")
    CONVERSION_HELPERS.each do |name|
      helper = source[/static [^{]+\b#{name}\s*\([^)]*\)\s*\{.*?^}/m]
      refute_nil helper, "missing conversion helper body: #{name}"
      checked_sources = checked_sources.gsub(helper, "")
    end

    direct_nfa_casts = checked_sources.scan(
      /\(OnibiNfaStateId\)\s*[A-Za-z_][A-Za-z0-9_.>\[\]-]*/
    )
    assert_equal ["(OnibiNfaStateId)nfa->states.count"], direct_nfa_casts
    refute_match(
      /\(OnibiNfaStateId\)\s*(?!nfa->states\.count\b)/,
      checked_sources
    )

    nfa_values = %w[
      accept destination from to root_entry entry exit choice body_entry
      body_exit projected_entry projected_exit increment enter_guard state
      fragment part branch result start_ids exit_ids choices map accept_starts
    ].join("|")
    refute_match(
      /\((?:long|OnibiStateId)\)\s*\(?\s*(?:#{nfa_values})\b/,
      checked_sources
    )
    refute_match(
      /\((?:long|OnibiStateId)\)\s*
       (?:nfa|edge|entry|fragment|start_ids|exit_ids|choices|map|accept_starts|
          body|part|branch|result)(?:->|\.)
       (?:accept|from|to|id|starts|exits)\.?(?:entries)?\b/x,
      checked_sources
    )
    refute_match(
      /\((?:long|OnibiStateId)\)\s*onibi_nfa_[A-Za-z0-9_]*\s*\(/,
      checked_sources
    )
  end
end
