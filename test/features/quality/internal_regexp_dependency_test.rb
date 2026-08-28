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

    assert_includes source, "feature_tokens;"
    assert_includes source, "feature_token_count;"
    assert_includes source, "xfree(obj->feature_tokens);"
    assert_includes source, "onibi_feature_token_bytes(obj->feature_token_count)"
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
    assert_includes lowerer, "OnibiValueVector class_payloads"
    assert_includes lowerer, "OnibiValueVector literal_payloads"
    assert_includes lowerer, "onibi_value_vector_free(&class_payloads)"
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
    assert_includes lowerer, "OnibiValueVector action_records"
    assert_includes lowerer, "onibi_value_vector_push(&action_records"
    assert_includes lowerer, "onibi_value_vector_free(&action_records)"
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
    assert_includes lowerer, "action_records.items[i]"
    assert_includes lowerer, "physical.action_count = (uint32_t)action_records.count"
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
    assert_includes record, "OnibiAsciiProperty property_kind"
  end
end
