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
    view->native_eligible = 0;
    return 1;
}

static void
onibi_rseq_view_prepare(OnibiRSeqView *view)
{
    const OnibiRSeqHeader *header = view->header;
    if ((header->features & 32U) != 0 || (header->flags & 3U) != 0 ||
	header->state_count == 0 || header->start_edge_count == 0)
	return;
    for (uint32_t i = 0; i < header->state_count; i++) {
	const OnibiRState *state = &view->states[i];
	if (state->flags != 0) return;
	if (state->op != 0 && state->op != ONIBI_RS_CHAR &&
	    state->op != ONIBI_RS_CLASS && state->op != ONIBI_RS_ANY &&
	    state->op != ONIBI_RS_GRAPHEME && state->op != ONIBI_RS_BACKREF &&
	    state->op != ONIBI_RS_CALL)
	    return;
	if (state->op == ONIBI_RS_CHAR &&
	    view->literals[state->payload].flags != 0)
	    return;
	if (state->op == ONIBI_RS_CLASS &&
	    view->classes[state->payload].flags != 0)
	    return;
	if (state->op == ONIBI_RS_CALL &&
	    state->payload >= header->subprogram_count)
	    return;
    }
    view->native_eligible = 1;
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
    for (uint32_t i = 0; i < header->class_count; i++) {
	const OnibiClassDesc *klass = &view.classes[i];
	if (klass->data_length != 32 || klass->kind != 0 ||
	    (uint64_t)klass->data_offset + klass->data_length >
		header->descriptors_offset)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq class descriptor");
    }
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
    int result = onibi_rseq_regular_match(
	ctx->rseq, ctx->view, ctx->subject, ctx->attempt_start,
	ctx->search_origin, &ctx->matched_end);
    return result > 0	? ONIBI_EXEC_STATUS_MATCH
	   : result < 0 ? ONIBI_EXEC_STATUS_INTERNAL_ERROR
			: ONIBI_EXEC_STATUS_NO_MATCH;
}

/* Execute the action-free regular subset directly from the immutable RSeq
   blob.  This path does not materialize semantic states, edges, or visited
   Ruby objects for each candidate start. */
