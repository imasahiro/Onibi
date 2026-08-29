# frozen_string_literal: true

require "test_helper"

class InternalRegexpDependencyTest < Minitest::Test
  LIBRARY_PATH = File.join(PROJECT_ROOT, "lib")
  EXTENSION_SOURCE = File.join(PROJECT_ROOT, "ext", "onibi", "onibi.c")

  def test_library_matching_does_not_use_mri_regexp_operators
    source = Dir[File.join(LIBRARY_PATH, "**", "*.rb")].map { |file| File.read(file) }.join

    refute_includes source, "=~"
    refute_includes source, "/\\s/"
    refute_includes source, "/[A-Za-z0-9_]/"
  end

  def test_space_and_word_escapes_match_ascii_codepoints
    assert Onibi::Regexp.new("\\s").match?(" ")
    assert Onibi::Regexp.new("\\s").match?("\n")
    assert Onibi::Regexp.new("\\w+").match?("word_2026")
    refute Onibi::Regexp.new("\\w").match?("é")
  end

  def test_compiler_pipeline_objects_are_not_public_constants
    refute_includes Onibi.constants(false), :Lexer
    refute_includes Onibi.constants(false), :Parser
    refute_includes Onibi.constants(false), :Compiler
    refute_includes Onibi.constants(false), :VM
    assert_includes Onibi.constants(false), :Regexp
  end

  def test_internal_pipeline_state_is_not_public_api
    internal_methods = %i[tokens ast gir rseq parsed compiled vm graph]

    internal_methods.each do |name|
      refute_includes Onibi::Regexp.instance_methods(false), name
      refute_includes Onibi::Regexp.singleton_methods(false), name
    end
  end

  def test_c_pipeline_does_not_use_repeated_string_comparisons
    source = File.read(EXTENSION_SOURCE)

    refute_match(/\b(?:str|mem)?ncmp\s*\(/, source)
    refute_match(/\bstrcmp\s*\(/, source)
  end

  def test_c_pipeline_uses_cached_ids_for_hash_fields
    source = File.read(EXTENSION_SOURCE).gsub(/#if 0.*?#endif/m, "")

    refute_match(/rb_hash_(?:aref|aset)\([^\n]*rb_intern\s*\(/, source)
  end

  def test_vm_position_assertions_use_numeric_subtype_codes
    source = File.read(EXTENSION_SOURCE)
    vm = source[/static int onibi_vm_actions_ok\(.*?\n}\n/m]

    refute_nil vm
    assert_includes vm, "id_key_assert_kind"
    assert_includes vm, "ONIBI_RAP_LOOKAHEAD"
    assert_includes vm, "ONIBI_RAP_LOOKBEHIND"
    assert_includes vm, "ONIBI_RAP_SEARCH_ORIGIN && pos != search_origin"
    refute_match(/id_a_assert_(?:begin_buffer|end_buffer|begin_line|end_line|lookahead|lookbehind)/, vm)
  end

  def test_search_origin_is_constant_across_candidate_starts
    source = File.read(EXTENSION_SOURCE)
    regular = source[/static VALUE onibi_vm_regular_fast\(.*?\n}\n/m]
    tagged = source[/static VALUE onibi_vm_tagged_ordered\(.*?\n}\n/m]
    dynamic = source[/static VALUE onibi_vm_dynamic\(.*?\n}\n/m]

    [regular, tagged, dynamic].each do |executor|
      refute_nil executor
      assert_includes executor, "for (long start = search_origin;"
    end
  end

  def test_fragment_connections_keep_state_ids_in_c_vectors
    source = File.read(EXTENSION_SOURCE)
    connector = source[/static void onibi_connect_fragment_actions\(.*?\n}\n/m]

    refute_nil connector
    refute_includes connector, "start_values"
    assert_includes connector, "starts->items[j]"
    assert_includes connector, "onibi_gir_edge_actions(builder, from, to, actions)"
  end

  def test_compiler_accept_start_uses_c_vector
    source = File.read(EXTENSION_SOURCE)
    compiler = source[/static void\nonibi_compiler_pass_lower.*?\n}\n/m]

    refute_nil compiler
    assert_includes compiler, "OnibiIdVector accept_starts;"
    assert_includes compiler, "onibi_id_vector_single(&accept_starts"
    refute_includes compiler, "VALUE accept_starts = rb_ary_new();"
  end

  def test_compiler_materializes_start_edges_from_c_records
    source = File.read(EXTENSION_SOURCE)
    compiler = source[/static VALUE\nonibi_compiler_pass_publish.*?\n}\n/m]

    refute_nil compiler
    assert_includes compiler, "start_edges->count"
    assert_includes compiler, "onibi_materialize_gir"
    assert_includes source, "onibi_gir_edge_vector_free(&start_edge_records)"
  end

  def test_conditional_guards_use_c_action_vectors
    source = File.read(EXTENSION_SOURCE)
    conditional = source[/if \(type_code == ONIBI_AST_CONDITIONAL\).*?\n    onibi_add_exit_guard_fragment/m]

    refute_nil conditional
    assert_includes conditional, "OnibiValueVector yes_guard"
    assert_includes conditional, "onibi_guard_vector_add_values"
    refute_includes conditional, "VALUE yes_guard = rb_ary_new()"
  end

  def test_empty_fragments_share_immutable_action_storage
    source = File.read(EXTENSION_SOURCE)
    fragment = source[/static onibi_fragment_t onibi_fragment_empty\(.*?\n}\n/m]

    refute_nil fragment
    assert_includes fragment, "fragment.start_actions = onibi_empty_actions"
    assert_includes fragment, "fragment.pending_actions = onibi_empty_actions"
    assert_includes source, "onibi_fragment_actions_mutable"
  end

  def test_regexp_keeps_ast_analysis_as_one_bitset
    source = File.read(EXTENSION_SOURCE)
    regexp_struct = source[/typedef struct \{.*?\} onibi_regexp_t;/m]

    refute_nil regexp_struct
    assert_includes regexp_struct, "unsigned int ast_flags;"
    refute_includes regexp_struct, "has_anchor_repeat"
    refute_includes regexp_struct, "has_nullable_absence"
    refute_includes regexp_struct, "has_safe_multibyte_class"
  end

  def test_execution_features_use_numeric_bitset
    source = File.read(EXTENSION_SOURCE)
    regexp_struct = source[/typedef struct \{.*?\} onibi_regexp_t;/m]

    assert_includes regexp_struct, "unsigned int execution_flags;"
    refute_includes regexp_struct, "has_dynamic"
    refute_includes regexp_struct, "has_tagged"
    refute_includes regexp_struct, "has_atomic"
  end

  def test_syntax_features_use_numeric_bitset
    source = File.read(EXTENSION_SOURCE)
    regexp_struct = source[/typedef struct \{.*?\} onibi_regexp_t;/m]

    assert_includes regexp_struct, "unsigned int feature_flags;"
    refute_includes regexp_struct, "has_grapheme"
    refute_includes regexp_struct, "has_wildcard"
    refute_includes regexp_struct, "has_anchor"
    refute_includes regexp_struct, "has_meta_escape"
    refute_includes regexp_struct, "has_unicode_escape"
  end

  def test_compiler_features_use_numeric_bitset
    source = File.read(EXTENSION_SOURCE)
    regexp_struct = source[/typedef struct \{.*?\} onibi_regexp_t;/m]

    assert_includes regexp_struct, "unsigned int feature_flags;"
    refute_includes regexp_struct, "has_class_intersection"
    refute_includes regexp_struct, "has_nested_class"
    refute_includes regexp_struct, "has_large_repeat"
    refute_includes regexp_struct, "has_conditional"
    refute_includes regexp_struct, "has_backref"
    refute_includes regexp_struct, "has_subroutine"
  end

  def test_active_regexp_state_has_no_boolean_feature_fields
    source = File.read(EXTENSION_SOURCE).gsub(/#if 0.*?#endif/m, "")

    refute_match(/obj->has_(?:class_intersection|nested_class|large_repeat|absence|conditional|backref|subroutine|grapheme|wildcard|anchor|meta_escape|unicode_escape)/, source)
  end

  def test_regexp_state_keeps_only_public_values_as_ruby_references
    source = File.read(EXTENSION_SOURCE)
    regexp_struct = source[/typedef struct \{.*?\} onibi_regexp_t;/m]

    assert_equal 5, regexp_struct.scan(/\bVALUE\s+[a-z_]+;/).length
    refute_match(/VALUE\s+(?:tokens|ast|graph|states|edges|actions);/, regexp_struct)
  end

  def test_feature_classification_does_not_reintern_token_names
    source = File.read(EXTENSION_SOURCE)
    classifier = source[/static void onibi_token_features\(.*?\n}\n/m]

    refute_nil classifier
    refute_includes classifier, "rb_intern_str"
    assert_includes classifier, "token->name_id"
    assert_includes classifier, "token->property_kind"
  end

  def test_posix_classification_uses_cached_name_ids
    source = File.read(EXTENSION_SOURCE)
    classifier = source[/static OnibiPosixKind onibi_posix_kind_id\(.*?\n}\n/m]

    refute_nil classifier
    refute_includes classifier, "rb_intern_str"
    assert_includes classifier, "ID property"
  end

  def test_unicode_classification_accepts_cached_name_ids
    source = File.read(EXTENSION_SOURCE)
    classifier = source[/static int onibi_unicode_ctype_id\(.*?\n}\n/m]

    refute_nil classifier
    refute_includes classifier, "rb_intern_str"
    assert_includes classifier, "ID property"
  end

  def test_option_arrays_use_symbol_ids_directly
    source = File.read(EXTENSION_SOURCE)
    option_code = source[/static int onibi_option_mask\([^;]*?\) \{.*?\n}\n/m]

    refute_nil option_code
    assert_includes option_code, "SYMBOL_P(item) ? SYM2ID(item)"
    refute_includes option_code, "rb_sym2str(item)"
  end

  def test_gir_guard_lookup_uses_c_vector_storage
    source = File.read(EXTENSION_SOURCE)
    builder = source[/typedef struct \{\n  OnibiGirStateVector states;.*?onibi_gir_builder_t;/m]

    refute_nil builder
    assert_includes builder, "OnibiGuardVector capture_guards"
    assert_includes builder, "OnibiGuardVector exit_guards"
    refute_match(/rb_hash_aref\(builder->(?:capture|exit)_guards/, source)
  end

  def test_gir_compile_indexes_use_c_value_maps
    source = File.read(EXTENSION_SOURCE)
    builder = source[/typedef struct \{\n  OnibiGirStateVector states;.*?onibi_gir_builder_t;/m]

    refute_nil builder
    assert_includes builder, "OnibiValueMap capture_names"
    assert_includes builder, "OnibiValueMap subprogram_ids"
    refute_match(/rb_hash_(?:aref|aset|delete)\(builder->(?:capture_names|capture_bodies|capture_ids|active_subroutines|subprogram_ids)/, source)
  end

  def test_c_compile_maps_keep_ruby_values_rooted
    source = File.read(EXTENSION_SOURCE)
    builder = source[/typedef struct \{\n  OnibiGirStateVector states;.*?onibi_gir_builder_t;/m]

    refute_nil builder
    assert_includes builder, "VALUE map_roots"
    assert_includes source, "rb_ary_push(roots, key)"
    assert_includes source, "rb_ary_push(roots, value)"
  end

  def test_large_regular_visited_sets_use_owned_c_storage
    source = File.read(EXTENSION_SOURCE)
    matcher = source[/static int onibi_gir_match\(.*?\n}\n/m]

    refute_nil matcher
    assert_includes matcher, "visited_bits_owned"
    assert_includes matcher, "ALLOC_N(unsigned char, visited_size)"
    assert_includes matcher, "xfree(visited_bits)"
  end

  def test_fragments_store_state_ids_in_c_vectors
    source = File.read(EXTENSION_SOURCE)
    fragment = source[/typedef struct \{ OnibiIdVector starts;.*?\} onibi_fragment_t;/m]

    refute_nil fragment
    assert_includes fragment, "OnibiIdVector starts"
    assert_includes fragment, "OnibiIdVector exits"
    assert_includes source, "onibi_id_vector_move"
    assert_includes source, "onibi_id_vector_append"
  end

  def test_gir_builder_materializes_states_and_edges_once
    source = File.read(EXTENSION_SOURCE)
    materializer = source[/static void onibi_materialize_gir\(.*?\n}\n/m]

    refute_nil materializer
    assert_includes materializer, "OnibiGirStateEntry"
    assert_includes materializer, "OnibiGirEdgeEntry"
    assert_includes materializer, "rb_obj_freeze(states)"
    assert_includes materializer, "rb_obj_freeze(edges)"
  end

  def test_rseq_lowering_deduplicates_payloads_in_c_vectors
    source = File.read(EXTENSION_SOURCE)
    lowerer = source[/static VALUE onibi_rseq_lower\(.*?\n}\n/m]

    refute_nil lowerer
    assert_includes lowerer, "OnibiRSeqClassPayloadVector class_payloads"
    assert_includes lowerer, "OnibiRSeqLiteralPayloadVector literal_payloads"
    assert_includes lowerer, "onibi_rseq_class_payload_vector_free(&class_payloads)"
  end

  def test_rseq_edge_adapters_materialize_from_c_records
    source = File.read(EXTENSION_SOURCE)
    lowerer = source[/static VALUE onibi_rseq_lower\(.*?\n}\n/m]

    refute_nil lowerer
    assert_includes lowerer, "OnibiGirEdgeVector r_edge_records"
    assert_includes lowerer, "OnibiGirEdgeVector r_start_edge_records"
    assert_includes lowerer, "onibi_gir_edge_vector_free(&r_edge_records)"
  end

  def test_rseq_actions_use_c_records_until_publication
    source = File.read(EXTENSION_SOURCE)
    lowerer = source[/static VALUE onibi_rseq_lower\(.*?\n}\n/m]

    refute_nil lowerer
    assert_includes lowerer, "OnibiRSeqActionVector action_records"
    assert_includes lowerer, "onibi_rseq_action_vector_push(&action_records"
    assert_includes lowerer, "onibi_rseq_action_vector_free(&action_records)"
  end

  def test_rseq_states_use_c_records_during_lowering
    source = File.read(EXTENSION_SOURCE)
    lowerer = source[/static VALUE onibi_rseq_lower\(.*?\n}\n/m]

    refute_nil lowerer
    assert_includes lowerer, "OnibiGirStateVector state_records"
    assert_includes lowerer, "state_records.entries[i].opcode"
    assert_includes lowerer, "onibi_gir_state_vector_free(&state_records)"
  end

  def test_rseq_physical_edges_use_c_records
    source = File.read(EXTENSION_SOURCE)
    lowerer = source[/static VALUE onibi_rseq_lower\(.*?\n}\n/m]

    refute_nil lowerer
    assert_includes lowerer, "r_edge_records.entries[i]"
    assert_includes lowerer, "r_start_edge_records.entries[i]"
    refute_match(/physical_edges\[i\].*onibi_hash_value\(edge/, lowerer)
  end

  def test_rseq_groups_physical_edges_by_source_with_stable_scatter
    source = File.read(EXTENSION_SOURCE)
    grouper = source[/static void onibi_gir_edge_vector_group_by_from\(.*?\n}\n/m]
    lowerer = source[/static VALUE onibi_rseq_lower\(.*?\n}\n/m]

    refute_nil grouper
    refute_nil lowerer
    assert_includes grouper, "ordered[next[from]++] = vector->entries[i]"
    assert_includes lowerer, "onibi_gir_edge_vector_group_by_from(&r_edge_records, (size_t)state_count)"
    assert_includes lowerer, "size_t edge_count = physical_edge_index - edge_base"
    refute_includes lowerer, "for (size_t e = 0; e < r_edge_records.count; e++)"
  end

  def test_rseq_physical_actions_use_c_vector
    source = File.read(EXTENSION_SOURCE)
    lowerer = source[/static VALUE onibi_rseq_lower\(.*?\n}\n/m]

    refute_nil lowerer
    assert_includes lowerer, "action_records.entries[i].value"
    assert_includes lowerer, "physical.action_count = (uint32_t)action_records.count"
    assert_includes source, "uint8_t set; uint8_t positive"
    assert_includes lowerer, "action_records.entries[i].positive"
    assert_includes source, "uint8_t has_arg32"
    assert_includes lowerer, "action_records.entries[i].arg32"
    assert_includes source, "uint8_t has_assert_kind"
    assert_includes lowerer, "action_records.entries[i].assert_kind"
    assert_includes source, "uint8_t physical_op"
    assert_includes lowerer, "action_records.entries[i].physical_op"
  end

  def test_rseq_literal_payloads_cache_numeric_fields
    source = File.read(EXTENSION_SOURCE)
    lowerer = source[/static VALUE onibi_rseq_lower\(.*?\n}\n/m]

    refute_nil lowerer
    assert_includes lowerer, "OnibiRSeqLiteralPayloadVector literal_payloads"
    assert_includes lowerer, "prior->byte"
    assert_includes lowerer, "entry->ignorecase"
  end

  def test_rseq_states_cache_payload_indexes
    source = File.read(EXTENSION_SOURCE)
    lowerer = source[/static VALUE onibi_rseq_lower\(.*?\n}\n/m]

    refute_nil lowerer
    assert_includes source, "uint32_t payload_index"
    assert_includes lowerer, "state->payload_index"
    assert_includes lowerer, "physical_states[i].payload = state->payload_index"
  end

  def test_gir_edge_records_cache_action_count
    source = File.read(EXTENSION_SOURCE)
    record = source[/typedef struct \{ long from; long to;.*?\} OnibiGirEdgeEntry;/m]

    refute_nil record
    assert_includes record, "uint32_t action_count"
    assert_includes source, "record->action_count == 0"
    assert_includes source, "prior->action_count = (uint32_t)RARRAY_LEN(merged_actions)"
    assert_includes source, "prior_explicit_count"
    assert_includes source, "onibi_gir_compose_edge_actions(builder, from, to, explicit_actions)"
  end

  def test_gir_guard_records_cache_action_count
    source = File.read(EXTENSION_SOURCE)
    record = source[/typedef struct \{ OnibiStateId state;.*?\} OnibiGuardEntry;/m]
    refute_nil record
    assert_includes record, "OnibiValueVector actions"
    refute_includes record, "VALUE actions"
    assert_includes source, "onibi_guard_vector_find_entry"
    assert_includes source, "onibi_value_vector_append_array(&vector->entries[i].actions"
    assert_includes source, "onibi_value_vector_reserve(destination, (size_t)count)"
    assert_includes source, "long count = RARRAY_LEN(source)"
    assert_includes source, "UINT32_MAX - (uint32_t)incoming"
    assert_includes source, "onibi_gir_compose_edge_actions"
    assert_includes source, "onibi_guard_vector_find_entry"
  end

  def test_gir_guard_edge_actions_have_one_defined_order
    source = File.read(EXTENSION_SOURCE)
    composer = source[/static VALUE onibi_gir_compose_edge_actions\(.*?\n}\n/m]

    refute_nil composer
    exit_guard = "onibi_append_vector_values(actions, &exit_guard->actions)"
    explicit = "onibi_append_values(actions, explicit_actions)"
    capture_guard = "onibi_append_vector_values(actions, &capture_guard->actions)"
    assert_equal 1, composer.scan(exit_guard).length
    assert_equal 1, composer.scan(explicit).length
    assert_equal 1, composer.scan(capture_guard).length
    assert_operator composer.index(exit_guard), :<, composer.index(explicit)
    assert_operator composer.index(explicit), :<, composer.index(capture_guard)
  end

  def test_negative_option_payload_survives_gc_stress_during_token_materialization
    previous_stress = GC.stress
    GC.stress = true
    source = Array.new(16, "(?im-mx:a)").join

    regexp = Onibi::Regexp.new(source)

    assert regexp.match?("A" * 16)
  ensure
    GC.stress = previous_stress
  end

  def test_fragment_transition_actions_are_preallocated
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "rb_ary_new_capa(RARRAY_LEN(result.pending_actions)"
    assert_includes source, "onibi_concat_action_values(repeat.pending_actions"
    refute_includes source, "rb_ary_dup(result.pending_actions)"
    refute_includes source, "rb_ary_dup(repeat.pending_actions)"
  end

  def test_start_edges_preallocate_fragment_actions
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "onibi_concat_action_values(fragment.start_actions, fragment.pending_actions)"
  end

  def test_rseq_subprograms_use_typed_records
    source = File.read(EXTENSION_SOURCE)
    lowerer = source[/static VALUE onibi_rseq_lower\(.*?\n}\n/m]

    refute_nil lowerer
    assert_includes lowerer, "OnibiRSeqSubprogramVector subprogram_records"
    assert_includes lowerer, "physical_subprograms[i].entry = record->entry"
    assert_includes lowerer, "onibi_rseq_subprogram_vector_free(&subprogram_records)"
  end

  def test_physical_graph_copies_cached_action_ranges
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "uint32_t action_count = action_offset == 0 ? 0"
    assert_includes source, "rb_ary_new_capa((long)action_count)"
    assert_includes source, "action_index + n"
    refute_includes source[/static VALUE onibi_rseq_physical_graph\(VALUE rseq\).*?\n}\n/m],
      "id_key_action_code)) == ONIBI_GA_END"
  end

  def test_physical_graph_preallocates_outgoing_edge_indexes
    source = File.read(EXTENSION_SOURCE)
    graph = source[/static VALUE onibi_rseq_physical_graph\(VALUE rseq\) \{.*?\n}\n/m]

    refute_nil graph
    assert_includes graph, "outgoing_degrees"
    assert_includes graph, "rb_ary_new_capa(capacity"
  end

  def test_compiler_property_paths_use_cached_name_ids
    source = File.read(EXTENSION_SOURCE)
    assert_equal 0, source.scan(/NIL_P\([^)]*name_id\).*rb_intern_str/).length
    assert_equal 0, source.scan(/NIL_P\([^)]*child_name_id\).*rb_intern_str/).length
    assert_equal 0, source.scan(/NIL_P\([^)]*property_name_id\).*rb_intern_str/).length
    refute_includes source, "onibi_ascii_property_kind(VALUE name)"
    assert_includes source, "name_id == 0 ? ONIBI_ASCII_PROP_UNKNOWN"
  end

  def test_utf8_class_match_does_not_allocate_missing_literal_bytes
    source = File.read(EXTENSION_SOURCE)
    matcher = source[/static int onibi_vm_class_match\(.*?\n}\n/m]

    refute_nil matcher
    refute_includes matcher, "rb_str_new((const char[]){"
    assert_includes matcher, "code == (OnigCodePoint)NUM2INT(child_byte)"
    assert_includes matcher, "id_key_class_mode"
    refute_includes matcher, "onibi_ast_kind(payload) == ONIBI_AST_CLASS_INTERSECTION"
  end

  def test_compiler_subprograms_use_c_vector_until_publication
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "OnibiValueVector subprograms"
    assert_includes source, "onibi_value_vector_push(&builder->subprograms"
    assert_includes source, "VALUE subprograms = rb_ary_new_capa"
  end

  def test_subprogram_entry_actions_share_frozen_fragment_storage
    source = File.read(EXTENSION_SOURCE)
    compiler = source[/static long onibi_compile_subprogram\(.*?\n}\n/m]
    named = source[/static long onibi_compile_named_subprogram\(.*?\n}\n/m]

    refute_nil compiler
    refute_nil named
    assert_includes compiler, "onibi_deep_freeze(fragment.start_actions)"
    assert_includes named, "onibi_deep_freeze(fragment.start_actions)"
    refute_includes compiler, "rb_ary_dup(fragment.start_actions)"
    refute_includes named, "rb_ary_dup(fragment.start_actions)"
  end

  def test_regular_vm_uses_hash_visited_only_without_c_bitset
    source = File.read(EXTENSION_SOURCE)
    matcher = source[/static int onibi_gir_match\(.*?\n}\n/m]

    refute_nil matcher
    assert_includes matcher, "VALUE visited = Qnil"
    assert_includes matcher, "if (use_counters || visited_bits == NULL) visited = rb_hash_new();"
  end

  def test_vm_uses_shared_empty_actions_for_missing_entry_actions
    source = File.read(EXTENSION_SOURCE)
    refute_includes source, "RB_TYPE_P(entry_actions, T_ARRAY) ? entry_actions : rb_ary_new()"
    assert_operator source.scan("? entry_actions : onibi_empty_actions").length, :>=, 3
  end

  def test_absence_entry_action_failure_uses_numeric_rseq_opcode
    source = File.read(EXTENSION_SOURCE)
    walker = source[/static int onibi_vm_walk_captures\(.*?\n}\n/m]

    refute_nil walker
    refute_includes walker, "op == id_g_absent"
    assert_includes walker, "if (op == ONIBI_RS_ABSENT) { frame->waiting_call = 0; continue; }"
  end

  def test_rseq_uses_gir_capture_resource_count_not_action_occurrences
    source = File.read(EXTENSION_SOURCE)
    lowerer = source[/static VALUE onibi_rseq_lower\(.*?\n}\n/m]

    refute_nil lowerer
    assert_includes lowerer, "VALUE capture_count_value = onibi_hash_value_id(graph, id_key_capture_count)"
    assert_includes lowerer, "uint32_t capture_count = (uint32_t)gir_capture_count"
    refute_includes lowerer, "capture_count++"
  end

  def test_gir_validator_bounds_capture_test_ids_for_all_edge_kinds
    source = File.read(EXTENSION_SOURCE)
    validator = source[/static void onibi_gir_validate\(.*?\n}\n/m]

    refute_nil validator
    assert_equal 2, validator.scan("code == ONIBI_GA_TEST_CAPTURE && NUM2LONG(slot) >= capture_count").length
    assert_includes source, 'rb_raise(eRegexpError, "invalid GIR capture test id")'
  end

  def test_tagged_vm_reuses_cached_physical_graph_for_all_starts
    source = File.read(EXTENSION_SOURCE)
    matcher = source[/static VALUE onibi_vm_tagged_ordered\(.*?\n}\n/m]

    refute_nil matcher
    assert_equal 1, matcher.scan("onibi_rseq_physical_graph(rseq)").length
    assert_includes matcher, "VALUE graph = onibi_rseq_physical_graph(rseq);"
  end

  def test_regular_vm_reuses_physical_graph_lookup_for_all_starts
    source = File.read(EXTENSION_SOURCE)
    matcher = source[/static VALUE onibi_vm_regular_fast\(.*?\n}\n/m]

    refute_nil matcher
    assert_includes matcher, "VALUE graph = Qnil;"
    assert_equal 1, matcher.scan("onibi_rseq_physical_graph(rseq)").length
  end

  def test_regular_vm_reuses_one_rseq_view_for_all_starts
    source = File.read(EXTENSION_SOURCE)
    matcher = source[/static VALUE onibi_vm_regular_fast\(.*?\n}\n/m]

    refute_nil matcher
    assert_includes matcher, "OnibiRSeqView view;"
    assert_includes matcher, "onibi_rseq_simple_match(rseq, cached_view"
    assert_equal 1, matcher.scan("onibi_rseq_view_init(blob, &view)").length
  end

  def test_tagged_vm_reuses_one_rseq_view_for_simple_starts
    source = File.read(EXTENSION_SOURCE)
    matcher = source[/static VALUE onibi_vm_tagged_ordered\(.*?\n}\n/m]

    refute_nil matcher
    assert_includes matcher, "const OnibiRSeqView *cached_view"
    assert_includes matcher, "onibi_rseq_simple_match(rseq, cached_view"
  end

  def test_capture_seed_does_not_duplicate_empty_counter_state
    source = File.read(EXTENSION_SOURCE)
    refute_includes source, "rb_hash_dup(counters)"
    assert_includes source, "long *branch_counters = use_counters && counter_count > 0"
    refute_includes source, "VALUE branch_counters = use_counters ? rb_hash_new() : Qnil;"
  end

  def test_tagged_vm_keeps_counter_state_out_of_ruby_hashes
    source = File.read(EXTENSION_SOURCE)
    walker = source[/static int onibi_vm_walk_captures\(.*?\n}\n/m]

    refute_nil walker
    assert_includes walker, "long *counter_pool"
    assert_includes walker, "OnibiCounterState call_counter_state"
    refute_includes walker, "rb_hash_new() : Qnil"
    refute_includes walker, "rb_hash_dup(frame->counters)"
  end

  def test_sequence_transition_actions_reuse_empty_side
    source = File.read(EXTENSION_SOURCE)
    compiler = source[/static onibi_fragment_t onibi_compile_sequence\(.*?\n}\n/m]

    refute_nil compiler
    assert_includes compiler, "if (RARRAY_LEN(result.pending_actions) == 0)"
    assert_includes compiler, "transition_actions = part.start_actions"
    assert_includes compiler, "transition_actions = result.pending_actions"
  end

  def test_repeat_action_concat_reuses_empty_side
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "static VALUE onibi_concat_action_values(VALUE first, VALUE second)"
    assert_includes source, "onibi_concat_action_values(repeat.pending_actions"
  end

  def test_start_edges_reuse_fragment_action_arrays
    source = File.read(EXTENSION_SOURCE)
    compiler = source[/static void\nonibi_compiler_pass_lower.*?\n}\n/m]

    refute_nil compiler
    assert_includes compiler, "onibi_concat_action_values(fragment.start_actions,"
    assert_includes compiler, "VALUE with_guard = rb_ary_new_capa"
  end

  def test_runtime_id_lookups_use_shared_accessor
    source = File.read(EXTENSION_SOURCE)
    runtime = source[/static VALUE onibi_initialize\(.*?\n}\n/m]

    refute_nil runtime
    refute_includes runtime, "rb_hash_aref(options, ID2SYM(id_timeout))"
    refute_includes source, "rb_hash_aref(captures, ID2SYM(id_recursive_marker))"
  end

  def test_match_paths_cache_encoding_indexes
    source = File.read(EXTENSION_SOURCE)
    initialize = source[/static VALUE onibi_initialize\(.*?\n}\n/m]
    match = source[/static VALUE onibi_match\(.*?\n}\n/m]
    match_p = source[/static VALUE onibi_match_p\(.*?\n}\n/m]
    vm_match_p = source[/static VALUE onibi_vm_match_p\(VALUE self, VALUE str\) \{.*?\n}\n/m]

    [initialize, match, match_p, vm_match_p].each { |method| refute_nil method }
    assert_includes initialize, "int source_encoding_index = rb_enc_get_index(source);"
    assert_includes initialize, "int source_ascii_only = rb_enc_str_asciionly_p(source);"
    assert_equal 1, initialize.scan("rb_enc_get_index(source)").length
    assert_equal 1, initialize.scan("rb_enc_str_asciionly_p(source)").length
    assert_includes source, "unsigned char source_ascii_only;"
    refute_includes source, "rb_enc_str_asciionly_p(obj->source)"
    assert_includes match, "int str_encoding_index = RB_TYPE_P(str, T_STRING) ? rb_enc_get_index(str) : -1;"
    assert_includes match, "int str_ascii_only = RB_TYPE_P(str, T_STRING) && rb_enc_str_asciionly_p(str);"
    assert_equal 1, match.scan("rb_enc_get_index(str)").length
    assert_includes match_p, "int str_encoding_index = RB_TYPE_P(str, T_STRING) ? rb_enc_get_index(str) : -1;"
    assert_includes match_p, "int str_ascii_only = RB_TYPE_P(str, T_STRING) && rb_enc_str_asciionly_p(str);"
    assert_equal 1, match_p.scan("rb_enc_get_index(str)").length
    assert_includes vm_match_p, "int str_encoding_index = rb_enc_get_index(str);"
    assert_equal 1, vm_match_p.scan("rb_enc_get_index(str)").length
    refute_includes source, "rb_enc_get_index(obj->source)"
  end

  def test_vm_matchers_do_not_reintern_property_names
    source = File.read(EXTENSION_SOURCE)
    matcher = source[/static int onibi_vm_class_match\(VALUE payload,.*?\n}\n/m]

    refute_nil matcher
    refute_includes matcher, "rb_intern"
    refute_includes matcher, "rb_intern_str"
    assert_includes matcher, "VALUE child_byte_value = onibi_hash_value_id(child, id_key_byte);"
    assert_operator matcher.index("VALUE name = onibi_hash_value_id(payload, id_key_name);"), :>,
      matcher.index("if (ctype >= 0 && encoding_index == rb_utf8_encindex())")
    assert_includes matcher, "int encoding_index = rb_enc_get_index(str);"
  end

  def test_class_bitmap_caches_child_escape_byte
    source = File.read(EXTENSION_SOURCE)
    bitmap = source[/static VALUE onibi_class_bitmap\(VALUE payload, int fold\) \{.*?\n}\n/m]

    refute_nil bitmap
    assert_includes bitmap, "VALUE child_byte_value = onibi_hash_value_id(child, id_key_byte);"
    assert_includes bitmap, "ID name_id = onibi_token_name_id(child);"
    refute_includes bitmap, "NIL_P(name_id) ? ONIBI_ASCII_PROP_UNKNOWN"
    assert_includes bitmap, "ID escape_name_id = onibi_token_name_id(payload);"
  end

  def test_compiler_value_maps_use_c_owned_growth
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "static void onibi_value_map_reserve"
    assert_includes source, "onibi_value_map_reserve(map, 1)"
    refute_includes source, "map->entries[i].value = value;\n      rb_ary_push(roots, key)"
  end

  def test_compiler_ascii_property_check_uses_name_id
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "static int onibi_ascii_property_name_p(ID name_id)"
    refute_includes source, "onibi_ascii_property_name_p(name)"
    assert_includes source, "ID escape_name_id = onibi_token_name_id(payload)"
  end

  def test_tagged_counter_state_uses_c_snapshots
    document = File.read(File.expand_path("../../../docs/development.md", __dir__))
    assert_includes document, "C counter snapshots per frame"
    assert_includes document, "Every tagged frame now uses fixed C counter storage"
    assert_includes document, "Capture and tag history remain independent Ruby values"
  end

  def test_rseq_physical_graph_adapter_is_marked_for_c_view_migration
    document = File.read(File.expand_path("../../../docs/development.md", __dir__))
    assert_includes document, "Pending: `OnibiRSeqView`-backed VM entry"
    assert_includes document, "capture walkers still require a C view migration"
  end

  def test_numeric_assertion_dispatch_preserves_public_matching
    assert Onibi::Regexp.new("^a$").match?("a")
    assert Onibi::Regexp.new("(?=a)a").match?("a")
    assert Onibi::Regexp.new("(?<=a)b").match?("ab")
  end

  def test_token_stream_uses_c_records_and_byte_storage
    source = File.read(EXTENSION_SOURCE)
    record = source[/typedef struct \{\n  OnibiTokenKind kind;.*?\n\} OnibiTokenRecord;/m]
    vector = source[/typedef struct \{\n  OnibiTokenRecord \*items;.*?\n\} OnibiTokenVector;/m]

    refute_nil record
    refute_nil vector
    refute_match(/\bVALUE\b/, record)
    assert_includes record, "OnibiTokenSlice name"
    assert_includes record, "ID name_id"
    assert_includes vector, "unsigned char *bytes"
  end

  def test_tokenizer_does_not_materialize_ruby_token_containers
    source = File.read(EXTENSION_SOURCE)
    tokenizer = source[/static void onibi_tokenize_internal\(.*?\n}\n/m]

    refute_nil tokenizer
    refute_includes tokenizer, "rb_hash_new"
    refute_includes tokenizer, "rb_ary_new"
    refute_includes tokenizer, "rb_str_substr("
    assert_includes tokenizer, "onibi_token_record_push(tokens, record)"
  end

  def test_tokenizer_owns_cleanup_across_exceptions
    source = File.read(EXTENSION_SOURCE)
    initialize = source[/static VALUE onibi_initialize\(.*?\n}\n/m]

    refute_nil initialize
    assert_includes initialize, "rb_protect(onibi_tokenize_protected"
    assert_includes initialize, "onibi_token_vector_free(&tokens)"
    assert_includes initialize, "rb_jump_tag(tokenize_state)"
  end

  def test_ast_uses_c_node_arena
    source = File.read(EXTENSION_SOURCE)
    node = source[/typedef struct \{\n  OnibiAstKind kind;.*?\n\} OnibiAstNode;/m]
    arena = source[/typedef struct \{\n  OnibiAstNode \*nodes;.*?\n\} OnibiAstArena;/m]

    refute_nil node
    refute_nil arena
    refute_match(/\bVALUE\b/, node)
    assert_includes node, "OnibiAstId *children"
    assert_includes node, "OnibiAstRange *ranges"
    assert_includes arena, "OnibiAstId root"
  end

  def test_parser_builds_only_c_ast_nodes
    source = File.read(EXTENSION_SOURCE)
    parser = source[/static OnibiAstId onibi_c_parse_range\(.*?\n}\n/m]
    entry = source[/static VALUE onibi_parser_parse_internal\(.*?\n}\n/m]

    refute_nil parser
    refute_nil entry
    refute_includes parser, "rb_hash_new"
    refute_includes parser, "rb_ary_new"
    assert_includes parser, "onibi_ast_arena_add"
    assert_includes entry, "parsed->arena.root = onibi_c_parse_range"
    refute_includes source, "static VALUE onibi_parse_range"
  end

  def test_compiler_starts_from_c_ast_root
    source = File.read(EXTENSION_SOURCE)
    compiler = source[/static VALUE\s+onibi_compiler_compile\(.*?\n}\n/m]

    refute_nil compiler
    assert_includes compiler, "parsed_data->arena.root"
    assert_includes compiler, "onibi_compiler_pass_init_builder"
    assert_includes compiler, "onibi_compiler_pass_collect_captures"
    assert_includes compiler, "onibi_compiler_pass_lower"
    assert_includes compiler, "onibi_compiler_pass_count_counters"
    assert_includes compiler, "onibi_compiler_pass_publish"
  end

  def test_compiler_passes_have_one_directional_pipeline
    source = File.read(EXTENSION_SOURCE)
    init = source[/static void\nonibi_compiler_pass_init_builder.*?\n}\n/m]
    lower = source[/static void\nonibi_compiler_pass_lower.*?\n}\n/m]
    publish = source[/static VALUE\nonibi_compiler_pass_publish.*?\n}\n/m]

    refute_nil init
    refute_nil lower
    refute_nil publish
    assert_includes init, "builder->ast = &parsed->arena"
    assert_includes lower, "onibi_compile_node(root_reference, builder)"
    refute_includes lower, "onibi_gir_validate"
    assert_includes publish, "onibi_materialize_gir"
    assert_includes publish, "onibi_gir_validate(graph)"
  end

  def test_ast_analysis_reads_c_nodes
    source = File.read(EXTENSION_SOURCE)
    nullable = source[/static int onibi_ast_nullable_scan\([^;]*?\) \{.*?\n}\n/m]

    refute_nil nullable
    assert_includes nullable, "const OnibiAstArena *arena"
    assert_includes nullable, "onibi_ast_node_const(arena, id)"
    assert_includes nullable, "ONIBI_AST_ANALYSIS_ANCHOR_REPEAT"
    refute_includes nullable, "onibi_hash_value_id"
  end

  def test_ast_arena_is_released_after_program_build
    source = File.read(EXTENSION_SOURCE)
    builder = source[/static VALUE onibi_build_program\(.*?\n}\n/m]

    refute_nil builder
    assert_includes builder, "onibi_ast_arena_free(&onibi_parsed_get(parsed)->arena)"
    assert_includes source, "The AST is an initialization artifact"
  end
end
