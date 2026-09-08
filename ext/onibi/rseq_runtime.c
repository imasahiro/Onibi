typedef struct {
    uint32_t state;
    long pos;
    long *counters;
    long *captures;
    uint32_t *returns;
    uint16_t return_depth;
} onibi_simple_frame_t;

static int
onibi_rseq_view_init(VALUE blob, OnibiRSeqView *view)
{
    if (!RB_TYPE_P(blob, T_STRING) ||
	RSTRING_LEN(blob) < (long)sizeof(OnibiRSeqHeader) ||
	RSTRING_LEN(blob) > UINT32_MAX)
	return 0;
    view->blob = (const unsigned char *)RSTRING_PTR(blob);
    view->header = (const OnibiRSeqHeader *)view->blob;
    if (view->header->magic != ONIBI_RSEQ_MAGIC ||
	view->header->version != ONIBI_RSEQ_VERSION ||
	view->header->blob_size != (uint32_t)RSTRING_LEN(blob))
	return 0;
    view->states = NULL;
    view->edges = NULL;
    view->actions = NULL;
    view->classes = NULL;
    view->literals = NULL;
    view->backrefs = NULL;
    view->backref_capture_ids = NULL;
    view->subprograms = NULL;
    view->lookbehind_widths = NULL;
    view->class_stack_capacity = 0;
    view->regular_capable = 0;
    return 1;
}

/* Bind typed section pointers only after the verifier proved every offset.
 * This keeps malformed blobs from causing pointer arithmetic before bounds
 * checks complete. */
static void
onibi_rseq_view_bind(OnibiRSeqView *view)
{
    const OnibiRSeqHeader *header = view->header;
    view->states = (const OnibiRState *)(view->blob + header->states_offset);
    view->edges = (const OnibiREdge *)(view->blob + header->edges_offset);
    view->actions = (const OnibiRAction *)(view->blob + header->actions_offset);
    view->classes =
	(const OnibiClassDesc *)(view->blob + header->classes_offset);
    view->literals =
	(const OnibiLiteralDesc *)(view->blob + header->descriptors_offset);
    view->backrefs =
	(const OnibiBackrefDesc *)(view->blob + header->backrefs_offset);
    view->backref_capture_ids =
	(const uint32_t *)(view->blob + header->backref_lists_offset);
    view->subprograms =
	(const OnibiSubprogramDesc *)(view->blob + header->subprograms_offset);
    view->lookbehind_widths =
	(const uint32_t *)(view->blob + header->lookbehind_widths_offset);
}

static void
onibi_rseq_view_prepare(OnibiRSeqView *view)
{
    onibi_rseq_view_bind(view);
    view->class_stack_capacity = 0;
    for (uint32_t i = 0; i < view->header->class_count; i++) {
	const OnibiClassDesc *klass = &view->classes[i];
	if (klass->kind != ONIBI_CLASS_MIXED) continue;
	uint32_t count = klass->data_length / sizeof(OnibiClassExpr);
	if (count > view->class_stack_capacity)
	    view->class_stack_capacity = count;
    }
    view->regular_capable = onibi_rseq_regular_capable(view);
}

static int
onibi_rseq_regular_edge_capable(const OnibiRSeqView *view,
				const OnibiREdge *edge)
{
    if (edge->action_offset == 0) return 1;
    uint32_t index = edge->action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
    if (index >= view->header->action_count) return 0;
    for (; index < view->header->action_count; index++) {
	const OnibiRAction *action = &view->actions[index];
	if (action->op == ONIBI_RA_END) return 1;
	if (action->op == ONIBI_RA_CAPTURE) continue;
	if (action->op == ONIBI_RA_ASSERT_POSITION &&
	    (action->arg16 == ONIBI_RAP_WORD_BOUNDARY ||
	     action->arg16 == ONIBI_RAP_NONWORD_BOUNDARY))
	    continue;
	return 0;
    }
    return 0;
}

static int
onibi_rseq_regular_capable(const OnibiRSeqView *view)
{
    const OnibiRSeqHeader *header = view->header;
    if ((header->features & ONIBI_RSEQ_FEATURE_LOOKAROUND) != 0 ||
	header->state_count == 0 || header->start_edge_count == 0 ||
	header->counter_count != 0 || header->subprogram_count != 1)
	return 0;
    for (uint32_t i = 0; i < header->state_count; i++) {
	const OnibiRState *state = &view->states[i];
	if (state->flags != 0) {
	    uint8_t allowed =
		state->op == ONIBI_RS_CHAR ? ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE
		: (state->op == ONIBI_RS_CLASS || state->op == ONIBI_RS_ANY)
		    ? ONIBI_RSEQ_STATE_FLAG_NEGATED
		    : 0;
	    if ((state->flags & ~allowed) != 0) return 0;
	}
	if (state->op != 0 && state->op != ONIBI_RS_CHAR &&
	    state->op != ONIBI_RS_CLASS && state->op != ONIBI_RS_ANY)
	    return 0;
	if (state->op == ONIBI_RS_CLASS &&
	    (view->classes[state->payload].flags &
	     ~ONIBI_RSEQ_CLASS_FLAG_NEGATED) != 0)
	    return 0;
	if (state->op == ONIBI_RS_CHAR) {
	    const OnibiLiteralDesc *literal = &view->literals[state->payload];
	    if ((literal->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0) {
		const unsigned char *bytes = view->blob + literal->data_offset;
		for (uint32_t j = 0; j < literal->data_length; j++)
		    if (bytes[j] >= 0x80) return 0;
	    }
	}
	if (state->op == ONIBI_RS_CALL) return 0;
	for (uint32_t e = 0; e < state->edge_count; e++) {
	    const OnibiREdge *edge = &view->edges[state->edge_base + e];
	    if (!onibi_rseq_regular_edge_capable(view, edge)) return 0;
	}
    }
    for (uint32_t i = 0; i < header->start_edge_count; i++)
	if (!onibi_rseq_regular_edge_capable(
		view, &view->edges[header->start_edge_base + i]))
	    return 0;
    return 1;
}

static int
onibi_rseq_ctype_valid(rb_encoding *encoding, uint32_t ctype)
{
    if (ctype <= ONIGENC_MAX_STD_CTYPE) return 1;
    if (ctype > INT_MAX) return 0;
    OnigCodePoint single_byte_boundary = 0;
    const OnigCodePoint *ranges = NULL;
    return ONIGENC_GET_CTYPE_CODE_RANGE(encoding, (OnigCtype)ctype,
					&single_byte_boundary, &ranges) == 0 &&
	   ranges != NULL;
}

static int
onibi_rseq_class_descriptor_valid(const OnibiRSeqView *view,
				  rb_encoding *encoding,
				  const OnibiClassDesc *klass,
				  uint64_t data_begin, uint64_t data_end)
{
    if (klass->kind > ONIBI_CLASS_MIXED || klass->data_length == 0 ||
	(klass->flags & ~(ONIBI_RSEQ_CLASS_FLAG_NEGATED |
			  ONIBI_RSEQ_CLASS_FLAG_INCOMPLETE_CASEFOLD)) != 0 ||
	klass->data_offset != data_begin || (klass->data_offset & 3U) != 0 ||
	(uint64_t)klass->data_offset + klass->data_length > data_end)
	return 0;
    if (klass->kind == ONIBI_CLASS_ASCII_BITMAP)
	return klass->data_length == 32;
    if (klass->kind == ONIBI_CLASS_ENCODING_CTYPE) {
	uint32_t ctype;
	if (klass->data_length != sizeof(ctype)) return 0;
	memcpy(&ctype, view->blob + klass->data_offset, sizeof(ctype));
	return onibi_rseq_ctype_valid(encoding, ctype);
    }
    if (klass->kind == ONIBI_CLASS_CODEPOINT_RANGES) {
	if (klass->data_length % sizeof(OnibiCodepointRange) != 0) return 0;
	const OnibiCodepointRange *ranges =
	    (const OnibiCodepointRange *)(view->blob + klass->data_offset);
	size_t count = klass->data_length / sizeof(*ranges);
	for (size_t i = 0; i < count; i++)
	    if (ranges[i].first > ranges[i].last ||
		(i > 0 && ranges[i - 1].last >= ranges[i].first))
		return 0;
	return count != 0;
    }
    if (klass->data_length % sizeof(OnibiClassExpr) != 0) return 0;
    const OnibiClassExpr *expr =
	(const OnibiClassExpr *)(view->blob + klass->data_offset);
    size_t count = klass->data_length / sizeof(*expr);
    size_t depth = 0;
    for (size_t i = 0; i < count; i++) {
	if (expr[i].flags != 0 || expr[i].reserved != 0 ||
	    expr[i].op < ONIBI_CLASS_EXPR_RANGE ||
	    expr[i].op > ONIBI_CLASS_EXPR_NEGATE)
	    return 0;
	if (expr[i].op == ONIBI_CLASS_EXPR_RANGE ||
	    expr[i].op == ONIBI_CLASS_EXPR_CTYPE) {
	    if (expr[i].op == ONIBI_CLASS_EXPR_RANGE &&
		expr[i].arg0 > expr[i].arg1)
		return 0;
	    if (expr[i].op == ONIBI_CLASS_EXPR_CTYPE &&
		(expr[i].arg1 != 0 ||
		 !onibi_rseq_ctype_valid(encoding, expr[i].arg0)))
		return 0;
	    depth++;
	}
	else if (expr[i].op == ONIBI_CLASS_EXPR_NEGATE) {
	    if (depth < 1 || expr[i].arg0 != 0 || expr[i].arg1 != 0) return 0;
	}
	else {
	    if (depth < 2 || expr[i].arg0 != 0 || expr[i].arg1 != 0) return 0;
	    depth--;
	}
    }
    return count != 0 && depth == 1;
}

static int
onibi_rseq_bytes_zero(const unsigned char *bytes, size_t length)
{
    for (size_t i = 0; i < length; i++)
	if (bytes[i] != 0) return 0;
    return 1;
}

typedef struct {
    VALUE blob;
    onibi_allocation_owner_t allocations;
} OnibiRSeqVerifyCall;

typedef struct {
    uint32_t from;
    uint32_t to;
    uint32_t action_offset;
    size_t next_outgoing;
    size_t next_incoming;
} OnibiRSeqNullableEdgeIndex;

typedef struct {
    uint32_t to;
    uint32_t action_offset;
    size_t next;
} OnibiRSeqNullableEntryIndex;

typedef struct {
    unsigned char *owner_bases;
    unsigned char *reserved_slots;
    uint32_t *owner_indices;
    size_t owner_count;
    size_t word_count;
    uint64_t *all_owners;
    uint64_t *state_in;
    size_t *outgoing_heads;
    size_t *incoming_heads;
    size_t *entry_heads;
    OnibiRSeqNullableEdgeIndex *edges;
    OnibiRSeqNullableEntryIndex *entries;
    size_t entry_count;
    unsigned char *reachable;
    unsigned char *queued;
    uint32_t *worklist;
} OnibiRSeqNullableVerify;

static void
onibi_rseq_nullable_set(uint64_t *state, uint32_t owner_index)
{
    state[(size_t)owner_index / (sizeof(uint64_t) * CHAR_BIT)] |=
	UINT64_C(1) << (owner_index % (sizeof(uint64_t) * CHAR_BIT));
}

static void
onibi_rseq_nullable_clear(uint64_t *state, uint32_t owner_index)
{
    state[(size_t)owner_index / (sizeof(uint64_t) * CHAR_BIT)] &=
	~(UINT64_C(1) << (owner_index % (sizeof(uint64_t) * CHAR_BIT)));
}

static const OnibiRAction *
onibi_rseq_action_program(const OnibiRSeqView *view, uint32_t action_offset,
			  uint32_t *count)
{
    if (action_offset == 0) {
	*count = 0;
	return NULL;
    }
    uint32_t index = action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
    uint32_t length = 0;
    while (index + length < view->header->action_count) {
	if (view->actions[index + length].op == ONIBI_RA_END) {
	    *count = length;
	    return view->actions + index;
	}
	length++;
    }
    rb_raise(rb_eArgError, "unterminated Onibi RSeq action program");
    return NULL;
}

static void
onibi_rseq_nullable_collect_owner(const OnibiRSeqView *view,
				  OnibiRSeqNullableVerify *nullable,
				  uint32_t base)
{
    if ((uint32_t)base + 1U >= view->header->counter_count)
	rb_raise(rb_eArgError, "invalid Onibi RSeq nullable owner range");
    if (nullable->owner_bases[base]) return;
    if (nullable->reserved_slots[base] || nullable->reserved_slots[base + 1U])
	rb_raise(rb_eArgError,
		 "overlapping Onibi RSeq nullable owner intervals");
    nullable->owner_bases[base] = 1;
    nullable->reserved_slots[base] = 1;
    nullable->reserved_slots[base + 1U] = 1;
    nullable->owner_indices[base] = (uint32_t)nullable->owner_count++;
}

static void
onibi_rseq_nullable_transfer(const OnibiRSeqView *view,
			     const OnibiRSeqNullableVerify *nullable,
			     uint32_t action_offset, const uint64_t *input,
			     uint64_t *output)
{
    uint32_t count;
    const OnibiRAction *actions =
	onibi_rseq_action_program(view, action_offset, &count);
    if (output != input)
	memcpy(output, input, nullable->word_count * sizeof(*output));
    for (uint32_t i = 0; i < count; i++) {
	const OnibiRAction *action = &actions[i];
	if (action->op == ONIBI_RA_NULL_ENTER)
	    onibi_rseq_nullable_set(output,
				    nullable->owner_indices[action->arg16]);
	else if (action->op == ONIBI_RA_NULL_CONTINUE ||
		 action->op == ONIBI_RA_NULL_STOP)
	    onibi_rseq_nullable_clear(output,
				      nullable->owner_indices[action->arg16]);
    }
}

static void
onibi_rseq_nullable_validate_program(const OnibiRSeqView *view,
				     const OnibiRSeqNullableVerify *nullable,
				     uint32_t action_offset,
				     const uint64_t *input, uint64_t *output)
{
    uint32_t count;
    const OnibiRAction *actions =
	onibi_rseq_action_program(view, action_offset, &count);
    memcpy(output, input, nullable->word_count * sizeof(*output));
    for (uint32_t i = 0; i < count; i++) {
	const OnibiRAction *action = &actions[i];
	if (action->op == ONIBI_RA_NULL_ENTER) {
	    onibi_rseq_nullable_set(output,
				    nullable->owner_indices[action->arg16]);
	}
	else if (action->op == ONIBI_RA_NULL_CAPTURE ||
		 action->op == ONIBI_RA_NULL_CONTINUE ||
		 action->op == ONIBI_RA_NULL_STOP) {
	    uint32_t owner_index = nullable->owner_indices[action->arg16];
	    if (!(output[(size_t)owner_index / (sizeof(uint64_t) * CHAR_BIT)] &
		  (UINT64_C(1)
		   << (owner_index % (sizeof(uint64_t) * CHAR_BIT)))))
		rb_raise(rb_eArgError,
			 "Onibi RSeq nullable owner is not initialized");
	    if (action->op == ONIBI_RA_NULL_CONTINUE ||
		action->op == ONIBI_RA_NULL_STOP)
		onibi_rseq_nullable_clear(output, owner_index);
	}
    }
}

static void
onibi_rseq_nullable_meet(uint64_t *destination, const uint64_t *source,
			 size_t word_count)
{
    for (size_t i = 0; i < word_count; i++)
	destination[i] &= source[i];
}

static int
onibi_rseq_nullable_update_state(const OnibiRSeqView *view,
				 const OnibiRSeqNullableVerify *nullable,
				 size_t state, uint64_t *next, uint64_t *output)
{
    int has_incoming = 0;
    memcpy(next, nullable->all_owners, nullable->word_count * sizeof(*next));
    for (size_t entry = nullable->entry_heads[state]; entry != SIZE_MAX;
	 entry = nullable->entries[entry].next) {
	const OnibiRSeqNullableEntryIndex *incoming = &nullable->entries[entry];
	memset(output, 0, nullable->word_count * sizeof(*output));
	onibi_rseq_nullable_transfer(view, nullable, incoming->action_offset,
				     output, output);
	if (!has_incoming) {
	    memcpy(next, output, nullable->word_count * sizeof(*next));
	    has_incoming = 1;
	}
	else
	    onibi_rseq_nullable_meet(next, output, nullable->word_count);
    }
    for (size_t edge = nullable->incoming_heads[state]; edge != SIZE_MAX;
	 edge = nullable->edges[edge].next_incoming) {
	const OnibiRSeqNullableEdgeIndex *incoming = &nullable->edges[edge];
	if (!nullable->reachable[incoming->from]) continue;
	const uint64_t *input =
	    nullable->state_in + (size_t)incoming->from * nullable->word_count;
	onibi_rseq_nullable_transfer(view, nullable, incoming->action_offset,
				     input, output);
	if (!has_incoming) {
	    memcpy(next, output, nullable->word_count * sizeof(*next));
	    has_incoming = 1;
	}
	else
	    onibi_rseq_nullable_meet(next, output, nullable->word_count);
    }
    if (!has_incoming) return 0;
    uint64_t *current = nullable->state_in + state * nullable->word_count;
    if (memcmp(next, current, nullable->word_count * sizeof(*next)) == 0)
	return 0;
    memcpy(current, next, nullable->word_count * sizeof(*next));
    return 1;
}

static void
onibi_rseq_nullable_verify_paths(const OnibiRSeqView *view,
				 OnibiRSeqVerifyCall *call,
				 OnibiRSeqNullableVerify *nullable)
{
    const OnibiRSeqHeader *header = view->header;
    if (nullable->owner_count == 0) return;
    size_t bit_count = sizeof(uint64_t) * CHAR_BIT;
    nullable->word_count = (nullable->owner_count + bit_count - 1U) / bit_count;
    nullable->all_owners = onibi_owned_realloc(
	&call->allocations, NULL,
	nullable->word_count * sizeof(*nullable->all_owners));
    for (size_t i = 0; i < nullable->word_count; i++)
	nullable->all_owners[i] = UINT64_MAX;

    if (header->state_count > SIZE_MAX / sizeof(*nullable->outgoing_heads) ||
	header->state_count >
	    SIZE_MAX / sizeof(*nullable->state_in) / nullable->word_count)
	rb_raise(rb_eArgError,
		 "Onibi RSeq nullable verification index is too large");
    nullable->outgoing_heads = onibi_owned_realloc(
	&call->allocations, NULL,
	(size_t)header->state_count * sizeof(*nullable->outgoing_heads));
    nullable->incoming_heads = onibi_owned_realloc(
	&call->allocations, NULL,
	(size_t)header->state_count * sizeof(*nullable->incoming_heads));
    nullable->entry_heads = onibi_owned_realloc(
	&call->allocations, NULL,
	(size_t)header->state_count * sizeof(*nullable->entry_heads));
    nullable->state_in =
	onibi_owned_realloc(&call->allocations, NULL,
			    (size_t)header->state_count * nullable->word_count *
				sizeof(*nullable->state_in));
    nullable->reachable =
	onibi_owned_realloc(&call->allocations, NULL, header->state_count);
    nullable->queued =
	onibi_owned_realloc(&call->allocations, NULL, header->state_count);
    nullable->worklist = onibi_owned_realloc(&call->allocations, NULL,
					     (size_t)header->state_count *
						 sizeof(*nullable->worklist));
    for (uint32_t i = 0; i < header->state_count; i++) {
	nullable->outgoing_heads[i] = SIZE_MAX;
	nullable->incoming_heads[i] = SIZE_MAX;
	nullable->entry_heads[i] = SIZE_MAX;
    }
    memset(nullable->reachable, 0, header->state_count);
    memset(nullable->queued, 0, header->state_count);

    uint32_t normal_edge_count = header->start_edge_base;
    nullable->edges = onibi_owned_realloc(&call->allocations, NULL,
					  (size_t)normal_edge_count *
					      sizeof(*nullable->edges));
    uint32_t edge_cursor = 0;
    for (uint32_t state = 0; state < header->state_count; state++) {
	for (uint32_t i = 0; i < view->states[state].edge_count; i++) {
	    const OnibiREdge *edge =
		&view->edges[view->states[state].edge_base + i];
	    OnibiRSeqNullableEdgeIndex *indexed = &nullable->edges[edge_cursor];
	    indexed->from = state;
	    indexed->to = edge->destination;
	    indexed->action_offset = edge->action_offset;
	    indexed->next_outgoing = nullable->outgoing_heads[state];
	    indexed->next_incoming =
		edge->destination == ONIBI_ACCEPT_STATE
		    ? SIZE_MAX
		    : nullable->incoming_heads[edge->destination];
	    nullable->outgoing_heads[state] = edge_cursor;
	    if (edge->destination != ONIBI_ACCEPT_STATE)
		nullable->incoming_heads[edge->destination] = edge_cursor;
	    edge_cursor++;
	}
    }
    if (edge_cursor != normal_edge_count)
	rb_raise(rb_eArgError, "invalid Onibi RSeq nullable edge index");

    nullable->entry_count = header->edge_count - normal_edge_count;
    nullable->entries =
	onibi_owned_realloc(&call->allocations, NULL,
			    nullable->entry_count * sizeof(*nullable->entries));
    size_t entry = 0;
    for (uint32_t i = 0; i < header->start_edge_count; i++, entry++) {
	const OnibiREdge *edge = &view->edges[header->start_edge_base + i];
	nullable->entries[entry].to = edge->destination;
	nullable->entries[entry].action_offset = edge->action_offset;
	nullable->entries[entry].next =
	    edge->destination == ONIBI_ACCEPT_STATE
		? SIZE_MAX
		: nullable->entry_heads[edge->destination];
	if (edge->destination != ONIBI_ACCEPT_STATE)
	    nullable->entry_heads[edge->destination] = entry;
    }
    for (uint32_t i = 1; i < header->subprogram_count; i++) {
	const OnibiSubprogramDesc *subprogram = &view->subprograms[i];
	for (uint32_t j = 0; j < subprogram->entry_edge_count; j++, entry++) {
	    const OnibiREdge *edge =
		&view->edges[subprogram->entry_edge_base + j];
	    nullable->entries[entry].to = edge->destination;
	    nullable->entries[entry].action_offset = edge->action_offset;
	    nullable->entries[entry].next =
		edge->destination == ONIBI_ACCEPT_STATE
		    ? SIZE_MAX
		    : nullable->entry_heads[edge->destination];
	    if (edge->destination != ONIBI_ACCEPT_STATE)
		nullable->entry_heads[edge->destination] = entry;
	}
    }
    if (entry != nullable->entry_count)
	rb_raise(rb_eArgError, "invalid Onibi RSeq nullable entry index");

    size_t queue_head = 0, queue_tail = 0, queue_count = 0;
    for (size_t i = 0; i < nullable->entry_count; i++) {
	uint32_t state = nullable->entries[i].to;
	if (state == ONIBI_ACCEPT_STATE) continue;
	if (nullable->reachable[state]) continue;
	nullable->reachable[state] = 1;
	if (queue_count == header->state_count)
	    rb_raise(rb_eArgError,
		     "Onibi RSeq nullable reachability queue is too large");
	nullable->worklist[queue_tail++] = state;
	if (queue_tail == header->state_count) queue_tail = 0;
	queue_count++;
    }
    while (queue_count != 0) {
	uint32_t state = nullable->worklist[queue_head++];
	queue_count--;
	if (queue_head == header->state_count) queue_head = 0;
	for (size_t edge = nullable->outgoing_heads[state]; edge != SIZE_MAX;
	     edge = nullable->edges[edge].next_outgoing) {
	    uint32_t destination = nullable->edges[edge].to;
	    if (destination == ONIBI_ACCEPT_STATE) continue;
	    if (nullable->reachable[destination]) continue;
	    nullable->reachable[destination] = 1;
	    if (queue_count == header->state_count)
		rb_raise(rb_eArgError,
			 "Onibi RSeq nullable reachability queue is too large");
	    nullable->worklist[queue_tail++] = destination;
	    if (queue_tail == header->state_count) queue_tail = 0;
	    queue_count++;
	}
    }

    queue_head = queue_tail = queue_count = 0;
    uint64_t *next = onibi_owned_realloc(&call->allocations, NULL,
					 nullable->word_count * sizeof(*next));
    uint64_t *output = onibi_owned_realloc(
	&call->allocations, NULL, nullable->word_count * sizeof(*output));
    for (uint32_t state = 0; state < header->state_count; state++) {
	if (!nullable->reachable[state]) continue;
	memcpy(nullable->state_in + (size_t)state * nullable->word_count,
	       nullable->all_owners,
	       nullable->word_count * sizeof(*nullable->all_owners));
	if (queue_count == header->state_count)
	    rb_raise(rb_eArgError, "Onibi RSeq nullable worklist is too large");
	nullable->worklist[queue_tail++] = state;
	if (queue_tail == header->state_count) queue_tail = 0;
	nullable->queued[state] = 1;
	queue_count++;
    }
    while (queue_count != 0) {
	uint32_t state = nullable->worklist[queue_head++];
	queue_count--;
	nullable->queued[state] = 0;
	if (queue_head == header->state_count) queue_head = 0;
	if (!onibi_rseq_nullable_update_state(view, nullable, state, next,
					      output))
	    continue;
	for (size_t edge = nullable->outgoing_heads[state]; edge != SIZE_MAX;
	     edge = nullable->edges[edge].next_outgoing) {
	    uint32_t destination = nullable->edges[edge].to;
	    if (destination == ONIBI_ACCEPT_STATE) continue;
	    if (nullable->queued[destination]) continue;
	    if (queue_count == header->state_count)
		rb_raise(rb_eArgError,
			 "Onibi RSeq nullable worklist is too large");
	    nullable->worklist[queue_tail++] = destination;
	    if (queue_tail == header->state_count) queue_tail = 0;
	    nullable->queued[destination] = 1;
	    queue_count++;
	}
    }

    memset(output, 0, nullable->word_count * sizeof(*output));
    for (size_t i = 0; i < nullable->entry_count; i++)
	onibi_rseq_nullable_validate_program(
	    view, nullable, nullable->entries[i].action_offset, output, next);
    for (uint32_t i = 0; i < normal_edge_count; i++) {
	const OnibiRSeqNullableEdgeIndex *edge = &nullable->edges[i];
	if (!nullable->reachable[edge->from]) continue;
	const uint64_t *input =
	    nullable->state_in + (size_t)edge->from * nullable->word_count;
	onibi_rseq_nullable_validate_program(view, nullable,
					     edge->action_offset, input, next);
    }
}

static VALUE
onibi_rseq_blob_validate_body(VALUE opaque)
{
    OnibiRSeqVerifyCall *call = (OnibiRSeqVerifyCall *)(uintptr_t)opaque;
    VALUE blob = call->blob;
    OnibiRSeqView view;
    if (!onibi_rseq_view_init(blob, &view) || !RTEST(rb_obj_frozen_p(blob)))
	rb_raise(rb_eArgError, "invalid Onibi RSeq blob");
    const OnibiRSeqHeader *header = view.header;
    const uint32_t option_mask = ONIBI_OPT_IGNORECASE | ONIBI_OPT_EXTENDED |
				 ONIBI_OPT_MULTILINE | ONIBI_OPT_FIXEDENCODING |
				 ONIBI_OPT_NOENCODING;
    const uint32_t feature_mask =
	ONIBI_RSEQ_FEATURE_BACKREF | ONIBI_RSEQ_FEATURE_CAPTURE |
	ONIBI_RSEQ_FEATURE_COUNTER | ONIBI_RSEQ_FEATURE_MATCH_RESET |
	ONIBI_RSEQ_FEATURE_ASSERTION | ONIBI_RSEQ_FEATURE_LOOKAROUND |
	ONIBI_RSEQ_FEATURE_FIRST_BITMAP |
	ONIBI_RSEQ_FEATURE_INCOMPLETE_CASEFOLD |
	ONIBI_RSEQ_FEATURE_LITERAL_CASEFOLD |
	ONIBI_RSEQ_FEATURE_ZERO_WIDTH_ONLY;
    uint64_t states_end = (uint64_t)header->states_offset +
			  (uint64_t)header->state_count * sizeof(OnibiRState);
    uint64_t edges_end = (uint64_t)header->edges_offset +
			 (uint64_t)header->edge_count * sizeof(OnibiREdge);
    uint64_t actions_end =
	(uint64_t)header->actions_offset +
	(uint64_t)header->action_count * sizeof(OnibiRAction);
    uint64_t class_desc_end =
	(uint64_t)header->classes_offset +
	(uint64_t)header->class_count * sizeof(OnibiClassDesc);
    uint64_t backref_end =
	(uint64_t)header->backrefs_offset +
	(uint64_t)header->backref_count * sizeof(OnibiBackrefDesc);
    uint64_t subprogram_end =
	(uint64_t)header->subprograms_offset +
	(uint64_t)header->subprogram_count * sizeof(OnibiSubprogramDesc);
    uint64_t widths_end =
	(uint64_t)header->lookbehind_widths_offset +
	(uint64_t)header->lookbehind_width_count * sizeof(uint32_t);
    if (header->state_count == 0 || header->subprogram_count == 0 ||
	header->capture_count > ONIBI_GIR_MAX_CAPTURE_COUNT ||
	header->counter_count > ONIBI_GIR_MAX_COUNTER_COUNT ||
	header->semantic_capture_count > header->capture_count ||
	header->exec_kind > ONIBI_EXEC_DYNAMIC ||
	(header->flags & ~(ONIBI_RSEQ_HEADER_FLAG_IGNORECASE |
			   ONIBI_RSEQ_HEADER_FLAG_MULTILINE)) != 0 ||
	(header->features & ~feature_mask) != 0 ||
	header->prefix_length > sizeof(header->prefix) ||
	(header->states_offset | header->edges_offset | header->actions_offset |
	 header->classes_offset | header->literals_offset |
	 header->descriptors_offset | header->backrefs_offset |
	 header->backref_lists_offset | header->subprograms_offset |
	 header->lookbehind_widths_offset | header->blob_size) &
	    3U ||
	header->states_offset != sizeof(*header) ||
	states_end != header->edges_offset ||
	edges_end != header->actions_offset ||
	actions_end != header->classes_offset ||
	class_desc_end > header->literals_offset ||
	header->literals_offset > header->descriptors_offset ||
	header->descriptors_offset > header->backrefs_offset ||
	backref_end != header->backref_lists_offset ||
	header->backref_lists_offset > header->subprograms_offset ||
	((header->subprograms_offset - header->backref_lists_offset) & 3U) !=
	    0 ||
	subprogram_end != header->lookbehind_widths_offset ||
	widths_end != header->blob_size || header->start_edge_count == 0 ||
	header->start_edge_base > header->edge_count ||
	header->start_edge_count > header->edge_count - header->start_edge_base)
	rb_raise(rb_eArgError, "invalid Onibi RSeq section layout");

    onibi_rseq_view_bind(&view);
    uint32_t literal_count = 0;
    uint32_t backref_list_count =
	(header->subprograms_offset - header->backref_lists_offset) /
	(uint32_t)sizeof(uint32_t);
    uint32_t state_edge_cursor = 0;
    uint32_t semantic_capture_count = 0;
    unsigned char *semantic_captures =
	header->capture_count == 0
	    ? NULL
	    : onibi_owned_realloc(&call->allocations, NULL,
				  (size_t)header->capture_count);
    unsigned char *action_boundaries =
	header->action_count == 0
	    ? NULL
	    : onibi_owned_realloc(&call->allocations, NULL,
				  (size_t)header->action_count);
    unsigned char *subprogram_references = onibi_owned_realloc(
	&call->allocations, NULL, (size_t)header->subprogram_count);
    if (semantic_captures) memset(semantic_captures, 0, header->capture_count);
    if (action_boundaries) memset(action_boundaries, 0, header->action_count);
    memset(subprogram_references, 0, header->subprogram_count);
    subprogram_references[0] = 1;

    OnibiRSeqNullableVerify nullable;
    memset(&nullable, 0, sizeof(nullable));
    if (header->counter_count != 0) {
	nullable.owner_bases = onibi_owned_realloc(&call->allocations, NULL,
						   header->counter_count);
	nullable.reserved_slots = onibi_owned_realloc(&call->allocations, NULL,
						      header->counter_count);
	nullable.owner_indices = onibi_owned_realloc(
	    &call->allocations, NULL,
	    (size_t)header->counter_count * sizeof(*nullable.owner_indices));
	memset(nullable.owner_bases, 0, header->counter_count);
	memset(nullable.reserved_slots, 0, header->counter_count);
	for (uint32_t i = 0; i < header->counter_count; i++)
	    nullable.owner_indices[i] = UINT32_MAX;
    }

    for (uint32_t i = 0; i < header->state_count; i++) {
	const OnibiRState *state = &view.states[i];
	if (state->edge_base != state_edge_cursor ||
	    (uint64_t)state_edge_cursor + state->edge_count >
		header->start_edge_base)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq state edge range");
	state_edge_cursor += state->edge_count;
	if (state->op > ONIBI_RS_RUN_ANY)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq state opcode");
	if (state->op == 0 && (state->payload != 0 || state->flags != 0 ||
			       state->edge_count != 0))
	    rb_raise(rb_eArgError, "invalid Onibi RSeq accept state");
	if ((state->op == ONIBI_RS_CHAR || state->op == ONIBI_RS_STRING) &&
	    (state->flags & ~ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq literal flags");
	if (state->op == ONIBI_RS_ANY || state->op == ONIBI_RS_RUN_ANY) {
	    if (state->payload != 0 ||
		(state->flags & ~ONIBI_RSEQ_STATE_FLAG_NEGATED) != 0)
		rb_raise(rb_eArgError, "invalid Onibi RSeq state flags");
	}
	if (state->op == ONIBI_RS_GRAPHEME && state->payload != 0)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq state payload");
	else if (state->op != ONIBI_RS_CHAR && state->op != ONIBI_RS_STRING &&
		 state->op != ONIBI_RS_BACKREF && state->op != 0 &&
		 state->flags != 0)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq state flags");
	if ((state->op == ONIBI_RS_CHAR || state->op == ONIBI_RS_STRING) &&
	    state->payload == UINT32_MAX)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq literal payload");
	if ((state->op == ONIBI_RS_CHAR || state->op == ONIBI_RS_STRING) &&
	    state->payload + 1U > literal_count)
	    literal_count = state->payload + 1U;
	if ((state->op == ONIBI_RS_CLASS || state->op == ONIBI_RS_RUN_CLASS) &&
	    state->payload >= header->class_count)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq class payload");
	if (state->op == ONIBI_RS_BACKREF) {
	    if (state->payload >= header->backref_count ||
		(state->flags & ~ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0)
		rb_raise(rb_eArgError, "invalid Onibi RSeq backreference");
	    const OnibiBackrefDesc *descriptor = &view.backrefs[state->payload];
	    if (descriptor->capture_count == 0 ||
		(descriptor->flags &
		 ~(ONIBI_BACKREF_FLAG_IGNORE_CASE | ONIBI_BACKREF_FLAG_NAMED |
		   ONIBI_BACKREF_FLAG_RELATIVE |
		   ONIBI_BACKREF_FLAG_WITH_LEVEL)) != 0 ||
		(!(descriptor->flags & ONIBI_BACKREF_FLAG_WITH_LEVEL) &&
		 descriptor->recursion_level != 0) ||
		(((state->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0) !=
		 ((descriptor->flags & ONIBI_BACKREF_FLAG_IGNORE_CASE) != 0)) ||
		descriptor->capture_list_off < header->backref_lists_offset ||
		(descriptor->capture_list_off & 3U) != 0 ||
		(uint64_t)descriptor->capture_list_off +
			(uint64_t)descriptor->capture_count * sizeof(uint32_t) >
		    (uint64_t)header->subprograms_offset)
		rb_raise(rb_eArgError,
			 "invalid Onibi RSeq backreference descriptor");
	    uint32_t list_index =
		(descriptor->capture_list_off - header->backref_lists_offset) /
		(uint32_t)sizeof(uint32_t);
	    if (list_index > backref_list_count ||
		descriptor->capture_count > backref_list_count - list_index)
		rb_raise(rb_eArgError,
			 "invalid Onibi RSeq backreference capture list");
	    for (uint16_t j = 0; j < descriptor->capture_count; j++) {
		uint32_t capture = view.backref_capture_ids[list_index + j];
		if (capture >= header->capture_count)
		    rb_raise(rb_eArgError,
			     "invalid Onibi RSeq backreference capture list");
		if (!semantic_captures[capture]) {
		    semantic_captures[capture] = 1;
		    semantic_capture_count++;
		}
	    }
	}
	if (state->op == ONIBI_RS_CALL || state->op == ONIBI_RS_ATOMIC ||
	    state->op == ONIBI_RS_ABSENT) {
	    uint8_t kind = state->op == ONIBI_RS_CALL ? ONIBI_SUBPROGRAM_CALL
			   : state->op == ONIBI_RS_ATOMIC
			       ? ONIBI_SUBPROGRAM_ATOMIC_GROUP
			       : ONIBI_SUBPROGRAM_ABSENCE;
	    if (state->payload == 0 ||
		state->payload >= header->subprogram_count ||
		view.subprograms[state->payload].kind != kind)
		rb_raise(rb_eArgError,
			 "invalid Onibi RSeq subprogram reference");
	    subprogram_references[state->payload] = 1;
	}
    }
    if (state_edge_cursor != header->start_edge_base)
	rb_raise(rb_eArgError, "invalid Onibi RSeq state edge layout");
    uint64_t literal_desc_end =
	(uint64_t)header->descriptors_offset +
	(uint64_t)literal_count * sizeof(OnibiLiteralDesc);
    if (literal_desc_end != header->backrefs_offset)
	rb_raise(rb_eArgError, "invalid Onibi RSeq literal layout");

    uint32_t action_features = 0;
    int counter_set_seen = 0;
    int counter_action_seen = 0;
    uint32_t highest_counter_slot = 0;
    uint32_t action_index = 0;
    while (action_index < header->action_count) {
	uint32_t program_begin = action_index;
	action_boundaries[program_begin] = 1;
	for (;;) {
	    if (action_index >= header->action_count)
		rb_raise(rb_eArgError,
			 "unterminated Onibi RSeq action program");
	    const OnibiRAction *action = &view.actions[action_index++];
	    switch (action->op) {
	    case ONIBI_RA_END:
		if (action->flags != 0 || action->arg16 != 0 ||
		    action->arg32 != 0)
		    rb_raise(rb_eArgError, "invalid Onibi RSeq action end");
		goto action_program_done;
	    case ONIBI_RA_CAPTURE:
		if (action->flags > ONIBI_RA_CAPTURE_OPEN_UNSCOPED ||
		    action->arg32 != 0 ||
		    action->arg16 >= header->capture_count * 2U ||
		    ((action->arg16 & 1U) !=
		     (action->flags == ONIBI_RA_CAPTURE_CLOSE)))
		    rb_raise(rb_eArgError, "invalid Onibi RSeq capture action");
		break;
	    case ONIBI_RA_MATCH_RESET:
		if (action->flags != 0 || action->arg16 != 0 ||
		    action->arg32 != 0)
		    rb_raise(rb_eArgError,
			     "invalid Onibi RSeq match-reset action");
		action_features |= ONIBI_RSEQ_FEATURE_MATCH_RESET;
		break;
	    case ONIBI_RA_ASSERT_POSITION:
		if (action->flags != 0 || action->arg32 != 0 ||
		    action->arg16 < ONIBI_RAP_BEGIN_BUFFER ||
		    action->arg16 > ONIBI_RAP_NONWORD_BOUNDARY)
		    rb_raise(rb_eArgError,
			     "invalid Onibi RSeq position assertion");
		action_features |= ONIBI_RSEQ_FEATURE_ASSERTION;
		break;
	    case ONIBI_RA_ASSERT_SUBPROGRAM: {
		int positive = action->flags == 1 || action->flags == 5;
		uint8_t kind = action->arg16 == ONIBI_RAP_LOOKAHEAD
				   ? ONIBI_SUBPROGRAM_LOOKAHEAD
				   : ONIBI_SUBPROGRAM_LOOKBEHIND;
		if ((action->flags != 1 && action->flags != 2 &&
		     action->flags != 5 && action->flags != 6) ||
		    (action->arg16 != ONIBI_RAP_LOOKAHEAD &&
		     action->arg16 != ONIBI_RAP_LOOKBEHIND) ||
		    action->arg32 == 0 ||
		    action->arg32 >= header->subprogram_count ||
		    view.subprograms[action->arg32].kind != kind ||
		    ((view.subprograms[action->arg32].effects &
		      ONIBI_SUBPROGRAM_EFFECT_POSITIVE) != 0) != positive)
		    rb_raise(rb_eArgError,
			     "invalid Onibi RSeq assertion subprogram");
		subprogram_references[action->arg32] = 1;
		action_features |= ONIBI_RSEQ_FEATURE_ASSERTION |
				   ONIBI_RSEQ_FEATURE_LOOKAROUND;
		break;
	    }
	    case ONIBI_RA_TEST_CAPTURE:
		if ((action->flags != ONIBI_RA_TEST_CAPTURE_SET &&
		     action->flags != ONIBI_RA_TEST_CAPTURE_UNSET) ||
		    action->arg16 >= header->capture_count ||
		    action->arg32 != 0)
		    rb_raise(rb_eArgError, "invalid Onibi RSeq capture test");
		if (!semantic_captures[action->arg16]) {
		    semantic_captures[action->arg16] = 1;
		    semantic_capture_count++;
		}
		break;
	    case ONIBI_RA_COUNTER_SET:
		if (action->flags != 0 ||
		    action->arg16 >= header->counter_count)
		    rb_raise(rb_eArgError, "invalid Onibi RSeq counter action");
		counter_set_seen = 1;
		counter_action_seen = 1;
		if (action->arg16 > highest_counter_slot)
		    highest_counter_slot = action->arg16;
		break;
	    case ONIBI_RA_COUNTER_ADD:
		if (action->flags != 0 ||
		    action->arg16 >= header->counter_count ||
		    action->arg32 != 0)
		    rb_raise(rb_eArgError, "invalid Onibi RSeq counter action");
		counter_action_seen = 1;
		if (action->arg16 > highest_counter_slot)
		    highest_counter_slot = action->arg16;
		break;
	    case ONIBI_RA_COUNTER_TEST:
		if (action->flags > ONIBI_RA_COUNTER_GE ||
		    action->arg16 >= header->counter_count)
		    rb_raise(rb_eArgError, "invalid Onibi RSeq counter action");
		counter_action_seen = 1;
		if (action->arg16 > highest_counter_slot)
		    highest_counter_slot = action->arg16;
		break;
	    case ONIBI_RA_PROGRESS:
		if (action->flags != 0 ||
		    action->arg16 >= header->counter_count ||
		    action->arg32 != 0)
		    rb_raise(rb_eArgError,
			     "invalid Onibi RSeq progress action");
		counter_action_seen = 1;
		if (action->arg16 > highest_counter_slot)
		    highest_counter_slot = action->arg16;
		break;
	    case ONIBI_RA_NULL_ENTER:
	    case ONIBI_RA_NULL_CAPTURE:
	    case ONIBI_RA_NULL_CONTINUE:
	    case ONIBI_RA_NULL_STOP:
		if (action->flags != 0 ||
		    (uint32_t)action->arg16 + 1U >= header->counter_count ||
		    (action->op == ONIBI_RA_NULL_CAPTURE
			 ? action->arg32 >= header->capture_count
			 : action->arg32 != 0))
		    rb_raise(rb_eArgError,
			     "invalid Onibi RSeq nullable repeat action");
		if (action->op == ONIBI_RA_NULL_ENTER)
		    onibi_rseq_nullable_collect_owner(&view, &nullable,
						      action->arg16);
		if (action->op == ONIBI_RA_NULL_CAPTURE &&
		    !semantic_captures[action->arg32]) {
		    semantic_captures[action->arg32] = 1;
		    semantic_capture_count++;
		}
		counter_action_seen = 1;
		if ((uint32_t)action->arg16 + 1U > highest_counter_slot)
		    highest_counter_slot = (uint32_t)action->arg16 + 1U;
		break;
	    case ONIBI_RA_ORDER:
		if (action->flags || action->arg16)
		    rb_raise(rb_eArgError, "invalid Onibi RSeq order action");
		break;
	    default: rb_raise(rb_eArgError, "invalid Onibi RSeq action opcode");
	    }
	}
    action_program_done:
	if (action_index == program_begin)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq action program");
    }

    for (uint32_t i = 0; i < header->edge_count; i++) {
	const OnibiREdge *edge = &view.edges[i];
	if (edge->destination != ONIBI_ACCEPT_STATE &&
	    edge->destination >= header->state_count)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq edge destination");
	if (edge->action_offset != 0) {
	    if (edge->action_offset % sizeof(OnibiRAction) != 0)
		rb_raise(rb_eArgError, "invalid Onibi RSeq action offset");
	    uint32_t action =
		edge->action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
	    if (action >= header->action_count || !action_boundaries[action])
		rb_raise(rb_eArgError, "invalid Onibi RSeq action offset");
	}
    }
    uint32_t expected_counter_count =
	counter_action_seen ? highest_counter_slot + 1U : 0;
    if (header->counter_count != expected_counter_count)
	rb_raise(rb_eArgError, "invalid Onibi RSeq counter count");

    for (uint32_t i = 0; i < header->action_count; i++) {
	const OnibiRAction *action = &view.actions[i];
	if (action->op == ONIBI_RA_NULL_CAPTURE ||
	    action->op == ONIBI_RA_NULL_CONTINUE ||
	    action->op == ONIBI_RA_NULL_STOP) {
	    if (nullable.owner_indices[action->arg16] == UINT32_MAX)
		rb_raise(rb_eArgError,
			 "invalid Onibi RSeq nullable owner base");
	}
	if (action->op == ONIBI_RA_COUNTER_SET ||
	    action->op == ONIBI_RA_COUNTER_ADD ||
	    action->op == ONIBI_RA_COUNTER_TEST ||
	    action->op == ONIBI_RA_PROGRESS) {
	    if (nullable.reserved_slots != NULL &&
		nullable.reserved_slots[action->arg16])
		rb_raise(rb_eArgError,
			 "Onibi RSeq counter aliases nullable owner");
	}
    }

    uint32_t entry_cursor = header->start_edge_base + header->start_edge_count;
    int root_encoding_index = view.subprograms[0].option_env.encoding_index;
    rb_encoding *root_encoding =
	root_encoding_index < 0 ? NULL : rb_enc_from_index(root_encoding_index);
    if (root_encoding == NULL)
	rb_raise(rb_eArgError, "invalid Onibi RSeq root encoding");
    uint32_t width_cursor = 0;
    for (uint32_t i = 0; i < header->subprogram_count; i++) {
	const OnibiSubprogramDesc *subprogram = &view.subprograms[i];
	uint32_t expected_flags =
	    subprogram->kind == ONIBI_SUBPROGRAM_ATOMIC_GROUP
		? ONIBI_SUBPROGRAM_ATOMIC
	    : subprogram->kind == ONIBI_SUBPROGRAM_ABSENCE
		? ONIBI_SUBPROGRAM_ABSENT
		: 0;
	uint8_t expected_effects =
	    subprogram->kind == ONIBI_SUBPROGRAM_ATOMIC_GROUP
		? ONIBI_SUBPROGRAM_EFFECT_FIRST_SUCCESS
	    : ((subprogram->kind == ONIBI_SUBPROGRAM_LOOKAHEAD ||
		subprogram->kind == ONIBI_SUBPROGRAM_LOOKBEHIND) &&
	       (subprogram->effects & ONIBI_SUBPROGRAM_EFFECT_POSITIVE) != 0)
		? ONIBI_SUBPROGRAM_EFFECT_POSITIVE |
		      ONIBI_SUBPROGRAM_EFFECT_PUBLISH_CAPTURES
		: 0;
	if (subprogram->entry >= header->state_count ||
	    subprogram->accept >= header->state_count ||
	    view.states[subprogram->accept].op != 0 ||
	    subprogram->kind > ONIBI_SUBPROGRAM_ABSENCE ||
	    subprogram->flags != expected_flags ||
	    subprogram->effects != expected_effects ||
	    subprogram->reserved != 0 ||
	    (subprogram->option_env.options & ~option_mask) != 0 ||
	    subprogram->option_env.encoding_index != root_encoding_index ||
	    rb_enc_from_index(subprogram->option_env.encoding_index) == NULL ||
	    (uint64_t)subprogram->width_base + subprogram->width_count >
		header->lookbehind_width_count ||
	    ((subprogram->kind == ONIBI_SUBPROGRAM_LOOKBEHIND) !=
	     (subprogram->width_count != 0)))
	    rb_raise(rb_eArgError, "invalid Onibi RSeq subprogram");
	if (i == 0) {
	    int root_started = 0;
	    for (uint32_t j = 0; j < header->start_edge_count; j++) {
		uint32_t destination =
		    view.edges[header->start_edge_base + j].destination;
		if (destination == ONIBI_ACCEPT_STATE)
		    destination = subprogram->accept;
		if (destination == subprogram->entry) root_started = 1;
	    }
	    if (subprogram->kind != ONIBI_SUBPROGRAM_ROOT ||
		subprogram->accept != header->state_count - 1U ||
		!root_started || subprogram->entry_edge_base != 0 ||
		subprogram->entry_edge_count != 0 ||
		subprogram->width_base != 0 || subprogram->width_count != 0 ||
		((subprogram->option_env.options & ONIBI_OPT_IGNORECASE) !=
		 0) != ((header->flags & ONIBI_RSEQ_HEADER_FLAG_IGNORECASE) !=
			0) ||
		((subprogram->option_env.options & ONIBI_OPT_MULTILINE) != 0) !=
		    ((header->flags & ONIBI_RSEQ_HEADER_FLAG_MULTILINE) != 0))
		rb_raise(rb_eArgError, "invalid Onibi RSeq root subprogram");
	}
	else {
	    if (subprogram->entry_edge_count == 0 ||
		subprogram->entry_edge_base != entry_cursor)
		rb_raise(rb_eArgError, "invalid Onibi RSeq subprogram entry");
	    entry_cursor += subprogram->entry_edge_count;
	    if (view.edges[subprogram->entry_edge_base].destination !=
		subprogram->entry)
		rb_raise(rb_eArgError, "invalid Onibi RSeq subprogram entry");
	    if (subprogram->kind == ONIBI_SUBPROGRAM_LOOKBEHIND) {
		if (subprogram->width_base != width_cursor)
		    rb_raise(rb_eArgError,
			     "invalid Onibi RSeq lookbehind width layout");
		width_cursor += subprogram->width_count;
	    }
	    else if (subprogram->width_base != 0)
		rb_raise(rb_eArgError, "invalid Onibi RSeq subprogram width");
	}
    }
    if (entry_cursor != header->edge_count)
	rb_raise(rb_eArgError, "invalid Onibi RSeq subprogram edge layout");
    if (width_cursor != header->lookbehind_width_count)
	rb_raise(rb_eArgError, "invalid Onibi RSeq lookbehind width layout");

    unsigned char *root_reachable = onibi_owned_realloc(
	&call->allocations, NULL, (size_t)header->state_count);
    uint32_t *root_worklist = onibi_owned_realloc(&call->allocations, NULL,
						  (size_t)header->state_count *
						      sizeof(*root_worklist));
    memset(root_reachable, 0, header->state_count);
    uint32_t root_work_head = 0, root_work_count = 0;
    for (uint32_t i = 0; i < header->start_edge_count; i++) {
	uint32_t destination =
	    view.edges[header->start_edge_base + i].destination;
	if (destination < header->state_count && !root_reachable[destination]) {
	    root_reachable[destination] = 1;
	    root_worklist[root_work_count++] = destination;
	}
    }
    int root_consuming = 0;
    while (root_work_head < root_work_count) {
	const OnibiRState *state =
	    &view.states[root_worklist[root_work_head++]];
	if (state->op != 0 && state->op != ONIBI_RS_CALL &&
	    state->op != ONIBI_RS_ATOMIC)
	    root_consuming = 1;
	if (state->op == ONIBI_RS_CALL || state->op == ONIBI_RS_ATOMIC) {
	    const OnibiSubprogramDesc *subprogram =
		&view.subprograms[state->payload];
	    for (uint32_t i = 0; i < subprogram->entry_edge_count; i++) {
		uint32_t destination =
		    view.edges[subprogram->entry_edge_base + i].destination;
		if (destination < header->state_count &&
		    !root_reachable[destination]) {
		    root_reachable[destination] = 1;
		    root_worklist[root_work_count++] = destination;
		}
	    }
	}
	for (uint32_t i = 0; i < state->edge_count; i++) {
	    uint32_t destination = view.edges[state->edge_base + i].destination;
	    if (destination < header->state_count &&
		!root_reachable[destination]) {
		root_reachable[destination] = 1;
		root_worklist[root_work_count++] = destination;
	    }
	}
    }

    uint64_t class_data_cursor = class_desc_end;
    for (uint32_t i = 0; i < header->class_count; i++) {
	const OnibiClassDesc *klass = &view.classes[i];
	if (!onibi_rseq_class_descriptor_valid(&view, root_encoding, klass,
					       class_data_cursor,
					       header->literals_offset))
	    rb_raise(rb_eArgError, "invalid Onibi RSeq class descriptor");
	class_data_cursor += klass->data_length;
    }
    if (class_data_cursor != header->literals_offset)
	rb_raise(rb_eArgError, "invalid Onibi RSeq class data layout");
    uint64_t literal_cursor = header->literals_offset;
    int literal_casefold = 0;
    int incomplete_casefold = 0;
    for (uint32_t i = 0; i < literal_count; i++) {
	const OnibiLiteralDesc *literal = &view.literals[i];
	if (literal->data_length == 0 ||
	    (literal->flags & ~ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0 ||
	    literal->data_offset != literal_cursor ||
	    (uint64_t)literal->data_offset + literal->data_length >
		header->descriptors_offset)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq literal descriptor");
	literal_cursor += literal->data_length;
	if (literal->flags != 0) literal_casefold = 1;
    }
    while (literal_cursor < header->descriptors_offset) {
	if (view.blob[literal_cursor++] != 0)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq literal padding");
    }
    for (uint32_t i = 0; i < header->state_count; i++) {
	const OnibiRState *state = &view.states[i];
	if ((state->op == ONIBI_RS_CHAR || state->op == ONIBI_RS_STRING) &&
	    view.literals[state->payload].flags != state->flags)
	    rb_raise(rb_eArgError, "inconsistent Onibi RSeq literal flags");
	if (state->op == ONIBI_RS_BACKREF &&
	    (view.backrefs[state->payload].flags &
	     ONIBI_BACKREF_FLAG_IGNORE_CASE) != 0)
	    incomplete_casefold = 1;
    }
    for (uint32_t i = 0; i < header->class_count; i++)
	if ((view.classes[i].flags &
	     ONIBI_RSEQ_CLASS_FLAG_INCOMPLETE_CASEFOLD) != 0)
	    incomplete_casefold = 1;

    for (uint32_t i = 0; i < header->lookbehind_width_count; i++)
	(void)view.lookbehind_widths[i];

    for (uint32_t i = 1; i < header->subprogram_count; i++)
	if (!subprogram_references[i])
	    rb_raise(rb_eArgError, "unreferenced Onibi RSeq subprogram");
    if (semantic_capture_count != header->semantic_capture_count)
	rb_raise(rb_eArgError, "invalid Onibi RSeq semantic capture count");

    onibi_rseq_nullable_verify_paths(&view, call, &nullable);

    uint32_t expected_features =
	(header->capture_count != 0 ? ONIBI_RSEQ_FEATURE_CAPTURE : 0) |
	(counter_set_seen ? ONIBI_RSEQ_FEATURE_COUNTER : 0) | action_features |
	(literal_casefold ? ONIBI_RSEQ_FEATURE_LITERAL_CASEFOLD : 0) |
	(incomplete_casefold ? ONIBI_RSEQ_FEATURE_INCOMPLETE_CASEFOLD : 0);
    uint32_t execution_requirements = 0;
    for (uint32_t i = 0; i < header->state_count; i++) {
	const OnibiRState *state = &view.states[i];
	if (state->op == ONIBI_RS_BACKREF) {
	    expected_features |= ONIBI_RSEQ_FEATURE_BACKREF;
	    execution_requirements |= ONIBI_EXEC_REQUIRE_DYNAMIC;
	}
	if (state->op == ONIBI_RS_GRAPHEME || state->op == ONIBI_RS_CALL ||
	    state->op == ONIBI_RS_ATOMIC || state->op == ONIBI_RS_ABSENT)
	    execution_requirements |= ONIBI_EXEC_REQUIRE_DYNAMIC;
    }
    if ((action_features & (ONIBI_RSEQ_FEATURE_ASSERTION |
			    ONIBI_RSEQ_FEATURE_MATCH_RESET)) != 0 ||
	counter_action_seen)
	execution_requirements |= ONIBI_EXEC_REQUIRE_TAGGED;
    for (uint32_t i = 0; i < header->action_count; i++)
	if (view.actions[i].op == ONIBI_RA_TEST_CAPTURE)
	    execution_requirements |= ONIBI_EXEC_REQUIRE_DYNAMIC;
	else if (view.actions[i].op == ONIBI_RA_CAPTURE &&
		 view.actions[i].flags >= ONIBI_RA_CAPTURE_OPEN_UNSCOPED)
	    execution_requirements |= ONIBI_EXEC_REQUIRE_TAGGED;
    if (!root_consuming)
	expected_features |= ONIBI_RSEQ_FEATURE_ZERO_WIDTH_ONLY;
    uint32_t semantic_feature_mask =
	ONIBI_RSEQ_FEATURE_BACKREF | ONIBI_RSEQ_FEATURE_CAPTURE |
	ONIBI_RSEQ_FEATURE_COUNTER | ONIBI_RSEQ_FEATURE_MATCH_RESET |
	ONIBI_RSEQ_FEATURE_ASSERTION | ONIBI_RSEQ_FEATURE_LOOKAROUND |
	ONIBI_RSEQ_FEATURE_LITERAL_CASEFOLD |
	ONIBI_RSEQ_FEATURE_INCOMPLETE_CASEFOLD |
	ONIBI_RSEQ_FEATURE_ZERO_WIDTH_ONLY;
    unsigned char expected_bitmap[sizeof(header->first_bitmap)];
    int bitmap_valid = 1, bitmap_have = 0;
    memset(expected_bitmap, 0, sizeof(expected_bitmap));
    for (uint32_t i = 0; i < header->start_edge_count; i++) {
	const OnibiREdge *edge = &view.edges[header->start_edge_base + i];
	if (edge->action_offset != 0 ||
	    edge->destination >= header->state_count) {
	    bitmap_valid = 0;
	    continue;
	}
	const OnibiRState *state = &view.states[edge->destination];
	if (state->op != ONIBI_RS_CHAR || state->flags != 0 ||
	    view.literals[state->payload].data_length != 1) {
	    bitmap_valid = 0;
	    continue;
	}
	unsigned char byte =
	    view.blob[view.literals[state->payload].data_offset];
	expected_bitmap[byte >> 3] |= (unsigned char)(1U << (byte & 7));
	bitmap_have = 1;
    }
    int bitmap_expected = bitmap_valid && bitmap_have;
    unsigned char expected_prefix[sizeof(header->prefix)];
    uint8_t expected_prefix_length = 0;
    memset(expected_prefix, 0, sizeof(expected_prefix));
    if ((header->flags & ONIBI_RSEQ_HEADER_FLAG_IGNORECASE) == 0 &&
	header->start_edge_count == 1) {
	const OnibiREdge *edge = &view.edges[header->start_edge_base];
	uint32_t current = edge->destination;
	if (edge->action_offset == 0 && current < header->state_count) {
	    while (current < header->state_count) {
		const OnibiRState *state = &view.states[current];
		if (state->op != ONIBI_RS_CHAR || state->flags != 0) break;
		const OnibiLiteralDesc *literal =
		    &view.literals[state->payload];
		if (literal->data_length == 0 ||
		    literal->data_length >
			sizeof(expected_prefix) - expected_prefix_length)
		    break;
		memcpy(expected_prefix + expected_prefix_length,
		       view.blob + literal->data_offset, literal->data_length);
		expected_prefix_length += literal->data_length;
		if (state->edge_count != 1) break;
		edge = &view.edges[state->edge_base];
		if (edge->action_offset != 0 ||
		    edge->destination >= header->state_count)
		    break;
		current = edge->destination;
	    }
	}
    }
    if ((header->features & semantic_feature_mask) != expected_features ||
	((header->features & ONIBI_RSEQ_FEATURE_FIRST_BITMAP) != 0 &&
	 (!bitmap_expected || memcmp(header->first_bitmap, expected_bitmap,
				     sizeof(expected_bitmap)) != 0)) ||
	((header->features & ONIBI_RSEQ_FEATURE_FIRST_BITMAP) == 0 &&
	 !onibi_rseq_bytes_zero(header->first_bitmap,
				sizeof(header->first_bitmap))) ||
	(header->prefix_length != 0 &&
	 (header->prefix_length != expected_prefix_length ||
	  memcmp(header->prefix, expected_prefix, sizeof(expected_prefix)) !=
	      0)) ||
	onibi_execution_kind_for_requirements(execution_requirements) !=
	    header->exec_kind)
	rb_raise(rb_eArgError, "inconsistent Onibi RSeq execution contract");
    return Qnil;
}

static VALUE
onibi_rseq_blob_validate_cleanup(VALUE opaque)
{
    OnibiRSeqVerifyCall *call = (OnibiRSeqVerifyCall *)(uintptr_t)opaque;
    onibi_allocation_owner_cleanup(&call->allocations);
    return Qnil;
}

static void
onibi_rseq_blob_validate(VALUE blob)
{
    OnibiRSeqVerifyCall call;
    memset(&call, 0, sizeof(call));
    call.blob = blob;
    onibi_allocation_owner_init(&call.allocations, NULL);
    call.allocations.failure_phase = -1;
    (void)rb_ensure(onibi_rseq_blob_validate_body, (VALUE)(uintptr_t)&call,
		    onibi_rseq_blob_validate_cleanup, (VALUE)(uintptr_t)&call);
}

static OnibiExecStatus
onibi_exec_regular(OnibiExecCtx *ctx)
{
    onibi_diagnostics.regular++;
    int result = onibi_rseq_regular_match(ctx);
    if (result == -2) {
	onibi_diagnostics.fallback++;
	return ONIBI_EXEC_STATUS_FALLBACK;
    }
    return result > 0	? ONIBI_EXEC_STATUS_MATCH
	   : result < 0 ? ONIBI_EXEC_STATUS_INTERNAL_ERROR
			: ONIBI_EXEC_STATUS_NO_MATCH;
}

/* Execute the action-free regular subset directly from the immutable RSeq
   blob.  This path does not materialize semantic states, edges, or visited
   Ruby objects for each candidate start. */
/* RSeq runtime representation: view construction, validation, and the
 * REGULAR_FAST entry.  Interpreter policy lives in this module, not in the
 * Unicode or diagnostic modules. */
