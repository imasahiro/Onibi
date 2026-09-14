# frozen_string_literal: true

require "test_helper"

class InternalRegexpDependencyTest < Minitest::Test
  LIBRARY_PATH = File.join(PROJECT_ROOT, "lib")
  EXTENSION_SOURCE = File.join(PROJECT_ROOT, "ext", "onibi", "onibi.c")

  # Read the same implementation files that the amalgamated build reads.
  # This keeps the structural checks tied to the build dependency order.
  def extension_manifest
    File.foreach(EXTENSION_SOURCE).filter_map do |line|
      line[/^\s*#include\s+"([^"]+\.c)"\s*$/, 1]
    end
  end

  def extension_source
    extension_manifest.map do |file|
      path = File.join(File.dirname(EXTENSION_SOURCE), file)
      raise "missing implementation included by #{EXTENSION_SOURCE}: #{file}" unless File.file?(path)

      File.read(path)
    end.join("\n").gsub(/\bstatic\s+([A-Za-z_][A-Za-z0-9_ ]*)\n\s*/, 'static \\1 ')
  end

  def source_for(*files)
    files.map do |file|
      path = File.join(File.dirname(EXTENSION_SOURCE), file)
      raise "missing implementation included by #{EXTENSION_SOURCE}: #{file}" unless File.file?(path)

      File.read(path)
    end.join("\n")
  end

  def test_amalgamated_manifest_resolves_every_implementation_include
    paths = extension_manifest.map do |file|
      path = File.join(File.dirname(EXTENSION_SOURCE), file)
      assert File.file?(path), "missing implementation included by #{EXTENSION_SOURCE}: #{file}"
      path
    end

    assert_includes extension_manifest, "diagnostics.c"
    assert_includes extension_manifest, "unicode.c"
    assert_includes extension_manifest, "rseq_runtime.c"
    assert_includes extension_manifest, "exec_dynamic.c"
    assert_equal paths.length, paths.uniq.length
  end

  def test_library_matching_does_not_use_mri_regexp_operators
    source = Dir[File.join(LIBRARY_PATH, "**", "*.rb")].map { |file| File.read(file) }.join

    refute_includes source, "=~"
    refute_includes source, "/\\s/"
    refute_includes source, "/[A-Za-z0-9_]/"
  end

  def test_native_pipeline_objects_are_not_public_ruby_constants
    refute_includes Onibi.constants(false), :Lexer
    refute_includes Onibi.constants(false), :Parser
    refute_includes Onibi.constants(false), :Compiler
    refute_includes Onibi.constants(false), :VM
    refute_includes Onibi.constants(false), :IRGen
    refute_includes Onibi.constants(false), :AST
    assert_includes Onibi.constants(false), :Regexp
  end

  def test_internal_pipeline_state_is_not_public_api
    internal_methods = %i[tokens ast gir rseq parsed compiled vm graph bytecode_program]

    internal_methods.each do |name|
      refute_includes Onibi::Regexp.instance_methods(false), name
      refute_includes Onibi::Regexp.singleton_methods(false), name
    end
  end

  def test_c_pipeline_does_not_use_repeated_string_comparisons
    source = extension_source

    refute_match(/\b(?:str|mem)?ncmp\s*\(/, source)
    refute_match(/\bstrcmp\s*\(/, source)
  end

  def test_c_pipeline_uses_cached_ids_for_hash_fields
    # Diagnostics intentionally create Ruby hashes at the API boundary.
    # Inspect only compiler and runtime paths for cached field IDs.
    source = source_for(
      "onibi_common.c", "token.c", "ast.c", "parser.c", "gir.c", "compiler.c",
      "rseq.c", "rseq_runtime.c", "match.c"
    )

    refute_match(/rb_hash_(?:aref|aset)\([^\n]*rb_intern\s*\(/, source)
    assert_includes source, "id_key_"
  end

  def test_regexp_state_keeps_rseq_view_and_numeric_flags_in_c
    source = source_for("onibi_common.c")
    regexp_struct = source[/struct onibi_regexp_t \{.*?\};/m]

    refute_nil regexp_struct
    assert_includes regexp_struct, "OnibiRSeqView rseq_view;"
    assert_includes regexp_struct, "OnibiExecutionKind execution_kind;"
    assert_includes regexp_struct, "unsigned int ast_flags;"
    assert_includes regexp_struct, "unsigned int feature_flags;"
    refute_includes regexp_struct, "execution_flags"
    refute_match(/VALUE\s+(?:tokens|ast|graph|states|edges|actions);/, regexp_struct)
  end

  def test_token_and_ast_records_are_c_owned
    token_source = source_for("token.c")
    ast_source = source_for("onibi_common.c")
    token = token_source[/typedef struct \{\s*OnibiTokenKind kind;.*?\} OnibiTokenRecord;/m]
    ast = ast_source[/typedef struct \{\s*OnibiAstKind kind;.*?\} OnibiAstNode;/m]
    arena = ast_source[/typedef struct OnibiAstArena \{.*?\} OnibiAstArena;/m]

    [token, ast, arena].each { |declaration| refute_nil declaration }
    refute_match(/\bVALUE\b/, token)
    refute_match(/\bVALUE\b/, ast)
    assert_includes token, "ID name_id"
    assert_includes token, "OnibiTokenSlice bytes"
    assert_includes ast, "OnibiAstId *children"
    assert_includes arena, "OnibiAstId root"
  end

  def test_tokenizer_and_parser_publish_only_c_records
    source = extension_source
    tokenizer = source[/static void onibi_tokenize_internal\(.*?\n}\n/m]
    parser = source[/static VALUE onibi_parser_parse_internal\(.*?\n}\n/m]

    [tokenizer, parser].each { |method| refute_nil method }
    refute_match(/rb_hash_new|rb_ary_new|rb_str_substr\(/, tokenizer)
    assert_includes tokenizer, "onibi_token_record_push(tokens, record)"
    refute_match(/rb_hash_new|rb_ary_new/, parser)
    assert_includes parser, "onibi_c_parse_range"
    assert_includes parser, "parsed->arena.root"
  end

  def test_tokenizer_cleanup_is_exception_safe
    source = extension_source
    initialize = source[/static VALUE onibi_initialize\(.*?\n}\n/m]

    refute_nil initialize
    assert_includes initialize, "rb_protect(onibi_tokenize_protected"
    assert_includes initialize, "onibi_token_vector_free(&tokens)"
    assert_includes initialize, "rb_jump_tag(tokenize_state)"
  end

  def test_gir_records_and_guards_use_owned_c_vectors
    source = extension_source
    builder = source[/typedef struct \{\s*OnibiGirStateVector states;.*?\} onibi_gir_builder_t;/m]
    records = %w[OnibiGAction OnibiGirStateEntry OnibiGirEdgeEntry OnibiGIRView].map do |name|
      source[/typedef struct \{[^}]*\} #{name};/m]
    end

    refute_nil builder
    records.each do |record|
      refute_nil record
      refute_match(/\bVALUE\b/, record)
    end
    assert_includes builder, "OnibiGuardVector capture_guards"
    assert_includes builder, "OnibiGuardVector exit_guards"
    assert_includes source, "onibi_guard_vector_find_entry"
    assert_includes source, "onibi_g_action_vector_concat"
  end

  def test_compiler_passes_keep_one_directional_c_pipeline
    source = extension_source
    compile = source[/static VALUE\s+onibi_compiler_compile_body.*?^}/m]

    refute_nil compile
    %w[
      onibi_compiler_pass_resolve onibi_compiler_pass_normalize
      onibi_compiler_pass_init_builder onibi_compiler_pass_analyze
      onibi_compiler_pass_lower onibi_compiler_pass_verify_gir
      onibi_compiler_pass_classify onibi_compiler_pass_optimize
      onibi_compiler_pass_publish
    ].each { |pass| assert_includes compile, pass }
    assert_includes compile, "parsed_data->arena.root"
    refute_includes compile, "physical_graph"
    refute_includes compile, "execution_graph"
  end

  def test_compiler_and_rseq_lowering_keep_mutable_records_in_c_storage
    source = extension_source
    lower = source[/static VALUE\s+onibi_rseq_lower_body.*?^}/m]

    refute_nil lower
    assert_includes source, "OnibiCompilerOwner"
    assert_includes source, "onibi_allocation_owner_cleanup"
    assert_includes source, "OnibiRSeqLowerOwner"
    assert_includes lower, "onibi_compiled_get(compiled)"
    assert_includes lower, "onibi_rseq_edge_vector_group_by_from"
    assert_includes lower, "onibi_rseq_intern_class"
    assert_includes lower, "onibi_rseq_intern_actions"
    assert_includes lower, "onibi_rseq_intern_literal"
    assert_includes source_for("rseq.c"), "rb_ensure(onibi_rseq_lower_body"
  end

  def test_rseq_records_have_typed_edges_actions_and_payloads
    source = extension_source
    %w[OnibiRSeqEdgeEntry OnibiRSeqClassPayloadEntry OnibiRSeqActionProgramEntry].each do |name|
      refute_nil source[/typedef struct \{.*?\} #{name};/m]
    end

    assert_includes source, "OnibiRSeqEdgeVector edges"
    assert_includes source, "OnibiRSeqEdgeVector start_edges"
    assert_includes source, "OnibiRSeqActionProgramVector action_programs"
    assert_includes source, "onibi_rseq_edge_vector_group_by_from"
    refute_match(/physical_edges\[i\].*onibi_hash_value\(edge/, source)
  end

  def test_rseq_lowering_uses_numeric_payload_indexes
    source = extension_source
    lower = source[/static VALUE\s+onibi_rseq_lower_body.*?^}/m]

    assert_includes lower, "state->payload_index"
    assert_includes lower, "state_records.entries[i].payload_index"
    assert_includes lower, "uint32_t capture_count"
    refute_includes lower, "capture_count++"
    assert_includes source, "prior->byte"
    assert_includes source, "entry->ignorecase"
  end

  def test_compiler_allocations_are_owned_until_publication
    source = extension_source
    lower = source[/static VALUE\s+onibi_rseq_lower_body.*?^}/m]

    assert_includes source_for("compiler.c"), "rb_ensure(onibi_compiler_compile_body"
    assert_includes source_for("compiler.c"), "onibi_compiler_owner_cleanup"
    assert_includes lower, "onibi_owned_realloc"
    assert_includes source_for("rseq.c"), "rb_ensure(onibi_rseq_lower_body"
    assert_includes source, "onibi_owned_free"
  end

  def test_rseq_view_is_validated_once_and_cached_on_regexp
    source = extension_source
    runtime = source_for("rseq_runtime.c")
    initialize = source_for("onibi_init.c")
    match = source_for("match.c")

    [runtime, initialize, match].each { |method| refute_nil method }
    assert_includes source, "onibi_rseq_view_prepare(&obj->rseq_view)"
    assert_includes source, "obj->rseq_view_valid"
    assert_includes runtime, "onibi_rseq_view_init(blob, &view)"
    assert_includes match, "exec_ctx.view = &obj->rseq_view"
    refute_includes match, "onibi_rseq_view_init"
  end

  def test_search_origin_stays_fixed_across_candidate_starts
    match = source_for("match.c")
    search = match[/static OnibiExecStatus\s+onibi_vm_search_body\(.*?\n}\n/m]

    refute_nil search
    assert_includes search, "exec_ctx.search_origin = search_origin < 0 ? 0 : search_origin;"
    assert_equal 1, search.scan("exec_ctx.search_origin =").length
    assert_includes search, "OnibiBytePos start = search_origin;"
    assert_includes search, "int candidate_valid = onibi_search_candidate_origin("
    assert_includes search, "exec_ctx.attempt_start = start;"
    assert_includes search, "candidate_valid = onibi_search_candidate_next("
    refute_match(/exec_ctx\.search_origin\s*=\s*start/, search)
  end

  def test_regexp_state_has_no_legacy_boolean_feature_fields
    source = source_for("onibi_common.c")
    regexp_struct = source[/struct onibi_regexp_t \{[^}]*\};/m]

    refute_nil regexp_struct
    refute_match(/\bhas_[a-z_]+\b/, regexp_struct)
  end

  def test_regexp_state_owns_exact_ruby_values_and_marks_each_value
    source = source_for("onibi_common.c")
    regexp_struct = source[/struct onibi_regexp_t \{[^}]*\};/m]
    marker = source[/static void\s+onibi_mark\(.*?\n}\n/m]

    refute_nil regexp_struct
    refute_nil marker
    assert_equal %w[regexp source rseq rseq_blob names named_captures],
                 regexp_struct.scan(/VALUE\s+(\w+);/).flatten
    %w[regexp source rseq rseq_blob names named_captures].each do |name|
      assert_includes marker, "rb_gc_mark(obj->#{name});"
    end
  end

  def test_property_classifiers_use_cached_ids_without_text_reinterning
    posix = source_for("gir.c")[/static OnibiPosixKind\s+onibi_posix_kind_id\(.*?\n}\n/m]
    unicode = source_for("diagnostics.c")[/static int\s+onibi_unicode_ctype_id\(.*?\n}\n/m]

    [posix, unicode].each do |classifier|
      refute_nil classifier
      assert_includes classifier, "ID property"
      assert_includes classifier, "rb_intern(names[i])"
      refute_includes classifier, "rb_intern_str"
      refute_includes classifier, "StringValueCStr"
      assert_match(/property\s*==\s*ids\[/, classifier)
    end
  end

  def test_option_array_parsing_uses_cached_option_ids
    source = source_for("rseq.c")
    option_array = source[/if \(RB_TYPE_P\(options, T_ARRAY\)\).*?return mask;\n    }/m]

    refute_nil option_array
    assert_includes option_array, "SYMBOL_P(item) ? SYM2ID(item)"
    %w[id_opt_ignorecase id_opt_multiline id_opt_extended id_opt_fixedencoding
       id_opt_noencoding].each do |id|
      assert_includes option_array, id
    end
    refute_includes option_array, "rb_sym2str(item)"
  end

  def test_rseq_edge_grouping_preserves_stable_scatter_order
    source = source_for("rseq.c")
    grouper = source[/static VALUE\s+onibi_rseq_edge_group_body\(.*?\n}\n/m]
    lower = source[/static VALUE\s+onibi_rseq_lower_body\(.*?\n}\n/m]

    refute_nil grouper
    refute_nil lower
    assert_includes grouper, "owner->ordered[owner->next[from]++] = vector->entries[i]"
    assert_includes lower, "onibi_rseq_edge_vector_group_by_from(&r_edge_records, state_count)"
    assert_includes lower, "size_t edge_count = physical_edge_index - edge_base"
  end

  def test_rseq_edge_records_cache_action_counts_for_physical_lowering
    source = source_for("rseq.c")
    record = source[/typedef struct \{\n    long from;\n    long to;.*?\} OnibiRSeqEdgeEntry;/m]
    lower = source[/static VALUE\s+onibi_rseq_lower_body\(.*?\n}\n/m]

    refute_nil record
    refute_nil lower
    assert_includes record, "uint32_t action_count;"
    assert_includes lower, "(uint32_t)edge_actions->count"
    assert_includes lower, "record->action_count == 0"
  end

  def test_option_payload_survives_gc_stress_during_token_materialization
    previous_stress = GC.stress
    GC.stress = true
    source = Array.new(16, "(?im-mx:a)").join

    assert Onibi::Regexp.new(source).match?("A" * 16)
  ensure
    GC.stress = previous_stress
  end

  def test_encoding_indexes_are_cached_at_initialization_and_checked_once_per_match
    initialize = source_for("rseq.c")
    match = source_for("match.c")
    common = source_for("onibi_common.c")
    eligibility = common[/static (?:int|OnibiRuntimeFallbackReason)\s+onibi_vm_input_eligible\(.*?\n}\n/m]

    assert_includes initialize, "int source_encoding_index = rb_enc_get_index(source);"
    assert_includes initialize, "obj->source_encoding_index = source_encoding_index;"
    assert_equal 1, initialize.scan("rb_enc_get_index(source)").length
    assert_includes match, "onibi_vm_input_eligible(obj, str)"
    refute_nil eligibility
    assert_includes eligibility, "int encoding = rb_enc_get_index(str);"
    assert_equal 1, eligibility.scan("rb_enc_get_index(str)").length
    refute_includes match, "rb_enc_get_index(obj->source)"
  end

  def test_ast_arena_is_released_after_building_the_published_program
    source = source_for("rseq.c")
    build = source[/static VALUE\s+onibi_build_program\(.*?\n}\n/m]

    refute_nil build
    assert_includes build, "onibi_ast_arena_free(&onibi_parsed_get(parsed)->arena)"
  end

  def test_rseq_validator_uses_owned_work_arrays_and_numeric_contracts
    source = extension_source
    validator = source_for("rseq_runtime.c")

    assert_includes validator, "onibi_owned_realloc(&call->allocations"
    assert_includes validator, "onibi_rseq_nullable_verify_paths"
    assert_includes source, "onibi_execution_kind_for_requirements"
    assert_includes validator, "header->exec_kind"
    assert_includes validator, "header->state_count"
    refute_includes validator, "rb_hash_aref"
  end

  def test_one_native_execution_classifier_dispatches_three_c_interpreters
    source = source_for("onibi_common.c")
    dispatcher = source_for("exec_dynamic.c")[/static OnibiExecStatus\s+onibi_execute\(OnibiExecCtx \*ctx\).*?\n}\n/m]

    refute_nil dispatcher
    %w[ONIBI_EXEC_REGULAR ONIBI_EXEC_TAGGED ONIBI_EXEC_DYNAMIC].each do |kind|
      assert_includes dispatcher, kind
    end
    %w[onibi_exec_regular onibi_exec_tagged onibi_exec_dynamic].each do |entry|
      assert_includes dispatcher, entry
    end
    assert_includes source, "onibi_execution_kind_for_requirements"
  end

  def test_executor_state_uses_c_structures_and_typed_byte_positions
    source = source_for("onibi_exec_internal.h")
    context = source[/typedef struct OnibiExecCtx \{.*?\} OnibiExecCtx;/m]
    dynamic = File.read(File.join(PROJECT_ROOT, "ext", "onibi", "exec_dynamic.c"))

    refute_nil context
    assert_includes context, "OnibiSemanticArena semantic_arena;"
    assert_includes context, "const OnibiRSeqView *view;"
    assert_includes context, "OnibiBytePos search_origin;"
    assert_includes context, "OnibiRawMatch *raw_match;"
    assert_match(/static OnibiBytePos\s+onibi_semantic_position_read/, dynamic)
    assert_match(/static OnibiRepeatCount\s+onibi_semantic_counter_read/, dynamic)
    refute_match(/\bVALUE\s+(?:frontier|thread|frame|counter)/, dynamic)
  end

  def test_native_matching_keeps_public_api_at_the_boundary
    assert Onibi::Regexp.new("^a$").match?("a")
    assert Onibi::Regexp.new("(?=a)a").match?("a")
    assert Onibi::Regexp.new("(?<=a)b").match?("ab")
    assert_equal [1, 2], Onibi::Regexp.new("a").match("ba").offset(0)
  end

  def test_byte_position_contract_is_explicit_in_native_sources
    execution = File.read(File.join(PROJECT_ROOT, "ext", "onibi", "onibi_exec_internal.h"))
    header = File.read(File.join(PROJECT_ROOT, "ext", "onibi", "onibi_ir.h"))

    assert_includes execution, "typedef OnigPosition OnibiBytePos;"
    assert_includes execution, "OnibiBytePos begin_byte;"
    assert_includes execution, "OnibiBytePos end_byte;"
    assert_includes header, "typedef long OnibiRepeatCount;"
    refute_match(/long\s+(?:search_origin|current_position|matched_end)/, execution)
  end

  def test_diagnostic_ruby_values_are_not_execution_state
    source = extension_source
    dynamic = File.read(File.join(PROJECT_ROOT, "ext", "onibi", "exec_dynamic.c"))

    assert_includes source, "onibi_diagnostics"
    assert_includes dynamic, "OnibiSemanticState ordered = *semantic;"
    refute_match(/VALUE\s+(?:tokens|ast|graph|states|edges|actions);/, source)
    refute_includes source, "semantic_root"
    refute_includes source, "bytecode_program"
  end

  def test_supported_space_and_word_escapes_use_native_matcher
    assert Onibi::Regexp.new("\\s").match?(" ")
    assert Onibi::Regexp.new("\\s").match?("\n")
    assert Onibi::Regexp.new("\\w+").match?("word_2026")
    refute Onibi::Regexp.new("\\w").match?("é")
  end
end
