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
	RSTRING_LEN(blob) < (long)sizeof(OnibiRSeqHeader))
	return 0;
    view->blob = (const unsigned char *)RSTRING_PTR(blob);
    view->header = (const OnibiRSeqHeader *)view->blob;
    if (view->header->magic != ONIBI_RSEQ_MAGIC ||
	view->header->version != ONIBI_RSEQ_VERSION ||
	view->header->blob_size > (uint32_t)RSTRING_LEN(blob))
	return 0;
    view->states =
	(const OnibiRState *)(view->blob + view->header->states_offset);
    view->edges = (const OnibiREdge *)(view->blob + view->header->edges_offset);
    view->actions =
	(const OnibiRAction *)(view->blob + view->header->actions_offset);
    view->classes =
	(const OnibiClassDesc *)(view->blob + view->header->classes_offset);
    view->literals =
	(const OnibiLiteralDesc *)(view->blob +
				   view->header->descriptors_offset);
    view->subprograms =
	(const OnibiSubprogramDesc *)(view->blob +
				      view->header->subprograms_offset);
    view->class_stack_capacity = 0;
    view->regular_capable = 0;
    return 1;
}

static void
onibi_rseq_view_prepare(OnibiRSeqView *view)
{
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
onibi_rseq_class_descriptor_valid(const OnibiRSeqView *view,
				  const OnibiClassDesc *klass,
				  uint64_t data_begin, uint64_t data_end)
{
    if (klass->kind > ONIBI_CLASS_MIXED || klass->data_length == 0 ||
	(klass->flags & ~ONIBI_RSEQ_CLASS_FLAG_NEGATED) != 0 ||
	klass->data_offset != data_begin || (klass->data_offset & 3U) != 0 ||
	(uint64_t)klass->data_offset + klass->data_length > data_end)
	return 0;
    if (klass->kind == ONIBI_CLASS_ASCII_BITMAP)
	return klass->data_length == 32;
    if (klass->kind == ONIBI_CLASS_ENCODING_CTYPE)
	return klass->data_length == sizeof(uint32_t);
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
	    depth++;
	}
	else if (expr[i].op == ONIBI_CLASS_EXPR_NEGATE) {
	    if (depth < 1) return 0;
	}
	else {
	    if (depth < 2) return 0;
	    depth--;
	}
    }
    return count != 0 && depth == 1;
}

static void
onibi_rseq_blob_validate(VALUE blob)
{
    OnibiRSeqView view;
    if (!onibi_rseq_view_init(blob, &view) || !RTEST(rb_obj_frozen_p(blob)))
	rb_raise(rb_eArgError, "invalid Onibi RSeq blob");
    const OnibiRSeqHeader *header = view.header;
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
    uint32_t literal_count = 0;
    if (states_end <= header->blob_size) {
	for (uint32_t i = 0; i < header->state_count; i++) {
	    if (view.states[i].op != ONIBI_RS_CHAR) continue;
	    if (view.states[i].payload == UINT32_MAX)
		rb_raise(rb_eArgError, "invalid Onibi RSeq literal payload");
	    if (view.states[i].payload + 1U > literal_count)
		literal_count = view.states[i].payload + 1U;
	}
    }
    uint64_t literal_desc_end =
	(uint64_t)header->descriptors_offset +
	(uint64_t)literal_count * sizeof(OnibiLiteralDesc);
    uint64_t subprogram_end =
	(uint64_t)header->subprograms_offset +
	(uint64_t)header->subprogram_count * sizeof(OnibiSubprogramDesc);
    if (header->states_offset < sizeof(*header) ||
	states_end > header->edges_offset ||
	edges_end > header->actions_offset ||
	actions_end > header->classes_offset ||
	class_desc_end > header->literals_offset ||
	header->literals_offset > header->descriptors_offset ||
	literal_desc_end > header->subprograms_offset ||
	subprogram_end > header->blob_size ||
	header->start_edge_base > header->edge_count ||
	header->start_edge_count > header->edge_count - header->start_edge_base)
	rb_raise(rb_eArgError, "invalid Onibi RSeq section layout");
    for (uint32_t i = 0; i < header->state_count; i++) {
	const OnibiRState *state = &view.states[i];
	if ((uint64_t)state->edge_base + state->edge_count >
	    header->start_edge_base)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq state edge range");
	if (state->op > ONIBI_RS_RUN_ANY)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq state opcode");
	if (state->op == ONIBI_RS_CLASS &&
	    state->payload >= header->class_count)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq class payload");
	if (state->op == ONIBI_RS_CHAR && state->payload >= literal_count)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq literal payload");
    }
    for (uint32_t i = 0; i < header->edge_count; i++) {
	const OnibiREdge *edge = &view.edges[i];
	if (edge->destination != ONIBI_ACCEPT_STATE &&
	    edge->destination >= header->state_count)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq edge destination");
	if (edge->action_offset != 0) {
	    if (edge->action_offset % sizeof(OnibiRAction) != 0)
		rb_raise(rb_eArgError, "invalid Onibi RSeq action offset");
	    uint32_t index =
		edge->action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
	    if (index >= header->action_count)
		rb_raise(rb_eArgError, "invalid Onibi RSeq action offset");
	}
    }
    for (uint32_t i = 0; i < header->action_count; i++)
	if (view.actions[i].op > ONIBI_RA_PROGRESS)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq action opcode");
    for (uint32_t i = 0; i < header->subprogram_count; i++) {
	const OnibiSubprogramDesc *subprogram = &view.subprograms[i];
	if (subprogram->entry >= header->state_count ||
	    subprogram->accept >= header->state_count)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq subprogram");
    }
    uint64_t class_data_cursor = class_desc_end;
    for (uint32_t i = 0; i < header->class_count; i++) {
	const OnibiClassDesc *klass = &view.classes[i];
	if (!onibi_rseq_class_descriptor_valid(&view, klass, class_data_cursor,
					       header->literals_offset))
	    rb_raise(rb_eArgError, "invalid Onibi RSeq class descriptor");
	class_data_cursor += klass->data_length;
    }
    if (class_data_cursor != header->literals_offset)
	rb_raise(rb_eArgError, "invalid Onibi RSeq class data layout");
    for (uint32_t i = 0; i < literal_count; i++) {
	const OnibiLiteralDesc *literal = &view.literals[i];
	if ((uint64_t)literal->data_offset + literal->data_length >
	    header->descriptors_offset)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq literal descriptor");
    }
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
