static int
onibi_rseq_simple_match(VALUE rseq, const OnibiRSeqView *cached_view, VALUE str,
			long start, long *matched_end)
{
    OnibiRSeqView local_view;
    const OnibiRSeqView *view = cached_view;
    if (!view) {
	VALUE blob = onibi_hash_value_id(rseq, id_key_blob);
	if (!onibi_rseq_view_init(blob, &local_view)) return -1;
	view = &local_view;
    }
    const OnibiRSeqHeader *header = view->header;
    if (header->counter_count != 0 || header->subprogram_count != 1) return -1;
    if (header->action_count != 0) {
	for (uint32_t i = 0; i < header->action_count; i++) {
	    /* Capture boundaries and MATCH_RESET do not change match?
	     * acceptance. Position assertions and all dynamic actions still
	     * require GIR. */
	    if (view->actions[i].op != ONIBI_RA_END &&
		view->actions[i].op != ONIBI_RA_CAPTURE &&
		view->actions[i].op != ONIBI_RA_MATCH_RESET)
		return -1;
	}
    }
    if (header->state_count == 0 || header->start_edge_count == 0) return -1;
    VALUE semantic_states = onibi_hash_value_id(rseq, id_key_states);
    VALUE semantic_header = onibi_hash_value_id(rseq, id_key_header);
    if (RTEST(onibi_hash_value_id(semantic_header, id_key_ignorecase)) ||
	RTEST(onibi_hash_value_id(semantic_header, id_key_multiline)))
	return -1;
    for (long i = 0; i < RARRAY_LEN(semantic_states); i++) {
	VALUE payload = onibi_hash_value_id(rb_ary_entry(semantic_states, i),
					    id_key_payload);
	if (RB_TYPE_P(payload, T_HASH) &&
	    (RTEST(onibi_hash_value_id(payload, id_key_ignorecase)) ||
	     RTEST(onibi_hash_value_id(payload, id_key_multiline))))
	    return -1;
    }
    const OnibiRState *states = view->states;
    const OnibiREdge *edges = view->edges;
    const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(str);
    if (!rb_enc_str_asciionly_p(str) &&
	rb_enc_get_index(str) != rb_ascii8bit_encindex())
	return -1;
    for (uint32_t i = 0; i < header->state_count; i++) {
	/* Keep branching and repeat cycles on the established ordered walker
	   until their physical edge priority has a dedicated direct lowering.
	 */
	if (states[i].edge_count > 1) return -1;
	if (states[i].flags != 0) return -1;
	if (states[i].op == ONIBI_RS_CLASS || states[i].op == ONIBI_RS_ANY)
	    return -1;
	if (states[i].op != 0 && states[i].op != ONIBI_RS_CHAR &&
	    states[i].op != ONIBI_RS_CLASS && states[i].op != ONIBI_RS_ANY)
	    return -1;
	if (states[i].op == ONIBI_RS_CHAR) {
	    if (view->literals[states[i].payload].flags != 0) return -1;
	}
	else if (states[i].op == ONIBI_RS_CLASS) {
	    if (view->classes[states[i].payload].flags != 0) return -1;
	}
    }
    size_t span = (size_t)RSTRING_LEN(str) + 1U;
    if ((size_t)header->state_count > SIZE_MAX / span) return -1;
    size_t visited_size = (size_t)header->state_count * span;
    if (visited_size > (size_t)1 << 20) return -1;
    if (visited_size > SIZE_MAX / sizeof(onibi_simple_frame_t)) return -1;
    unsigned char *visited = (unsigned char *)alloca(visited_size);
    memset(visited, 0, visited_size);
    size_t stack_capacity = visited_size;
    onibi_simple_frame_t *stack =
	(onibi_simple_frame_t *)alloca(stack_capacity * sizeof(*stack));
    size_t stack_size = 0;
    for (uint32_t i = 0; i < header->start_edge_count; i++) {
	const OnibiREdge *edge = &edges[header->start_edge_base + i];
	if (edge->destination == ONIBI_ACCEPT_STATE) {
	    *matched_end = start;
	    return 1;
	}
	if (edge->destination < header->state_count)
	    stack[stack_size++] =
		(onibi_simple_frame_t){edge->destination, start};
    }
    while (stack_size > 0) {
	onibi_simple_frame_t frame = stack[--stack_size];
	if (frame.pos < 0 || frame.pos > RSTRING_LEN(str)) continue;
	size_t mark = (size_t)frame.state * span + (size_t)frame.pos;
	if (visited[mark]) continue;
	visited[mark] = 1;
	const OnibiRState *state = &states[frame.state];
	long next_pos = frame.pos;
	int hit = 1;
	if (state->op == 0) {
	    *matched_end = frame.pos;
	    return 1;
	}
	if (state->op == ONIBI_RS_CHAR || state->op == ONIBI_RS_CLASS ||
	    state->op == ONIBI_RS_ANY) {
	    if (frame.pos >= RSTRING_LEN(str))
		hit = 0;
	    else if (state->op == ONIBI_RS_CHAR) {
		const OnibiLiteralDesc *literal =
		    &view->literals[state->payload];
		hit = bytes[frame.pos] == view->blob[literal->data_offset];
	    }
	    else if (state->op == ONIBI_RS_CLASS) {
		const OnibiClassDesc *klass = &view->classes[state->payload];
		const unsigned char *bitmap = view->blob + klass->data_offset;
		hit = (bitmap[bytes[frame.pos] >> 3] &
		       (1U << (bytes[frame.pos] & 7))) != 0;
	    }
	    else
		hit = bytes[frame.pos] != '\n';
	    if (hit) next_pos++;
	}
	else
	    hit = 0;
	if (!hit) continue;
	uint32_t begin = state->edge_base;
	for (uint32_t e = 0; e < state->edge_count; e++) {
	    uint32_t destination = edges[begin + e].destination;
	    if (destination == ONIBI_ACCEPT_STATE) {
		*matched_end = next_pos;
		return 1;
	    }
	    if (destination < header->state_count &&
		stack_size < stack_capacity)
		stack[stack_size++] =
		    (onibi_simple_frame_t){destination, next_pos};
	}
    }
    return 0;
}


