static int
onibi_rseq_word_byte(unsigned char byte)
{
    return ((byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
	    (byte >= '0' && byte <= '9') || byte == '_');
}

static int
onibi_ascii_literal_equal(const unsigned char *left, const unsigned char *right,
			  size_t length, int fold)
{
    for (size_t i = 0; i < length; i++) {
	unsigned char a = left[i], b = right[i];
	if (fold) {
	    if (a >= 'A' && a <= 'Z') a = (unsigned char)(a + ('a' - 'A'));
	    if (b >= 'A' && b <= 'Z') b = (unsigned char)(b + ('a' - 'A'));
	}
	if (a != b) return 0;
    }
    return 1;
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
	    if (onibi_regular_capture_result) onibi_diagnostics.tag_events++;
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
	if (action->op == ONIBI_RA_MATCH_RESET) {
	    /* MATCH_RESET changes the reported start, not the VM attempt start.
	     */
	    if (onibi_active_exec_ctx)
		onibi_active_exec_ctx->reported_start = pos;
	    continue;
	}
	if (action->op == ONIBI_RA_PROGRESS) {
	    if (!counters || action->arg16 >= counter_count) return 0;
	    long marker = pos + 1;
	    if (counters[action->arg16] == marker) return 0;
	    counters[action->arg16] = marker;
	    continue;
	}
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
onibi_rseq_backtracking_match(VALUE rseq, const OnibiRSeqView *cached_view,
			      VALUE str, long start, long search_origin,
			      long *matched_end)
{
    onibi_diagnostics.dfs++;
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
    size_t span = (size_t)RSTRING_LEN(str) + 1U;
    if ((size_t)header->state_count > SIZE_MAX / span) return -1;
    size_t visited_size = (size_t)header->state_count * span;
    if (visited_size > (size_t)65536) return -1;
    if (visited_size > SIZE_MAX / sizeof(onibi_simple_frame_t)) return -1;
    unsigned char *visited = (unsigned char *)alloca(visited_size);
    memset(visited, 0, visited_size);
    /* A state/position revisit is a zero-progress cycle.  Keep the guard
     * active even when captures exist; capture actions do not consume input
     * and must not permit an unbounded nullable repetition. */
    /* Progress slot equivalent for the PoC: one bit per state/position.
     * A second visit means the nullable iteration made no input progress. */
    int progress_guard = 1;
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
    /* Start edges use the same checked push invariant as successor edges. */
    if ((size_t)header->start_edge_count > stack_capacity) return -1;
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
	if (edge->destination < header->state_count) {
	    if (stack_size >= stack_capacity) return -1;
	    stack[stack_size++] = (onibi_simple_frame_t){
		edge->destination, start,	   branch_counters,
		branch_captures,   branch_returns, 0};
	}
    }
    while (stack_size > 0) {
	onibi_simple_frame_t frame = stack[--stack_size];
	if (frame.pos < 0 || frame.pos > RSTRING_LEN(str)) continue;
	size_t mark = (size_t)frame.state * span + (size_t)frame.pos;
	if (progress_guard) {
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
		hit = frame.pos + literal->data_length <= RSTRING_LEN(str) &&
		      onibi_ascii_literal_equal(
			  bytes + frame.pos, view->blob + literal->data_offset,
			  literal->data_length,
			  (literal->flags &
			   ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0);
		if (hit) next_pos += literal->data_length - 1;
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

/* Regular execution uses ordered frontiers.  It has no DFS stack and keeps
 * one membership bitset for each frontier.  Dynamic programs stay in the
 * isolated compatibility walker above. */
static int
onibi_rseq_regular_match(VALUE rseq, const OnibiRSeqView *cached_view,
			 VALUE str, long start, long search_origin,
			 long *matched_end)
{
    OnibiRSeqView local_view;
    const OnibiRSeqView *view = cached_view;
    if (!view) {
	if (!onibi_rseq_view_init(rseq, &local_view)) return -1;
	onibi_rseq_view_prepare(&local_view);
	view = &local_view;
    }
    const OnibiRSeqHeader *header = view->header;
    if (!view->native_eligible) return -2;

    if (header->counter_count != 0 || header->subprogram_count != 1) {
	return -2;
    }
    uint32_t count = header->state_count;
    if (count == 0) return 0;
    uint32_t capture_slots = header->capture_count * 2U;
    size_t bits_size = ((size_t)count + 7U) / 8U;
    uint32_t *current = ALLOCA_N(uint32_t, count);
    uint32_t *next = ALLOCA_N(uint32_t, count);
    unsigned char *current_bits = ALLOCA_N(unsigned char, bits_size);
    unsigned char *next_bits = ALLOCA_N(unsigned char, bits_size);
    long *current_caps = capture_slots == 0 ? NULL
	: ALLOCA_N(long, (size_t)count * capture_slots);
    long *next_caps = capture_slots == 0 ? NULL
	: ALLOCA_N(long, (size_t)count * capture_slots);
    size_t current_count = 0;
    long best_end = -1;
    memset(current_bits, 0, bits_size);
    if (capture_slots != 0)
	for (size_t i = 0; i < (size_t)count * capture_slots; i++)
	    current_caps[i] = -1;
    for (uint32_t i = 0; i < header->start_edge_count; i++) {
	const OnibiREdge *edge = &view->edges[header->start_edge_base + i];
	/* Output-only capture actions do not change the regular state key.  The
	 * capture-producing frontier will materialize them in a later pass; for
	 * boolean matching they are non-failing actions. */
	if (edge->action_offset != 0) {
	    uint32_t ai =
		edge->action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
	    if (ai >= header->action_count ||
		(view->actions[ai].op != ONIBI_RA_CAPTURE &&
		 view->actions[ai].op != ONIBI_RA_END))
		continue;
	}
	if (edge->destination == ONIBI_ACCEPT_STATE) {
	    /* An empty alternative is a fallback.  A consuming branch at this
	     * same start has higher priority when it can match. */
	    best_end = start;
	    continue;
	}
	if (edge->destination >= count) continue;
	uint32_t state = edge->destination;
	if ((current_bits[state >> 3] & (1U << (state & 7))) == 0) {
	    if (capture_slots != 0) {
		long *caps = current_caps + (size_t)current_count * capture_slots;
		for (uint32_t slot = 0; slot < capture_slots; slot++) caps[slot] = -1;
		if (edge->action_offset != 0 &&
		    !onibi_rseq_edge_actions_ok(view, edge, str, start,
						search_origin, NULL, 0, caps,
						capture_slots))
		    continue;
	    }
	    current_bits[state >> 3] |= (unsigned char)(1U << (state & 7));
	    current[current_count++] = state;
	}
    }
    long position = start;
    long *fallback_caps = capture_slots == 0 ? NULL
	: ALLOCA_N(long, capture_slots);
    if (fallback_caps)
	for (uint32_t i = 0; i < capture_slots; i++) fallback_caps[i] = -1;
    for (;;) {
	long step_width = 1;
	size_t next_count = 0;
	memset(next_bits, 0, bits_size);
	int have_fallback = 0;
	long fallback_end = 0;
	for (size_t i = 0; i < current_count; i++) {
	    uint32_t state_id = current[i];
	    const OnibiRState *state = &view->states[state_id];
	    if (state->op == 0) {
		if (!next_count) {
		    if (onibi_regular_capture_result && capture_slots != 0) {
			memcpy(onibi_regular_capture_result,
			       current_caps + i * capture_slots,
			       capture_slots * sizeof(long));
			for (uint32_t ae = 0; ae < state->edge_count; ae++) {
			    const OnibiREdge *accept_edge =
				&view->edges[state->edge_base + ae];
			    if (accept_edge->destination == ONIBI_ACCEPT_STATE &&
				accept_edge->action_offset != 0) {
				onibi_rseq_edge_actions_ok(
				    view, accept_edge, str, position,
				    search_origin, NULL, 0,
				    onibi_regular_capture_result, capture_slots);
				break;
			    }
			}
		    }
		    *matched_end = position;
		    return 1;
		}
		have_fallback = 1;
		fallback_end = position;
		continue;
	    }
	    if (position >= RSTRING_LEN(str)) continue;
	    int hit =
		state->op == ONIBI_RS_ANY &&
		((header->flags & ONIBI_RSEQ_HEADER_FLAG_MULTILINE) != 0 ||
		 (unsigned char)RSTRING_PTR(str)[position] != '\n');
	    if (state->op == ONIBI_RS_CHAR) {
		const OnibiLiteralDesc *literal =
		    &view->literals[state->payload];
		step_width = literal->data_length;
		hit = position + step_width <= RSTRING_LEN(str) &&
		      onibi_ascii_literal_equal(
			  (const unsigned char *)RSTRING_PTR(str) + position,
			  view->blob + literal->data_offset, step_width,
			  (literal->flags &
			   ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0);
	    }
	    else if (state->op == ONIBI_RS_CLASS) {
		const unsigned char *bitmap =
		    view->blob + view->classes[state->payload].data_offset;
		hit =
		    (bitmap[(unsigned char)RSTRING_PTR(str)[position] >> 3] &
		     (1U << ((unsigned char)RSTRING_PTR(str)[position] & 7))) !=
		    0;
	    }
	    if (!hit) continue;
	    uint32_t base = state->edge_base;
	    for (uint32_t e = 0; e < state->edge_count; e++) {
		const OnibiREdge *edge = &view->edges[base + e];
		if (edge->action_offset != 0) {
		    uint32_t ai =
			edge->action_offset / (uint32_t)sizeof(OnibiRAction) -
			1U;
		    if (ai >= header->action_count ||
			(view->actions[ai].op != ONIBI_RA_CAPTURE &&
			 view->actions[ai].op != ONIBI_RA_END))
			continue;
		}
		if (edge->destination == ONIBI_ACCEPT_STATE) {
		    /* Keep scanning this state's edges. A later continuation
		     * can still win at the next position. */
		    if (next_count == 0) {
			if (onibi_regular_capture_result && capture_slots != 0) {
			    memcpy(onibi_regular_capture_result,
				   current_caps + i * capture_slots,
				   capture_slots * sizeof(long));
			    if (edge->action_offset != 0)
				onibi_rseq_edge_actions_ok(view, edge, str,
							position + step_width,
							search_origin, NULL, 0,
							onibi_regular_capture_result,
							capture_slots);
			}
			*matched_end = position + step_width;
			return 1;
		    }
		    have_fallback = 1;
		    fallback_end = position + 1;
		    if (fallback_caps)
			memcpy(fallback_caps, current_caps + i * capture_slots,
			       capture_slots * sizeof(long));
		    if (fallback_caps && edge->action_offset != 0)
			onibi_rseq_edge_actions_ok(view, edge, str,
						    position + step_width,
						    search_origin, NULL, 0,
						    fallback_caps, capture_slots);
		    best_end = fallback_end;
		    continue;
		}
		if (edge->destination >= count) continue;
		uint32_t destination = edge->destination;
		if ((next_bits[destination >> 3] & (1U << (destination & 7))) ==
		    0) {
		    if (capture_slots != 0) {
			long *dst = next_caps + (size_t)next_count * capture_slots;
			memcpy(dst, current_caps + i * capture_slots,
			       capture_slots * sizeof(long));
			if (edge->action_offset != 0 &&
			    !onibi_rseq_edge_actions_ok(view, edge, str,
						    position + step_width,
						    search_origin, NULL, 0, dst,
						    capture_slots))
			    continue;
		    }
		    next_bits[destination >> 3] |=
			(unsigned char)(1U << (destination & 7));
		    next[next_count++] = destination;
		}
	    }
	}
	if (!next_count) {
	    if (have_fallback) {
		if (onibi_regular_capture_result && capture_slots != 0 &&
		    fallback_caps)
		    memcpy(onibi_regular_capture_result, fallback_caps,
			   capture_slots * sizeof(long));
		*matched_end = fallback_end;
		return 1;
	    }
	    if (best_end >= 0) {
		if (onibi_regular_capture_result && capture_slots != 0 &&
		    fallback_caps)
		    memcpy(onibi_regular_capture_result, fallback_caps,
			   capture_slots * sizeof(long));
		*matched_end = best_end;
		return 1;
	    }
	    return 0;
	}
	uint32_t *states_tmp = current;
	current = next;
	next = states_tmp;
	unsigned char *bits_tmp = current_bits;
	current_bits = next_bits;
	next_bits = bits_tmp;
	long *caps_tmp = current_caps;
	current_caps = next_caps;
	next_caps = caps_tmp;
	current_count = next_count;
	position += step_width;
    }
}

static OnibiExecStatus
onibi_exec_dynamic(OnibiExecCtx *ctx)
{
    onibi_diagnostics.dynamic++;
    int result = onibi_rseq_backtracking_match(
	ctx->rseq, ctx->view, ctx->subject, ctx->attempt_start,
	ctx->search_origin, &ctx->matched_end);
	if (result < 0) {
	    onibi_diagnostics.fallback++;
	    return ONIBI_EXEC_STATUS_FALLBACK;
	}
	return result > 0 ? ONIBI_EXEC_STATUS_MATCH : ONIBI_EXEC_STATUS_NO_MATCH;
}

static OnibiExecStatus
onibi_exec_tagged(OnibiExecCtx *ctx)
{
    onibi_diagnostics.tagged++;
    return onibi_exec_dynamic(ctx);
}

static OnibiExecStatus
onibi_execute(OnibiExecCtx *ctx)
{
    switch ((OnibiExecutionKind)ctx->program->exec_kind) {
    case ONIBI_EXEC_REGULAR: return onibi_exec_regular(ctx);
    case ONIBI_EXEC_TAGGED: return onibi_exec_tagged(ctx);
    case ONIBI_EXEC_DYNAMIC: return onibi_exec_dynamic(ctx);
    default: return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
    }
}
/* DYNAMIC interpreter and its isolated compatibility traversal. */
