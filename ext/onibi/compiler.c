static onibi_fragment_t onibi_compile_node(OnibiAstId node_id,
					   onibi_gir_builder_t *builder);

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

/* A compile owner contains every mutable allocation that can outlive one
 * pass.  The owner is stack scoped and is released by rb_ensure. */
typedef struct {
    onibi_allocation_owner_t allocations;
    onibi_gir_builder_t builder;
    OnibiGirEdgeVector start_edges;
    OnibiTaggedNfa nfa;
    onibi_fragment_t root_fragment;
    OnibiIdVector accept_starts;
    OnibiGActionVector pending_actions;
    int nfa_active;
    int root_fragment_active;
    int gir_transferred;
    int failure_phase;
    int *failure_fired;
} OnibiCompilerOwner;
typedef struct {
    OnibiCompilerOwner *owner;
    VALUE parsed;
    int nfa_diagnostics;
} OnibiCompilerCall;

static void
onibi_compiler_fail_if(OnibiCompilerOwner *owner, int phase)
{
    if (owner->failure_phase == phase) {
	if (owner->failure_fired) *owner->failure_fired = 1;
	rb_raise(eRegexpError, "injected compiler failure at pass %d", phase);
    }
}

/* Compiler pass contracts.  These records make ownership and pass order
 * explicit, even while several early analyses still share the C AST. */
typedef struct {
    OnibiParsed *parsed;
    int options;
} OnibiParseOutput;
typedef struct {
    OnibiParsed *parsed;
    const OnibiResolvedArena *semantics;
} OnibiResolveOutput;
typedef struct {
    OnibiParsed *parsed;
    const OnibiResolvedArena *semantics;
} OnibiNormalizeOutput;
typedef struct {
    OnibiParsed *parsed;
    const OnibiResolvedArena *semantics;
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
onibi_compiler_normalize_class(const OnibiAstArena *arena, OnibiAstId id,
			       int fold)
{
    OnibiNormalizedClass normalized;
    onibi_class_bitmap_ast(arena, id, fold, normalized.bitmap);
    normalized.negated =
	(onibi_ast_node_const(arena, id)->flags & ONIBI_AST_NODE_NEGATED) != 0;
    return normalized;
}
static void
onibi_compiled_mark(void *ptr)
{
    (void)ptr;
}

static void
onibi_compiler_owner_cleanup(OnibiCompilerOwner *owner)
{
    if (owner->nfa_active) {
	onibi_nfa_free(&owner->nfa);
	owner->nfa_active = 0;
    }
    onibi_id_vector_free(&owner->accept_starts);
    onibi_g_action_vector_free(&owner->pending_actions);
    if (owner->root_fragment_active) {
	onibi_id_vector_free(&owner->root_fragment.starts);
	onibi_id_vector_free(&owner->root_fragment.exits);
	onibi_g_action_vector_free(&owner->root_fragment.start_actions);
	onibi_g_action_vector_free(&owner->root_fragment.pending_actions);
	owner->root_fragment_active = 0;
    }
    /* Publication reinitializes every transferred vector.  Keep the flag
     * explicit so a later publication path cannot free published storage. */
    onibi_guard_vector_free(&owner->builder.capture_guards);
    onibi_guard_vector_free(&owner->builder.exit_guards);
    if (!owner->gir_transferred) {
	onibi_gir_edge_vector_free(&owner->start_edges);
	onibi_rseq_subprogram_vector_free(&owner->builder.subprograms);
	onibi_gir_state_vector_free(&owner->builder.states);
	onibi_gir_edge_vector_free(&owner->builder.edges);
    }
    onibi_owned_free(&owner->allocations, owner->builder.subprogram_status);
    owner->builder.subprogram_status = NULL;
    onibi_allocation_owner_cleanup(&owner->allocations);
}

static VALUE
onibi_compiler_owner_ensure(VALUE opaque)
{
    onibi_compiler_owner_cleanup((OnibiCompilerOwner *)(uintptr_t)opaque);
    return Qnil;
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

static int
onibi_ast_slice_equal(const OnibiAstArena *arena, OnibiTokenSlice first,
		      OnibiTokenSlice second)
{
    return first.present && second.present && first.length == second.length &&
	   memcmp(arena->bytes + first.offset, arena->bytes + second.offset,
		  first.length) == 0;
}

static uint64_t
onibi_name_hash(const OnibiAstArena *arena, OnibiTokenSlice name)
{
    uint64_t h = UINT64_C(1469598103934665603);
    for (size_t i = 0; i < name.length; i++) {
	h ^= arena->bytes[name.offset + i];
	h *= UINT64_C(1099511628211);
    }
    return h;
}

static OnibiNameIndexEntry *
onibi_name_index_find(OnibiResolvedArena *semantics, const OnibiAstArena *arena,
		      OnibiTokenSlice name)
{
    if (semantics->name_index_capacity == 0) return NULL;
    size_t mask = semantics->name_index_capacity - 1;
    size_t slot = (size_t)onibi_name_hash(arena, name) & mask;
    for (;;) {
	OnibiNameIndexEntry *entry = &semantics->name_entries[slot];
	if (!entry->used) return entry;
	if (onibi_ast_slice_equal(arena, entry->name, name)) return entry;
	slot = (slot + 1) & mask;
    }
}

static void
onibi_name_index_build(OnibiParsed *parsed)
{
    OnibiResolvedArena *semantics = &parsed->semantics;
    size_t needed = semantics->capture_count * 2 + 1;
    size_t capacity = 1;
    while (capacity < needed)
	capacity <<= 1;
    semantics->name_entries = ALLOC_N(OnibiNameIndexEntry, capacity);
    memset(semantics->name_entries, 0,
	   capacity * sizeof(*semantics->name_entries));
    semantics->name_index_capacity = capacity;
    for (size_t i = 0; i < semantics->count; i++) {
	const OnibiAstNode *node =
	    onibi_ast_node_const(&parsed->arena, (OnibiAstId)i);
	if (node->kind != ONIBI_AST_CAPTURE || !node->name.present) continue;
	OnibiNameIndexEntry *entry =
	    onibi_name_index_find(semantics, &parsed->arena, node->name);
	if (!entry->used) {
	    entry->used = 1;
	    entry->name = node->name;
	    entry->subprogram_id = UINT32_MAX;
	    semantics->name_entry_count++;
	}
	if (entry->definition_count == entry->definition_capacity) {
	    size_t cap =
		entry->definition_capacity ? entry->definition_capacity * 2 : 2;
	    REALLOC_N(entry->definitions, OnibiAstId, cap);
	    entry->definition_capacity = cap;
	}
	entry->definitions[entry->definition_count++] = (OnibiAstId)i;
    }
}

static int
onibi_ast_slice_number(const OnibiAstArena *arena, OnibiTokenSlice slice,
		       long *number)
{
    if (!slice.present || slice.length == 0) return 0;
    long value = 0;
    for (size_t i = 0; i < slice.length; i++) {
	unsigned char byte = arena->bytes[slice.offset + i];
	if (byte < '0' || byte > '9') return 0;
	if (value > (LONG_MAX - (byte - '0')) / 10)
	    rb_raise(eRegexpError, "capture number is too large");
	value = value * 10 + (byte - '0');
    }
    *number = value;
    return 1;
}

static OnibiAstId
onibi_resolved_named_capture(const OnibiAstArena *arena,
			     const OnibiResolvedArena *semantics,
			     OnibiTokenSlice name)
{
    OnibiNameIndexEntry *entry =
	onibi_name_index_find((OnibiResolvedArena *)semantics, arena, name);
    if (entry != NULL && entry->used && entry->definition_count != 0)
	return entry->definitions[0];
    return ONIBI_AST_NONE;
}

static OnibiSubprogramId
onibi_resolved_named_subprogram(const OnibiAstArena *arena,
				const OnibiResolvedArena *semantics,
				OnibiTokenSlice name)
{
    OnibiNameIndexEntry *entry =
	onibi_name_index_find((OnibiResolvedArena *)semantics, arena, name);
    return entry != NULL && entry->used ? entry->subprogram_id : UINT32_MAX;
}

static OnibiAstId
onibi_resolved_numbered_capture(const OnibiResolvedArena *semantics,
				long number)
{
    if (number <= 0) return ONIBI_AST_NONE;
    if ((size_t)(number - 1) < semantics->capture_by_number_count)
	return semantics->capture_by_number[number - 1];
    return ONIBI_AST_NONE;
}

static void
onibi_resolve_capture_numbers(OnibiParsed *parsed, OnibiAstId id,
			      long *next_capture)
{
    const OnibiAstNode *node = onibi_ast_node_const(&parsed->arena, id);
    OnibiResolvedNode *semantic = &parsed->semantics.nodes[id];
    if (node->kind == ONIBI_AST_CAPTURE) {
	semantic->capture_id = (int32_t)(*next_capture)++;
    }
    if (node->body != ONIBI_AST_NONE)
	onibi_resolve_capture_numbers(parsed, node->body, next_capture);
    if (node->atom != ONIBI_AST_NONE)
	onibi_resolve_capture_numbers(parsed, node->atom, next_capture);
    if (node->yes != ONIBI_AST_NONE)
	onibi_resolve_capture_numbers(parsed, node->yes, next_capture);
    if (node->no != ONIBI_AST_NONE)
	onibi_resolve_capture_numbers(parsed, node->no, next_capture);
    for (size_t i = 0; i < node->child_count; i++)
	onibi_resolve_capture_numbers(parsed, node->children[i], next_capture);
}

static uint32_t
onibi_resolve_option_slice(const OnibiAstArena *arena, OnibiTokenSlice slice,
			   uint32_t options, int enabled)
{
    if (!slice.present) return options;
    for (size_t i = 0; i < slice.length; i++) {
	uint32_t bit;
	switch (arena->bytes[slice.offset + i]) {
	case 'i': bit = ONIBI_OPT_IGNORECASE; break;
	case 'm': bit = ONIBI_OPT_MULTILINE; break;
	case 'x': bit = ONIBI_OPT_EXTENDED; break;
	default: rb_raise(eRegexpError, "unknown inline option flag");
	}
	if (enabled)
	    options |= bit;
	else
	    options &= ~bit;
    }
    return options;
}

static uint32_t
onibi_resolve_option_node(const OnibiAstArena *arena, const OnibiAstNode *node,
			  uint32_t options)
{
    int enabled = (node->flags & ONIBI_AST_NODE_NEGATIVE) == 0;
    options = onibi_resolve_option_slice(arena, node->name, options, enabled);
    return onibi_resolve_option_slice(arena, node->negative_options, options,
				      0);
}

static uint32_t
onibi_resolve_semantic_node(OnibiParsed *parsed, OnibiAstId id,
			    uint32_t options, uint32_t *next_subprogram)
{
    const OnibiAstArena *arena = &parsed->arena;
    const OnibiAstNode *node = onibi_ast_node_const(arena, id);
    OnibiResolvedNode *semantic = &parsed->semantics.nodes[id];
    semantic->lexical_options = options;
    semantic->encoding_index = parsed->encoding_index;
    semantic->flags |= ONIBI_SEMANTIC_RESOLVED;

    if (node->kind == ONIBI_AST_BACKREF) {
	OnibiAstId target = ONIBI_AST_NONE;
	if (node->name.present)
	    target = onibi_resolved_named_capture(arena, &parsed->semantics,
						  node->name);
	else
	    target = onibi_resolved_numbered_capture(&parsed->semantics,
						     node->capture);
	if (target == ONIBI_AST_NONE)
	    rb_raise(eRegexpError, "undefined backreference");
	semantic->reference_target = target;
	semantic->capture_id = parsed->semantics.nodes[target].capture_id;
    }
    else if (node->kind == ONIBI_AST_SUBROUTINE) {
	long number = 0;
	OnibiAstId target =
	    onibi_ast_slice_number(arena, node->name, &number)
		? onibi_resolved_numbered_capture(&parsed->semantics, number)
		: onibi_resolved_named_capture(arena, &parsed->semantics,
					       node->name);
	if (target == ONIBI_AST_NONE)
	    rb_raise(eRegexpError, "undefined subroutine call");
	semantic->reference_target = target;
	semantic->capture_id = parsed->semantics.nodes[target].capture_id;
	if (number == 0) {
	    OnibiSubprogramId indexed = onibi_resolved_named_subprogram(
		arena, &parsed->semantics, node->name);
	    if (indexed != UINT32_MAX) semantic->subprogram_id = indexed;
	}
	if (semantic->subprogram_id == UINT32_MAX) {
	    if (parsed->semantics.nodes[target].subprogram_id == UINT32_MAX)
		parsed->semantics.nodes[target].subprogram_id =
		    (*next_subprogram)++;
	    semantic->subprogram_id =
		parsed->semantics.nodes[target].subprogram_id;
	    if (number == 0) {
		OnibiNameIndexEntry *entry = onibi_name_index_find(
		    &parsed->semantics, arena, node->name);
		if (entry != NULL)
		    entry->subprogram_id = semantic->subprogram_id;
	    }
	}
    }
    else if (node->kind == ONIBI_AST_ATOMIC ||
	     node->kind == ONIBI_AST_ABSENCE) {
	semantic->subprogram_id = (*next_subprogram)++;
    }
    else if (node->kind == ONIBI_AST_CONDITIONAL) {
	OnibiTokenSlice condition = node->name;
	if (condition.present && condition.length >= 2 &&
	    arena->bytes[condition.offset] == '<' &&
	    arena->bytes[condition.offset + condition.length - 1] == '>') {
	    condition.offset++;
	    condition.length -= 2;
	}
	long number = 0;
	OnibiAstId target =
	    onibi_ast_slice_number(arena, condition, &number)
		? onibi_resolved_numbered_capture(&parsed->semantics, number)
		: onibi_resolved_named_capture(arena, &parsed->semantics,
					       condition);
	if (target == ONIBI_AST_NONE)
	    rb_raise(eRegexpError, "conditional capture is undefined");
	semantic->reference_target = target;
	semantic->capture_id = parsed->semantics.nodes[target].capture_id;
    }

    if (node->kind == ONIBI_AST_SEQUENCE) {
	uint32_t current = options;
	for (size_t i = 0; i < node->child_count; i++) {
	    OnibiAstId child_id = node->children[i];
	    current = onibi_resolve_semantic_node(parsed, child_id, current,
						  next_subprogram);
	}
	return current;
    }
    if (node->kind == ONIBI_AST_ALTERNATIVE) {
	uint32_t current = options;
	for (size_t i = 0; i < node->child_count; i++)
	    current = onibi_resolve_semantic_node(parsed, node->children[i],
						  current, next_subprogram);
	return current;
    }
    if (node->kind == ONIBI_AST_OPTION_GLOBAL) {
	return onibi_resolve_option_node(arena, node, options);
    }
    if (node->kind == ONIBI_AST_OPTION_SCOPE) {
	uint32_t scoped = onibi_resolve_option_node(arena, node, options);
	if (node->body != ONIBI_AST_NONE)
	    (void)onibi_resolve_semantic_node(parsed, node->body, scoped,
					      next_subprogram);
	return options;
    }
    if (node->body != ONIBI_AST_NONE)
	(void)onibi_resolve_semantic_node(parsed, node->body, options,
					  next_subprogram);
    if (node->atom != ONIBI_AST_NONE)
	(void)onibi_resolve_semantic_node(parsed, node->atom, options,
					  next_subprogram);
    if (node->yes != ONIBI_AST_NONE)
	(void)onibi_resolve_semantic_node(parsed, node->yes, options,
					  next_subprogram);
    if (node->no != ONIBI_AST_NONE)
	(void)onibi_resolve_semantic_node(parsed, node->no, options,
					  next_subprogram);
    for (size_t i = 0; i < node->child_count; i++)
	(void)onibi_resolve_semantic_node(parsed, node->children[i], options,
					  next_subprogram);
    return options;
}

static void
onibi_assign_lookaround_subprograms(OnibiParsed *parsed,
				    uint32_t *next_subprogram)
{
    for (size_t i = 0; i < parsed->semantics.count; i++) {
	OnibiResolvedNode *node = &parsed->semantics.nodes[i];
	if (!(node->flags & ONIBI_SEMANTIC_RESOLVED)) continue;
	if (node->kind == ONIBI_AST_LOOKAHEAD ||
	    node->kind == ONIBI_AST_LOOKBEHIND)
	    node->subprogram_id = (*next_subprogram)++;
    }
}

static OnibiResolveOutput
onibi_compiler_pass_resolve(OnibiParseOutput parse, OnibiCompilerOwner *owner)
{
    OnibiParsed *parsed = parse.parsed;
    onibi_resolved_indexes_free(&parsed->semantics);
    xfree(parsed->semantics.nodes);
    parsed->semantics.nodes = NULL;
    parsed->semantics.count = parsed->arena.count;
    parsed->semantics.nodes =
	ALLOC_N(OnibiResolvedNode, parsed->semantics.count);
    for (size_t i = 0; i < parsed->semantics.count; i++) {
	const OnibiAstNode *source =
	    onibi_ast_node_const(&parsed->arena, (OnibiAstId)i);
	OnibiResolvedNode *node = &parsed->semantics.nodes[i];
	memset(node, 0, sizeof(*node));
	node->kind = source->kind;
	node->source_id = (OnibiAstId)i;
	node->reference_target = ONIBI_AST_NONE;
	node->subprogram_id = UINT32_MAX;
	node->capture_id = -1;
	node->assertion_kind = 0;
	node->repeat_max = -1;
	node->max_width = -1;
	node->source_start = source->start;
	node->source_end = source->end;
    }
    long captures = 0;
    onibi_resolve_capture_numbers(parsed, parsed->arena.root, &captures);
    parsed->semantics.capture_count = (uint32_t)captures;
    parsed->semantics.capture_by_number_count = (size_t)captures;
    if (captures != 0)
	parsed->semantics.capture_by_number =
	    ALLOC_N(OnibiAstId, (size_t)captures);
    for (size_t i = 0; i < (size_t)captures; i++)
	parsed->semantics.capture_by_number[i] = ONIBI_AST_NONE;
    for (size_t i = 0; i < parsed->semantics.count; i++) {
	if (parsed->semantics.nodes[i].capture_id >= 0)
	    parsed->semantics
		.capture_by_number[parsed->semantics.nodes[i].capture_id] =
		(OnibiAstId)i;
    }
    onibi_name_index_build(parsed);
    uint32_t subprograms = 1;
    (void)onibi_resolve_semantic_node(parsed, parsed->arena.root,
				      (uint32_t)parse.options, &subprograms);
    for (size_t i = 0; i < parsed->semantics.name_index_capacity; i++) {
	OnibiNameIndexEntry *entry = &parsed->semantics.name_entries[i];
	if (entry->used && entry->definition_count != 0)
	    entry->subprogram_id =
		parsed->semantics.nodes[entry->definitions[0]].subprogram_id;
    }
    parsed->semantics.lowered_subprogram_count = subprograms;
    onibi_assign_lookaround_subprograms(parsed, &subprograms);
    parsed->semantics.subprogram_count = subprograms;
    onibi_compiler_fail_if(owner, 1);
    return (OnibiResolveOutput){parsed, &parsed->semantics};
}

static int32_t
onibi_normalized_assertion(const OnibiAstNode *node)
{
    if (node->kind == ONIBI_AST_LOOKAHEAD) return ONIBI_RAP_LOOKAHEAD;
    if (node->kind == ONIBI_AST_LOOKBEHIND) return ONIBI_RAP_LOOKBEHIND;
    if (node->kind != ONIBI_AST_ANCHOR) return 0;
    switch (node->byte) {
    case '^': return ONIBI_RAP_BEGIN_LINE;
    case '$': return ONIBI_RAP_END_LINE;
    case 'b': return ONIBI_RAP_WORD_BOUNDARY;
    case 'B': return ONIBI_RAP_NONWORD_BOUNDARY;
    case 'A': return ONIBI_RAP_BEGIN_BUFFER;
    case 'G': return ONIBI_RAP_SEARCH_ORIGIN;
    case 'Z': return ONIBI_RAP_SEMI_END_BUFFER;
    default: return ONIBI_RAP_END_BUFFER;
    }
}

static OnibiNormalizeOutput
onibi_compiler_pass_normalize(OnibiResolveOutput resolve,
			      OnibiCompilerOwner *owner)
{
    OnibiParsed *parsed = resolve.parsed;
    for (size_t i = 0; i < resolve.semantics->count; i++) {
	const OnibiAstNode *source =
	    onibi_ast_node_const(&parsed->arena, (OnibiAstId)i);
	OnibiResolvedNode *node = &parsed->semantics.nodes[i];
	if (!(node->flags & ONIBI_SEMANTIC_RESOLVED)) continue;
	if (node->kind != source->kind || node->encoding_index < 0)
	    rb_raise(eRegexpError, "semantic resolve invariant failed");
	node->assertion_kind = onibi_normalized_assertion(source);
	if (source->kind == ONIBI_AST_QUANTIFIER) {
	    if (source->min < 0 || ((source->flags & ONIBI_AST_NODE_HAS_MAX) &&
				    source->max < source->min))
		rb_raise(eRegexpError, "invalid normalized repeat");
	    node->repeat_min = source->min;
	    node->repeat_max =
		(source->flags & ONIBI_AST_NODE_HAS_MAX) ? source->max : -1;
	    if (source->flags & ONIBI_AST_NODE_HAS_MAX)
		node->flags |= ONIBI_SEMANTIC_REPEAT_HAS_MAX;
	    if (source->flags & ONIBI_AST_NODE_GREEDY)
		node->flags |= ONIBI_SEMANTIC_REPEAT_GREEDY;
	    if (source->flags & ONIBI_AST_NODE_POSSESSIVE)
		node->flags |= ONIBI_SEMANTIC_REPEAT_POSSESSIVE;
	}
	node->flags |= ONIBI_SEMANTIC_NORMALIZED;
    }
    onibi_compiler_fail_if(owner, 2);
    return (OnibiNormalizeOutput){parsed, resolve.semantics};
}

static long
onibi_width_add(long first, long second)
{
    if (first < 0 || second < 0) return -1;
    if (first > LONG_MAX - second) return -1;
    return first + second;
}

static long
onibi_width_multiply(long width, long count)
{
    if (width < 0 || count < 0) return -1;
    if (count != 0 && width > LONG_MAX / count) return -1;
    return width * count;
}

static void
onibi_analyze_semantic_node(OnibiParsed *parsed, OnibiAstId id)
{
    OnibiResolvedNode *semantic = &parsed->semantics.nodes[id];
    const OnibiAstNode *node = onibi_ast_node_const(&parsed->arena, id);
    if (semantic->flags & ONIBI_SEMANTIC_ANALYZED) return;
    if (semantic->flags & ONIBI_SEMANTIC_ANALYZING) {
	semantic->min_width = 0;
	semantic->max_width = -1;
	semantic->flags |= ONIBI_SEMANTIC_ANALYZED | ONIBI_SEMANTIC_NULLABLE;
	return;
    }
    semantic->flags |= ONIBI_SEMANTIC_ANALYZING;
    long min = 0;
    long max = 0;
    int nullable = 1;
    switch (node->kind) {
    case ONIBI_AST_LITERAL:
    case ONIBI_AST_ESCAPE:
    case ONIBI_AST_ANY:
    case ONIBI_AST_CHARACTER_CLASS:
    case ONIBI_AST_CLASS_INTERSECTION:
	for (size_t i = 0; i < node->child_count; i++)
	    onibi_analyze_semantic_node(parsed, node->children[i]);
	min = max = 1;
	nullable = 0;
	break;
    case ONIBI_AST_BACKREF:
	min = 0;
	max = -1;
	nullable = 1;
	break;
    case ONIBI_AST_SEQUENCE:
	for (size_t i = 0; i < node->child_count; i++) {
	    onibi_analyze_semantic_node(parsed, node->children[i]);
	    OnibiResolvedNode *child =
		&parsed->semantics.nodes[node->children[i]];
	    min = onibi_width_add(min, child->min_width);
	    max = onibi_width_add(max, child->max_width);
	    nullable =
		nullable && ((child->flags & ONIBI_SEMANTIC_NULLABLE) != 0);
	}
	break;
    case ONIBI_AST_ALTERNATIVE:
	min = LONG_MAX;
	max = 0;
	nullable = 0;
	for (size_t i = 0; i < node->child_count; i++) {
	    onibi_analyze_semantic_node(parsed, node->children[i]);
	    OnibiResolvedNode *child =
		&parsed->semantics.nodes[node->children[i]];
	    if (child->min_width < min) min = child->min_width;
	    if (child->max_width < 0 || max < 0)
		max = -1;
	    else if (child->max_width > max)
		max = child->max_width;
	    nullable =
		nullable || ((child->flags & ONIBI_SEMANTIC_NULLABLE) != 0);
	}
	if (min == LONG_MAX) min = 0;
	break;
    case ONIBI_AST_QUANTIFIER: {
	onibi_analyze_semantic_node(parsed, node->atom);
	OnibiResolvedNode *atom = &parsed->semantics.nodes[node->atom];
	min = onibi_width_multiply(atom->min_width, semantic->repeat_min);
	max = semantic->repeat_max < 0
		  ? -1
		  : onibi_width_multiply(atom->max_width, semantic->repeat_max);
	nullable = semantic->repeat_min == 0 ||
		   ((atom->flags & ONIBI_SEMANTIC_NULLABLE) != 0);
	break;
    }
    case ONIBI_AST_CAPTURE:
    case ONIBI_AST_GROUP:
    case ONIBI_AST_ATOMIC:
    case ONIBI_AST_OPTION_SCOPE:
	onibi_analyze_semantic_node(parsed, node->body);
	min = parsed->semantics.nodes[node->body].min_width;
	max = parsed->semantics.nodes[node->body].max_width;
	nullable = (parsed->semantics.nodes[node->body].flags &
		    ONIBI_SEMANTIC_NULLABLE) != 0;
	break;
    case ONIBI_AST_SUBROUTINE: {
	OnibiAstId target = semantic->reference_target;
	const OnibiAstNode *capture =
	    onibi_ast_node_const(&parsed->arena, target);
	onibi_analyze_semantic_node(parsed, capture->body);
	min = parsed->semantics.nodes[capture->body].min_width;
	max = parsed->semantics.nodes[capture->body].max_width;
	nullable = (parsed->semantics.nodes[capture->body].flags &
		    ONIBI_SEMANTIC_NULLABLE) != 0;
	break;
    }
    case ONIBI_AST_CONDITIONAL:
	onibi_analyze_semantic_node(parsed, node->yes);
	onibi_analyze_semantic_node(parsed, node->no);
	min = parsed->semantics.nodes[node->yes].min_width <
		      parsed->semantics.nodes[node->no].min_width
		  ? parsed->semantics.nodes[node->yes].min_width
		  : parsed->semantics.nodes[node->no].min_width;
	max = parsed->semantics.nodes[node->yes].max_width;
	if (max >= 0 && (parsed->semantics.nodes[node->no].max_width < 0 ||
			 parsed->semantics.nodes[node->no].max_width > max))
	    max = parsed->semantics.nodes[node->no].max_width;
	nullable = ((parsed->semantics.nodes[node->yes].flags |
		     parsed->semantics.nodes[node->no].flags) &
		    ONIBI_SEMANTIC_NULLABLE) != 0;
	break;
    case ONIBI_AST_ABSENCE:
	onibi_analyze_semantic_node(parsed, node->body);
	min = 0;
	max = -1;
	nullable = 1;
	break;
    case ONIBI_AST_LOOKAHEAD:
    case ONIBI_AST_LOOKBEHIND:
	onibi_analyze_semantic_node(parsed, node->body);
	min = max = 0;
	nullable = 1;
	break;
    default:
	min = max = 0;
	nullable = 1;
	break;
    }
    semantic->min_width = min;
    semantic->max_width = max;
    semantic->flags &= ~ONIBI_SEMANTIC_ANALYZING;
    semantic->flags |= ONIBI_SEMANTIC_ANALYZED;
    if (nullable) semantic->flags |= ONIBI_SEMANTIC_NULLABLE;
}

static long
onibi_compile_resolved_body_subprogram(OnibiAstId body,
				       OnibiSubprogramId subprogram_id,
				       onibi_gir_builder_t *builder,
				       uint32_t flags)
{
    if (subprogram_id == 0 ||
	(size_t)subprogram_id >= builder->resolved_subprogram_count)
	rb_raise(eRegexpError, "resolved subprogram ID is invalid");
    if (builder->subprogram_status[subprogram_id] != 0)
	return (long)subprogram_id;
    builder->subprogram_status[subprogram_id] = 1;
    onibi_fragment_t fragment = onibi_compile_node(body, builder);
    long accept = builder->next_id++;
    onibi_nfa_state(builder, accept, ONIBI_G_ACCEPT, 0, 0);
    OnibiIdVector accept_starts;
    onibi_id_vector_init(&accept_starts);
    onibi_id_vector_bind(&accept_starts, builder->allocation_owner);
    onibi_id_vector_push(&accept_starts, (OnibiStateId)accept);
    onibi_connect_fragment_actions(builder, &fragment.exits, &accept_starts,
				   &fragment.pending_actions, 0);
    long entry =
	fragment.starts.count > 0 ? (long)fragment.starts.entries[0] : accept;

    onibi_rseq_subprogram_vector_store(
	&builder->subprograms, (size_t)subprogram_id,
	(OnibiRSeqSubprogramEntry){(OnibiStateId)entry, (OnibiStateId)accept,
				   flags});
    onibi_id_vector_free(&fragment.starts);
    onibi_id_vector_free(&fragment.exits);
    onibi_id_vector_free(&accept_starts);
    onibi_g_action_vector_free(&fragment.start_actions);
    onibi_g_action_vector_free(&fragment.pending_actions);
    builder->subprogram_status[subprogram_id] = 2;
    return (long)subprogram_id;
}

static int
onibi_semantic_has_call(const onibi_gir_builder_t *builder, OnibiAstId id,
			OnibiSubprogramId subprogram_id)
{
    const OnibiAstNode *node = onibi_ast_node_const(builder->ast, id);
    const OnibiResolvedNode *semantic = &builder->semantics->nodes[id];
    if (node->kind == ONIBI_AST_SUBROUTINE &&
	semantic->subprogram_id == subprogram_id)
	return 1;
    if (node->body != ONIBI_AST_NONE &&
	onibi_semantic_has_call(builder, node->body, subprogram_id))
	return 1;
    if (node->atom != ONIBI_AST_NONE &&
	onibi_semantic_has_call(builder, node->atom, subprogram_id))
	return 1;
    if (node->yes != ONIBI_AST_NONE &&
	onibi_semantic_has_call(builder, node->yes, subprogram_id))
	return 1;
    if (node->no != ONIBI_AST_NONE &&
	onibi_semantic_has_call(builder, node->no, subprogram_id))
	return 1;
    for (size_t i = 0; i < node->child_count; i++)
	if (onibi_semantic_has_call(builder, node->children[i], subprogram_id))
	    return 1;
    return 0;
}

static long
onibi_compile_resolved_subprogram(OnibiAstId capture_id,
				  OnibiSubprogramId subprogram_id,
				  onibi_gir_builder_t *builder)
{
    if (subprogram_id == 0 ||
	(size_t)subprogram_id >= builder->resolved_subprogram_count)
	rb_raise(eRegexpError, "resolved subprogram ID is invalid");
    if (builder->subprogram_status[subprogram_id] != 0)
	return (long)subprogram_id;
    builder->subprogram_status[subprogram_id] = 1;
    const OnibiAstNode *capture =
	onibi_ast_node_const(builder->ast, capture_id);
    const OnibiResolvedNode *capture_semantic =
	&builder->semantics->nodes[capture_id];
    onibi_fragment_t fragment = onibi_compile_node(capture->body, builder);
    long capture_slot = capture_semantic->capture_id;
    if (capture_slot >= 0) {
	OnibiGAction open = {ONIBI_GA_CAPTURE_OPEN,
			     0,
			     0,
			     1,
			     (uint16_t)(2 * capture_slot),
			     0,
			     0,
			     0,
			     0};
	OnibiGAction close = {ONIBI_GA_CAPTURE_CLOSE,
			      0,
			      0,
			      1,
			      (uint16_t)(2 * capture_slot + 1),
			      0,
			      0,
			      0,
			      0};
	if (onibi_semantic_has_call(builder, capture->body, subprogram_id))
	    close.set = 1;
	OnibiGActionVector starts;
	onibi_g_action_vector_init(&starts);
	onibi_g_action_vector_bind(&starts, builder->allocation_owner);
	onibi_g_action_vector_push(&starts, open);
	onibi_g_action_vector_append(&starts, &fragment.start_actions);
	onibi_g_action_vector_free(&fragment.start_actions);
	fragment.start_actions = starts;
	OnibiGActionVector exits;
	onibi_g_action_vector_init(&exits);
	onibi_g_action_vector_bind(&exits, builder->allocation_owner);
	onibi_g_action_vector_push(&exits, close);
	onibi_g_action_vector_append(&exits, &fragment.pending_actions);
	onibi_g_action_vector_free(&fragment.pending_actions);
	fragment.pending_actions = exits;
    }
    long accept = builder->next_id++;
    onibi_nfa_state(builder, accept, ONIBI_G_ACCEPT, 0, 0);
    OnibiIdVector accept_starts;
    onibi_id_vector_single(&accept_starts, (OnibiStateId)accept,
			   builder->allocation_owner);
    onibi_connect_fragment_actions(builder, &fragment.exits, &accept_starts,
				   &fragment.pending_actions, 0);
    long entry =
	fragment.starts.count > 0 ? (long)fragment.starts.entries[0] : accept;
    onibi_rseq_subprogram_vector_store(
	&builder->subprograms, (size_t)subprogram_id,
	(OnibiRSeqSubprogramEntry){(OnibiStateId)entry, (OnibiStateId)accept,
				   0});
    onibi_id_vector_free(&fragment.starts);
    onibi_id_vector_free(&fragment.exits);
    onibi_id_vector_free(&accept_starts);
    onibi_g_action_vector_free(&fragment.start_actions);
    onibi_g_action_vector_free(&fragment.pending_actions);
    builder->subprogram_status[subprogram_id] = 2;
    return (long)subprogram_id;
}

static onibi_fragment_t
onibi_compile_sequence(const OnibiAstNode *sequence,
		       onibi_gir_builder_t *builder)
{
    onibi_fragment_t result = onibi_fragment_empty(builder);
    int have_consuming = 0;
    for (size_t i = 0; i < sequence->child_count; i++) {
	onibi_fragment_t part =
	    onibi_compile_node(sequence->children[i], builder);
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
	    onibi_id_vector_bind(&result.exits, builder->allocation_owner);
	    if (result.nullable) {
		if (result.lazy) {
		    OnibiIdVector reordered;
		    onibi_id_vector_init(&reordered);
		    onibi_id_vector_bind(&reordered, builder->allocation_owner);
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
	    if (part.nullable && (part.start_actions.count > 0 ||
				  part.pending_actions.count > 0)) {
		/* A nullable continuation can also be bypassed from old_exits.
		 * Preserve its empty-path actions on that bypass while
		 * retaining the normal actions on the transition into the
		 * continuation. */
		OnibiGActionVector bypass_actions =
		    onibi_g_action_vector_concat(&part.start_actions,
						 &part.pending_actions,
						 builder->allocation_owner);
		onibi_add_exit_guard_fragment(builder, &old_exits,
					      &bypass_actions);
		onibi_g_action_vector_free(&bypass_actions);
	    }
	    OnibiGActionVector transition_actions = onibi_g_action_vector_copy(
		&part.start_actions, builder->allocation_owner);
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
	    onibi_g_action_vector_bind(&result.pending_actions,
				       builder->allocation_owner);
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

static int
onibi_utf8_decode_bytes(const unsigned char *bytes, size_t length,
			uint32_t *codepoint)
{
    if (length == 1 && bytes[0] < 0x80) {
	*codepoint = bytes[0];
	return 1;
    }
    if (length == 2 && (bytes[0] & 0xe0) == 0xc0 && (bytes[1] & 0xc0) == 0x80) {
	*codepoint = ((uint32_t)(bytes[0] & 0x1f) << 6) | (bytes[1] & 0x3f);
	return *codepoint >= 0x80;
    }
    if (length == 3 && (bytes[0] & 0xf0) == 0xe0 && (bytes[1] & 0xc0) == 0x80 &&
	(bytes[2] & 0xc0) == 0x80) {
	*codepoint = ((uint32_t)(bytes[0] & 0x0f) << 12) |
		     ((uint32_t)(bytes[1] & 0x3f) << 6) | (bytes[2] & 0x3f);
	return *codepoint >= 0x800;
    }
    if (length == 4 && (bytes[0] & 0xf8) == 0xf0 && (bytes[1] & 0xc0) == 0x80 &&
	(bytes[2] & 0xc0) == 0x80 && (bytes[3] & 0xc0) == 0x80) {
	*codepoint = ((uint32_t)(bytes[0] & 0x07) << 18) |
		     ((uint32_t)(bytes[1] & 0x3f) << 12) |
		     ((uint32_t)(bytes[2] & 0x3f) << 6) | (bytes[3] & 0x3f);
	return *codepoint >= 0x10000 && *codepoint <= 0x10ffff;
    }
    return 0;
}

static size_t
onibi_utf8_encode_bytes(uint32_t codepoint, unsigned char bytes[4])
{
    if (codepoint <= 0x7f) {
	bytes[0] = (unsigned char)codepoint;
	return 1;
    }
    if (codepoint <= 0x7ff) {
	bytes[0] = (unsigned char)(0xc0 | (codepoint >> 6));
	bytes[1] = (unsigned char)(0x80 | (codepoint & 0x3f));
	return 2;
    }
    if (codepoint <= 0xffff && !(codepoint >= 0xd800 && codepoint <= 0xdfff)) {
	bytes[0] = (unsigned char)(0xe0 | (codepoint >> 12));
	bytes[1] = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3f));
	bytes[2] = (unsigned char)(0x80 | (codepoint & 0x3f));
	return 3;
    }
    if (codepoint <= 0x10ffff) {
	bytes[0] = (unsigned char)(0xf0 | (codepoint >> 18));
	bytes[1] = (unsigned char)(0x80 | ((codepoint >> 12) & 0x3f));
	bytes[2] = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3f));
	bytes[3] = (unsigned char)(0x80 | (codepoint & 0x3f));
	return 4;
    }
    return 0;
}

static onibi_fragment_t
onibi_compile_literal_bytes(const unsigned char *bytes, size_t length,
			    int ignorecase, onibi_gir_builder_t *builder)
{
    long id = builder->next_id++;
    onibi_nfa_state_literal(builder, id, bytes, length, ignorecase);
    onibi_fragment_t result = onibi_fragment_empty(builder);
    onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			   builder->allocation_owner);
    onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			   builder->allocation_owner);
    result.nullable = 0;
    return result;
}

static void
onibi_append_branch(onibi_fragment_t *result, onibi_fragment_t *branch)
{
    onibi_id_vector_append(&result->starts, &branch->starts);
    onibi_id_vector_append(&result->exits, &branch->exits);
    onibi_id_vector_free(&branch->starts);
    onibi_id_vector_free(&branch->exits);
    onibi_g_action_vector_free(&branch->start_actions);
    onibi_g_action_vector_free(&branch->pending_actions);
}

static onibi_fragment_t
onibi_compile_character_class(OnibiAstId node_id, int ignorecase,
			      onibi_gir_builder_t *builder)
{
    const OnibiAstNode *node = onibi_ast_node_const(builder->ast, node_id);
    int literal_children = 1;
    int has_multibyte = 0;
    for (size_t i = 0; i < node->child_count; i++) {
	const OnibiAstNode *child =
	    onibi_ast_node_const(builder->ast, node->children[i]);
	if (child->token_kind != ONIBI_TOKEN_LITERAL) literal_children = 0;
	if (child->bytes.present && child->bytes.length > 1) has_multibyte = 1;
    }
    int expand_ranges = node->range_count > 0 && node->range_count <= 4;
    long expanded = 0;
    if (expand_ranges) {
	for (size_t i = 0; i < node->range_count; i++) {
	    const OnibiAstRange *range = &node->ranges[i];
	    uint32_t first, last;
	    if (!range->first_has_bytes || !range->last_has_bytes ||
		!onibi_utf8_decode_bytes(builder->ast->bytes +
					     range->first.offset,
					 range->first.length, &first) ||
		!onibi_utf8_decode_bytes(builder->ast->bytes +
					     range->last.offset,
					 range->last.length, &last) ||
		last < first || last - first > 256U) {
		expand_ranges = 0;
		break;
	    }
	    expanded += (long)(last - first + 1U);
	    if (expanded > 256) {
		expand_ranges = 0;
		break;
	    }
	}
    }
    if (!(node->flags & ONIBI_AST_NODE_NEGATED) && literal_children &&
	((node->range_count == 0 && has_multibyte) || expand_ranges)) {
	onibi_fragment_t result = onibi_fragment_empty(builder);
	result.nullable = 0;
	for (size_t i = 0; i < node->child_count; i++) {
	    const OnibiAstNode *child =
		onibi_ast_node_const(builder->ast, node->children[i]);
	    const unsigned char *bytes =
		child->bytes.present ? builder->ast->bytes + child->bytes.offset
				     : (const unsigned char *)&child->byte;
	    size_t length = child->bytes.present ? child->bytes.length : 1;
	    onibi_fragment_t branch =
		onibi_compile_literal_bytes(bytes, length, ignorecase, builder);
	    onibi_append_branch(&result, &branch);
	}
	if (expand_ranges) {
	    for (size_t i = 0; i < node->range_count; i++) {
		const OnibiAstRange *range = &node->ranges[i];
		uint32_t first, last;
		onibi_utf8_decode_bytes(builder->ast->bytes +
					    range->first.offset,
					range->first.length, &first);
		onibi_utf8_decode_bytes(builder->ast->bytes +
					    range->last.offset,
					range->last.length, &last);
		for (uint32_t cp = first; cp <= last; cp++) {
		    unsigned char bytes[4];
		    size_t length = onibi_utf8_encode_bytes(cp, bytes);
		    onibi_fragment_t branch = onibi_compile_literal_bytes(
			bytes, length, ignorecase, builder);
		    onibi_append_branch(&result, &branch);
		    if (cp == last) break;
		}
	    }
	}
	return result;
    }
    long id = builder->next_id++;
    OnibiNormalizedClass normalized =
	onibi_compiler_normalize_class(builder->ast, node_id, ignorecase);
    onibi_nfa_state_class(builder, id, normalized.bitmap, normalized.negated);
    onibi_fragment_t result = onibi_fragment_empty(builder);
    onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			   builder->allocation_owner);
    onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			   builder->allocation_owner);
    result.nullable = 0;
    return result;
}

static onibi_fragment_t
onibi_compile_node(OnibiAstId node_id, onibi_gir_builder_t *builder)
{
    const OnibiAstNode *c_node = onibi_ast_node_const(builder->ast, node_id);
    const OnibiResolvedNode *resolved_node =
	&builder->semantics->nodes[node_id];
    OnibiAstKind type_code = c_node->kind;
    int ignorecase =
	(resolved_node->lexical_options & ONIBI_OPT_IGNORECASE) != 0;
    int multiline = (resolved_node->lexical_options & ONIBI_OPT_MULTILINE) != 0;
    if (type_code == ONIBI_AST_CHARACTER_CLASS ||
	type_code == ONIBI_AST_CLASS_INTERSECTION)
	return onibi_compile_character_class(node_id, ignorecase, builder);
    if (type_code == ONIBI_AST_SEQUENCE)
	return onibi_compile_sequence(c_node, builder);
    if (type_code == ONIBI_AST_ALTERNATIVE) {
	onibi_fragment_t result = onibi_fragment_empty(builder);
	result.nullable = 0;
	for (size_t i = 0; i < c_node->child_count; i++) {
	    onibi_fragment_t branch =
		onibi_compile_node(c_node->children[i], builder);
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
    if (type_code == ONIBI_AST_LITERAL) {
	const unsigned char *bytes =
	    c_node->bytes.present ? builder->ast->bytes + c_node->bytes.offset
				  : (const unsigned char *)&c_node->byte;
	size_t length = c_node->bytes.present ? c_node->bytes.length : 1;
	return onibi_compile_literal_bytes(bytes, length, ignorecase, builder);
    }
    if (type_code == ONIBI_AST_ESCAPE) {
	size_t name_length = c_node->name.present ? c_node->name.length : 1;
	unsigned char name_byte = c_node->name.present
				      ? builder->ast->bytes[c_node->name.offset]
				      : (unsigned char)c_node->byte;
	int is_property = onibi_ascii_property_name_p(c_node->name_id);
	if (name_length > 1 && !is_property)
	    rb_raise(eRegexpError,
		     "Unicode property escapes require encoded GIR classes");
	int code = name_length == 1 ? onibi_ascii_fold(name_byte) : 0;
	if (name_length <= 1 && (code == 'r' || code == 'p' || code == 'u'))
	    rb_raise(eRegexpError, "escape is not supported in RSeq");
	if (code == 'x')
	    rb_raise(eRegexpError,
		     "grapheme matching is not available in this PoC");
	unsigned char bitmap[32];
	onibi_class_bitmap_ast(builder->ast, node_id, ignorecase, bitmap);
	long id = builder->next_id++;
	onibi_nfa_state_class(builder, id, bitmap, 0);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_ANY) {
	unsigned char bitmap[32];
	memset(bitmap, 0xff, sizeof(bitmap));
	if (!multiline)
	    bitmap[(unsigned char)'\n' >> 3] &=
		(unsigned char)~(1U << ((unsigned char)'\n' & 7));
	long id = builder->next_id++;
	onibi_nfa_state_class(builder, id, bitmap, 0);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_BACKREF) {
	if (resolved_node->capture_id < 0)
	    rb_raise(eRegexpError, "invalid GIR backreference capture");
	long id = builder->next_id++;
	onibi_nfa_state(builder, id, ONIBI_G_BACKREF,
			(uint32_t)resolved_node->capture_id,
			ignorecase ? ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE : 0);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_SUBROUTINE) {
	if (resolved_node == NULL ||
	    resolved_node->reference_target == ONIBI_AST_NONE ||
	    resolved_node->subprogram_id == UINT32_MAX)
	    rb_raise(eRegexpError, "unresolved subroutine call");
	long subprogram_id = onibi_compile_resolved_subprogram(
	    resolved_node->reference_target, resolved_node->subprogram_id,
	    builder);
	long id = builder->next_id++;
	onibi_nfa_state(builder, id, ONIBI_G_CALL, (uint32_t)subprogram_id, 0);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_OPTION_GLOBAL) {
	/* Resolve applies this option to later semantic nodes. */
	return onibi_fragment_empty(builder);
    }
    if (type_code == ONIBI_AST_OPTION_SCOPE) {
	return onibi_compile_node(c_node->body, builder);
    }
    if (type_code == ONIBI_AST_ANCHOR) {
	onibi_fragment_t result = onibi_fragment_empty(builder);
	if (resolved_node == NULL || resolved_node->assertion_kind == 0)
	    rb_raise(eRegexpError, "unnormalized assertion");
	OnibiGAction action = {ONIBI_GA_ASSERT_POSITION,
			       0,
			       0,
			       0,
			       0,
			       1,
			       (uint16_t)resolved_node->assertion_kind,
			       0,
			       0};
	onibi_g_action_vector_push(&result.pending_actions, action);
	return result;
    }
    if (type_code == ONIBI_AST_MATCH_RESET) {
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_g_action_vector_push(
	    &result.pending_actions,
	    (OnibiGAction){ONIBI_GA_MATCH_RESET, 0, 0, 0, 0, 0, 0, 0, 0});
	return result;
    }
    if (type_code == ONIBI_AST_CONDITIONAL) {
	if (resolved_node == NULL || resolved_node->capture_id < 0)
	    rb_raise(eRegexpError, "unresolved conditional capture");
	long capture_id = resolved_node->capture_id;
	onibi_fragment_t yes = onibi_compile_node(c_node->yes, builder);
	onibi_fragment_t no = onibi_compile_node(c_node->no, builder);
	OnibiGActionVector yes_guard;
	onibi_g_action_vector_init(&yes_guard);
	onibi_g_action_vector_bind(&yes_guard, builder->allocation_owner);
	onibi_g_action_vector_push(&yes_guard,
				   onibi_capture_test_action(capture_id, 1));
	onibi_g_action_vector_append(&yes_guard, &yes.start_actions);
	OnibiGActionVector no_guard;
	onibi_g_action_vector_init(&no_guard);
	onibi_g_action_vector_bind(&no_guard, builder->allocation_owner);
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
	onibi_fragment_t result = onibi_fragment_empty(builder);
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
	if (resolved_node == NULL || resolved_node->subprogram_id == UINT32_MAX)
	    rb_raise(eRegexpError, "unresolved atomic subprogram");
	long subprogram_id = onibi_compile_resolved_body_subprogram(
	    c_node->body, resolved_node->subprogram_id, builder,
	    ONIBI_SUBPROGRAM_ATOMIC);
	long id = builder->next_id++;
	onibi_nfa_state(builder, id, ONIBI_G_ATOMIC, (uint32_t)subprogram_id,
			0);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_ABSENCE) {
	if (resolved_node == NULL || resolved_node->subprogram_id == UINT32_MAX)
	    rb_raise(eRegexpError, "unresolved absence subprogram");
	long subprogram_id = onibi_compile_resolved_body_subprogram(
	    c_node->body, resolved_node->subprogram_id, builder,
	    ONIBI_SUBPROGRAM_ABSENT);
	long id = builder->next_id++;
	onibi_nfa_state(builder, id, ONIBI_G_ABSENT, (uint32_t)subprogram_id,
			0);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 1;
	return result;
    }
    if (type_code == ONIBI_AST_LOOKAHEAD || type_code == ONIBI_AST_LOOKBEHIND) {
	/* TASK-23 will lower this resolved ID to an RSeq subprogram. The
	 * current fixed-predicate form still requires the semantic owner ID
	 * here. */
	if (resolved_node == NULL ||
	    resolved_node->subprogram_id == UINT32_MAX ||
	    resolved_node->subprogram_id <
		builder->semantics->lowered_subprogram_count)
	    rb_raise(eRegexpError, "unresolved lookaround subprogram");
	if (c_node == NULL || c_node->body == ONIBI_AST_NONE)
	    rb_raise(eRegexpError, "lookaround body has no literal sequence");
	const OnibiAstNode *body =
	    onibi_ast_node_const(builder->ast, c_node->body);
	if (body->kind != ONIBI_AST_SEQUENCE)
	    rb_raise(eRegexpError, "lookaround body has no literal sequence");
	uint32_t predicate_count = 0;
	for (size_t i = 0; i < body->child_count; i++) {
	    OnibiAstId child_id = body->children[i];
	    const OnibiAstNode *child =
		onibi_ast_node_const(builder->ast, child_id);
	    uint32_t child_options =
		builder->semantics->nodes[child_id].lexical_options;
	    int child_ignorecase = (child_options & ONIBI_OPT_IGNORECASE) != 0;
	    if (child->kind == ONIBI_AST_CHARACTER_CLASS ||
		child->kind == ONIBI_AST_CLASS_INTERSECTION ||
		child->kind == ONIBI_AST_ESCAPE) {
		if (child->kind == ONIBI_AST_ESCAPE) {
		    size_t name_length =
			child->name.present ? child->name.length : 1;
		    unsigned char name_byte =
			child->name.present
			    ? builder->ast->bytes[child->name.offset]
			    : (unsigned char)child->byte;
		    int simple =
			onibi_ascii_property_name_p(child->name_id) ||
			(name_length == 1 && onibi_simple_escape_p(name_byte));
		    if (!simple)
			rb_raise(eRegexpError,
				 "lookaround body has an unsupported escape");
		}
		unsigned char bitmap[32];
		onibi_class_bitmap_ast(builder->ast, child_id, child_ignorecase,
				       bitmap);
	    }
	    else if (child->kind != ONIBI_AST_ANY &&
		     child->kind != ONIBI_AST_LITERAL) {
		rb_raise(
		    eRegexpError,
		    "lookaround body is not a fixed literal/class sequence");
	    }
	    predicate_count++;
	}
	if (resolved_node == NULL || resolved_node->assertion_kind == 0)
	    rb_raise(eRegexpError, "unnormalized lookaround assertion");
	OnibiGAction action = {ONIBI_GA_ASSERT_POSITION,
			       0,
			       (c_node->flags & ONIBI_AST_NODE_POSITIVE) ? 1
									 : 0,
			       0,
			       0,
			       1,
			       (uint16_t)resolved_node->assertion_kind,
			       1,
			       predicate_count};
	onibi_fragment_t result = onibi_fragment_empty(builder);
	result.nullable = 1;
	onibi_g_action_vector_push(&result.start_actions, action);
	return result;
    }
    if (type_code == ONIBI_AST_CAPTURE) {
	if (resolved_node == NULL || resolved_node->capture_id < 0)
	    rb_raise(eRegexpError, "unresolved capture");
	long capture_id = resolved_node->capture_id;
	onibi_fragment_t result = onibi_compile_node(c_node->body, builder);
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
	if (c_node->name.present &&
	    onibi_c_ast_has_subroutine_name(builder->ast, c_node->body,
					    c_node->name))
	    close.set = 1;
	OnibiGActionVector starts;
	onibi_g_action_vector_init(&starts);
	onibi_g_action_vector_bind(&starts, builder->allocation_owner);
	onibi_g_action_vector_push(&starts, open);
	onibi_g_action_vector_append(&starts, &result.start_actions);
	onibi_g_action_vector_free(&result.start_actions);
	result.start_actions = starts;
	onibi_g_action_vector_push(&result.pending_actions, close);
	if (result.nullable && result.starts.count > 0)
	    onibi_fragment_append_actions(&result.start_actions,
					  &result.pending_actions);
	return result;
    }
    if (type_code == ONIBI_AST_GROUP)
	return onibi_compile_node(c_node->body, builder);
    if (type_code == ONIBI_AST_QUANTIFIER) {
	if (resolved_node == NULL ||
	    !(resolved_node->flags & ONIBI_SEMANTIC_NORMALIZED))
	    rb_raise(eRegexpError, "unnormalized repeat");
	long min = resolved_node->repeat_min;
	long normalized_max = resolved_node->repeat_max;
	int possessive =
	    (resolved_node->flags & ONIBI_SEMANTIC_REPEAT_POSSESSIVE) != 0;
	int greedy = (resolved_node->flags & ONIBI_SEMANTIC_REPEAT_GREEDY) != 0;
	OnibiAstId atom = c_node->atom;
	if (min == 0) builder->optional_seen = 1;
	if (possessive && (normalized_max < 0 || normalized_max != min))
	    rb_raise(eRegexpError,
		     "variable possessive quantifier is not supported in RSeq");
	if (possessive && onibi_c_ast_has_capture(builder->ast, atom))
	    rb_raise(eRegexpError,
		     "possessive capture repeat is not supported in RSeq");
	if (normalized_max >= 0 && min == 0 && normalized_max == 0)
	    return onibi_fragment_empty(builder);
	if (normalized_max >= 0 && min == 0 && normalized_max == 1) {
	    onibi_fragment_t result = onibi_compile_node(atom, builder);
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
	    onibi_g_action_vector_bind(&result.start_actions,
				       builder->allocation_owner);
	    onibi_g_action_vector_init(&result.pending_actions);
	    onibi_g_action_vector_bind(&result.pending_actions,
				       builder->allocation_owner);
	    result.nullable = 1;
	    result.lazy = !greedy;
	    return result;
	}
	long counter_slot = -1;
	if (normalized_max >= 0 && normalized_max != min)
	    counter_slot = builder->counter_count++;
	onibi_fragment_t result = onibi_fragment_empty(builder);
	result.nullable = min == 0;
	if (normalized_max >= 0 && normalized_max < min)
	    rb_raise(eRegexpError, "invalid quantifier range");
	long max = normalized_max;
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
			&result.pending_actions, &part.start_actions,
			builder->allocation_owner);
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
			&result.pending_actions, &part.start_actions,
			builder->allocation_owner);
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
	    result.lazy = !greedy;
	    return result;
	}
	if (max >= 0 && max != min) {
	    /* Counted repeats use one counter slot.  The first start edge
	       initializes it.  Optional bodies use ordered test edges. */
	    OnibiGAction init =
		onibi_counter_action(ONIBI_GA_COUNTER_INIT, counter_slot, 0, 0);
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
		onibi_g_action_vector_bind(&actions, builder->allocation_owner);
		if (counter_slot >= 0)
		    onibi_g_action_vector_push(
			&actions,
			onibi_counter_action(ONIBI_GA_COUNTER_INCREMENT,
					     counter_slot, 0, 0));
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
		onibi_g_action_vector_bind(&repeat_actions,
					   builder->allocation_owner);
		onibi_g_action_vector_push(
		    &repeat_actions,
		    onibi_counter_action(ONIBI_GA_TEST_COUNTER_LT, counter_slot,
					 1, max));
		onibi_g_action_vector_push(
		    &repeat_actions,
		    onibi_counter_action(ONIBI_GA_COUNTER_INCREMENT,
					 counter_slot, 0, 0));
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
		onibi_counter_action(ONIBI_GA_TEST_COUNTER_GE, counter_slot, 1,
				     min));
	}
	else if (normalized_max < 0) {
	    onibi_fragment_t repeat = onibi_compile_node(atom, builder);
	    long progress_slot =
		repeat.nullable ? builder->counter_count++ : -1;
	    if (min == 0 && !repeat.nullable) {
		/* The repeated body is optional.  Its actions belong only to
		 * body and loop edges, never to the zero-iteration accept edge.
		 */
		onibi_add_capture_guard_fragment(builder, &repeat.starts,
						 &repeat.start_actions);
		onibi_add_exit_guard_fragment(builder, &repeat.exits,
					      &repeat.pending_actions);
		onibi_g_action_vector_free(&repeat.start_actions);
		onibi_g_action_vector_free(&repeat.pending_actions);
		onibi_g_action_vector_init(&repeat.start_actions);
		onibi_g_action_vector_bind(&repeat.start_actions,
					   builder->allocation_owner);
		onibi_g_action_vector_init(&repeat.pending_actions);
		onibi_g_action_vector_bind(&repeat.pending_actions,
					   builder->allocation_owner);
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
						     &repeat.start_actions,
						     builder->allocation_owner);
		    onibi_connect_fragment_actions(builder, &result.exits,
						   &repeat.starts,
						   &next_actions, 0);
		    onibi_g_action_vector_free(&next_actions);
		}
	    }
	    if (repeat.nullable) {
		OnibiGActionVector progress_actions;
		onibi_g_action_vector_init(&progress_actions);
		onibi_g_action_vector_bind(&progress_actions,
					   builder->allocation_owner);
		if (progress_slot >= 0)
		    onibi_g_action_vector_push(
			&progress_actions,
			onibi_counter_action(ONIBI_GA_PROGRESS, progress_slot,
					     0, 0));
		onibi_connect_fragment_actions(builder, &repeat.exits,
					       &repeat.starts,
					       &progress_actions, 0);
		onibi_g_action_vector_free(&progress_actions);
	    }
	    else {
		OnibiGActionVector loop_actions = onibi_g_action_vector_concat(
		    &repeat.pending_actions, &repeat.start_actions,
		    builder->allocation_owner);
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
	result.lazy = !greedy;
	return result;
    }
    rb_raise(eRegexpError, "unsupported AST node");
    return onibi_fragment_empty(builder);
}

/* Initialize pass: create one owner for all mutable compiler state. */
static void
onibi_compiler_pass_init_builder(onibi_gir_builder_t *builder,
				 OnibiParsed *parsed,
				 const OnibiResolvedArena *semantics,
				 onibi_allocation_owner_t *allocation_owner)
{
    memset(builder, 0, sizeof(*builder));
    builder->ast = &parsed->arena;
    builder->semantics = semantics;
    builder->allocation_owner = allocation_owner;
    onibi_gir_state_vector_init(&builder->states);
    onibi_gir_state_vector_bind(&builder->states, allocation_owner);
    onibi_gir_edge_vector_init(&builder->edges);
    onibi_gir_edge_vector_bind(&builder->edges, builder->allocation_owner);
    onibi_rseq_subprogram_vector_init(&builder->subprograms);
    onibi_rseq_subprogram_vector_bind(&builder->subprograms,
				      builder->allocation_owner);
    onibi_rseq_subprogram_vector_push(&builder->subprograms,
				      (OnibiRSeqSubprogramEntry){0, 0, 0});
    for (size_t i = 1; i < semantics->lowered_subprogram_count; i++)
	onibi_rseq_subprogram_vector_push(&builder->subprograms,
					  (OnibiRSeqSubprogramEntry){0, 0, 0});
    builder->resolved_subprogram_count = semantics->lowered_subprogram_count;
    builder->subprogram_status = onibi_owned_realloc(
	builder->allocation_owner, NULL, builder->resolved_subprogram_count);
    memset(builder->subprogram_status, 0,
	   builder->resolved_subprogram_count * sizeof(unsigned char));
    onibi_guard_vector_init(&builder->capture_guards);
    onibi_guard_vector_bind(&builder->capture_guards,
			    builder->allocation_owner);
    onibi_guard_vector_init(&builder->exit_guards);
    onibi_guard_vector_bind(&builder->exit_guards, builder->allocation_owner);
}

/* Lower NFA pass, followed by the explicit epsilon-elimination boundary. */
static void
onibi_compiler_pass_lower(OnibiParsed *parsed, OnibiCompilerOwner *owner,
			  OnibiGirEdgeVector *start_edges, long *accept_out,
			  long *root_entry_out, VALUE *nfa_diagnostics_out)
{
    onibi_gir_builder_t *builder = &owner->builder;
    OnibiTaggedNfa *nfa = &owner->nfa;
    onibi_nfa_init(nfa, builder->allocation_owner);
    owner->nfa_active = 1;
    builder->nfa = nfa;
    owner->root_fragment = onibi_compile_node(parsed->arena.root, builder);
    owner->root_fragment_active = 1;
    onibi_fragment_t *fragment = &owner->root_fragment;
    long accept = builder->next_id++;
    onibi_nfa_state(builder, accept, ONIBI_G_ACCEPT, 0, 0);
    onibi_id_vector_single(&owner->accept_starts, (OnibiStateId)accept,
			   builder->allocation_owner);
    OnibiIdVector exit_ids = fragment->exits;
    onibi_connect_fragment_actions(builder, &exit_ids, &owner->accept_starts,
				   &fragment->pending_actions, fragment->lazy);
    onibi_id_vector_free(&owner->accept_starts);
    onibi_id_vector_init(&fragment->exits);
    long root_entry =
	fragment->starts.count > 0 ? (long)fragment->starts.entries[0] : accept;
    if (fragment->nullable && fragment->lazy) {
	owner->pending_actions = onibi_g_action_vector_concat(
	    &fragment->start_actions, &fragment->pending_actions,
	    builder->allocation_owner);
	onibi_nfa_add_start(builder, accept, &owner->pending_actions);
	onibi_g_action_vector_free(&owner->pending_actions);
	onibi_g_action_vector_init(&owner->pending_actions);
    }
    OnibiIdVector start_ids = fragment->starts;
    for (size_t i = 0; i < start_ids.count; i++) {
	long destination = (long)start_ids.entries[i];
	owner->pending_actions = onibi_g_action_vector_copy(
	    &fragment->start_actions, builder->allocation_owner);
	onibi_nfa_add_start(builder, destination, &owner->pending_actions);
	onibi_g_action_vector_free(&owner->pending_actions);
	onibi_g_action_vector_init(&owner->pending_actions);
    }
    onibi_id_vector_free(&start_ids);
    onibi_id_vector_free(&exit_ids);
    onibi_id_vector_init(&fragment->starts);
    if (fragment->nullable && !fragment->lazy) {
	owner->pending_actions = onibi_g_action_vector_concat(
	    &fragment->start_actions, &fragment->pending_actions,
	    builder->allocation_owner);
	onibi_nfa_add_start(builder, accept, &owner->pending_actions);
	onibi_g_action_vector_free(&owner->pending_actions);
	onibi_g_action_vector_init(&owner->pending_actions);
    }
    onibi_g_action_vector_free(&fragment->start_actions);
    onibi_g_action_vector_free(&fragment->pending_actions);
    onibi_fragment_t empty_fragment;
    memset(&empty_fragment, 0, sizeof(empty_fragment));
    *fragment = empty_fragment;
    owner->root_fragment_active = 0;
    nfa->accept = accept;
    if (nfa_diagnostics_out) *nfa_diagnostics_out = onibi_nfa_diagnostics(nfa);
    onibi_epsilon_eliminate(nfa, builder, start_edges, &accept, &root_entry);
    if (nfa_diagnostics_out)
	onibi_nfa_add_elimination_diagnostics(*nfa_diagnostics_out, builder,
					      start_edges);
    onibi_nfa_free(nfa);
    owner->nfa_active = 0;
    builder->nfa = NULL;
    *accept_out = accept;
    *root_entry_out = root_entry;
}

static void
onibi_compiler_pass_verify_gir(const onibi_gir_builder_t *builder,
			       OnibiCompilerOwner *owner)
{
    for (size_t i = 0; i < builder->edges.count; i++) {
	const OnibiGirEdgeEntry *edge = &builder->edges.entries[i];
	if (edge->from < 0 || edge->to < 0 ||
	    (size_t)edge->from >= builder->states.count ||
	    (size_t)edge->to >= builder->states.count)
	    rb_raise(eRegexpError,
		     "GIR verification failed: edge state is out of range");
    }
    onibi_compiler_fail_if(owner, 5);
}

static VerifiedGIRAnalysis
onibi_compiler_pass_classify(const onibi_gir_builder_t *builder,
			     const OnibiGirEdgeVector *start_edges,
			     OnibiCompilerOwner *owner)
{
    VerifiedGIRAnalysis result = {0, (uint32_t)builder->capture_count, 0, 0,
				  ONIBI_EXEC_REGULAR};
    unsigned char *semantic = NULL;
    if (builder->capture_count > 0) {
	semantic = onibi_owned_realloc(builder->allocation_owner, NULL,
				       (size_t)builder->capture_count);
	memset(semantic, 0, (size_t)builder->capture_count);
    }
#define MARK_SEMANTIC_CAPTURE(slot)                                            \
    do {                                                                       \
	uint32_t _slot = (uint32_t)(slot);                                     \
	if (semantic && _slot < result.capture_count && !semantic[_slot]) {    \
	    semantic[_slot] = 1;                                               \
	    result.semantic_capture_count++;                                   \
	}                                                                      \
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
    onibi_compiler_fail_if(owner, 6);
    onibi_owned_free(builder->allocation_owner, semantic);
    return result;
}

static void
onibi_compiler_pass_optimize(onibi_gir_builder_t *builder,
			     OnibiCompilerOwner *owner)
{
    /* Optimization must not change ordered edge semantics. The first safe
     * optimization is performed by the RSeq lowerer after this boundary. */
    (void)builder;
    onibi_compiler_fail_if(owner, 7);
}

/* Analyze pass.  This pass reads only the immutable AST.  Lowering must not
 * perform these queries while it walks nodes. */
static OnibiAnalyzeOutput
onibi_compiler_pass_analyze(OnibiNormalizeOutput normalize,
			    onibi_gir_builder_t *builder,
			    OnibiCompilerOwner *owner)
{
    OnibiParsed *parsed = normalize.parsed;
    onibi_analyze_semantic_node(parsed, parsed->arena.root);
    const OnibiResolvedNode *root =
	&normalize.semantics->nodes[parsed->arena.root];
    for (size_t i = 0; i < normalize.semantics->count; i++) {
	const OnibiResolvedNode *node = &normalize.semantics->nodes[i];
	if (!(node->flags & ONIBI_SEMANTIC_RESOLVED)) continue;
	if ((node->flags &
	     (ONIBI_SEMANTIC_RESOLVED | ONIBI_SEMANTIC_NORMALIZED |
	      ONIBI_SEMANTIC_ANALYZED)) !=
	    (ONIBI_SEMANTIC_RESOLVED | ONIBI_SEMANTIC_NORMALIZED |
	     ONIBI_SEMANTIC_ANALYZED))
	    rb_raise(eRegexpError, "semantic analysis invariant failed");
	if ((node->kind == ONIBI_AST_BACKREF ||
	     node->kind == ONIBI_AST_SUBROUTINE ||
	     node->kind == ONIBI_AST_CONDITIONAL) &&
	    node->reference_target == ONIBI_AST_NONE)
	    rb_raise(eRegexpError, "semantic reference invariant failed");
	if ((node->kind == ONIBI_AST_SUBROUTINE ||
	     node->kind == ONIBI_AST_ATOMIC ||
	     node->kind == ONIBI_AST_ABSENCE ||
	     node->kind == ONIBI_AST_LOOKAHEAD ||
	     node->kind == ONIBI_AST_LOOKBEHIND) &&
	    node->subprogram_id == UINT32_MAX)
	    rb_raise(eRegexpError, "semantic subprogram invariant failed");
    }
    onibi_compiler_fail_if(owner, 3);
    return (OnibiAnalyzeOutput){parsed,
				normalize.semantics,
				builder,
				(long)normalize.semantics->capture_count,
				(root->flags & ONIBI_SEMANTIC_NULLABLE) != 0,
				root->min_width,
				root->max_width};
}

/* Publish pass: transfer verified immutable GIR records to the result. */
static VALUE
onibi_compiler_pass_publish(onibi_gir_builder_t *builder,
			    OnibiGirEdgeVector *start_edges, long accept,
			    long root_entry, long counter_count,
			    int parsed_options, VerifiedGIRAnalysis analysis,
			    OnibiCompilerOwner *owner)
{
    onibi_rseq_subprogram_vector_store(
	&builder->subprograms, 0,
	(OnibiRSeqSubprogramEntry){(OnibiStateId)root_entry,
				   (OnibiStateId)accept, 0});
    onibi_compiler_fail_if(owner, 8);
    OnibiCompiled *compiled_result;
    VALUE result = TypedData_Make_Struct(rb_cObject, OnibiCompiled,
					 &onibi_compiled_type, compiled_result);
    memset(compiled_result, 0, sizeof(*compiled_result));
    onibi_rseq_subprogram_vector_init(&compiled_result->subprograms);
    onibi_gir_state_vector_init(&compiled_result->states);
    onibi_gir_edge_vector_init(&compiled_result->edges);
    onibi_gir_edge_vector_init(&compiled_result->start_edges);

    for (size_t i = 0; i < builder->edges.count; i++)
	if (!onibi_owned_pointer_p(builder->allocation_owner,
				   builder->edges.entries[i].actions.entries))
	    rb_raise(eRegexpError,
		     "GIR edge action publication owner is invalid");
    for (size_t i = 0; i < start_edges->count; i++)
	if (!onibi_owned_pointer_p(builder->allocation_owner,
				   start_edges->entries[i].actions.entries))
	    rb_raise(eRegexpError,
		     "GIR start action publication owner is invalid");
    if (!onibi_owned_pointer_p(builder->allocation_owner,
			       builder->states.entries) ||
	!onibi_owned_pointer_p(builder->allocation_owner,
			       builder->edges.entries) ||
	!onibi_owned_pointer_p(builder->allocation_owner,
			       start_edges->entries) ||
	!onibi_owned_pointer_p(builder->allocation_owner,
			       builder->subprograms.entries))
	rb_raise(eRegexpError, "GIR publication owner is invalid");

    for (size_t i = 0; i < builder->edges.count; i++) {
	onibi_owned_transfer(builder->allocation_owner,
			     builder->edges.entries[i].actions.entries);
	builder->edges.entries[i].actions.allocation_owner = NULL;
    }
    for (size_t i = 0; i < start_edges->count; i++) {
	onibi_owned_transfer(builder->allocation_owner,
			     start_edges->entries[i].actions.entries);
	start_edges->entries[i].actions.allocation_owner = NULL;
    }
    onibi_owned_transfer(builder->allocation_owner, builder->states.entries);
    onibi_owned_transfer(builder->allocation_owner, builder->edges.entries);
    onibi_owned_transfer(builder->allocation_owner, start_edges->entries);
    onibi_owned_transfer(builder->allocation_owner,
			 builder->subprograms.entries);
    builder->states.allocation_owner = NULL;
    builder->edges.allocation_owner = NULL;
    start_edges->allocation_owner = NULL;
    builder->subprograms.allocation_owner = NULL;
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
onibi_compiler_compile_body(VALUE opaque)
{
    OnibiCompilerCall *call = (OnibiCompilerCall *)(uintptr_t)opaque;
    OnibiCompilerOwner *owner = call->owner;
    VALUE parsed = call->parsed;
    OnibiParsed *parsed_data = onibi_parsed_get(parsed);
    if (parsed_data->arena.root == ONIBI_AST_NONE)
	rb_raise(rb_eArgError, "compiler requires parser output");
    OnibiParseOutput parse = {parsed_data, parsed_data->options};
    onibi_allocation_owner_set_phase(&owner->allocations, 1);
    OnibiResolveOutput resolve = onibi_compiler_pass_resolve(parse, owner);
    onibi_allocation_owner_set_phase(&owner->allocations, 2);
    OnibiNormalizeOutput normalize =
	onibi_compiler_pass_normalize(resolve, owner);
    int parsed_options = parse.options;

    onibi_compiler_pass_init_builder(&owner->builder, parsed_data,
				     normalize.semantics, &owner->allocations);
    onibi_allocation_owner_set_phase(&owner->allocations, 3);
    OnibiAnalyzeOutput analyze =
	onibi_compiler_pass_analyze(normalize, &owner->builder, owner);
    owner->builder.capture_count = analyze.capture_count;
    long accept;
    long root_entry;
    VALUE nfa_diagnostics = Qnil;

    onibi_allocation_owner_set_phase(&owner->allocations, 4);
    onibi_compiler_pass_lower(parsed_data, owner, &owner->start_edges, &accept,
			      &root_entry,
			      call->nfa_diagnostics ? &nfa_diagnostics : NULL);

    if (call->nfa_diagnostics) return nfa_diagnostics;

    OnibiLowerNfaOutput lower_nfa = {&owner->builder, &owner->start_edges,
				     accept, root_entry};
    /* onibi_compiler_pass_lower owns the tagged-NFA and epsilon-elimination
     * boundary.  Keep the result contract explicit for later split passes. */
    (void)lower_nfa;
    OnibiGirOutput gir = {&owner->builder};
    (void)gir;
    onibi_allocation_owner_set_phase(&owner->allocations, 5);
    onibi_compiler_pass_verify_gir(&owner->builder, owner);
    onibi_allocation_owner_set_phase(&owner->allocations, 6);
    VerifiedGIRAnalysis analysis = onibi_compiler_pass_classify(
	&owner->builder, &owner->start_edges, owner);
    onibi_allocation_owner_set_phase(&owner->allocations, 7);
    onibi_compiler_pass_optimize(&owner->builder, owner);
    onibi_allocation_owner_set_phase(&owner->allocations, 8);
    VALUE result = onibi_compiler_pass_publish(
	&owner->builder, &owner->start_edges, accept, root_entry,
	analysis.counter_count, parsed_options, analysis, owner);
    owner->gir_transferred = 1;
    rb_obj_freeze(result);
    return result;
}

static VALUE
onibi_compiler_compile_with_failure(VALUE parsed, int failure_phase,
				    int *failure_fired,
				    OnibiAllocationAccounting *accounting)
{
    OnibiCompilerOwner owner;
    memset(&owner, 0, sizeof(owner));
    onibi_allocation_owner_init(&owner.allocations, accounting);
    owner.failure_phase = failure_phase;
    owner.failure_fired = failure_fired;
    owner.allocations.failure_phase = failure_phase;
    owner.allocations.failure_fired = failure_fired;
    onibi_gir_edge_vector_init(&owner.start_edges);
    onibi_gir_edge_vector_bind(&owner.start_edges, &owner.allocations);
    OnibiCompilerCall call = {&owner, parsed, 0};
    return rb_ensure(onibi_compiler_compile_body, (VALUE)(uintptr_t)&call,
		     onibi_compiler_owner_ensure, (VALUE)(uintptr_t)&owner);
}

static VALUE
onibi_compiler_nfa_diagnostics(VALUE parsed)
{
    OnibiCompilerOwner owner;
    memset(&owner, 0, sizeof(owner));
    onibi_allocation_owner_init(&owner.allocations, NULL);
    onibi_gir_edge_vector_init(&owner.start_edges);
    onibi_gir_edge_vector_bind(&owner.start_edges, &owner.allocations);
    OnibiCompilerCall call = {&owner, parsed, 1};
    return rb_ensure(onibi_compiler_compile_body, (VALUE)(uintptr_t)&call,
		     onibi_compiler_owner_ensure, (VALUE)(uintptr_t)&owner);
}

static VALUE
onibi_compiler_compile(VALUE self, VALUE parsed)
{
    (void)self;
    return onibi_compiler_compile_with_failure(parsed, 0, NULL, NULL);
}
