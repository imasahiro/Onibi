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

  def test_ast_anchor_analysis_uses_one_recursive_scan
    source = File.read(EXTENSION_SOURCE)
    scan = source[/static int onibi_ast_anchor_scan\(VALUE ast\) \{.*?\n}\n/m]

    refute_nil scan
    assert_includes scan, "if (type == ONIBI_AST_QUANTIFIER && keys[i] == id_key_atom"
    refute_includes source, "onibi_ast_contains_anchor"
  end

  def test_ast_nullability_flags_share_one_scan
    source = File.read(EXTENSION_SOURCE)
    scan = source[/static int onibi_ast_nullable_scan\(VALUE ast,.*?\n}\n/m]

    refute_nil scan
    assert_includes scan, "OnibiAstAnalysis *analysis"
    assert_includes source, "unsigned int flags;"
    refute_includes source, "onibi_ast_nullable_absence"
    refute_includes source, "static int onibi_ast_nullable(VALUE ast"
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
    refute_match(/id_a_assert_(?:begin_buffer|end_buffer|begin_line|end_line|lookahead|lookbehind)/, vm)
  end

  def test_compiled_token_view_has_explicit_c_owner
    source = File.read(EXTENSION_SOURCE)

    assert_includes source, "OnibiFeatureTokenVector feature_tokens = onibi_feature_tokens(tokens, feature_storage);"
    assert_includes source, "onibi_token_features(&feature_tokens, obj);"
    assert_includes source, "xfree(feature_tokens.items);"
    refute_includes source, "obj->feature_tokens"
    refute_includes source, "obj->feature_token_count"
  end

  def test_feature_vector_helper_does_not_allocate_storage
    source = File.read(EXTENSION_SOURCE)
    helper = source[/static OnibiFeatureTokenVector onibi_feature_tokens\(.*?\n}\n/m]

    refute_nil helper
    refute_includes helper, "ALLOC_N"
    refute_includes helper, "REALLOC_N"
    refute_includes helper, "rb_ary_new"
  end

  def test_regexp_keeps_ast_analysis_as_one_bitset
    source = File.read(EXTENSION_SOURCE)
    regexp_struct = source[/typedef struct \{ VALUE regexp;.*?\} onibi_regexp_t;/m]

    refute_nil regexp_struct
    assert_includes regexp_struct, "unsigned int ast_flags;"
    refute_includes regexp_struct, "has_anchor_repeat"
    refute_includes regexp_struct, "has_nullable_absence"
    refute_includes regexp_struct, "has_safe_multibyte_class"
  end

  def test_execution_features_use_numeric_bitset
    source = File.read(EXTENSION_SOURCE)
    regexp_struct = source[/typedef struct \{ VALUE regexp;.*?\} onibi_regexp_t;/m]

    assert_includes regexp_struct, "unsigned int execution_flags;"
    refute_includes regexp_struct, "has_dynamic"
    refute_includes regexp_struct, "has_tagged"
    refute_includes regexp_struct, "has_atomic"
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
    option_code = source[/static int onibi_extended_option_p\(.*?\n}\n/m]

    refute_nil option_code
    assert_includes option_code, "SYMBOL_P(item) ? SYM2ID(item)"
    refute_includes option_code, "rb_sym2str(item)"
  end

  def test_gir_guard_lookup_uses_c_vector_storage
    source = File.read(EXTENSION_SOURCE)
    builder = source[/typedef struct \{ OnibiGirStateVector states;.*?onibi_gir_builder_t;/m]

    refute_nil builder
    assert_includes builder, "OnibiGuardVector capture_guards"
    assert_includes builder, "OnibiGuardVector exit_guards"
    refute_match(/rb_hash_aref\(builder->(?:capture|exit)_guards/, source)
  end

  def test_gir_compile_indexes_use_c_value_maps
    source = File.read(EXTENSION_SOURCE)
    builder = source[/typedef struct \{ OnibiGirStateVector states;.*?onibi_gir_builder_t;/m]

    refute_nil builder
    assert_includes builder, "OnibiValueMap capture_names"
    assert_includes builder, "OnibiValueMap subprogram_ids"
    refute_match(/rb_hash_(?:aref|aset|delete)\(builder->(?:capture_names|capture_bodies|capture_ids|active_subroutines|subprogram_ids)/, source)
  end

  def test_c_compile_maps_keep_ruby_values_rooted
    source = File.read(EXTENSION_SOURCE)
    builder = source[/typedef struct \{ OnibiGirStateVector states;.*?onibi_gir_builder_t;/m]

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
    assert_includes source, "rb_ary_new_capa(RARRAY_LEN(actions) + (long)prior->action_count)"
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
    assert_includes source, "rb_ary_new_capa((long)capture_count"
    assert_includes source, "onibi_guard_vector_find_entry"
  end

  def test_gir_guard_edge_merge_uses_single_destination_array
    source = File.read(EXTENSION_SOURCE)
    gir_edge = source[/static void onibi_gir_edge\(.*?\n}\n/m]
    refute_nil gir_edge
    assert_includes gir_edge, "rb_ary_new_capa"
    refute_includes gir_edge, "rb_ary_dup"
  end

  def test_fragment_transition_actions_are_preallocated
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "rb_ary_new_capa(RARRAY_LEN(result.pending_actions)"
    assert_includes source, "rb_ary_new_capa(RARRAY_LEN(repeat.pending_actions)"
    refute_includes source, "rb_ary_dup(result.pending_actions)"
    refute_includes source, "rb_ary_dup(repeat.pending_actions)"
  end

  def test_start_edges_preallocate_fragment_actions
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "rb_ary_new_capa(RARRAY_LEN(fragment.start_actions) + RARRAY_LEN(fragment.pending_actions))"
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

  def test_tokenizer_preallocates_transient_adapter
    source = File.read(EXTENSION_SOURCE)
    tokenizer = source[/static VALUE onibi_tokenize_internal\(.*?\n}\n/m]

    refute_nil tokenizer
    assert_includes tokenizer, "rb_ary_new_capa(RSTRING_LEN(src))"
    refute_includes tokenizer, "VALUE tokens = rb_ary_new();"
    assert_operator tokenizer.index("VALUE token = rb_hash_new();"), :>,
      tokenizer.index("if (extended && !in_class && (byte == ' ' ||")
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

  def test_tagged_vm_reuses_cached_physical_graph_for_all_starts
    source = File.read(EXTENSION_SOURCE)
    matcher = source[/static VALUE onibi_vm_tagged_ordered\(.*?\n}\n/m]

    refute_nil matcher
    assert_equal 1, matcher.scan("onibi_rseq_physical_graph(rseq)").length
    assert_includes matcher, "VALUE graph = onibi_rseq_physical_graph(rseq);"
  end

  def test_capture_seed_does_not_duplicate_empty_counter_state
    source = File.read(EXTENSION_SOURCE)
    refute_includes source, "rb_hash_dup(counters)"
    assert_includes source, "VALUE branch_counters = use_counters ? rb_hash_new() : Qnil;"
  end

  def test_parser_class_and_range_adapters_preallocate_known_sizes
    source = File.read(EXTENSION_SOURCE)
    parser_class = source[/static VALUE onibi_parse_class\(VALUE tokens, long begin, long close\) \{.*?\n}\n/m]
    parser_range = source[/static VALUE onibi_parse_range\(VALUE tokens, long begin, long end\) \{.*?\n}\n/m]

    refute_nil parser_class
    refute_nil parser_range
    assert_includes parser_class, "rb_ary_new_capa(class_capacity)"
    assert_includes parser_class, "rb_ary_new_capa(part_end - part_begin + 2)"
    assert_includes parser_range, "rb_ary_new_capa(end > begin ? end - begin : 0)"
    assert_includes parser_range, "OnibiTokenKind kind = onibi_token_kind_code(token);"
  end

  def test_parser_uses_cached_id_accessor_for_token_fields
    source = File.read(EXTENSION_SOURCE)
    parser = source[/static long onibi_find_close\(.*?static VALUE onibi_parse_range\(VALUE tokens, long begin, long end\) \{.*?\n}\n/m]

    refute_nil parser
    refute_match(/rb_hash_aref\([^\n]*ID2SYM\(id_key_(kind_code|start|end|name|capture|bytes)/, parser)
    refute_includes parser, "NUM2UINT(onibi_hash_value_id(token, id_key_kind_code))"
    assert_includes source, "return NIL_P(kind) ? (OnibiTokenKind)-1"
  end

  def test_parser_range_adapter_uses_fixed_pair_capacity
    source = File.read(EXTENSION_SOURCE)
    parser = source[/static VALUE onibi_parse_class\(VALUE tokens, long begin, long close\) \{.*?\n}\n/m]

    refute_nil parser
    assert_includes parser, "VALUE range = rb_ary_new_capa(2);"
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

  def test_feature_tokens_read_cached_inline_option_flag
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "id_key_inline_ignorecase"
    assert_includes source, "RTEST(onibi_hash_value_id(token, id_key_inline_ignorecase))"
  end

  def test_compiler_ascii_property_check_uses_name_id
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "static int onibi_ascii_property_name_p(ID name_id)"
    refute_includes source, "onibi_ascii_property_name_p(name)"
    assert_includes source, "ID escape_name_id = onibi_token_name_id(payload)"
  end

  def test_ast_audit_defines_typed_node_migration_boundary
    document = File.read(File.expand_path("../../../docs/development.md", __dir__))
    assert_includes document, "Pending: typed C node arena"
    assert_includes document, "The first AST migration unit is the node arena"
    assert_includes document, "OnibiAstKind"
  end

  def test_parsed_ast_analysis_is_cached_in_c_fields
    source = File.read(EXTENSION_SOURCE)
    parsed = source[/typedef struct \{\n  VALUE ast;\n  int options;.*?\n\} OnibiParsed;/m]

    refute_nil parsed
    assert_includes parsed, "unsigned int ast_flags"
    assert_includes source, "ONIBI_AST_FLAG_SAFE_MULTIBYTE_CLASS"
    assert_includes source, "ONIBI_AST_FLAG_NULLABLE_CAPTURE"
    assert_includes source, "parsed_data->ast_flags"
  end

  def test_ast_adapter_is_released_after_initialization
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "parsed_data->ast = Qnil"
    assert_includes source, "The AST is an initialization artifact"
    assert_includes source, "onibi_parsed_get(parsed)->ast = Qnil"
  end

  def test_internal_ast_is_not_deep_frozen_during_parse
    source = File.read(EXTENSION_SOURCE)
    parser = source[/static VALUE onibi_parser_parse_internal\(.*?\n}\n/m]

    refute_nil parser
    assert_includes parser, "parsed->ast = onibi_parse_range"
    refute_match(/parsed->ast = onibi_deep_freeze/, parser)
  end

  def test_tagged_counter_maps_are_marked_for_c_snapshot_migration
    document = File.read(File.expand_path("../../../docs/development.md", __dir__))
    assert_includes document, "Pending: C counter snapshots"
    assert_includes document, "fixed C array per frame"
    assert_includes document, "Capture maps"
  end

  def test_rseq_physical_graph_adapter_is_marked_for_c_view_migration
    document = File.read(File.expand_path("../../../docs/development.md", __dir__))
    assert_includes document, "Pending: `OnibiRSeqView`-backed VM entry"
    assert_includes document, "capture walkers still require a C view migration"
  end

  def test_container_audit_counts_match_current_source
    source = File.read(EXTENSION_SOURCE)
    document = File.read(File.expand_path("../../../docs/development.md", __dir__))
    hash_count = source.scan(/rb_hash_new\(/).length
    array_count = source.scan(/rb_ary_new\(/).length
    assert_includes document, "The current source has #{hash_count} `rb_hash_new` calls and #{array_count} `rb_ary_new` calls."
  end


  def test_ast_nodes_retain_numeric_name_ids
    source = File.read(EXTENSION_SOURCE)
    ast_node = source[/static VALUE onibi_ast_node\(.*?\n}\n/m]

    refute_nil ast_node
    assert_includes ast_node, "id_key_name_id"
    assert_includes ast_node, "name_id"
  end

  def test_numeric_assertion_dispatch_preserves_public_matching
    assert Onibi::Regexp.new("^a$").match?("a")
    assert Onibi::Regexp.new("(?=a)a").match?("a")
    assert Onibi::Regexp.new("(?<=a)b").match?("ab")
  end

  def test_feature_token_record_has_no_ruby_value_fields
    source = File.read(EXTENSION_SOURCE)
    record = source[/typedef struct(?: OnibiFeatureToken)? \{\s*OnibiTokenKind kind;.*?\} OnibiFeatureToken;/m]

    refute_nil record
    refute_match(/\bVALUE\b/, record)
    assert_includes record, "long start;"
    assert_includes record, "long end;"
    assert_includes record, "OnibiAsciiProperty property_kind"
  end

  def test_token_fixed_fields_have_dedicated_accessors
    source = File.read(EXTENSION_SOURCE)
    assert_includes source, "static inline long onibi_token_byte(VALUE token)"
    assert_includes source, "static inline long onibi_token_start(VALUE token)"
    assert_includes source, "static inline long onibi_token_end(VALUE token)"
    assert_includes source, "vector.items[i].start = onibi_token_start(token)"
    assert_includes source, "vector.items[i].end = onibi_token_end(token)"
    assert_includes source, "vector.items[i].name_id = onibi_token_name_id(token)"
    assert_includes source, "static inline unsigned char onibi_token_inline_ignorecase(VALUE token)"
    assert_includes source, "vector.items[i].inline_ignorecase = onibi_token_inline_ignorecase(token)"
  end
end
