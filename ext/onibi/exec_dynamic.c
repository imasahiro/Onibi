static int
onibi_rseq_word_byte(unsigned char byte)
{
    return isalnum(byte) || byte == '_';
}

static int
onibi_rseq_edge_actions_ok(const OnibiRSeqView *view, const OnibiREdge *edge,
			   VALUE str, long pos, long search_origin,
			   long *counters, uint32_t counter_count,
			   long *captures, uint32_t capture_slots)
{
    if (edge->action_offset == 0) return 1;
    uint32_t index = edge->action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
    for (; index < view->header->action_count; index++) {
	const OnibiRAction *action = &view->actions[index];
	if (action->op == ONIBI_RA_END) return 1;
	if (action->op == ONIBI_RA_CAPTURE) {
	    if (!captures || action->arg16 >= capture_slots) return 0;
	    captures[action->arg16] = pos;
	    continue;
	}
	if (action->op == ONIBI_RA_TEST_CAPTURE) {
	    uint32_t begin = (uint32_t)action->arg16 * 2U;
	    int set = captures && begin + 1U < capture_slots &&
		      captures[begin] >= 0 && captures[begin + 1U] >= 0;
	    if ((action->flags == ONIBI_RA_TEST_CAPTURE_SET && !set) ||
		(action->flags == ONIBI_RA_TEST_CAPTURE_UNSET && set))
		return 0;
	    continue;
	}
	if (action->op == ONIBI_RA_MATCH_RESET) continue;
	if (action->op == ONIBI_RA_COUNTER_SET ||
	    action->op == ONIBI_RA_COUNTER_ADD ||
	    action->op == ONIBI_RA_COUNTER_TEST) {
	    if (!counters || action->arg16 >= counter_count) return 0;
	    if (action->op == ONIBI_RA_COUNTER_SET)
		counters[action->arg16] = (long)action->arg32;
	    else if (action->op == ONIBI_RA_COUNTER_ADD)
		counters[action->arg16]++;
	    else {
		int hit = action->flags == ONIBI_RA_COUNTER_GE
			      ? counters[action->arg16] >= (long)action->arg32
			      : counters[action->arg16] < (long)action->arg32;
		if (!hit) return 0;
	    }
	    continue;
	}
	if (action->op != ONIBI_RA_ASSERT_POSITION) return 0;
	int hit = 0;
	switch ((OnibiRAssertKind)action->arg16) {
	case ONIBI_RAP_BEGIN_BUFFER: hit = pos == 0; break;
	case ONIBI_RAP_END_BUFFER: hit = pos == RSTRING_LEN(str); break;
	case ONIBI_RAP_BEGIN_LINE:
	    hit = pos == 0 || RSTRING_PTR(str)[pos - 1] == '\n';
	    break;
	case ONIBI_RAP_END_LINE:
	    hit = pos == RSTRING_LEN(str) || RSTRING_PTR(str)[pos] == '\n';
	    break;
	case ONIBI_RAP_SEMI_END_BUFFER:
	    hit = pos == RSTRING_LEN(str) || (pos + 1 == RSTRING_LEN(str) &&
					      RSTRING_PTR(str)[pos] == '\n');
	    break;
	case ONIBI_RAP_SEARCH_ORIGIN: hit = pos == search_origin; break;
	case ONIBI_RAP_WORD_BOUNDARY:
	case ONIBI_RAP_NONWORD_BOUNDARY: {
	    int left = pos > 0 && onibi_rseq_word_byte(
				      (unsigned char)RSTRING_PTR(str)[pos - 1]);
	    int right =
		pos < RSTRING_LEN(str) &&
		onibi_rseq_word_byte((unsigned char)RSTRING_PTR(str)[pos]);
	    hit = left != right;
	    if (action->arg16 == ONIBI_RAP_NONWORD_BOUNDARY) hit = !hit;
	    break;
	}
	default: return 0;
	}
	if (!hit) return 0;
    }
    return 0;
}

static int
onibi_rseq_simple_match(VALUE rseq, const OnibiRSeqView *cached_view, VALUE str,
			long start, long search_origin, long *matched_end)
{
    OnibiRSeqView local_view;
    const OnibiRSeqView *view = cached_view;
    if (!view) {
	VALUE blob = rseq;
	if (!onibi_rseq_view_init(blob, &local_view)) return -1;
	onibi_rseq_view_prepare(&local_view);
	view = &local_view;
    }
    const OnibiRSeqHeader *header = view->header;
    if (!view->native_eligible) return -1;
    const OnibiRState *states = view->states;
    const OnibiREdge *edges = view->edges;
    const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(str);
    if (!rb_enc_str_asciionly_p(str) &&
	rb_enc_get_index(str) != rb_ascii8bit_encindex())
	return -1;
    size_t span = (size_t)RSTRING_LEN(str) + 1U;
    if ((size_t)header->state_count > SIZE_MAX / span) return -1;
    size_t visited_size = (size_t)header->state_count * span;
    if (visited_size > (size_t)65536) return -1;
    if (visited_size > SIZE_MAX / sizeof(onibi_simple_frame_t)) return -1;
    unsigned char *visited = (unsigned char *)alloca(visited_size);
    memset(visited, 0, visited_size);
    int use_visited = header->counter_count == 0 &&
		      header->capture_count == 0 &&
		      header->subprogram_count == 1;
    size_t stack_capacity = visited_size;
    onibi_simple_frame_t *stack =
	(onibi_simple_frame_t *)alloca(stack_capacity * sizeof(*stack));
    if (header->counter_count != 0 &&
	(stack_capacity > SIZE_MAX / header->counter_count ||
	 stack_capacity * header->counter_count > SIZE_MAX / sizeof(long)))
	return -1;
    long *counter_pool =
	header->counter_count == 0
	    ? NULL
	    : (long *)alloca(stack_capacity * header->counter_count *
			     sizeof(long));
    if (header->capture_count > UINT32_MAX / 2U) return -1;
    uint32_t capture_slots = header->capture_count * 2U;
    if (capture_slots != 0 &&
	(stack_capacity > SIZE_MAX / capture_slots ||
	 stack_capacity * capture_slots > SIZE_MAX / sizeof(long)))
	return -1;
    long *capture_pool =
	capture_slots == 0
	    ? NULL
	    : (long *)alloca(stack_capacity * capture_slots * sizeof(long));
    enum { ONIBI_NATIVE_CALL_LIMIT = 32, ONIBI_NATIVE_CALL_STACKS = 16384 };
    uint32_t *return_pool = NULL;
    if (header->subprogram_count > 1) {
	if (stack_capacity > ONIBI_NATIVE_CALL_STACKS) return -1;
	return_pool = (uint32_t *)alloca(
	    stack_capacity * ONIBI_NATIVE_CALL_LIMIT * sizeof(uint32_t));
    }
    size_t stack_size = 0;
    for (uint32_t i = header->start_edge_count; i > 0; i--) {
	const OnibiREdge *edge = &edges[header->start_edge_base + (i - 1U)];
	long *branch_counters =
	    counter_pool ? counter_pool + stack_size * header->counter_count
			 : NULL;
	long *branch_captures =
	    capture_pool ? capture_pool + stack_size * capture_slots : NULL;
	uint32_t *branch_returns =
	    return_pool ? return_pool + stack_size * ONIBI_NATIVE_CALL_LIMIT
			: NULL;
	if (branch_counters)
	    memset(branch_counters, 0, header->counter_count * sizeof(long));
	if (branch_captures)
	    for (uint32_t slot = 0; slot < capture_slots; slot++)
		branch_captures[slot] = -1;
	if (!onibi_rseq_edge_actions_ok(view, edge, str, start, search_origin,
					branch_counters, header->counter_count,
					branch_captures, capture_slots))
	    continue;
	if (edge->destination == ONIBI_ACCEPT_STATE) {
	    *matched_end = start;
	    return 1;
	}
	if (edge->destination < header->state_count)
	    stack[stack_size++] = (onibi_simple_frame_t){
		edge->destination, start,	   branch_counters,
		branch_captures,   branch_returns, 0};
    }
    while (stack_size > 0) {
	onibi_simple_frame_t frame = stack[--stack_size];
	if (frame.pos < 0 || frame.pos > RSTRING_LEN(str)) continue;
	size_t mark = (size_t)frame.state * span + (size_t)frame.pos;
	if (use_visited) {
	    if (visited[mark]) continue;
	    visited[mark] = 1;
	}
	const OnibiRState *state = &states[frame.state];
	long next_pos = frame.pos;
	int hit = 1;
	if (state->op == 0) {
	    if (frame.return_depth == 0) {
		*matched_end = frame.pos;
		return 1;
	    }
	    if (stack_size >= stack_capacity) continue;
	    uint32_t edge_index = frame.returns[frame.return_depth - 1U];
	    if (edge_index >= header->start_edge_base) return -1;
	    const OnibiREdge *edge = &edges[edge_index];
	    long *next_counters =
		counter_pool ? counter_pool + stack_size * header->counter_count
			     : NULL;
	    if (next_counters)
		memcpy(next_counters, frame.counters,
		       header->counter_count * sizeof(long));
	    long *next_captures =
		capture_pool ? capture_pool + stack_size * capture_slots : NULL;
	    if (next_captures)
		memcpy(next_captures, frame.captures,
		       capture_slots * sizeof(long));
	    uint32_t *next_returns =
		return_pool + stack_size * ONIBI_NATIVE_CALL_LIMIT;
	    if (frame.return_depth > 1U)
		memcpy(next_returns, frame.returns,
		       (frame.return_depth - 1U) * sizeof(uint32_t));
	    if (!onibi_rseq_edge_actions_ok(
		    view, edge, str, frame.pos, search_origin, next_counters,
		    header->counter_count, next_captures, capture_slots))
		continue;
	    if (edge->destination == ONIBI_ACCEPT_STATE) {
		*matched_end = frame.pos;
		return 1;
	    }
	    stack[stack_size++] = (onibi_simple_frame_t){
		edge->destination, frame.pos,
		next_counters,	   next_captures,
		next_returns,	   (uint16_t)(frame.return_depth - 1U)};
	    continue;
	}
	if (state->op == ONIBI_RS_CALL) {
	    if (frame.return_depth >= ONIBI_NATIVE_CALL_LIMIT) return -1;
	    const OnibiSubprogramDesc *subprogram =
		&view->subprograms[state->payload];
	    uint32_t begin = state->edge_base;
	    for (uint32_t e = state->edge_count; e > 0; e--) {
		if (stack_size >= stack_capacity) break;
		long *next_counters =
		    counter_pool
			? counter_pool + stack_size * header->counter_count
			: NULL;
		if (next_counters)
		    memcpy(next_counters, frame.counters,
			   header->counter_count * sizeof(long));
		long *next_captures =
		    capture_pool ? capture_pool + stack_size * capture_slots
				 : NULL;
		if (next_captures)
		    memcpy(next_captures, frame.captures,
			   capture_slots * sizeof(long));
		uint32_t *next_returns =
		    return_pool + stack_size * ONIBI_NATIVE_CALL_LIMIT;
		if (frame.return_depth > 0)
		    memcpy(next_returns, frame.returns,
			   frame.return_depth * sizeof(uint32_t));
		next_returns[frame.return_depth] = begin + (e - 1U);
		stack[stack_size++] = (onibi_simple_frame_t){
		    subprogram->entry, frame.pos,
		    next_counters,     next_captures,
		    next_returns,      (uint16_t)(frame.return_depth + 1U)};
	    }
	    continue;
	}
	if (state->op == ONIBI_RS_GRAPHEME) {
	    long width = onibi_grapheme_width(str, frame.pos);
	    if (width <= 0)
		hit = 0;
	    else
		next_pos += width;
	}
	else if (state->op == ONIBI_RS_BACKREF) {
	    uint32_t begin = state->payload * 2U;
	    if (!frame.captures || begin + 1U >= capture_slots ||
		frame.captures[begin] < 0 || frame.captures[begin + 1U] < 0)
		hit = 0;
	    else {
		long length =
		    frame.captures[begin + 1U] - frame.captures[begin];
		if (length < 0 || frame.pos + length > RSTRING_LEN(str) ||
		    memcmp(RSTRING_PTR(str) + frame.pos,
			   RSTRING_PTR(str) + frame.captures[begin],
			   (size_t)length) != 0)
		    hit = 0;
		else
		    next_pos += length;
	    }
	}
	else if (state->op == ONIBI_RS_CHAR || state->op == ONIBI_RS_CLASS ||
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
	for (uint32_t e = state->edge_count; e > 0; e--) {
	    if (stack_size >= stack_capacity) break;
	    const OnibiREdge *edge = &edges[begin + (e - 1U)];
	    long *next_counters =
		counter_pool ? counter_pool + stack_size * header->counter_count
			     : NULL;
	    if (next_counters)
		memcpy(next_counters, frame.counters,
		       header->counter_count * sizeof(long));
	    long *next_captures =
		capture_pool ? capture_pool + stack_size * capture_slots : NULL;
	    if (next_captures)
		memcpy(next_captures, frame.captures,
		       capture_slots * sizeof(long));
	    uint32_t *next_returns =
		return_pool ? return_pool + stack_size * ONIBI_NATIVE_CALL_LIMIT
			    : NULL;
	    if (frame.return_depth > 0)
		memcpy(next_returns, frame.returns,
		       frame.return_depth * sizeof(uint32_t));
	    if (!onibi_rseq_edge_actions_ok(
		    view, edge, str, next_pos, search_origin, next_counters,
		    header->counter_count, next_captures, capture_slots))
		continue;
	    uint32_t destination = edge->destination;
	    if (destination == ONIBI_ACCEPT_STATE) {
		*matched_end = next_pos;
		return 1;
	    }
	    if (destination < header->state_count)
		stack[stack_size++] = (onibi_simple_frame_t){
		    destination,   next_pos,	 next_counters,
		    next_captures, next_returns, frame.return_depth};
	}
    }
    return 0;
}
