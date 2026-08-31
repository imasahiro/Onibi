static onibi_fragment_t onibi_compile_node(VALUE node_reference,
					   onibi_gir_builder_t *builder);
static void onibi_gir_state(onibi_gir_builder_t *builder, long id,
			    OnibiGStateOp opcode, VALUE payload);
static VALUE onibi_class_payload_with_ctypes(VALUE payload);
static int onibi_unicode_ctype_id(ID property);

typedef struct {
    uint32_t rseq_features;
    uint32_t capture_count;
    uint32_t semantic_capture_count;
    uint32_t counter_count;
    OnibiExecutionKind execution_kind;
} VerifiedGIRAnalysis;

typedef struct {
    OnibiRSeqSubprogramVector subprograms;
    OnibiGirStateVector states;
    OnibiGirEdgeVector edges;
    OnibiGirEdgeVector start_edges;
    long accept;
    long capture_count;
    long counter_count;
    int options;
    VerifiedGIRAnalysis analysis;
} OnibiCompiled;

/* Compiler pass contracts.  These records make ownership and pass order
 * explicit, even while several early analyses still share the C AST. */
typedef struct {
    OnibiParsed *parsed;
    int options;
} OnibiParseOutput;
typedef struct {
    OnibiParsed *parsed;
    int options;
} OnibiResolveOutput;
typedef struct {
    OnibiParsed *parsed;
    int options;
} OnibiNormalizeOutput;
typedef struct {
    OnibiParsed *parsed;
    onibi_gir_builder_t *builder;
    long capture_count;
    int nullable;
    long min_width;
    long max_width;
} OnibiAnalyzeOutput;
typedef struct {
    onibi_gir_builder_t *builder;
    OnibiGirEdgeVector *start_edges;
    long accept;
    long root_entry;
} OnibiLowerNfaOutput;
typedef struct {
    onibi_gir_builder_t *builder;
} OnibiGirOutput;
typedef struct {
    VALUE rseq;
} OnibiRseqOutput;
typedef struct {
    VALUE rseq;
} OnibiSearchMetadataOutput;
typedef struct {
    unsigned char bitmap[32];
    unsigned char negated;
} OnibiNormalizedClass;

static OnibiNormalizedClass
onibi_compiler_normalize_class(VALUE payload, int fold)
{
    VALUE bitmap = onibi_class_bitmap(payload, fold);
    OnibiNormalizedClass normalized;
    if (!RB_TYPE_P(bitmap, T_STRING) || RSTRING_LEN(bitmap) != 32)
	rb_raise(eRegexpError, "class normalization produced invalid bitmap");
    memcpy(normalized.bitmap, RSTRING_PTR(bitmap), 32);
    normalized.negated = RTEST(onibi_hash_value_id(payload, id_key_negated));
    return normalized;
}
static void
onibi_compiled_mark(void *ptr)
{
    (void)ptr;
}
static void
onibi_compiled_free(void *ptr)
{
    OnibiCompiled *compiled = (OnibiCompiled *)ptr;
    if (!compiled) return;
    onibi_gir_state_vector_free(&compiled->states);
    onibi_gir_edge_vector_free(&compiled->edges);
    onibi_gir_edge_vector_free(&compiled->start_edges);
    onibi_rseq_subprogram_vector_free(&compiled->subprograms);
    xfree(ptr);
}
static size_t
onibi_compiled_memsize(const void *ptr)
{
    const OnibiCompiled *compiled = (const OnibiCompiled *)ptr;
    if (!compiled) return 0;
    return sizeof(*compiled) +
	   compiled->states.capacity * sizeof(*compiled->states.entries) +
	   compiled->edges.capacity * sizeof(*compiled->edges.entries) +
	   compiled->start_edges.capacity *
	       sizeof(*compiled->start_edges.entries) +
	   compiled->subprograms.capacity *
	       sizeof(*compiled->subprograms.entries);
}
static const rb_data_type_t onibi_compiled_type = {"Onibi::Compiled",
						   {onibi_compiled_mark,
						    onibi_compiled_free,
						    onibi_compiled_memsize,
						    NULL,
						    {NULL}},
						   0,
						   0,
						   RUBY_TYPED_FREE_IMMEDIATELY};
static inline OnibiCompiled *
onibi_compiled_get(VALUE value)
{
    OnibiCompiled *compiled;
    TypedData_Get_Struct(value, OnibiCompiled, &onibi_compiled_type, compiled);
    return compiled;
}

static long
onibi_compile_subprogram(VALUE body, onibi_gir_builder_t *builder,
			 uint32_t flags)
{
    onibi_fragment_t fragment = onibi_compile_node(body, builder);
    long accept = builder->next_id++;
    onibi_gir_state(builder, accept, ONIBI_G_ACCEPT, Qnil);
    OnibiIdVector accept_starts;
    onibi_id_vector_init(&accept_starts);
    onibi_id_vector_push(&accept_starts, (OnibiStateId)accept);
    onibi_connect_fragment_actions(builder, &fragment.exits, &accept_starts,
				   &fragment.pending_actions, 0);
    long entry =
	fragment.starts.count > 0 ? (long)fragment.starts.entries[0] : accept;
    onibi_rseq_subprogram_vector_push(
	&builder->subprograms,
	(OnibiRSeqSubprogramEntry){(OnibiStateId)entry, (OnibiStateId)accept,
				   flags});
    onibi_id_vector_free(&fragment.starts);
    onibi_id_vector_free(&fragment.exits);
    onibi_id_vector_free(&accept_starts);
    onibi_g_action_vector_free(&fragment.start_actions);
    onibi_g_action_vector_free(&fragment.pending_actions);
    return (long)builder->subprograms.count - 1;
}

/* Resolve pass: collect immutable symbol information from the C AST. */
static void
onibi_compiler_pass_collect_captures(OnibiAstId ast_id,
				     onibi_gir_builder_t *builder,
				     long *next_capture)
{
    OnibiAstNode *node = onibi_ast_node_at(builder->ast, ast_id);
    if (node->kind == ONIBI_AST_CAPTURE) {
	long id = (*next_capture)++;
	node->capture = id;
	onibi_value_map_set(&builder->capture_ids, LONG2NUM(node->start),
			    LONG2NUM(id), builder->map_roots);
	VALUE key = rb_str_new_cstr("");
	char number[32];
	snprintf(number, sizeof(number), "%ld", id + 1);
	key = rb_str_new_cstr(number);
	onibi_value_map_set(&builder->capture_bodies, key, UINT2NUM(node->body),
			    builder->map_roots);
	VALUE name = onibi_ast_slice_string(builder->ast, node->name);
	if (!NIL_P(name)) {
	    if (!NIL_P(onibi_value_map_find(&builder->capture_names, name)))
		rb_raise(
		    eRegexpError,
		    "duplicate named capture requires compatibility execution");
	    /* MRI resolves a duplicate named backreference to the first
	       matching group definition.  Keep the earliest slot in the compile
	       index. */
	    onibi_value_map_set(&builder->capture_names, name, LONG2NUM(id),
				builder->map_roots);
	    onibi_value_map_set(&builder->capture_bodies, name,
				UINT2NUM(node->body), builder->map_roots);
	}
	onibi_compiler_pass_collect_captures(node->body, builder, next_capture);
	return;
    }
    if (node->body != ONIBI_AST_NONE)
	onibi_compiler_pass_collect_captures(node->body, builder, next_capture);
    if (node->atom != ONIBI_AST_NONE)
	onibi_compiler_pass_collect_captures(node->atom, builder, next_capture);
    if (node->yes != ONIBI_AST_NONE)
	onibi_compiler_pass_collect_captures(node->yes, builder, next_capture);
    if (node->no != ONIBI_AST_NONE)
	onibi_compiler_pass_collect_captures(node->no, builder, next_capture);
    for (size_t i = 0; i < node->child_count; i++)
	onibi_compiler_pass_collect_captures(node->children[i], builder,
					     next_capture);
}

static long
onibi_compile_named_subprogram(VALUE name, VALUE body,
			       onibi_gir_builder_t *builder)
{
    long id = (long)builder->subprograms.count;
    onibi_rseq_subprogram_vector_push(
	&builder->subprograms,
	(OnibiRSeqSubprogramEntry){0, 0, 0}); /* reserve recursive target */
    onibi_value_map_set(&builder->subprogram_ids, name, LONG2NUM(id),
			builder->map_roots);
    onibi_value_map_set(&builder->active_subroutines, name, Qtrue,
			builder->map_roots);
    onibi_fragment_t fragment = onibi_compile_node(body, builder);
    onibi_value_map_delete(&builder->active_subroutines, name);
    VALUE capture_id_value =
	onibi_value_map_find(&builder->capture_names, name);
    if (!NIL_P(capture_id_value)) {
	long capture_id = NUM2LONG(capture_id_value);
	OnibiGAction open = {ONIBI_GA_CAPTURE_OPEN,
			     0,
			     0,
			     1,
			     (uint16_t)(2 * capture_id),
			     0,
			     0,
			     0,
			     0};
	OnibiGAction close = {ONIBI_GA_CAPTURE_CLOSE,
			      0,
			      0,
			      1,
			      (uint16_t)(2 * capture_id + 1),
			      0,
			      0,
			      0,
			      0};
	if (RB_INTEGER_TYPE_P(body) &&
	    onibi_c_ast_has_subroutine_name(builder->ast,
					    (OnibiAstId)NUM2UINT(body), name))
	    close.set = 1;
	OnibiGActionVector starts;
	onibi_g_action_vector_init(&starts);
	onibi_g_action_vector_push(&starts, open);
	onibi_g_action_vector_append(&starts, &fragment.start_actions);
	onibi_g_action_vector_free(&fragment.start_actions);
	fragment.start_actions = starts;
	OnibiGActionVector exits;
	onibi_g_action_vector_init(&exits);
	onibi_g_action_vector_push(&exits, close);
	onibi_g_action_vector_append(&exits, &fragment.pending_actions);
	onibi_g_action_vector_free(&fragment.pending_actions);
	fragment.pending_actions = exits;
    }
    long accept = builder->next_id++;
    onibi_gir_state(builder, accept, ONIBI_G_ACCEPT, Qnil);
    OnibiIdVector accept_starts;
    onibi_id_vector_single(&accept_starts, (OnibiStateId)accept);
    onibi_connect_fragment_actions(builder, &fragment.exits, &accept_starts,
				   &fragment.pending_actions, 0);
    long entry =
	fragment.starts.count > 0 ? (long)fragment.starts.entries[0] : accept;
    onibi_rseq_subprogram_vector_store(
	&builder->subprograms, (size_t)id,
	(OnibiRSeqSubprogramEntry){(OnibiStateId)entry, (OnibiStateId)accept,
				   0});
    onibi_id_vector_free(&fragment.starts);
    onibi_id_vector_free(&fragment.exits);
    onibi_id_vector_free(&accept_starts);
    onibi_g_action_vector_free(&fragment.start_actions);
    onibi_g_action_vector_free(&fragment.pending_actions);
    return id;
}

static onibi_fragment_t
onibi_compile_sequence(const OnibiAstNode *sequence,
		       onibi_gir_builder_t *builder)
{
    onibi_fragment_t result = onibi_fragment_empty();
    int have_consuming = 0;
    for (size_t i = 0; i < sequence->child_count; i++) {
	onibi_fragment_t part =
	    onibi_compile_node(UINT2NUM(sequence->children[i]), builder);
	if (part.starts.count == 0) {
	    if (have_consuming) {
		onibi_fragment_append_actions(&result.pending_actions,
					      &part.start_actions);
		onibi_fragment_append_actions(&result.pending_actions,
					      &part.pending_actions);
	    }
	    else {
		onibi_fragment_append_actions(&result.start_actions,
					      &part.start_actions);
		onibi_fragment_append_actions(&result.start_actions,
					      &part.pending_actions);
	    }
	    result.nullable = result.nullable && part.nullable;
	    onibi_id_vector_free(&part.starts);
	    onibi_id_vector_free(&part.exits);
	    onibi_g_action_vector_free(&part.start_actions);
	    onibi_g_action_vector_free(&part.pending_actions);
	    continue;
	}
	if (!have_consuming) {
	    onibi_id_vector_move(&result.starts, &part.starts);
	    onibi_id_vector_move(&result.exits, &part.exits);
	    onibi_fragment_append_actions(&result.start_actions,
					  &part.start_actions);
	    result.lazy = part.lazy;
	    have_consuming = 1;
	}
	else {
	    OnibiIdVector old_exits = result.exits;
	    onibi_id_vector_init(&result.exits);
	    if (result.nullable) {
		if (result.lazy) {
		    OnibiIdVector reordered;
		    onibi_id_vector_init(&reordered);
		    onibi_id_vector_append(&reordered, &part.starts);
		    onibi_id_vector_append(&reordered, &result.starts);
		    onibi_id_vector_free(&result.starts);
		    result.starts = reordered;
		}
		else
		    onibi_id_vector_append(&result.starts, &part.starts);
	    }
	    /* Actions pending at the prior fragment are exit actions.  Store
	     * them on the old exits so nullable continuations and the direct
	     * bypass path both retain the same capture boundaries. */
	    if (result.pending_actions.count > 0)
		onibi_add_exit_guard_fragment(builder, &old_exits,
					       &result.pending_actions);
	    if (part.nullable &&
		(part.start_actions.count > 0 || part.pending_actions.count > 0)) {
		/* A nullable continuation can also be bypassed from old_exits.
		 * Preserve its empty-path actions on that bypass while retaining
		 * the normal actions on the transition into the continuation. */
		OnibiGActionVector bypass_actions =
		    onibi_g_action_vector_concat(&part.start_actions,
						 &part.pending_actions);
		onibi_add_exit_guard_fragment(builder, &old_exits,
					       &bypass_actions);
		onibi_g_action_vector_free(&bypass_actions);
	    }
	    OnibiGActionVector transition_actions =
		onibi_g_action_vector_copy(&part.start_actions);
	    onibi_connect_fragment_actions(builder, &old_exits, &part.starts,
					   &transition_actions, result.lazy);
	    onibi_g_action_vector_free(&transition_actions);
	    onibi_id_vector_move(&result.exits, &part.exits);
	    /* A prior exit can bypass this part only when this part is
	     * nullable. */
	    if (part.nullable)
		onibi_id_vector_append(&result.exits, &old_exits);
	    onibi_id_vector_free(&old_exits);
	    onibi_g_action_vector_free(&result.pending_actions);
	    onibi_g_action_vector_init(&result.pending_actions);
	    result.lazy = part.lazy;
	}
	onibi_fragment_append_actions(&result.pending_actions,
				      &part.pending_actions);
	onibi_g_action_vector_free(&part.start_actions);
	onibi_g_action_vector_free(&part.pending_actions);
	result.nullable = result.nullable && part.nullable;
    }
    return result;
}

static VALUE
onibi_compile_node_field(const onibi_gir_builder_t *builder,
			 const OnibiAstNode *node, VALUE semantic_node, ID key)
{
    if (node == NULL) return onibi_hash_value_id(semantic_node, key);
    if (key == id_key_start)
	return node->start < 0 ? Qnil : LONG2NUM(node->start);
    if (key == id_key_end) return node->end < 0 ? Qnil : LONG2NUM(node->end);
    if (key == id_key_byte) return LONG2NUM(node->byte);
    if (key == id_key_name || key == id_key_options ||
	key == id_key_condition) {
	VALUE name = onibi_ast_slice_string(builder->ast, node->name);
	if (NIL_P(name) && key == id_key_name && node->kind == ONIBI_AST_ESCAPE)
	    return rb_str_new((const char[]){(char)node->byte}, 1);
	return name;
    }
    if (key == id_key_name_id)
	return node->name_id == 0 ? Qnil : ULONG2NUM(node->name_id);
    if (key == id_key_bytes)
	return onibi_ast_slice_string(builder->ast, node->bytes);
    if (key == id_key_negative_options)
	return onibi_ast_slice_string(builder->ast, node->negative_options);
    if (key == id_key_body)
	return node->body == ONIBI_AST_NONE ? Qnil : UINT2NUM(node->body);
    if (key == id_key_atom)
	return node->atom == ONIBI_AST_NONE ? Qnil : UINT2NUM(node->atom);
    if (key == id_key_yes)
	return node->yes == ONIBI_AST_NONE ? Qnil : UINT2NUM(node->yes);
    if (key == id_key_no)
	return node->no == ONIBI_AST_NONE ? Qnil : UINT2NUM(node->no);
    if (key == id_key_capture)
	return node->capture < 0 ? Qnil : LONG2NUM(node->capture);
    if (key == id_key_min) return LONG2NUM(node->min);
    if (key == id_key_max)
	return (node->flags & ONIBI_AST_NODE_HAS_MAX) ? LONG2NUM(node->max)
						      : Qnil;
    if (key == id_key_negated)
	return (node->flags & ONIBI_AST_NODE_NEGATED) ? Qtrue : Qfalse;
    if (key == id_key_negative)
	return (node->flags & ONIBI_AST_NODE_NEGATIVE) ? Qtrue : Qfalse;
    if (key == id_key_positive)
	return (node->flags & ONIBI_AST_NODE_POSITIVE) ? Qtrue : Qfalse;
    if (key == id_key_greedy)
	return (node->flags & ONIBI_AST_NODE_GREEDY) ? Qtrue : Qfalse;
    if (key == id_key_possessive)
	return (node->flags & ONIBI_AST_NODE_POSSESSIVE) ? Qtrue : Qfalse;
    return Qnil;
}

static onibi_fragment_t
onibi_compile_node(VALUE node_reference, onibi_gir_builder_t *builder)
{
    VALUE semantic_node =
	RB_INTEGER_TYPE_P(node_reference) ? Qnil : node_reference;
    const OnibiAstNode *c_node = NULL;
    OnibiAstKind type_code;
    if (RB_INTEGER_TYPE_P(node_reference)) {
	OnibiAstId id = (OnibiAstId)NUM2UINT(node_reference);
	c_node = onibi_ast_node_const(builder->ast, id);
	type_code = c_node->kind;
	if (type_code == ONIBI_AST_CHARACTER_CLASS ||
	    type_code == ONIBI_AST_CLASS_INTERSECTION)
	    semantic_node =
		onibi_gir_payload_from_ast_terminal(builder->ast, id, 1);
	else if (type_code == ONIBI_AST_ESCAPE ||
		 type_code == ONIBI_AST_BACKREF || type_code == ONIBI_AST_ANY)
	    semantic_node =
		onibi_gir_payload_from_ast_terminal(builder->ast, id, 0);
    }
    else {
	type_code = onibi_ast_kind(semantic_node);
    }
    if (type_code == ONIBI_AST_CHARACTER_CLASS) {
	VALUE children = onibi_hash_value_id(semantic_node, id_key_children);
	VALUE ranges = onibi_hash_value_id(semantic_node, id_key_ranges);
	if (!RTEST(onibi_hash_value_id(semantic_node, id_key_negated)) &&
	    RB_TYPE_P(children, T_ARRAY) && RB_TYPE_P(ranges, T_ARRAY) &&
	    RARRAY_LEN(ranges) == 0 && RARRAY_LEN(children) > 0) {
	    int literal_only = 1;
	    for (long i = 0; i < RARRAY_LEN(children); i++) {
		VALUE child = rb_ary_entry(children, i);
		if (onibi_token_kind_code(child) != ONIBI_TOKEN_LITERAL) {
		    literal_only = 0;
		    break;
		}
	    }
	    int has_multibyte = 0;
	    for (long i = 0; literal_only && i < RARRAY_LEN(children); i++) {
		VALUE bytes = onibi_hash_value_id(rb_ary_entry(children, i),
						  id_key_bytes);
		if (!NIL_P(bytes) && RSTRING_LEN(bytes) > 1) has_multibyte = 1;
	    }
	    if (literal_only && has_multibyte) {
		/* A literal-only class is an ordered union of encoded literals.
		   Each branch lowers to one or more G_CHAR states. */
		onibi_fragment_t result = onibi_fragment_empty();
		result.nullable = 0;
		for (long i = 0; i < RARRAY_LEN(children); i++) {
		    VALUE child = rb_hash_dup(rb_ary_entry(children, i));
		    rb_hash_aset(child, ID2SYM(id_key_type_code),
				 UINT2NUM(ONIBI_AST_LITERAL));
		    onibi_fragment_t branch =
			onibi_compile_node(child, builder);
		    onibi_id_vector_append(&result.starts, &branch.starts);
		    onibi_id_vector_append(&result.exits, &branch.exits);
		    onibi_id_vector_free(&branch.starts);
		    onibi_id_vector_free(&branch.exits);
		}
		return result;
	    }
	}
	if (!RTEST(onibi_hash_value_id(semantic_node, id_key_negated)) &&
	    RB_TYPE_P(children, T_ARRAY) && RB_TYPE_P(ranges, T_ARRAY) &&
	    RARRAY_LEN(ranges) > 0 && RARRAY_LEN(ranges) <= 4) {
	    int literal_children = 1;
	    for (long i = 0; i < RARRAY_LEN(children); i++)
		if (onibi_token_kind_code(rb_ary_entry(children, i)) !=
		    ONIBI_TOKEN_LITERAL)
		    literal_children = 0;
	    if (!literal_children) goto skip_utf8_range_expansion;
	    onibi_fragment_t result = onibi_fragment_empty();
	    result.nullable = 0;
	    int expandable = 1;
	    long expanded = 0;
	    for (long i = 0; i < RARRAY_LEN(children); i++) {
		VALUE child = rb_hash_dup(rb_ary_entry(children, i));
		rb_hash_aset(child, ID2SYM(id_key_type_code),
			     UINT2NUM(ONIBI_AST_LITERAL));
		onibi_fragment_t branch = onibi_compile_node(child, builder);
		onibi_id_vector_append(&result.starts, &branch.starts);
		onibi_id_vector_append(&result.exits, &branch.exits);
		onibi_id_vector_free(&branch.starts);
		onibi_id_vector_free(&branch.exits);
	    }
	    for (long i = 0; i < RARRAY_LEN(ranges); i++) {
		VALUE range = rb_ary_entry(ranges, i);
		uint32_t first = 0, last = 0;
		if (!RB_TYPE_P(range, T_ARRAY) || RARRAY_LEN(range) != 2 ||
		    !RB_TYPE_P(rb_ary_entry(range, 0), T_STRING) ||
		    !RB_TYPE_P(rb_ary_entry(range, 1), T_STRING) ||
		    !onibi_utf8_decode(rb_ary_entry(range, 0), &first) ||
		    !onibi_utf8_decode(rb_ary_entry(range, 1), &last) ||
		    last < first || last - first > 256U) {
		    expandable = 0;
		    break;
		}
		expanded += (long)(last - first + 1U);
		if (expanded > 256) {
		    expandable = 0;
		    break;
		}
		for (uint32_t cp = first; cp <= last; cp++) {
		    VALUE literal = rb_hash_new();
		    VALUE bytes = onibi_utf8_encode(cp);
		    rb_hash_aset(literal, ID2SYM(id_key_type_code),
				 UINT2NUM(ONIBI_AST_LITERAL));
		    rb_hash_aset(literal, ID2SYM(id_key_byte),
				 INT2NUM((unsigned char)RSTRING_PTR(bytes)[0]));
		    rb_hash_aset(literal, ID2SYM(id_key_bytes), bytes);
		    onibi_fragment_t branch =
			onibi_compile_node(literal, builder);
		    onibi_id_vector_append(&result.starts, &branch.starts);
		    onibi_id_vector_append(&result.exits, &branch.exits);
		    onibi_id_vector_free(&branch.starts);
		    onibi_id_vector_free(&branch.exits);
		    if (cp == last) break;
		}
	    }
	    if (expandable) return result;
	}
    skip_utf8_range_expansion:;
    }
    if (type_code == ONIBI_AST_SEQUENCE)
	return onibi_compile_sequence(c_node, builder);
    if (type_code == ONIBI_AST_ALTERNATIVE) {
	onibi_fragment_t result = onibi_fragment_empty();
	result.nullable = 0;
	for (size_t i = 0; i < c_node->child_count; i++) {
	    onibi_fragment_t branch =
		onibi_compile_node(UINT2NUM(c_node->children[i]), builder);
	    onibi_id_vector_append(&result.starts, &branch.starts);
	    onibi_id_vector_append(&result.exits, &branch.exits);
	    /* Preserve actions on each alternative edge.  A branch action
	       cannot be lifted to the fragment because that would apply it to
	       siblings. */
	    if (branch.start_actions.count > 0)
		onibi_add_capture_guard_fragment(builder, &branch.starts,
						 &branch.start_actions);
	    if (branch.pending_actions.count > 0)
		onibi_add_exit_guard_fragment(builder, &branch.exits,
					      &branch.pending_actions);
	    result.nullable = result.nullable || branch.nullable;
	    onibi_id_vector_free(&branch.starts);
	    onibi_id_vector_free(&branch.exits);
	    onibi_g_action_vector_free(&branch.start_actions);
	    onibi_g_action_vector_free(&branch.pending_actions);
	}
	return result;
    }
    if (type_code == ONIBI_AST_LITERAL || type_code == ONIBI_AST_ESCAPE ||
	type_code == ONIBI_AST_BACKREF ||
	type_code == ONIBI_AST_CHARACTER_CLASS ||
	type_code == ONIBI_AST_CLASS_INTERSECTION ||
	type_code == ONIBI_AST_ANY) {
	if (type_code == ONIBI_AST_ESCAPE) {
	    VALUE name = onibi_compile_node_field(builder, c_node,
						  semantic_node, id_key_name);
	    VALUE name_id = onibi_compile_node_field(
		builder, c_node, semantic_node, id_key_name_id);
	    int is_property = !NIL_P(name_id) && onibi_ascii_property_name_p(
						     (ID)NUM2ULONG(name_id));
	    if (RB_TYPE_P(name, T_STRING) && RSTRING_LEN(name) > 1 &&
		!is_property)
		rb_raise(
		    eRegexpError,
		    "Unicode property escapes require encoded GIR classes");
	    int code = !RB_TYPE_P(name, T_STRING)
			   ? 0
			   : (RSTRING_LEN(name) == 1
				  ? onibi_ascii_fold(
					(unsigned char)RSTRING_PTR(name)[0])
				  : 0);
	    if ((!RB_TYPE_P(name, T_STRING) || RSTRING_LEN(name) <= 1) &&
		(code == 'r' || code == 'p' || code == 'u'))
		rb_raise(eRegexpError, "escape is not supported in RSeq");
	}
	VALUE payload = semantic_node;
	if (type_code == ONIBI_AST_BACKREF &&
	    !NIL_P(onibi_compile_node_field(builder, c_node, semantic_node,
					    id_key_name))) {
	    VALUE id_value = onibi_value_map_find(
		&builder->capture_names,
		onibi_compile_node_field(builder, c_node, semantic_node,
					 id_key_name));
	    if (NIL_P(id_value))
		rb_raise(eRegexpError, "undefined named backreference");
	    payload = rb_hash_dup(semantic_node);
	    rb_hash_aset(payload, ID2SYM(id_key_capture),
			 LONG2NUM(NUM2LONG(id_value) + 1));
	    rb_obj_freeze(payload);
	}
	if (builder->ignorecase && type_code == ONIBI_AST_BACKREF) {
	    payload = rb_hash_dup(payload);
	    rb_hash_aset(payload, ID2SYM(id_key_ignorecase), Qtrue);
	    rb_obj_freeze(payload);
	}
	VALUE escape_name_for_op = onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_name);
	int grapheme_escape =
	    type_code == ONIBI_AST_ESCAPE &&
	    ((NIL_P(escape_name_for_op) &&
	      RB_INTEGER_TYPE_P(onibi_compile_node_field(
		  builder, c_node, semantic_node, id_key_byte)) &&
	      onibi_ascii_fold((unsigned char)NUM2INT(onibi_compile_node_field(
		  builder, c_node, semantic_node, id_key_byte))) == 'x') ||
	     (!NIL_P(escape_name_for_op) &&
	      RSTRING_LEN(escape_name_for_op) == 1 &&
	      onibi_ascii_fold(
		  (unsigned char)RSTRING_PTR(escape_name_for_op)[0]) == 'x'));
	if (grapheme_escape)
	    rb_raise(eRegexpError,
		     "grapheme matching is not available in this PoC");
	long id = builder->next_id++;
	OnibiGStateOp op =
	    type_code == ONIBI_AST_LITERAL
		? ONIBI_G_CHAR
		: ((type_code == ONIBI_AST_ANY)
		       ? ONIBI_G_ANY
		       : ((type_code == ONIBI_AST_BACKREF)
			      ? ONIBI_G_BACKREF
			      : (grapheme_escape ? ONIBI_G_GRAPHEME
						 : ONIBI_G_CLASS)));
	if (builder->ignorecase && type_code == ONIBI_AST_LITERAL &&
	    !RB_INTEGER_TYPE_P(node_reference)) {
	    payload = rb_hash_dup(payload);
	    rb_hash_aset(payload, ID2SYM(id_key_byte),
			 INT2NUM(onibi_ascii_fold((unsigned char)NUM2INT(
			     onibi_hash_value_id(payload, id_key_byte)))));
	    rb_hash_aset(payload, ID2SYM(id_key_ignorecase), Qtrue);
	    rb_obj_freeze(payload);
	}
	if (builder->ignorecase &&
	    (type_code == ONIBI_AST_CHARACTER_CLASS ||
	     type_code == ONIBI_AST_CLASS_INTERSECTION)) {
	    payload = rb_hash_dup(payload);
	    rb_hash_aset(payload, ID2SYM(id_key_ignorecase), Qtrue);
	    rb_obj_freeze(payload);
	}
	if (type_code == ONIBI_AST_CHARACTER_CLASS ||
	    type_code == ONIBI_AST_CLASS_INTERSECTION) {
	    payload = onibi_class_payload_with_ctypes(payload);
	    rb_hash_aset(payload, ID2SYM(id_key_bitmap),
			 onibi_class_bitmap(payload, builder->ignorecase));
	    rb_obj_freeze(payload);
	}
	if (type_code == ONIBI_AST_ESCAPE) {
	    payload = rb_hash_dup(payload);
	    rb_hash_aset(payload, ID2SYM(id_key_ranges), rb_ary_new());
	    rb_hash_aset(payload, ID2SYM(id_key_children), rb_ary_new());
	    rb_hash_aset(payload, ID2SYM(id_key_bitmap),
			 onibi_class_bitmap(payload, builder->ignorecase));
	    VALUE property_name_id =
		onibi_hash_value_id(payload, id_key_name_id);
	    ID property =
		NIL_P(property_name_id) ? 0 : (ID)NUM2ULONG(property_name_id);
	    int property_ctype = onibi_unicode_ctype_id(property);
	    if (property_ctype >= 0)
		rb_hash_aset(payload, ID2SYM(id_key_ctype),
			     INT2NUM(property_ctype));
	    rb_obj_freeze(payload);
	}
	if (builder->multiline && type_code == ONIBI_AST_ANY) {
	    payload = rb_hash_dup(payload);
	    rb_hash_aset(payload, ID2SYM(id_key_multiline), Qtrue);
	    rb_obj_freeze(payload);
	}
	if (type_code == ONIBI_AST_LITERAL && c_node != NULL) {
	    const unsigned char *bytes =
		c_node->bytes.length == 0
		    ? (const unsigned char *)&c_node->byte
		    : builder->ast->bytes + c_node->bytes.offset;
	    size_t length =
		c_node->bytes.length == 0 ? 1 : c_node->bytes.length;
	    onibi_gir_state_literal(builder, id, bytes, length,
				    builder->ignorecase);
	}
	else if (op == ONIBI_G_CLASS) {
	    OnibiNormalizedClass normalized =
		onibi_compiler_normalize_class(payload, builder->ignorecase);
	    onibi_gir_state_class(builder, id, normalized.bitmap,
				  normalized.negated);
	}
	else {
	    onibi_gir_state(builder, id, op, payload);
	}
	onibi_fragment_t result = onibi_fragment_empty();
	onibi_id_vector_single(&result.starts, (OnibiStateId)id);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_SUBROUTINE) {
	VALUE name = onibi_compile_node_field(builder, c_node, semantic_node,
					      id_key_name);
	VALUE body = NIL_P(name)
			 ? Qnil
			 : onibi_value_map_find(&builder->capture_bodies, name);
	if (NIL_P(body)) rb_raise(eRegexpError, "undefined subroutine call");
	VALUE existing = onibi_value_map_find(&builder->subprogram_ids, name);
	long subprogram_id;
	if (!NIL_P(existing))
	    subprogram_id = NUM2LONG(existing);
	else
	    subprogram_id = onibi_compile_named_subprogram(name, body, builder);
	VALUE payload = rb_hash_new();
	rb_hash_aset(payload, ID2SYM(id_key_subprogram),
		     LONG2NUM(subprogram_id));
	rb_obj_freeze(payload);
	long id = builder->next_id++;
	onibi_gir_state(builder, id, ONIBI_G_CALL, payload);
	onibi_fragment_t result = onibi_fragment_empty();
	onibi_id_vector_single(&result.starts, (OnibiStateId)id);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_OPTION_GLOBAL) {
	VALUE option_names = onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_options);
	int negative = RTEST(onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_negative));
	if (NIL_P(option_names) || !RB_TYPE_P(option_names, T_STRING))
	    rb_raise(eRegexpError, "global option modifier has no flags");
	for (long i = 0; i < RSTRING_LEN(option_names); i++) {
	    int enabled = negative ? 0 : 1;
	    if (RSTRING_PTR(option_names)[i] == 'i')
		builder->ignorecase = enabled;
	    else if (RSTRING_PTR(option_names)[i] == 'm')
		builder->multiline = enabled;
	    else if (RSTRING_PTR(option_names)[i] == 'x')
		continue;
	    else
		rb_raise(eRegexpError, "unknown global option flag");
	}
	VALUE negative_options = onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_negative_options);
	if (!NIL_P(negative_options)) {
	    for (long i = 0; i < RSTRING_LEN(negative_options); i++) {
		if (RSTRING_PTR(negative_options)[i] == 'i')
		    builder->ignorecase = 0;
		else if (RSTRING_PTR(negative_options)[i] == 'm')
		    builder->multiline = 0;
		else if (RSTRING_PTR(negative_options)[i] == 'x')
		    continue;
		else
		    rb_raise(eRegexpError, "unknown global option flag");
	    }
	}
	return onibi_fragment_empty();
    }
    if (type_code == ONIBI_AST_OPTION_SCOPE) {
	VALUE option_names = onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_options);
	if (NIL_P(option_names) || !RB_TYPE_P(option_names, T_STRING))
	    rb_raise(eRegexpError, "option scope has no flags");
	int saved_ignorecase = builder->ignorecase;
	int saved_multiline = builder->multiline;
	int negative = RTEST(onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_negative));
	for (long i = 0; i < RSTRING_LEN(option_names); i++) {
	    int enabled = negative ? 0 : 1;
	    if (RSTRING_PTR(option_names)[i] == 'i')
		builder->ignorecase = enabled;
	    else if (RSTRING_PTR(option_names)[i] == 'm')
		builder->multiline = enabled;
	    else if (RSTRING_PTR(option_names)[i] == 'x')
		continue;
	    else
		rb_raise(eRegexpError, "unknown option scope flag");
	}
	VALUE negative_options = onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_negative_options);
	if (!NIL_P(negative_options)) {
	    for (long i = 0; i < RSTRING_LEN(negative_options); i++) {
		if (RSTRING_PTR(negative_options)[i] == 'i')
		    builder->ignorecase = 0;
		else if (RSTRING_PTR(negative_options)[i] == 'm')
		    builder->multiline = 0;
		else if (RSTRING_PTR(negative_options)[i] == 'x')
		    continue;
		else
		    rb_raise(eRegexpError, "unknown option scope flag");
	    }
	}
	onibi_fragment_t result =
	    onibi_compile_node(onibi_compile_node_field(
				   builder, c_node, semantic_node, id_key_body),
			       builder);
	builder->ignorecase = saved_ignorecase;
	builder->multiline = saved_multiline;
	return result;
    }
    if (type_code == ONIBI_AST_ANCHOR) {
	onibi_fragment_t result = onibi_fragment_empty();
	long marker = NUM2LONG(onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_byte));
	ID op = id_a_assert_end_buffer;
	/* Ruby keeps ^ and $ line anchors independent of the m option.  The
	   option changes dot-newline matching only. */
	if (marker == '^')
	    op = id_a_assert_begin_line;
	else if (marker == '$')
	    op = id_a_assert_end_line;
	else if (marker == 'b')
	    op = id_a_assert_word_boundary;
	else if (marker == 'B')
	    op = id_a_assert_nonword_boundary;
	else if (marker == 'A')
	    op = id_a_assert_begin_buffer;
	else if (marker == 'G')
	    op = id_a_assert_search_origin;
	else if (marker == 'Z')
	    op = id_a_assert_semi_end_buffer;
	OnibiGAction action = {ONIBI_GA_ASSERT_POSITION,
			       0,
			       0,
			       0,
			       0,
			       1,
			       (uint16_t)onibi_rseq_assert_kind(op),
			       0,
			       0};
	onibi_g_action_vector_push(&result.pending_actions, action);
	return result;
    }
    if (type_code == ONIBI_AST_MATCH_RESET) {
	onibi_fragment_t result = onibi_fragment_empty();
	onibi_g_action_vector_push(
	    &result.pending_actions,
	    (OnibiGAction){ONIBI_GA_MATCH_RESET, 0, 0, 0, 0, 0, 0, 0, 0});
	return result;
    }
    if (type_code == ONIBI_AST_CONDITIONAL) {
	VALUE condition = onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_condition);
	char *endptr = NULL;
	const char *condition_text = StringValueCStr(condition);
	long capture_id = strtol(condition_text, &endptr, 10) - 1;
	if (endptr == condition_text || *endptr != '\0') {
	    VALUE named_condition = condition;
	    if (RSTRING_LEN(condition) >= 2 &&
		RSTRING_PTR(condition)[0] == '<' &&
		RSTRING_PTR(condition)[RSTRING_LEN(condition) - 1] == '>')
		named_condition =
		    rb_str_substr(condition, 1, RSTRING_LEN(condition) - 2);
	    VALUE named =
		onibi_value_map_find(&builder->capture_names, named_condition);
	    if (NIL_P(named))
		rb_raise(eRegexpError, "conditional capture is undefined");
	    capture_id = NUM2LONG(named);
	}
	if (capture_id < 0)
	    rb_raise(eRegexpError, "conditional capture is invalid");
	onibi_fragment_t yes =
	    onibi_compile_node(onibi_compile_node_field(
				   builder, c_node, semantic_node, id_key_yes),
			       builder);
	onibi_fragment_t no = onibi_compile_node(
	    onibi_compile_node_field(builder, c_node, semantic_node, id_key_no),
	    builder);
	OnibiGActionVector yes_guard;
	onibi_g_action_vector_init(&yes_guard);
	onibi_g_action_vector_push(&yes_guard,
				   onibi_capture_test_action(capture_id, 1));
	onibi_g_action_vector_append(&yes_guard, &yes.start_actions);
	OnibiGActionVector no_guard;
	onibi_g_action_vector_init(&no_guard);
	onibi_g_action_vector_push(&no_guard,
				   onibi_capture_test_action(capture_id, 0));
	onibi_g_action_vector_append(&no_guard, &no.start_actions);
	for (size_t i = 0; i < yes.starts.count; i++)
	    onibi_guard_vector_add(&builder->capture_guards,
				   yes.starts.entries[i], &yes_guard);
	for (size_t i = 0; i < no.starts.count; i++)
	    onibi_guard_vector_add(&builder->capture_guards,
				   no.starts.entries[i], &no_guard);
	onibi_g_action_vector_free(&yes_guard);
	onibi_g_action_vector_free(&no_guard);
	onibi_add_exit_guard_fragment(builder, &yes.exits,
				      &yes.pending_actions);
	onibi_add_exit_guard_fragment(builder, &no.exits, &no.pending_actions);
	onibi_fragment_t result = onibi_fragment_empty();
	onibi_id_vector_append(&result.starts, &yes.starts);
	onibi_id_vector_append(&result.starts, &no.starts);
	onibi_id_vector_append(&result.exits, &yes.exits);
	onibi_id_vector_append(&result.exits, &no.exits);
	onibi_id_vector_free(&yes.starts);
	onibi_id_vector_free(&yes.exits);
	onibi_id_vector_free(&no.starts);
	onibi_id_vector_free(&no.exits);
	onibi_g_action_vector_free(&yes.start_actions);
	onibi_g_action_vector_free(&yes.pending_actions);
	onibi_g_action_vector_free(&no.start_actions);
	onibi_g_action_vector_free(&no.pending_actions);
	result.nullable = yes.nullable || no.nullable;
	result.lazy = yes.lazy;
	return result;
    }
    if (type_code == ONIBI_AST_ATOMIC) {
	VALUE body = onibi_compile_node_field(builder, c_node, semantic_node,
					      id_key_body);
	long subprogram_id =
	    onibi_compile_subprogram(body, builder, ONIBI_SUBPROGRAM_ATOMIC);
	VALUE payload = rb_hash_new();
	rb_hash_aset(payload, ID2SYM(id_key_subprogram),
		     LONG2NUM(subprogram_id));
	rb_obj_freeze(payload);
	long id = builder->next_id++;
	onibi_gir_state(builder, id, ONIBI_G_ATOMIC, payload);
	onibi_fragment_t result = onibi_fragment_empty();
	onibi_id_vector_single(&result.starts, (OnibiStateId)id);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_ABSENCE) {
	long subprogram_id = onibi_compile_subprogram(
	    onibi_compile_node_field(builder, c_node, semantic_node,
				     id_key_body),
	    builder, ONIBI_SUBPROGRAM_ABSENT);
	VALUE payload = rb_hash_new();
	rb_hash_aset(payload, ID2SYM(id_key_subprogram),
		     LONG2NUM(subprogram_id));
	rb_obj_freeze(payload);
	long id = builder->next_id++;
	onibi_gir_state(builder, id, ONIBI_G_ABSENT, payload);
	onibi_fragment_t result = onibi_fragment_empty();
	onibi_id_vector_single(&result.starts, (OnibiStateId)id);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id);
	result.nullable = 1;
	return result;
    }
    if (type_code == ONIBI_AST_LOOKAHEAD || type_code == ONIBI_AST_LOOKBEHIND) {
	if (c_node == NULL || c_node->body == ONIBI_AST_NONE)
	    rb_raise(eRegexpError, "lookaround body has no literal sequence");
	const OnibiAstNode *body =
	    onibi_ast_node_const(builder->ast, c_node->body);
	if (body->kind != ONIBI_AST_SEQUENCE)
	    rb_raise(eRegexpError, "lookaround body has no literal sequence");
	VALUE bytes = rb_str_new(NULL, 0);
	VALUE predicates = rb_ary_new();
	for (size_t i = 0; i < body->child_count; i++) {
	    OnibiAstId child_id = body->children[i];
	    OnibiAstKind child_type =
		onibi_ast_node_const(builder->ast, child_id)->kind;
	    VALUE child = onibi_gir_payload_from_ast_terminal(
		builder->ast, child_id,
		child_type == ONIBI_AST_CHARACTER_CLASS ||
		    child_type == ONIBI_AST_CLASS_INTERSECTION);
	    if (child_type == ONIBI_AST_CHARACTER_CLASS ||
		child_type == ONIBI_AST_CLASS_INTERSECTION) {
		VALUE predicate = rb_hash_new();
		rb_hash_aset(predicate, ID2SYM(id_key_kind),
			     ID2SYM(id_pred_bitmap));
		rb_hash_aset(predicate, ID2SYM(id_key_predicate_code),
			     UINT2NUM(ONIBI_PRED_BITMAP));
		rb_hash_aset(predicate, ID2SYM(id_key_bitmap),
			     onibi_class_bitmap(child, builder->ignorecase));
		rb_ary_push(predicates, predicate);
		continue;
	    }
	    if (child_type == ONIBI_AST_ANY) {
		VALUE predicate = rb_hash_new();
		rb_hash_aset(predicate, ID2SYM(id_key_kind),
			     ID2SYM(id_pred_any));
		rb_hash_aset(predicate, ID2SYM(id_key_predicate_code),
			     UINT2NUM(ONIBI_PRED_ANY));
		rb_hash_aset(predicate, ID2SYM(id_key_multiline),
			     builder->multiline ? Qtrue : Qfalse);
		rb_ary_push(predicates, predicate);
		continue;
	    }
	    if (child_type == ONIBI_AST_ESCAPE) {
		VALUE name = onibi_hash_value_id(child, id_key_name);
		VALUE name_id = onibi_hash_value_id(child, id_key_name_id);
		int simple =
		    !NIL_P(name) &&
		    ((!NIL_P(name_id) &&
		      onibi_ascii_property_name_p((ID)NUM2ULONG(name_id))) ||
		     (RSTRING_LEN(name) == 1 &&
		      onibi_simple_escape_p(
			  (unsigned char)RSTRING_PTR(name)[0])));
		if (!simple)
		    rb_raise(eRegexpError,
			     "lookaround body has an unsupported escape");
		VALUE payload = rb_hash_dup(child);
		rb_hash_aset(payload, ID2SYM(id_key_ranges), rb_ary_new());
		rb_hash_aset(payload, ID2SYM(id_key_children), rb_ary_new());
		VALUE predicate = rb_hash_new();
		rb_hash_aset(predicate, ID2SYM(id_key_kind),
			     ID2SYM(id_pred_bitmap));
		rb_hash_aset(predicate, ID2SYM(id_key_predicate_code),
			     UINT2NUM(ONIBI_PRED_BITMAP));
		rb_hash_aset(predicate, ID2SYM(id_key_bitmap),
			     onibi_class_bitmap(payload, builder->ignorecase));
		rb_ary_push(predicates, predicate);
		continue;
	    }
	    if (child_type != ONIBI_AST_LITERAL)
		rb_raise(
		    eRegexpError,
		    "lookaround body is not a fixed literal/class sequence");
	    VALUE predicate = rb_hash_new();
	    rb_hash_aset(predicate, ID2SYM(id_key_kind), ID2SYM(id_pred_byte));
	    rb_hash_aset(predicate, ID2SYM(id_key_predicate_code),
			 UINT2NUM(ONIBI_PRED_BYTE));
	    rb_hash_aset(predicate, ID2SYM(id_key_byte),
			 onibi_hash_value_id(child, id_key_byte));
	    rb_hash_aset(predicate, ID2SYM(id_key_ignorecase),
			 builder->ignorecase ? Qtrue : Qfalse);
	    rb_ary_push(predicates, predicate);
	    rb_str_cat(bytes,
		       (const char[]){(char)NUM2INT(
			   onibi_hash_value_id(child, id_key_byte))},
		       1);
	}
	rb_obj_freeze(bytes);
	rb_obj_freeze(predicates);
	ID assertion_op = type_code == ONIBI_AST_LOOKBEHIND
			      ? id_a_assert_lookbehind
			      : id_a_assert_lookahead;
	OnibiGAction action = {
	    ONIBI_GA_ASSERT_POSITION,
	    0,
	    RTEST(onibi_compile_node_field(builder, c_node, semantic_node,
					   id_key_positive))
		? 1
		: 0,
	    0,
	    0,
	    1,
	    (uint16_t)onibi_rseq_assert_kind(assertion_op),
	    1,
	    (uint32_t)RARRAY_LEN(predicates)};
	onibi_fragment_t result = onibi_fragment_empty();
	result.nullable = 1;
	onibi_g_action_vector_push(&result.start_actions, action);
	return result;
    }
    if (type_code == ONIBI_AST_CAPTURE) {
	VALUE capture_ast_key = onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_start);
	VALUE capture_id_value =
	    onibi_value_map_find(&builder->capture_ids, capture_ast_key);
	long capture_id;
	if (NIL_P(capture_id_value)) {
	    capture_id = builder->capture_count++;
	    onibi_value_map_set(&builder->capture_ids, capture_ast_key,
				LONG2NUM(capture_id), builder->map_roots);
	}
	else
	    capture_id = NUM2LONG(capture_id_value);
	VALUE capture_body = onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_body);
	onibi_fragment_t result = onibi_compile_node(capture_body, builder);
	OnibiGAction open = {ONIBI_GA_CAPTURE_OPEN,
			     0,
			     0,
			     1,
			     (uint16_t)(2 * capture_id),
			     0,
			     0,
			     0,
			     0};
	OnibiGAction close = {ONIBI_GA_CAPTURE_CLOSE,
			      0,
			      0,
			      1,
			      (uint16_t)(2 * capture_id + 1),
			      0,
			      0,
			      0,
			      0};
	VALUE capture_name = onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_name);
	if (!NIL_P(capture_name) && RB_INTEGER_TYPE_P(capture_body) &&
	    onibi_c_ast_has_subroutine_name(
		builder->ast, (OnibiAstId)NUM2UINT(capture_body), capture_name))
	    close.set = 1;
	char capture_name_key[32];
	snprintf(capture_name_key, sizeof(capture_name_key), "%ld",
		 capture_id + 1);
	onibi_value_map_set(&builder->capture_bodies,
			    rb_str_new_cstr(capture_name_key),
			    onibi_compile_node_field(
				builder, c_node, semantic_node, id_key_body),
			    builder->map_roots);
	if (!NIL_P(capture_name)) {
	    if (NIL_P(onibi_value_map_find(&builder->capture_names,
					   capture_name)))
		onibi_value_map_set(&builder->capture_names, capture_name,
				    LONG2NUM(capture_id), builder->map_roots);
	    onibi_value_map_set(&builder->capture_bodies, capture_name,
				onibi_compile_node_field(builder, c_node,
							 semantic_node,
							 id_key_body),
				builder->map_roots);
	}
	onibi_g_action_vector_push(&result.start_actions, open);
	onibi_g_action_vector_push(&result.pending_actions, close);
	if (result.nullable)
	    onibi_fragment_append_actions(&result.start_actions,
					  &result.pending_actions);
	return result;
    }
    if (type_code == ONIBI_AST_GROUP)
	return onibi_compile_node(onibi_compile_node_field(builder, c_node,
							   semantic_node,
							   id_key_body),
				  builder);
    if (type_code == ONIBI_AST_QUANTIFIER) {
	VALUE min_value = onibi_compile_node_field(builder, c_node,
						   semantic_node, id_key_min),
	      max_value = onibi_compile_node_field(builder, c_node,
						   semantic_node, id_key_max);
	long min = NUM2LONG(min_value);
	VALUE atom = onibi_compile_node_field(builder, c_node, semantic_node,
					      id_key_atom);
	if (min == 0) builder->optional_seen = 1;
	if (RTEST(onibi_compile_node_field(builder, c_node, semantic_node,
					   id_key_possessive)) &&
	    (NIL_P(max_value) || NUM2LONG(max_value) != min))
	    rb_raise(eRegexpError,
		     "variable possessive quantifier is not supported in RSeq");
	if (RTEST(onibi_compile_node_field(builder, c_node, semantic_node,
					   id_key_possessive)) &&
	    RB_INTEGER_TYPE_P(atom) &&
	    onibi_c_ast_has_capture(builder->ast, (OnibiAstId)NUM2UINT(atom)))
	    rb_raise(eRegexpError,
		     "possessive capture repeat is not supported in RSeq");
	if (!NIL_P(max_value) && min == 0 && NUM2LONG(max_value) == 0)
	    return onibi_fragment_empty();
	if (!NIL_P(max_value) && min == 0 && NUM2LONG(max_value) == 1) {
	    onibi_fragment_t result = onibi_compile_node(
		onibi_compile_node_field(builder, c_node, semantic_node,
					 id_key_atom),
		builder);
	    /* The atom is one ordered branch of the optional.  Keep its tag
	     * actions on that branch only.  Fragment-level start actions also
	     * apply to the nullable bypass edge, which would incorrectly turn
	     * an unset capture into an empty capture. */
	    onibi_add_capture_guard_fragment(builder, &result.starts,
					      &result.start_actions);
	    onibi_add_exit_guard_fragment(builder, &result.exits,
					   &result.pending_actions);
	    onibi_g_action_vector_free(&result.start_actions);
	    onibi_g_action_vector_free(&result.pending_actions);
	    onibi_g_action_vector_init(&result.start_actions);
	    onibi_g_action_vector_init(&result.pending_actions);
	    result.nullable = 1;
	    result.lazy = !RTEST(onibi_compile_node_field(
		builder, c_node, semantic_node, id_key_greedy));
	    return result;
	}
	long counter_slot = -1;
	if (!NIL_P(max_value) && NUM2LONG(max_value) != min)
	    counter_slot = builder->counter_count++;
	onibi_fragment_t result = onibi_fragment_empty();
	result.nullable = min == 0;
	if (!NIL_P(max_value) && NUM2LONG(max_value) < min)
	    rb_raise(eRegexpError, "invalid quantifier range");
	long max = NIL_P(max_value) ? -1 : NUM2LONG(max_value);
	if (max > ONIBI_RSEQ_REPEAT_UNROLL_LIMIT)
	    rb_raise(eRegexpError,
		     "quantifier exceeds RSeq representation limit");
	if (max >= 0 && max <= ONIBI_RSEQ_REPEAT_UNROLL_LIMIT && max != min) {
	    /* Small finite repeats are structurally unrolled.  This keeps the
	     * action-free subset on REGULAR_FAST and reserves counters for
	     * larger repeats.  Fragment order preserves greedy/lazy edge
	     * priority. */
	    for (long i = 0; i < min; i++) {
		onibi_fragment_t part = onibi_compile_node(atom, builder);
		if (i == 0)
		    onibi_id_vector_move(&result.starts, &part.starts);
		else {
		    OnibiGActionVector actions = onibi_g_action_vector_concat(
			&result.pending_actions, &part.start_actions);
		    onibi_connect_fragment_actions(builder, &result.exits,
						   &part.starts, &actions, 0);
		    onibi_g_action_vector_free(&actions);
		}
		onibi_id_vector_move(&result.exits, &part.exits);
		onibi_fragment_append_actions(&result.pending_actions,
					      &part.pending_actions);
		onibi_fragment_append_actions(
		    &result.start_actions,
		    i == 0 ? &part.start_actions : &(OnibiGActionVector){0});
		onibi_g_action_vector_free(&part.start_actions);
		onibi_g_action_vector_free(&part.pending_actions);
	    }
	    for (long i = min; i < max; i++) {
		onibi_fragment_t part = onibi_compile_node(atom, builder);
		if (result.starts.count == 0)
		    onibi_id_vector_move(&result.starts, &part.starts);
		if (result.exits.count > 0) {
		    OnibiGActionVector actions = onibi_g_action_vector_concat(
			&result.pending_actions, &part.start_actions);
		    onibi_connect_fragment_actions(builder, &result.exits,
						   &part.starts, &actions, 0);
		    onibi_g_action_vector_free(&actions);
		}
		onibi_id_vector_append(&result.exits, &part.exits);
		onibi_fragment_append_actions(&result.pending_actions,
					      &part.pending_actions);
		onibi_g_action_vector_free(&part.start_actions);
		onibi_g_action_vector_free(&part.pending_actions);
	    }
	    result.nullable = min == 0;
	    result.lazy = !RTEST(onibi_compile_node_field(
		builder, c_node, semantic_node, id_key_greedy));
	    return result;
	}
	if (max >= 0 && max != min) {
	    /* Counted repeats use one counter slot.  The first start edge
	       initializes it.  Optional bodies use ordered test edges. */
	    OnibiGAction init =
		onibi_counter_action(ONIBI_GA_COUNTER_INIT, counter_slot, Qnil);
	    init.arg32 = (uint32_t)(min > 0 ? 1 : 0);
	    onibi_g_action_vector_push(&result.start_actions, init);
	}
	for (long i = 0; i < min; i++) {
	    onibi_fragment_t part = onibi_compile_node(atom, builder);
	    if (i == 0)
		onibi_id_vector_move(&result.starts, &part.starts);
	    else {
		OnibiGActionVector actions;
		onibi_g_action_vector_init(&actions);
		if (counter_slot >= 0)
		    onibi_g_action_vector_push(
			&actions,
			onibi_counter_action(ONIBI_GA_COUNTER_INCREMENT,
					     counter_slot, Qnil));
		onibi_connect_fragment_actions(builder, &result.exits,
					       &part.starts, &actions, 0);
		onibi_g_action_vector_free(&actions);
	    }
	    onibi_id_vector_move(&result.exits, &part.exits);
	}
	if (max >= 0 && max > min) {
	    long optional = max - min;
	    for (long i = 0; i < optional; i++) {
		onibi_fragment_t part = onibi_compile_node(atom, builder);
		if (result.starts.count == 0)
		    onibi_id_vector_move(&result.starts, &part.starts);
		OnibiGActionVector repeat_actions;
		onibi_g_action_vector_init(&repeat_actions);
		onibi_g_action_vector_push(
		    &repeat_actions,
		    onibi_counter_action(ONIBI_GA_TEST_COUNTER_LT, counter_slot,
					 LONG2NUM(max)));
		onibi_g_action_vector_push(
		    &repeat_actions,
		    onibi_counter_action(ONIBI_GA_COUNTER_INCREMENT,
					 counter_slot, Qnil));
		if (result.exits.count > 0)
		    onibi_connect_fragment_actions(builder, &result.exits,
						   &part.starts,
						   &repeat_actions, 0);
		onibi_g_action_vector_free(&repeat_actions);
		onibi_id_vector_append(&result.exits, &part.exits);
		onibi_id_vector_free(&part.starts);
		onibi_id_vector_free(&part.exits);
	    }
	    onibi_g_action_vector_push(
		&result.pending_actions,
		onibi_counter_action(ONIBI_GA_TEST_COUNTER_GE, counter_slot,
				     LONG2NUM(min)));
	}
	else if (NIL_P(max_value)) {
	    onibi_fragment_t repeat = onibi_compile_node(atom, builder);
	    long progress_slot =
		repeat.nullable ? builder->counter_count++ : -1;
	    if (min == 0 && !repeat.nullable) {
		/* The repeated body is optional.  Its actions belong only to
		 * body and loop edges, never to the zero-iteration accept edge. */
		onibi_add_capture_guard_fragment(builder, &repeat.starts,
						  &repeat.start_actions);
		onibi_add_exit_guard_fragment(builder, &repeat.exits,
						 &repeat.pending_actions);
		onibi_g_action_vector_free(&repeat.start_actions);
		onibi_g_action_vector_free(&repeat.pending_actions);
		onibi_g_action_vector_init(&repeat.start_actions);
		onibi_g_action_vector_init(&repeat.pending_actions);
	    }
	    if (result.starts.count == 0)
		onibi_id_vector_append(&result.starts, &repeat.starts);
	    if (!repeat.nullable)
		onibi_fragment_append_actions(&result.start_actions,
					      &repeat.start_actions);
	    if (result.exits.count > 0) {
		if (repeat.nullable) {
		    onibi_connect_fragment(builder, &result.exits,
					   &repeat.starts);
		}
		else {
		    OnibiGActionVector next_actions =
			onibi_g_action_vector_concat(&repeat.pending_actions,
						     &repeat.start_actions);
		    onibi_connect_fragment_actions(builder, &result.exits,
						   &repeat.starts,
						   &next_actions, 0);
		    onibi_g_action_vector_free(&next_actions);
		}
	    }
	    if (repeat.nullable) {
		OnibiGActionVector progress_actions;
		onibi_g_action_vector_init(&progress_actions);
		if (progress_slot >= 0)
		    onibi_g_action_vector_push(
			&progress_actions,
			onibi_counter_action(ONIBI_GA_PROGRESS, progress_slot,
					     Qnil));
		onibi_connect_fragment_actions(builder, &repeat.exits,
					       &repeat.starts,
					       &progress_actions, 0);
		onibi_g_action_vector_free(&progress_actions);
	    }
	    else {
		OnibiGActionVector loop_actions = onibi_g_action_vector_concat(
		    &repeat.pending_actions, &repeat.start_actions);
		onibi_connect_fragment_actions(
		    builder, &repeat.exits, &repeat.starts, &loop_actions, 0);
		onibi_g_action_vector_free(&loop_actions);
	    }
	    onibi_fragment_append_actions(&result.pending_actions,
					  &repeat.pending_actions);
	    onibi_id_vector_append(&result.exits, &repeat.exits);
	    onibi_id_vector_free(&repeat.starts);
	    onibi_id_vector_free(&repeat.exits);
	}
	result.lazy = !RTEST(onibi_compile_node_field(
	    builder, c_node, semantic_node, id_key_greedy));
	return result;
    }
    rb_raise(eRegexpError, "unsupported AST node");
    return onibi_fragment_empty();
}

/* Initialize pass: create one owner for all mutable compiler state. */
static void
onibi_compiler_pass_init_builder(onibi_gir_builder_t *builder,
				 OnibiParsed *parsed, int ignorecase,
				 int multiline)
{
    memset(builder, 0, sizeof(*builder));
    builder->ast = &parsed->arena;
    onibi_gir_edge_vector_init(&builder->edges);
    onibi_value_map_init(&builder->capture_names);
    onibi_value_map_init(&builder->capture_bodies);
    onibi_value_map_init(&builder->capture_ids);
    onibi_value_map_init(&builder->active_subroutines);
    onibi_value_map_init(&builder->subprogram_ids);
    onibi_rseq_subprogram_vector_init(&builder->subprograms);
    builder->map_roots = rb_ary_new();
    onibi_rseq_subprogram_vector_push(&builder->subprograms,
				      (OnibiRSeqSubprogramEntry){0, 0, 0});
    onibi_guard_vector_init(&builder->capture_guards);
    onibi_guard_vector_init(&builder->exit_guards);
    builder->ignorecase = ignorecase;
    builder->multiline = multiline;
}

/* Lower NFA pass, followed by the explicit epsilon-elimination boundary. */
static void
onibi_compiler_pass_lower(OnibiParsed *parsed, onibi_gir_builder_t *builder,
			  OnibiGirEdgeVector *start_edges, long *accept_out,
			  long *root_entry_out)
{
    OnibiTaggedNfa nfa;
    onibi_nfa_init(&nfa);
    VALUE root_reference = UINT2NUM(parsed->arena.root);
    onibi_fragment_t fragment = onibi_compile_node(root_reference, builder);
    long accept = builder->next_id++;
    onibi_gir_state(builder, accept, ONIBI_G_ACCEPT, Qnil);
    OnibiIdVector accept_starts;
    onibi_id_vector_single(&accept_starts, (OnibiStateId)accept);
    OnibiIdVector exit_ids = fragment.exits;
    onibi_connect_fragment_actions(builder, &exit_ids, &accept_starts,
				   &fragment.pending_actions, fragment.lazy);
    onibi_id_vector_free(&accept_starts);
    onibi_gir_edge_vector_init(start_edges);
    long root_entry =
	fragment.starts.count > 0 ? (long)fragment.starts.entries[0] : accept;
    if (fragment.nullable && fragment.lazy) {
	OnibiGActionVector actions = onibi_g_action_vector_concat(
	    &fragment.start_actions, &fragment.pending_actions);
	onibi_gir_edge_vector_push(start_edges,
				   (OnibiGirEdgeEntry){-1, accept, 0, actions});
    }
    OnibiIdVector start_ids = fragment.starts;
    for (size_t i = 0; i < start_ids.count; i++) {
	long destination = (long)start_ids.entries[i];
	const OnibiGuardEntry *capture_guard = onibi_guard_vector_find_entry(
	    &builder->capture_guards, (OnibiStateId)start_ids.entries[i]);
	OnibiGActionVector actions =
	    onibi_g_action_vector_copy(&fragment.start_actions);
	if (capture_guard) {
	    onibi_g_action_vector_append(&actions, &capture_guard->actions);
	}
	onibi_gir_edge_vector_push(
	    start_edges, (OnibiGirEdgeEntry){-1, destination, 0, actions});
    }
    onibi_id_vector_free(&start_ids);
    onibi_id_vector_free(&exit_ids);
    if (fragment.nullable && !fragment.lazy) {
	OnibiGActionVector actions = onibi_g_action_vector_concat(
	    &fragment.start_actions, &fragment.pending_actions);
	onibi_gir_edge_vector_push(start_edges,
				   (OnibiGirEdgeEntry){-1, accept, 0, actions});
    }
    onibi_g_action_vector_free(&fragment.start_actions);
    onibi_g_action_vector_free(&fragment.pending_actions);
    /* Lowering is complete.  Transfer the mutable graph to the tagged
       epsilon-NFA owner, then run the explicit elimination pass. */
    nfa.states = builder->states;
    /* Convert mutable GIR edges to explicit NFA transitions.  The current
       lowering emits consuming-position edges; future zero-width lowering
       can append ONIBI_NFA_EPSILON edges without changing this pass. */
    for (size_t i = 0; i < builder->edges.count; i++) {
	OnibiGirEdgeEntry *source = &builder->edges.entries[i];
	OnibiNfaEdge edge = {source->from, source->to, ONIBI_NFA_CONSUME,
			     source->actions};
	onibi_nfa_edge_vector_push(&nfa.edges, edge);
	onibi_g_action_vector_init(&source->actions);
    }
    xfree(builder->edges.entries);
    builder->edges.entries = NULL;
    builder->edges.count = 0;
    builder->edges.capacity = 0;
    onibi_gir_state_vector_init(&builder->states);
    onibi_gir_edge_vector_init(&builder->edges);
    nfa.accept = accept;
    onibi_epsilon_eliminate(&nfa, builder);
    onibi_nfa_free(&nfa);
    *accept_out = accept;
    *root_entry_out = root_entry;
}

static void
onibi_compiler_pass_verify_gir(const onibi_gir_builder_t *builder)
{
    for (size_t i = 0; i < builder->edges.count; i++) {
	const OnibiGirEdgeEntry *edge = &builder->edges.entries[i];
	if (edge->from < 0 || edge->to < 0 ||
	    (size_t)edge->from >= builder->states.count ||
	    (size_t)edge->to >= builder->states.count)
	    rb_raise(eRegexpError,
		     "GIR verification failed: edge state is out of range");
    }
}

static VerifiedGIRAnalysis
onibi_compiler_pass_classify(const onibi_gir_builder_t *builder,
			     const OnibiGirEdgeVector *start_edges)
{
    VerifiedGIRAnalysis result = {0, (uint32_t)builder->capture_count, 0, 0,
				  ONIBI_EXEC_REGULAR};
    unsigned char *semantic = NULL;
    if (builder->capture_count > 0) {
	semantic = ALLOC_N(unsigned char, (size_t)builder->capture_count);
	memset(semantic, 0, (size_t)builder->capture_count);
    }
#define MARK_SEMANTIC_CAPTURE(slot) \
    do { \
	uint32_t _slot = (uint32_t)(slot); \
	if (semantic && _slot < result.capture_count && !semantic[_slot]) { \
	    semantic[_slot] = 1; \
	    result.semantic_capture_count++; \
	} \
    } while (0)
    if (result.capture_count > 0)
	result.rseq_features |= ONIBI_RSEQ_FEATURE_CAPTURE;
    for (size_t i = 0; i < builder->states.count; i++) {
	const OnibiGirStateEntry *state = &builder->states.entries[i];
	if (state->opcode == ONIBI_G_GRAPHEME ||
	    state->opcode == ONIBI_G_BACKREF || state->opcode == ONIBI_G_CALL ||
	    state->opcode == ONIBI_G_ATOMIC || state->opcode == ONIBI_G_ABSENT)
	    result.execution_kind = ONIBI_EXEC_DYNAMIC;
	if (state->opcode == ONIBI_G_BACKREF)
	    MARK_SEMANTIC_CAPTURE(state->value);
	if (state->opcode == ONIBI_G_BACKREF)
	    result.rseq_features |= ONIBI_RSEQ_FEATURE_BACKREF;
    }
    for (size_t i = 0; i < builder->edges.count; i++) {
	const OnibiGActionVector *actions = &builder->edges.entries[i].actions;
	for (size_t j = 0; j < actions->count; j++) {
	    const OnibiGAction *action = &actions->entries[j];
	    switch (action->code) {
	    case ONIBI_GA_TEST_CAPTURE:
		MARK_SEMANTIC_CAPTURE(action->slot);
		result.execution_kind = ONIBI_EXEC_DYNAMIC;
		break;
	    case ONIBI_GA_ASSERT_POSITION:
		result.rseq_features |= ONIBI_RSEQ_FEATURE_ASSERTION;
		if (action->assert_kind == ONIBI_RAP_LOOKAHEAD ||
		    action->assert_kind == ONIBI_RAP_LOOKBEHIND)
		    result.rseq_features |= ONIBI_RSEQ_FEATURE_LOOKAROUND;
		if (result.execution_kind == ONIBI_EXEC_REGULAR)
		    result.execution_kind = ONIBI_EXEC_TAGGED;
		break;
	    case ONIBI_GA_MATCH_RESET:
		result.rseq_features |= ONIBI_RSEQ_FEATURE_MATCH_RESET;
		if (result.execution_kind == ONIBI_EXEC_REGULAR)
		    result.execution_kind = ONIBI_EXEC_TAGGED;
		break;
	    case ONIBI_GA_COUNTER_INIT:
		result.rseq_features |= ONIBI_RSEQ_FEATURE_COUNTER;
		break;
	    case ONIBI_GA_CAPTURE_OPEN:
		result.rseq_features |= ONIBI_RSEQ_FEATURE_CAPTURE;
		break;
	    default: break;
	    }
	    if (action->code == ONIBI_GA_PROGRESS ||
		action->code == ONIBI_GA_COUNTER_INIT ||
		action->code == ONIBI_GA_COUNTER_INCREMENT ||
		action->code == ONIBI_GA_TEST_COUNTER_LT ||
		action->code == ONIBI_GA_TEST_COUNTER_GE) {
		if (action->has_slot &&
		    (uint32_t)action->slot + 1U > result.counter_count)
		    result.counter_count = (uint32_t)action->slot + 1U;
		if (result.execution_kind == ONIBI_EXEC_REGULAR)
		    result.execution_kind = ONIBI_EXEC_TAGGED;
	    }
	}
    }
	for (size_t i = 0; i < start_edges->count; i++) {
	const OnibiGActionVector *actions = &start_edges->entries[i].actions;
	for (size_t j = 0; j < actions->count; j++) {
	    const OnibiGAction *action = &actions->entries[j];
	    if (action->code == ONIBI_GA_TEST_CAPTURE) {
		MARK_SEMANTIC_CAPTURE(action->slot);
		result.execution_kind = ONIBI_EXEC_DYNAMIC;
	    }
	    if (action->code == ONIBI_GA_ASSERT_POSITION) {
		result.rseq_features |= ONIBI_RSEQ_FEATURE_ASSERTION;
		if (action->assert_kind == ONIBI_RAP_LOOKAHEAD ||
		    action->assert_kind == ONIBI_RAP_LOOKBEHIND)
		    result.rseq_features |= ONIBI_RSEQ_FEATURE_LOOKAROUND;
		if (result.execution_kind == ONIBI_EXEC_REGULAR)
		    result.execution_kind = ONIBI_EXEC_TAGGED;
	    }
	}
    }
#undef MARK_SEMANTIC_CAPTURE
    if (semantic) xfree(semantic);
    return result;
}

static void
onibi_compiler_pass_optimize(onibi_gir_builder_t *builder)
{
    /* Optimization must not change ordered edge semantics. The first safe
     * optimization is performed by the RSeq lowerer after this boundary. */
    (void)builder;
}

/* Analyze pass.  This pass reads only the immutable AST.  Lowering must not
 * perform these queries while it walks nodes. */
static OnibiAnalyzeOutput
onibi_compiler_pass_analyze(OnibiParsed *parsed, onibi_gir_builder_t *builder)
{
    long captures = 0;
    onibi_compiler_pass_collect_captures(parsed->arena.root, builder,
					 &captures);
    OnibiAstAnalysis ast_analysis = {0};
    int nullable = onibi_ast_nullable_scan(&parsed->arena, parsed->arena.root,
					   &ast_analysis);
    return (OnibiAnalyzeOutput){parsed, builder, captures, nullable, 0, -1};
}

/* Publish pass: transfer verified immutable GIR records to the result. */
static VALUE
onibi_compiler_pass_publish(onibi_gir_builder_t *builder,
			    OnibiGirEdgeVector *start_edges, long accept,
			    long root_entry, long counter_count,
			    int parsed_options, VerifiedGIRAnalysis analysis)
{
    onibi_rseq_subprogram_vector_store(
	&builder->subprograms, 0,
	(OnibiRSeqSubprogramEntry){(OnibiStateId)root_entry,
				   (OnibiStateId)accept, 0});
    OnibiCompiled *compiled_result;
    VALUE result = TypedData_Make_Struct(rb_cObject, OnibiCompiled,
					 &onibi_compiled_type, compiled_result);
    memset(compiled_result, 0, sizeof(*compiled_result));
    onibi_rseq_subprogram_vector_init(&compiled_result->subprograms);
    onibi_gir_state_vector_init(&compiled_result->states);
    onibi_gir_edge_vector_init(&compiled_result->edges);
    onibi_gir_edge_vector_init(&compiled_result->start_edges);
    compiled_result->states = builder->states;
    compiled_result->edges = builder->edges;
    compiled_result->start_edges = *start_edges;
    compiled_result->subprograms = builder->subprograms;
    onibi_gir_state_vector_init(&builder->states);
    onibi_gir_edge_vector_init(&builder->edges);
    onibi_gir_edge_vector_init(start_edges);
    onibi_rseq_subprogram_vector_init(&builder->subprograms);
    compiled_result->accept = accept;
    compiled_result->capture_count = builder->capture_count;
    compiled_result->counter_count = analysis.counter_count;
    compiled_result->analysis = analysis;
    compiled_result->options = parsed_options;
    return result;
}

static VALUE
onibi_compiler_compile(VALUE self, VALUE parsed)
{
    (void)self;
    OnibiParsed *parsed_data = onibi_parsed_get(parsed);
    onibi_compile_encoding = rb_enc_from_index(parsed_data->encoding_index);
    if (parsed_data->arena.root == ONIBI_AST_NONE)
	rb_raise(rb_eArgError, "compiler requires parser output");
    OnibiParseOutput parse = {parsed_data, parsed_data->options};
    /* Resolve names and options are separate contracts.  The parser already
     * stores normalized option bits, so these passes validate and forward it.
     */
    OnibiResolveOutput resolve = {parse.parsed, parse.options};
    OnibiNormalizeOutput normalize = {resolve.parsed, resolve.options};
    int parsed_options = normalize.options;
    int ignorecase = (parsed_options & ONIBI_OPT_IGNORECASE) != 0;
    int multiline = (parsed_options & ONIBI_OPT_MULTILINE) != 0;
    onibi_gir_builder_t builder;
    onibi_compiler_pass_init_builder(&builder, parsed_data, ignorecase,
				     multiline);
    OnibiAnalyzeOutput analyze =
	onibi_compiler_pass_analyze(normalize.parsed, &builder);
    builder.capture_count = analyze.capture_count;
    OnibiGirEdgeVector start_edge_records;
    long accept;
    long root_entry;
    onibi_compiler_pass_lower(parsed_data, &builder, &start_edge_records,
			      &accept, &root_entry);
    OnibiLowerNfaOutput lower_nfa = {&builder, &start_edge_records, accept,
				     root_entry};
    /* onibi_compiler_pass_lower owns the tagged-NFA and epsilon-elimination
     * boundary.  Keep the result contract explicit for later split passes. */
    (void)lower_nfa;
    OnibiGirOutput gir = {&builder};
    (void)gir;
    onibi_compiler_pass_verify_gir(&builder);
    VerifiedGIRAnalysis analysis =
	onibi_compiler_pass_classify(&builder, &start_edge_records);
    onibi_compiler_pass_optimize(&builder);
    VALUE result = onibi_compiler_pass_publish(
	&builder, &start_edge_records, accept, root_entry,
	analysis.counter_count, parsed_options, analysis);
    onibi_gir_edge_vector_free(&start_edge_records);
    onibi_guard_vector_free(&builder.capture_guards);
    onibi_guard_vector_free(&builder.exit_guards);
    onibi_value_map_free(&builder.capture_names);
    onibi_value_map_free(&builder.capture_bodies);
    onibi_value_map_free(&builder.capture_ids);
    onibi_value_map_free(&builder.active_subroutines);
    onibi_value_map_free(&builder.subprogram_ids);
    onibi_rseq_subprogram_vector_free(&builder.subprograms);
    onibi_gir_state_vector_free(&builder.states);
    onibi_gir_edge_vector_free(&builder.edges);
    rb_obj_freeze(result);
    return result;
}
