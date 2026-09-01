# frozen_string_literal: true

require "test_helper"

class ResolvedSemanticAstTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)

  def test_resolved_nodes_are_c_owned_and_hold_lowering_invariants
    source = File.read(File.join(ROOT, "ext/onibi/onibi_common.c"))
    node = source[/typedef struct \{\n    OnibiAstKind kind;.*?\n\} OnibiResolvedNode;/m]

    refute_nil node
    refute_includes node, "VALUE"
    assert_includes node, "uint32_t lexical_options"
    assert_includes node, "OnibiAstId reference_target"
    assert_includes node, "OnibiSubprogramId subprogram_id"
    assert_includes node, "int encoding_index"
    assert_includes node, "int32_t assertion_kind"
    assert_includes node, "long repeat_min"
    assert_includes node, "long source_start"
  end

  def test_passes_establish_semantic_invariants_before_lowering
    source = File.read(File.join(ROOT, "ext/onibi/compiler.c"))
    compile = source[/static VALUE\nonibi_compiler_compile.*?\n\}/m]

    refute_nil compile
    assert_operator compile.index("onibi_compiler_pass_resolve"), :<,
                    compile.index("onibi_compiler_pass_normalize")
    assert_operator compile.index("onibi_compiler_pass_normalize"), :<,
                    compile.index("onibi_compiler_pass_analyze")
    assert_operator compile.index("onibi_compiler_pass_analyze"), :<,
                    compile.index("onibi_compiler_pass_lower")
    assert_includes source, "semantic->lexical_options = options"
    assert_includes source, "semantic->reference_target = target"
    assert_includes source, "node->flags |= ONIBI_SEMANTIC_NORMALIZED"
    assert_includes source, "semantic->flags |= ONIBI_SEMANTIC_ANALYZED"
  end

  def test_lowering_has_no_mutable_option_state
    compiler = File.read(File.join(ROOT, "ext/onibi/compiler.c"))
    gir = File.read(File.join(ROOT, "ext/onibi/gir.c"))
    builder = gir[/typedef struct \{\n    OnibiGirStateVector states;.*?\n\} onibi_gir_builder_t;/m]

    refute_nil builder
    refute_includes builder, "int ignorecase"
    refute_includes builder, "int multiline"
    refute_match(/builder->(?:ignorecase|multiline)/, compiler)
    assert_includes compiler, "resolved_node->lexical_options"
  end

  def test_all_subprogram_ids_exist_before_lowering
    source = File.read(File.join(ROOT, "ext/onibi/compiler.c"))
    lower = source[/static onibi_fragment_t\nonibi_compile_node.*?\n\}/m]

    refute_nil lower
    assert_includes source, "node->kind == ONIBI_AST_ATOMIC"
    assert_includes source, "node->kind == ONIBI_AST_ABSENCE"
    assert_includes source, "onibi_assign_lookaround_subprograms"
    assert_includes source, "semantics->lowered_subprogram_count"
    assert_includes lower, "resolved_node->subprogram_id"
    refute_includes source, "onibi_compile_subprogram("
    refute_includes lower, "onibi_rseq_subprogram_vector_push"
  end
end
