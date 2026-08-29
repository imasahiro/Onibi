static VALUE
onibi_rseq_execution_graph(VALUE rseq)
{
    VALUE blob = onibi_hash_value_id(rseq, id_key_blob);
    VALUE semantic_states = onibi_hash_value_id(rseq, id_key_states);
    VALUE semantic_edges = onibi_hash_value_id(rseq, id_key_edges);
    VALUE semantic_start_edges = onibi_hash_value_id(rseq, id_key_start_edges);
    VALUE semantic_actions = onibi_hash_value_id(rseq, id_key_actions);
    VALUE graph = rb_hash_new();
    VALUE states = rb_ary_new_capa(RARRAY_LEN(semantic_states));
    VALUE edges = rb_ary_new_capa(RARRAY_LEN(semantic_edges));
    VALUE start_edges = rb_ary_new_capa(RARRAY_LEN(semantic_start_edges));
    VALUE outgoing = rb_ary_new_capa(RARRAY_LEN(semantic_states));
    long state_count = RARRAY_LEN(semantic_states);
    size_t degree_bytes =
	state_count > 0 && (size_t)state_count <= SIZE_MAX / sizeof(size_t)
	    ? (size_t)state_count * sizeof(size_t)
	    : 0;
    size_t *outgoing_degrees =
	degree_bytes == 0 ? NULL : ALLOC_N(size_t, (size_t)state_count);
    if (outgoing_degrees) memset(outgoing_degrees, 0, degree_bytes);
    for (long i = 0; i < RARRAY_LEN(semantic_edges); i++) {
	VALUE edge = rb_ary_entry(semantic_edges, i);
	VALUE from = onibi_hash_value_id(edge, id_key_from);
	if (outgoing_degrees && RB_INTEGER_TYPE_P(from)) {
	    long state = NUM2LONG(from);
	    if (state >= 0 && state < state_count) outgoing_degrees[state]++;
	}
    }
    for (long i = 0; i < state_count; i++) {
	size_t capacity = outgoing_degrees ? outgoing_degrees[i] : 0;
	rb_ary_push(outgoing, rb_ary_new_capa(capacity > (size_t)LONG_MAX
						  ? LONG_MAX
						  : (long)capacity));
    }
    if (outgoing_degrees) xfree(outgoing_degrees);
    OnibiRSeqHeader header;
    memcpy(&header, RSTRING_PTR(blob), sizeof(header));
    const OnibiRState *physical_states =
	(const OnibiRState *)(RSTRING_PTR(blob) + header.states_offset);
    const OnibiREdge *physical_edges =
	(const OnibiREdge *)(RSTRING_PTR(blob) + header.edges_offset);
    for (long i = 0; i < RARRAY_LEN(semantic_states); i++) {
	VALUE state = rb_hash_dup(rb_ary_entry(semantic_states, i));
	ID op = physical_states[i].op == ONIBI_RS_CHAR	     ? id_g_char
		: physical_states[i].op == ONIBI_RS_CLASS    ? id_g_class
		: physical_states[i].op == ONIBI_RS_ANY	     ? id_g_any
		: physical_states[i].op == ONIBI_RS_GRAPHEME ? id_g_grapheme
		: physical_states[i].op == ONIBI_RS_BACKREF  ? id_g_backref
		: physical_states[i].op == ONIBI_RS_CALL     ? id_g_call
		: physical_states[i].op == ONIBI_RS_ATOMIC   ? id_g_atomic
		: physical_states[i].op == ONIBI_RS_ABSENT   ? id_g_absent
							     : id_g_accept;
	rb_hash_aset(state, ID2SYM(id_key_op), ID2SYM(op));
	rb_hash_aset(state, ID2SYM(id_key_opcode),
		     UINT2NUM(physical_states[i].op));
	rb_ary_push(states, state);
    }
    for (long i = 0; i < RARRAY_LEN(semantic_edges); i++) {
	VALUE edge = rb_hash_dup(rb_ary_entry(semantic_edges, i));
	uint32_t destination = physical_edges[i].destination;
	if (destination == ONIBI_ACCEPT_STATE)
	    destination = (uint32_t)(RARRAY_LEN(states) - 1);
	rb_hash_aset(edge, ID2SYM(id_key_to), UINT2NUM(destination));
	uint32_t action_offset = physical_edges[i].action_offset;
	uint32_t action_count =
	    action_offset == 0
		? 0
		: (uint32_t)RARRAY_LEN(onibi_hash_value_id(
		      rb_ary_entry(semantic_edges, i), id_key_actions));
	VALUE physical_program = rb_ary_new_capa((long)action_count);
	if (action_offset != 0) {
	    uint32_t action_index =
		action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
	    for (uint32_t n = 0; n < action_count; n++) {
		VALUE action = rb_ary_entry(semantic_actions, action_index + n);
		rb_ary_push(physical_program, action);
	    }
	}
	rb_hash_aset(edge, ID2SYM(id_key_actions), physical_program);
	rb_ary_push(edges, edge);
	long from = NUM2LONG(onibi_hash_value_id(edge, id_key_from));
	if (from >= 0 && from < RARRAY_LEN(outgoing))
	    rb_ary_push(rb_ary_entry(outgoing, from), edge);
    }
    for (long i = 0; i < RARRAY_LEN(semantic_start_edges); i++) {
	VALUE edge = rb_hash_dup(rb_ary_entry(semantic_start_edges, i));
	const OnibiREdge *physical_edge =
	    &physical_edges[header.start_edge_base + i];
	rb_hash_aset(edge, ID2SYM(id_key_to),
		     UINT2NUM(physical_edge->destination));
	uint32_t action_count =
	    physical_edge->action_offset == 0
		? 0
		: (uint32_t)RARRAY_LEN(onibi_hash_value_id(
		      rb_ary_entry(semantic_start_edges, i), id_key_actions));
	VALUE physical_program = rb_ary_new_capa((long)action_count);
	if (physical_edge->action_offset != 0) {
	    uint32_t action_index =
		physical_edge->action_offset / (uint32_t)sizeof(OnibiRAction) -
		1U;
	    for (uint32_t n = 0; n < action_count; n++) {
		VALUE action = rb_ary_entry(semantic_actions, action_index + n);
		rb_ary_push(physical_program, action);
	    }
	}
	rb_hash_aset(edge, ID2SYM(id_key_actions), physical_program);
	rb_ary_push(start_edges, edge);
    }
    rb_hash_aset(graph, ID2SYM(id_key_states), states);
    rb_hash_aset(graph, ID2SYM(id_key_edges), edges);
    rb_hash_aset(graph, ID2SYM(id_key_start_edges), start_edges);
    rb_hash_aset(graph, ID2SYM(id_key_outgoing), outgoing);
    rb_hash_aset(graph, ID2SYM(id_key_subprograms),
		 onibi_hash_value_id(rseq, id_key_subprograms));
    rb_hash_aset(graph, ID2SYM(id_key_counter_count),
		 UINT2NUM(header.counter_count));
    return graph;
}

typedef struct {
    uint32_t state;
    long pos;
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
    return 1;
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

/* Execute the action-free regular subset directly from the immutable RSeq
   blob.  This path does not materialize semantic states, edges, or visited
   Ruby objects for each candidate start. */
