static int onibi_gir_match_captures(VALUE graph, VALUE str, long start,
				    long search_origin, long *matched_end,
				    long *matched_start,
				    VALUE *matched_captures);
static int onibi_gir_match_captures_seed(VALUE graph, VALUE str, long start,
					 long search_origin,
					 VALUE initial_captures,
					 VALUE initial_tags, long *matched_end,
					 long *matched_start,
					 VALUE *matched_captures);
static int onibi_gir_match_captures_entry(
    VALUE states, VALUE outgoing, VALUE subprograms, VALUE str, long start,
    long search_origin, VALUE entry, VALUE entry_actions,
    VALUE initial_captures, VALUE initial_tags, int use_counters,
    uint32_t counter_count, long *matched_end, long *matched_start,
    VALUE *matched_captures);
static int
onibi_hash_copy_i(VALUE key, VALUE value, VALUE arg)
{
    rb_hash_aset(arg, key, value);
    return ST_CONTINUE;
}

static int
onibi_grapheme_extend(OnigCodePoint code)
{
    return (code >= 0x0300 && code <= 0x036f) ||
	   (code >= 0x1ab0 && code <= 0x1aff) ||
	   (code >= 0x1dc0 && code <= 0x1dff) ||
	   (code >= 0x20d0 && code <= 0x20ff) ||
	   (code >= 0xfe00 && code <= 0xfe0f) ||
	   (code >= 0x1f3fb && code <= 0x1f3ff) ||
	   (code >= 0x1f300 && code <= 0x1faff && code >= 0x1f7e0) ||
	   (code >= 0x0903 && code <= 0x093c) ||
	   (code >= 0x0a3e && code <= 0x0a42) ||
	   (code >= 0x0bbe && code <= 0x0bce) ||
	   (code >= 0x1d165 && code <= 0x1d169) ||
	   (code >= 0xe0020 && code <= 0xe007f);
}

static int
onibi_grapheme_ri(OnigCodePoint code)
{
    return code >= 0x1f1e6 && code <= 0x1f1ff;
}

static int
onibi_grapheme_hangul_l(OnigCodePoint code)
{
    return (code >= 0x1100 && code <= 0x115f) ||
	   (code >= 0xa960 && code <= 0xa97c);
}

static int
onibi_grapheme_hangul_v(OnigCodePoint code)
{
    return (code >= 0x1160 && code <= 0x11a7) ||
	   (code >= 0xd7b0 && code <= 0xd7c6);
}

static int
onibi_grapheme_hangul_t(OnigCodePoint code)
{
    return (code >= 0x11a8 && code <= 0x11ff) ||
	   (code >= 0xd7cb && code <= 0xd7fb);
}

static int
onibi_grapheme_prepend(OnigCodePoint code)
{
    return (code >= 0x0600 && code <= 0x0605) ||
	   (code >= 0x06dd && code <= 0x06dd) ||
	   (code >= 0x070f && code <= 0x070f) ||
	   (code >= 0x0890 && code <= 0x0891) ||
	   (code >= 0x0d4e && code <= 0x0d4e) ||
	   (code >= 0x110bd && code <= 0x110bd) ||
	   (code >= 0x111c2 && code <= 0x111c3) ||
	   (code >= 0x1193f && code <= 0x1193f) ||
	   (code >= 0x11941 && code <= 0x11941) ||
	   (code >= 0x11a3a && code <= 0x11a3a) ||
	   (code >= 0x11a84 && code <= 0x11a89) ||
	   (code >= 0x11d46 && code <= 0x11d46);
}

static long
onibi_grapheme_width(VALUE str, long pos)
{
    OnigCodePoint code;
    long width;
    if (!onibi_codepoint_at(str, pos, &code, &width)) return 0;
    long end = pos + width;
    if (code == '\r' && end < RSTRING_LEN(str) && RSTRING_PTR(str)[end] == '\n')
	return width + 1;
    if (onibi_grapheme_ri(code)) {
	OnigCodePoint next;
	long next_width;
	if (onibi_codepoint_at(str, end, &next, &next_width) &&
	    onibi_grapheme_ri(next))
	    end += next_width;
	return end - pos;
    }
    if (onibi_grapheme_hangul_l(code)) {
	OnigCodePoint next;
	long next_width;
	while (onibi_codepoint_at(str, end, &next, &next_width) &&
	       (onibi_grapheme_hangul_l(next) || onibi_grapheme_hangul_v(next)))
	    end += next_width;
	return end - pos;
    }
    if (onibi_grapheme_hangul_v(code)) {
	OnigCodePoint next;
	long next_width;
	while (onibi_codepoint_at(str, end, &next, &next_width) &&
	       (onibi_grapheme_hangul_v(next) || onibi_grapheme_hangul_t(next)))
	    end += next_width;
	return end - pos;
    }
    int join = onibi_grapheme_prepend(code);
    for (;;) {
	OnigCodePoint next;
	long next_width;
	if (!onibi_codepoint_at(str, end, &next, &next_width)) break;
	if (onibi_grapheme_extend(next)) {
	    end += next_width;
	    continue;
	}
	if (next == 0x200d) {
	    join = 1;
	    end += next_width;
	    continue;
	}
	if (join) {
	    join = 0;
	    end += next_width;
	    continue;
	}
	break;
    }
    return end - pos;
}

static int
onibi_vm_walk(VALUE states, VALUE outgoing, VALUE str, long state_id, long pos,
	      long search_origin, VALUE visited, unsigned char *visited_bits,
	      size_t visited_span, long *initial_counters,
	      uint32_t counter_count, int use_counters, long *matched_end)
{
    typedef struct {
	long state_id, pos, next_edge;
	long *counters;
    } OnibiWalkFrame;
    /* Counter-bearing repeat paths can visit one state at many counter values.
     * Reserve a bounded workspace independent of graph state count. */
    long capacity = RARRAY_LEN(states) * 64 + 64;
    if (capacity > 65536) capacity = 65536;
    OnibiWalkFrame *stack = ALLOCA_N(OnibiWalkFrame, capacity);
    long *counter_pool =
	use_counters ? ALLOCA_N(long, (size_t)capacity *counter_count) : NULL;
    long depth = 0;
    if (use_counters && initial_counters)
	memcpy(counter_pool, initial_counters, sizeof(long) * counter_count);
    else if (use_counters)
	memset(counter_pool, 0, sizeof(long) * counter_count);
    stack[depth++] =
	(OnibiWalkFrame){state_id, pos, 0, use_counters ? counter_pool : NULL};
    while (depth > 0) {
	rb_thread_check_ints();
	onibi_check_deadline();
	OnibiWalkFrame *frame = &stack[depth - 1];
	if (frame->next_edge == 0) {
	    if (!use_counters && visited_bits && frame->state_id >= 0 &&
		frame->pos >= 0 &&
		(size_t)frame->state_id < (size_t)RARRAY_LEN(states) &&
		(size_t)frame->pos < visited_span) {
		size_t mark =
		    (size_t)frame->state_id * visited_span + (size_t)frame->pos;
		if (visited_bits[mark]) {
		    depth--;
		    continue;
		}
		visited_bits[mark] = 1;
	    }
	    else {
		VALUE key = rb_ary_new_from_args(
		    3, LONG2NUM(frame->state_id), LONG2NUM(frame->pos),
		    rb_str_new((const char *)frame->counters,
			       (long)(sizeof(long) * counter_count)));
		if (RTEST(rb_hash_aref(visited, key))) {
		    depth--;
		    continue;
		}
		rb_hash_aset(visited, key, Qtrue);
	    }
	    VALUE state = rb_ary_entry(states, frame->state_id);
	    unsigned int op =
		NUM2UINT(onibi_hash_value_id(state, id_key_opcode));
	    if (op == 0) {
		*matched_end = frame->pos;
		return 1;
	    }
	    if (op == ONIBI_RS_GRAPHEME) {
		long consumed = onibi_grapheme_width(str, frame->pos);
		if (consumed <= 0) {
		    depth--;
		    continue;
		}
		frame->pos += consumed;
	    }
	    else if (op == ONIBI_RS_ATOMIC || op == ONIBI_RS_ABSENT) {
		depth--;
		continue;
	    }
	    else if (op == ONIBI_RS_CHAR || op == ONIBI_RS_CLASS ||
		     op == ONIBI_RS_ANY) {
		if (frame->pos >= RSTRING_LEN(str)) {
		    depth--;
		    continue;
		}
		unsigned char byte =
		    (unsigned char)RSTRING_PTR(str)[frame->pos];
		VALUE payload = onibi_hash_value_id(state, id_key_payload);
		long consumed = 1;
		int hit =
		    op == ONIBI_RS_ANY
			? (byte != '\n' || RTEST(onibi_hash_value_id(
					       payload, id_key_multiline)))
			: (op == ONIBI_RS_CHAR
			       ? (RTEST(onibi_hash_value_id(payload,
							    id_key_ignorecase))
				      ? tolower(byte) ==
					    tolower(NUM2INT(onibi_hash_value_id(
						payload, id_key_byte)))
				      : byte == NUM2INT(onibi_hash_value_id(
						    payload, id_key_byte)))
			       : onibi_vm_class_match(payload, str, frame->pos,
						      byte, &consumed));
		if (!hit) {
		    depth--;
		    continue;
		}
		frame->pos += consumed;
	    }
	}
	VALUE state_edges = rb_ary_entry(outgoing, frame->state_id);
	if (frame->next_edge >= RARRAY_LEN(state_edges)) {
	    depth--;
	    continue;
	}
	if (depth >= capacity) onibi_vm_stack_overflow();
	VALUE edge = rb_ary_entry(state_edges, frame->next_edge++);
	VALUE edge_actions = onibi_hash_value_id(edge, id_key_actions);
	long *next_counters = frame->counters;
	if (use_counters) {
	    next_counters = counter_pool + (size_t)depth * counter_count;
	    memcpy(next_counters, frame->counters,
		   sizeof(long) * counter_count);
	    OnibiCounterState counter_state = {next_counters, counter_count};
	    if (!onibi_vm_counter_actions_ok(edge_actions, &counter_state))
		continue;
	    onibi_vm_apply_counter_actions_c(edge_actions, &counter_state);
	}
	if (!onibi_vm_actions_ok(edge_actions, str, frame->pos,
				 RSTRING_LEN(str), search_origin, Qnil, NULL,
				 Qnil))
	    continue;
	stack[depth++] =
	    (OnibiWalkFrame){NUM2LONG(onibi_hash_value_id(edge, id_key_to)),
			     frame->pos, 0, next_counters};
    }
    return 0;
}

static int
onibi_gir_match(VALUE graph, VALUE str, long start, long search_origin,
		long *matched_end)
{
    VALUE states = onibi_hash_value_id(graph, id_key_states);
    VALUE outgoing = onibi_hash_value_id(graph, id_key_outgoing);
    VALUE starts = onibi_hash_value_id(graph, id_key_start_edges);
    VALUE visited = Qnil;
    unsigned char *visited_bits = NULL;
    size_t visited_span = (size_t)RSTRING_LEN(str) + 1U;
    size_t visited_size = 0;
    if (visited_span != 0 &&
	(size_t)RARRAY_LEN(states) <= SIZE_MAX / visited_span)
	visited_size = (size_t)RARRAY_LEN(states) * visited_span;
    int visited_bits_owned = 0;
    if (visited_size != 0 && visited_size <= (size_t)64 << 20) {
	if (visited_size <= (size_t)1 << 20)
	    visited_bits = ALLOCA_N(unsigned char, visited_size);
	else {
	    visited_bits = ALLOC_N(unsigned char, visited_size);
	    visited_bits_owned = 1;
	}
	memset(visited_bits, 0, visited_size);
    }
    VALUE counter_count = onibi_hash_value_id(graph, id_key_counter_count);
    int use_counters = !NIL_P(counter_count) && NUM2UINT(counter_count) != 0;
    if (use_counters || visited_bits == NULL) visited = rb_hash_new();
    uint32_t counter_slots = use_counters ? NUM2UINT(counter_count) : 0;
    for (long i = 0; i < RARRAY_LEN(starts); i++) {
	VALUE edge = rb_ary_entry(starts, i);
	VALUE edge_actions = onibi_hash_value_id(edge, id_key_actions);
	long *branch_counters =
	    use_counters ? ALLOCA_N(long, counter_slots) : NULL;
	if (use_counters) {
	    memset(branch_counters, 0, sizeof(long) * counter_slots);
	    OnibiCounterState counter_state = {branch_counters, counter_slots};
	    if (!onibi_vm_counter_actions_ok(edge_actions, &counter_state))
		continue;
	    onibi_vm_apply_counter_actions_c(edge_actions, &counter_state);
	}
	if (!onibi_vm_actions_ok(edge_actions, str, start, RSTRING_LEN(str),
				 search_origin, Qnil, NULL, Qnil))
	    continue;
	if (onibi_vm_walk(states, outgoing, str,
			  NUM2LONG(onibi_hash_value_id(edge, id_key_to)), start,
			  search_origin, visited, visited_bits, visited_span,
			  branch_counters, counter_slots, use_counters,
			  matched_end)) {
	    if (visited_bits_owned) xfree(visited_bits);
	    return 1;
	}
    }
    if (visited_bits_owned) xfree(visited_bits);
    return 0;
}

static VALUE
onibi_capture_copy(VALUE captures)
{
    VALUE copy = rb_hash_dup(captures);
    return copy;
}

static VALUE
onibi_materialize_tags(VALUE tags, VALUE fallback)
{
    if (NIL_P(tags)) return fallback;
    VALUE captures = rb_hash_new();
    VALUE cursor = tags;
    while (!NIL_P(cursor)) {
	VALUE slot = rb_ary_entry(cursor, 1);
	if (SYMBOL_P(slot) && SYM2ID(slot) == id_recursive_marker) {
	    cursor = rb_ary_entry(cursor, 0);
	    continue;
	}
	if (NIL_P(rb_hash_aref(captures, slot)))
	    rb_hash_aset(captures, slot, rb_ary_entry(cursor, 2));
	cursor = rb_ary_entry(cursor, 0);
    }
    return captures;
}

static int
onibi_has_capture_action(VALUE actions)
{
    for (long i = 0; i < RARRAY_LEN(actions); i++) {
	OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(
	    onibi_hash_value_id(rb_ary_entry(actions, i), id_key_action_code));
	if (code == ONIBI_GA_CAPTURE_OPEN || code == ONIBI_GA_CAPTURE_CLOSE)
	    return 1;
    }
    return 0;
}

/* Capture output uses an append-only event chain.  Each branch shares the
   parent chain and allocates only the events that it adds. */
static VALUE
onibi_apply_capture_actions(VALUE actions, long pos, VALUE captures, VALUE tags,
			    long *reported_start)
{
    for (long i = 0; i < RARRAY_LEN(actions); i++) {
	VALUE action = rb_ary_entry(actions, i);
	OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(
	    onibi_hash_value_id(action, id_key_action_code));
	if (code == ONIBI_GA_MATCH_RESET) {
	    *reported_start = pos;
	    continue;
	}
	if (code != ONIBI_GA_CAPTURE_OPEN && code != ONIBI_GA_CAPTURE_CLOSE)
	    continue;
	VALUE slot = onibi_hash_value_id(action, id_key_slot);
	if (code == ONIBI_GA_CAPTURE_CLOSE &&
	    RTEST(onibi_hash_value_id(action, id_key_preserve_if_set)) &&
	    RTEST(onibi_hash_value_id(captures, id_recursive_marker)))
	    continue;
	rb_hash_aset(captures, slot, LONG2NUM(pos));
	VALUE event = rb_ary_new_from_args(3, tags, slot, LONG2NUM(pos));
	rb_obj_freeze(event);
	tags = event;
    }
    return tags;
}

static int
onibi_vm_walk_captures(VALUE states, VALUE outgoing, VALUE subprograms,
		       VALUE str, long state_id, long pos, long search_origin,
		       VALUE visited, VALUE captures, long *initial_counters,
		       uint32_t counter_count, VALUE tags, long reported_start,
		       int use_counters, long *matched_end, long *matched_start,
		       VALUE *matched_captures)
{
    typedef struct {
	long state_id, pos, next_edge, reported_start;
	VALUE captures, tags;
	long *counters;
	VALUE called_captures;
	long call_end, call_parent;
	int entered, waiting_call, call_status, call_kind;
    } OnibiCaptureFrame;
    long capacity = RARRAY_LEN(states) * 64 + 64;
    if (capacity > 65536) capacity = 65536;
    OnibiCaptureFrame *stack = ALLOCA_N(OnibiCaptureFrame, capacity);
    long *counter_pool = use_counters && counter_count > 0
			     ? ALLOCA_N(long, (size_t)capacity *counter_count)
			     : NULL;
    long depth = 0;
    long *root_counters = counter_pool;
    if (root_counters) {
	if (initial_counters)
	    memcpy(root_counters, initial_counters,
		   sizeof(long) * counter_count);
	else
	    memset(root_counters, 0, sizeof(long) * counter_count);
    }
    stack[depth++] = (OnibiCaptureFrame){state_id,
					 pos,
					 0,
					 reported_start,
					 captures,
					 tags,
					 root_counters,
					 Qnil,
					 0,
					 -1,
					 0,
					 0,
					 0,
					 0};
    while (depth > 0) {
	rb_thread_check_ints();
	onibi_check_deadline();
	OnibiCaptureFrame *frame = &stack[depth - 1];
	/* Pop a traversal frame and, when it is a subprogram root, its explicit
	 * call frame as well. */
#define ONIBI_CAPTURE_POP_FRAME()                                              \
    do {                                                                       \
	long parent_frame = frame->call_parent;                                \
	depth--;                                                               \
	if (parent_frame >= 0 && depth == parent_frame + 1) {                  \
	    onibi_call_frame_pop();                                            \
	    /* A failed call is an ordered-edge failure.  Atomic failure fails \
	     * its state; absence failure succeeds its zero-width state. */    \
	    stack[parent_frame].call_status =                                  \
		stack[parent_frame].call_kind == 2 ? -1 : 0;                   \
	    stack[parent_frame].waiting_call =                                 \
		stack[parent_frame].call_kind == 2 ? 1 : 0;                    \
	}                                                                      \
    } while (0)
	if (frame->waiting_call) {
	    if (frame->call_status < 0) {
		ONIBI_CAPTURE_POP_FRAME();
		continue;
	    }
	    if (frame->call_status > 0) {
		if (RB_TYPE_P(frame->called_captures, T_HASH)) {
		    frame->captures = rb_hash_dup(frame->captures);
		    rb_hash_foreach(frame->called_captures, onibi_hash_copy_i,
				    frame->captures);
		    rb_hash_aset(frame->captures, ID2SYM(id_recursive_marker),
				 Qtrue);
		    frame->tags = Qnil;
		}
		frame->pos = frame->call_end;
		frame->waiting_call = 0;
		frame->call_status = 0;
	    }
	}
	if (!frame->entered) {
	    frame->entered = 1;
	    VALUE counter_key =
		frame->counters
		    ? rb_str_new((const char *)frame->counters,
				 (long)(sizeof(long) * counter_count))
		    : Qnil;
	    VALUE key = rb_ary_new_from_args(
		6, LONG2NUM(frame->state_id), LONG2NUM(frame->pos),
		frame->captures, counter_key, frame->tags,
		LONG2NUM(frame->reported_start));
	    if (RTEST(rb_hash_aref(visited, key))) {
		ONIBI_CAPTURE_POP_FRAME();
		continue;
	    }
	    rb_hash_aset(visited, key, Qtrue);
	    VALUE state = rb_ary_entry(states, frame->state_id);
	    unsigned int op =
		NUM2UINT(onibi_hash_value_id(state, id_key_opcode));
	    if (op == 0) {
		if (frame->call_parent >= 0) {
		    VALUE result =
			onibi_materialize_tags(frame->tags, frame->captures);
		    long parent = frame->call_parent;
		    while (depth > parent + 1)
			depth--;
		    stack[parent].called_captures = result;
		    stack[parent].call_end = frame->pos;
		    stack[parent].call_status =
			stack[parent].call_kind == 3 ? -1 : 1;
		    stack[parent].waiting_call = 1;
		    onibi_call_frame_pop();
		    continue;
		}
		*matched_end = frame->pos;
		*matched_start = frame->reported_start;
		*matched_captures =
		    onibi_materialize_tags(frame->tags, frame->captures);
		return 1;
	    }
	    if (op == ONIBI_RS_GRAPHEME) {
		long consumed = onibi_grapheme_width(str, frame->pos);
		if (consumed <= 0) {
		    ONIBI_CAPTURE_POP_FRAME();
		    continue;
		}
		frame->pos += consumed;
	    }
	    if (op == ONIBI_RS_CALL) {
		VALUE payload = onibi_hash_value_id(state, id_key_payload);
		long subprogram_id =
		    NUM2LONG(onibi_hash_value_id(payload, id_key_subprogram));
		if (subprogram_id < 0 ||
		    subprogram_id >= RARRAY_LEN(subprograms)) {
		    ONIBI_CAPTURE_POP_FRAME();
		    continue;
		}
		VALUE descriptor = rb_ary_entry(subprograms, subprogram_id);
		VALUE entry = onibi_hash_value_id(descriptor, id_key_entry);
		if (NIL_P(entry)) {
		    ONIBI_CAPTURE_POP_FRAME();
		    continue;
		}
		OnibiCallFrame *call_frame =
		    onibi_call_frame_push((OnibiSubprogramId)subprogram_id);
		call_frame->continuation = (OnibiStateId)frame->state_id;
		frame->waiting_call = 1;
		frame->call_status = 0;
		frame->call_parent = -1;
		VALUE entry_actions =
		    onibi_hash_value_id(descriptor, id_key_entry_actions);
		if (depth >= capacity) onibi_vm_stack_overflow();
		long *call_counters =
		    use_counters && counter_count > 0
			? counter_pool + (size_t)depth * counter_count
			: NULL;
		if (call_counters)
		    memset(call_counters, 0, sizeof(long) * counter_count);
		OnibiCounterState call_counter_state = {call_counters,
							counter_count};
		VALUE call_captures = RB_TYPE_P(frame->captures, T_HASH)
					  ? rb_hash_dup(frame->captures)
					  : rb_hash_new();
		VALUE call_tags = frame->tags;
		long call_reported_start = frame->reported_start;
		VALUE actions = RB_TYPE_P(entry_actions, T_ARRAY)
				    ? entry_actions
				    : onibi_empty_actions;
		if (!onibi_vm_actions_ok(actions, str, frame->pos,
					 RSTRING_LEN(str), search_origin, Qnil,
					 &call_counter_state, call_captures)) {
		    onibi_call_frame_pop();
		    ONIBI_CAPTURE_POP_FRAME();
		    continue;
		}
		if (use_counters)
		    onibi_vm_apply_counter_actions_c(actions,
						     &call_counter_state);
		call_tags = onibi_apply_capture_actions(
		    actions, frame->pos, call_captures, call_tags,
		    &call_reported_start);
		long call_parent = depth - 1;
		stack[depth++] = (OnibiCaptureFrame){NUM2LONG(entry),
						     frame->pos,
						     0,
						     call_reported_start,
						     call_captures,
						     call_tags,
						     call_counters,
						     Qnil,
						     0,
						     call_parent,
						     0,
						     0,
						     0};
		continue;
	    }
	    else if (op == ONIBI_RS_ATOMIC || op == ONIBI_RS_ABSENT) {
		VALUE payload = onibi_hash_value_id(state, id_key_payload);
		long subprogram_id =
		    NUM2LONG(onibi_hash_value_id(payload, id_key_subprogram));
		if (subprogram_id < 0 ||
		    subprogram_id >= RARRAY_LEN(subprograms)) {
		    if (op == ONIBI_RS_ABSENT) continue;
		    ONIBI_CAPTURE_POP_FRAME();
		    continue;
		}
		VALUE descriptor = rb_ary_entry(subprograms, subprogram_id);
		VALUE entry = onibi_hash_value_id(descriptor, id_key_entry);
		if (NIL_P(entry)) {
		    if (op == ONIBI_RS_ABSENT) continue;
		    ONIBI_CAPTURE_POP_FRAME();
		    continue;
		}
		OnibiCallFrame *call_frame =
		    onibi_call_frame_push((OnibiSubprogramId)subprogram_id);
		call_frame->continuation = (OnibiStateId)frame->state_id;
		frame->waiting_call = 1;
		frame->call_status = 0;
		frame->call_kind = op == ONIBI_RS_ABSENT ? 3 : 2;
		VALUE entry_actions =
		    onibi_hash_value_id(descriptor, id_key_entry_actions);
		if (depth >= capacity) onibi_vm_stack_overflow();
		long *call_counters =
		    use_counters && counter_count > 0
			? counter_pool + (size_t)depth * counter_count
			: NULL;
		if (call_counters)
		    memset(call_counters, 0, sizeof(long) * counter_count);
		OnibiCounterState call_counter_state = {call_counters,
							counter_count};
		VALUE call_captures = RB_TYPE_P(frame->captures, T_HASH)
					  ? rb_hash_dup(frame->captures)
					  : rb_hash_new();
		VALUE call_tags = frame->tags;
		long call_reported_start = frame->reported_start;
		VALUE actions = RB_TYPE_P(entry_actions, T_ARRAY)
				    ? entry_actions
				    : onibi_empty_actions;
		if (!onibi_vm_actions_ok(actions, str, frame->pos,
					 RSTRING_LEN(str), search_origin, Qnil,
					 &call_counter_state, call_captures)) {
		    onibi_call_frame_pop();
		    if (op == ONIBI_RS_ABSENT) {
			frame->waiting_call = 0;
			continue;
		    }
		    ONIBI_CAPTURE_POP_FRAME();
		    continue;
		}
		if (use_counters)
		    onibi_vm_apply_counter_actions_c(actions,
						     &call_counter_state);
		call_tags = onibi_apply_capture_actions(
		    actions, frame->pos, call_captures, call_tags,
		    &call_reported_start);
		long call_parent = depth - 1;
		stack[depth++] = (OnibiCaptureFrame){NUM2LONG(entry),
						     frame->pos,
						     0,
						     call_reported_start,
						     call_captures,
						     call_tags,
						     call_counters,
						     Qnil,
						     0,
						     call_parent,
						     0,
						     0,
						     0,
						     0};
		continue;
	    }
	    else if (op == ONIBI_RS_CHAR || op == ONIBI_RS_CLASS ||
		     op == ONIBI_RS_ANY || op == ONIBI_RS_BACKREF) {
		if (frame->pos >= RSTRING_LEN(str)) {
		    ONIBI_CAPTURE_POP_FRAME();
		    continue;
		}
		if (op == ONIBI_RS_BACKREF) {
		    VALUE payload = onibi_hash_value_id(state, id_key_payload);
		    long capture =
			NUM2LONG(onibi_hash_value_id(payload, id_key_capture));
		    VALUE begin = rb_hash_aref(frame->captures,
					       LONG2NUM(2 * (capture - 1)));
		    VALUE finish = rb_hash_aref(
			frame->captures, LONG2NUM(2 * (capture - 1) + 1));
		    if (NIL_P(begin) || NIL_P(finish)) {
			ONIBI_CAPTURE_POP_FRAME();
			continue;
		    }
		    long length = NUM2LONG(finish) - NUM2LONG(begin);
		    if (frame->pos + length > RSTRING_LEN(str)) {
			ONIBI_CAPTURE_POP_FRAME();
			continue;
		    }
		    int fold =
			RTEST(onibi_hash_value_id(payload, id_key_ignorecase));
		    if (!fold) {
			if (memcmp(RSTRING_PTR(str) + frame->pos,
				   RSTRING_PTR(str) + NUM2LONG(begin),
				   (size_t)length) != 0) {
			    ONIBI_CAPTURE_POP_FRAME();
			    continue;
			}
		    }
		    else {
			int equal = 1;
			for (long i = 0; i < length; i++) {
			    if (tolower((unsigned char)RSTRING_PTR(
				    str)[frame->pos + i]) !=
				tolower((unsigned char)RSTRING_PTR(
				    str)[NUM2LONG(begin) + i])) {
				equal = 0;
				break;
			    }
			}
			if (!equal) {
			    ONIBI_CAPTURE_POP_FRAME();
			    continue;
			}
		    }
		    frame->pos += length;
		}
		else {
		    unsigned char byte =
			(unsigned char)RSTRING_PTR(str)[frame->pos];
		    VALUE payload = onibi_hash_value_id(state, id_key_payload);
		    long consumed = 1;
		    int hit =
			op == ONIBI_RS_ANY
			    ? (byte != '\n' || RTEST(onibi_hash_value_id(
						   payload, id_key_multiline)))
			    : (op == ONIBI_RS_CHAR
				   ? (RTEST(onibi_hash_value_id(
					  payload, id_key_ignorecase))
					  ? tolower(byte) ==
						tolower(
						    NUM2INT(onibi_hash_value_id(
							payload, id_key_byte)))
					  : byte == NUM2INT(onibi_hash_value_id(
							payload, id_key_byte)))
				   : onibi_vm_class_match(payload, str,
							  frame->pos, byte,
							  &consumed));
		    if (!hit) {
			ONIBI_CAPTURE_POP_FRAME();
			continue;
		    }
		    frame->pos += consumed;
		}
	    }
	}
	VALUE state_edges = rb_ary_entry(outgoing, frame->state_id);
	if (frame->next_edge >= RARRAY_LEN(state_edges)) {
	    ONIBI_CAPTURE_POP_FRAME();
	    continue;
	}
	VALUE edge = rb_ary_entry(state_edges, frame->next_edge++);
	VALUE edge_actions = onibi_hash_value_id(edge, id_key_actions);
	if (depth >= capacity) onibi_vm_stack_overflow();
	long *next_counters = frame->counters;
	if (use_counters && counter_count > 0) {
	    next_counters = counter_pool + (size_t)depth * counter_count;
	    memcpy(next_counters, frame->counters,
		   sizeof(long) * counter_count);
	}
	OnibiCounterState next_counter_state = {next_counters, counter_count};
	if (!onibi_vm_actions_ok(edge_actions, str, frame->pos,
				 RSTRING_LEN(str), search_origin, Qnil,
				 &next_counter_state, frame->captures))
	    continue;
	VALUE next_captures = onibi_has_capture_action(edge_actions)
				  ? onibi_capture_copy(frame->captures)
				  : frame->captures;
	long next_reported_start = frame->reported_start;
	if (use_counters)
	    onibi_vm_apply_counter_actions_c(edge_actions, &next_counter_state);
	VALUE next_tags =
	    onibi_apply_capture_actions(edge_actions, frame->pos, next_captures,
					frame->tags, &next_reported_start);
	stack[depth++] =
	    (OnibiCaptureFrame){NUM2LONG(onibi_hash_value_id(edge, id_key_to)),
				frame->pos,
				0,
				next_reported_start,
				next_captures,
				next_tags,
				next_counters,
				Qnil,
				0,
				frame->call_parent,
				0,
				0,
				0,
				0};
    }
#undef ONIBI_CAPTURE_POP_FRAME
    return 0;
}

static int
onibi_gir_match_captures_entry(VALUE states, VALUE outgoing, VALUE subprograms,
			       VALUE str, long start, long search_origin,
			       VALUE entry, VALUE entry_actions,
			       VALUE initial_captures, VALUE initial_tags,
			       int use_counters, uint32_t counter_count,
			       long *matched_end, long *matched_start,
			       VALUE *matched_captures)
{
    VALUE visited = rb_hash_new();
    VALUE captures = RB_TYPE_P(initial_captures, T_HASH)
			 ? rb_hash_dup(initial_captures)
			 : rb_hash_new();
    rb_hash_delete(captures, ID2SYM(id_recursive_marker));
    VALUE tags = initial_tags;
    VALUE actions =
	RB_TYPE_P(entry_actions, T_ARRAY) ? entry_actions : onibi_empty_actions;
    long *branch_counters = use_counters && counter_count > 0
				? ALLOCA_N(long, counter_count)
				: NULL;
    if (branch_counters)
	memset(branch_counters, 0, sizeof(long) * counter_count);
    OnibiCounterState branch_counter_state = {branch_counters, counter_count};
    if (!onibi_vm_actions_ok(actions, str, start, RSTRING_LEN(str),
			     search_origin, Qnil, &branch_counter_state,
			     captures))
	return 0;
    VALUE branch_captures = onibi_has_capture_action(actions)
				? onibi_capture_copy(captures)
				: captures;
    long reported_start = start;
    if (use_counters)
	onibi_vm_apply_counter_actions_c(actions, &branch_counter_state);
    VALUE branch_tags = onibi_apply_capture_actions(
	actions, start, branch_captures, tags, &reported_start);
    return onibi_vm_walk_captures(
	states, outgoing, subprograms, str, NUM2LONG(entry), start,
	search_origin, visited, branch_captures, branch_counters, counter_count,
	branch_tags, reported_start, use_counters, matched_end, matched_start,
	matched_captures);
}

static int
onibi_gir_match_captures_seed(VALUE graph, VALUE str, long start,
			      long search_origin, VALUE initial_captures,
			      VALUE initial_tags, long *matched_end,
			      long *matched_start, VALUE *matched_captures)
{
    VALUE states = onibi_hash_value_id(graph, id_key_states);
    VALUE outgoing = onibi_hash_value_id(graph, id_key_outgoing);
    VALUE starts = onibi_hash_value_id(graph, id_key_start_edges);
    VALUE subprograms = onibi_hash_value_id(graph, id_key_subprograms);
    VALUE counter_count = onibi_hash_value_id(graph, id_key_counter_count);
    int use_counters = !NIL_P(counter_count) && NUM2UINT(counter_count) != 0;
    for (long i = 0; i < RARRAY_LEN(starts); i++) {
	VALUE edge = rb_ary_entry(starts, i);
	if (onibi_gir_match_captures_entry(
		states, outgoing, subprograms, str, start, search_origin,
		onibi_hash_value_id(edge, id_key_to),
		onibi_hash_value_id(edge, id_key_actions), initial_captures,
		initial_tags, use_counters, NUM2UINT(counter_count),
		matched_end, matched_start, matched_captures))
	    return 1;
    }
    return 0;
}

static int
onibi_gir_match_captures(VALUE graph, VALUE str, long start, long search_origin,
			 long *matched_end, long *matched_start,
			 VALUE *matched_captures)
{
    return onibi_gir_match_captures_seed(graph, str, start, search_origin, Qnil,
					 Qnil, matched_end, matched_start,
					 matched_captures);
}

static void
onibi_rseq_validate(VALUE rseq)
{
    VALUE blob = onibi_hash_value_id(rseq, id_key_blob);
    VALUE physical_graph = onibi_hash_value_id(rseq, id_key_physical_graph);
    VALUE semantic = onibi_hash_value_id(rseq, id_key_header);
    VALUE semantic_states = onibi_hash_value_id(rseq, id_key_states);
    VALUE semantic_edges = onibi_hash_value_id(rseq, id_key_edges);
    VALUE semantic_start_edges = onibi_hash_value_id(rseq, id_key_start_edges);
    VALUE semantic_actions = onibi_hash_value_id(rseq, id_key_actions);
    VALUE semantic_subprograms = onibi_hash_value_id(rseq, id_key_subprograms);
    if (NIL_P(blob) || RSTRING_LEN(blob) < (long)sizeof(OnibiRSeqHeader) ||
	!RTEST(rb_obj_frozen_p(rseq)) || !RTEST(rb_obj_frozen_p(blob)) ||
	!RTEST(rb_obj_frozen_p(semantic)) ||
	!RTEST(rb_obj_frozen_p(semantic_states)) ||
	!RTEST(rb_obj_frozen_p(semantic_edges)) ||
	!RTEST(rb_obj_frozen_p(semantic_actions)) ||
	!RB_TYPE_P(semantic_subprograms, T_ARRAY) ||
	!RTEST(rb_obj_frozen_p(semantic_subprograms)) ||
	!RTEST(rb_obj_frozen_p(semantic_start_edges)) ||
	(!NIL_P(physical_graph) && !RTEST(rb_obj_frozen_p(physical_graph))))
	rb_raise(rb_eArgError, "invalid Onibi RSeq blob");
    if (!NIL_P(physical_graph)) {
	VALUE cached_states =
	    RB_TYPE_P(physical_graph, T_HASH)
		? onibi_hash_value_id(physical_graph, id_key_states)
		: Qnil;
	VALUE cached_edges =
	    RB_TYPE_P(physical_graph, T_HASH)
		? onibi_hash_value_id(physical_graph, id_key_edges)
		: Qnil;
	VALUE cached_starts =
	    RB_TYPE_P(physical_graph, T_HASH)
		? onibi_hash_value_id(physical_graph, id_key_start_edges)
		: Qnil;
	VALUE cached_outgoing =
	    RB_TYPE_P(physical_graph, T_HASH)
		? onibi_hash_value_id(physical_graph, id_key_outgoing)
		: Qnil;
	if (!RB_TYPE_P(physical_graph, T_HASH) ||
	    !RB_TYPE_P(cached_states, T_ARRAY) ||
	    !RB_TYPE_P(cached_edges, T_ARRAY) ||
	    !RB_TYPE_P(cached_starts, T_ARRAY) ||
	    !RB_TYPE_P(cached_outgoing, T_ARRAY) ||
	    !RTEST(rb_obj_frozen_p(cached_states)) ||
	    !RTEST(rb_obj_frozen_p(cached_edges)) ||
	    !RTEST(rb_obj_frozen_p(cached_starts)) ||
	    !RTEST(rb_obj_frozen_p(cached_outgoing)) ||
	    RARRAY_LEN(cached_states) != RARRAY_LEN(semantic_states) ||
	    RARRAY_LEN(cached_outgoing) != RARRAY_LEN(cached_states) ||
	    RARRAY_LEN(cached_edges) != RARRAY_LEN(semantic_edges) ||
	    RARRAY_LEN(cached_starts) != RARRAY_LEN(semantic_start_edges))
	    rb_raise(rb_eArgError, "invalid cached RSeq execution view");
	for (long state_id = 0; state_id < RARRAY_LEN(cached_outgoing);
	     state_id++) {
	    VALUE state_edges = rb_ary_entry(cached_outgoing, state_id);
	    if (!RB_TYPE_P(state_edges, T_ARRAY) ||
		!RTEST(rb_obj_frozen_p(state_edges)))
		rb_raise(rb_eArgError,
			 "invalid cached RSeq outgoing edge index");
	    for (long edge_id = 0; edge_id < RARRAY_LEN(state_edges);
		 edge_id++) {
		VALUE edge = rb_ary_entry(state_edges, edge_id);
		if (!RB_TYPE_P(edge, T_HASH) ||
		    NUM2LONG(onibi_hash_value_id(edge, id_key_from)) !=
			state_id ||
		    !RB_TYPE_P(onibi_hash_value_id(edge, id_key_actions),
			       T_ARRAY))
		    rb_raise(rb_eArgError, "invalid cached RSeq outgoing edge");
	    }
	}
    }
    OnibiRSeqHeader header;
    memcpy(&header, RSTRING_PTR(blob), sizeof(header));
    if (NIL_P(semantic) || NIL_P(semantic_states) ||
	!RB_TYPE_P(semantic_states, T_ARRAY) || NIL_P(semantic_edges) ||
	!RB_TYPE_P(semantic_edges, T_ARRAY) || NIL_P(semantic_actions) ||
	!RB_TYPE_P(semantic_actions, T_ARRAY) ||
	RARRAY_LEN(semantic_states) != header.state_count ||
	RARRAY_LEN(semantic_edges) !=
	    header.edge_count - header.start_edge_count ||
	RARRAY_LEN(semantic_actions) != header.action_count ||
	header.start_edge_count > header.edge_count ||
	NUM2UINT(onibi_hash_value_id(semantic, id_key_state_count)) !=
	    header.state_count ||
	NUM2UINT(onibi_hash_value_id(semantic, id_key_features)) !=
	    header.features ||
	NUM2UINT(onibi_hash_value_id(semantic, id_key_edge_count)) !=
	    header.edge_count - header.start_edge_count ||
	NUM2UINT(onibi_hash_value_id(semantic, id_key_action_count)) !=
	    header.action_count ||
	NUM2UINT(onibi_hash_value_id(semantic, id_key_class_count)) !=
	    header.class_count ||
	NUM2UINT(onibi_hash_value_id(semantic, id_key_capture_count)) !=
	    header.capture_count ||
	NUM2UINT(onibi_hash_value_id(semantic, id_key_counter_count)) !=
	    header.counter_count ||
	RARRAY_LEN(semantic_subprograms) != header.subprogram_count ||
	NUM2UINT(onibi_hash_value_id(semantic, id_key_subprogram_count)) !=
	    header.subprogram_count ||
	NUM2UINT(onibi_hash_value_id(semantic, id_key_start_edge_base)) !=
	    header.start_edge_base ||
	NUM2UINT(onibi_hash_value_id(semantic, id_key_start_edge_count)) !=
	    header.start_edge_count ||
	NUM2UINT(onibi_hash_value_id(semantic, id_key_blob_size)) !=
	    header.blob_size)
	rb_raise(rb_eArgError, "RSeq semantic and physical headers disagree");
    if (header.magic != ONIBI_RSEQ_MAGIC ||
	header.version != ONIBI_RSEQ_VERSION || header.exec_kind > 2 ||
	((header.flags & 1U) !=
	 (RTEST(onibi_hash_value_id(semantic, id_key_ignorecase)) ? 1U : 0U)) ||
	((header.flags & 2U) !=
	 (RTEST(onibi_hash_value_id(semantic, id_key_multiline)) ? 2U : 0U)) ||
	header.blob_size != (uint32_t)RSTRING_LEN(blob) ||
	header.states_offset < sizeof(OnibiRSeqHeader) ||
	(header.states_offset & 3U) != 0 || (header.edges_offset & 3U) != 0 ||
	(header.actions_offset & 3U) != 0 || (header.blob_size & 3U) != 0 ||
	header.edges_offset < header.states_offset ||
	header.states_offset + header.state_count * sizeof(OnibiRState) >
	    header.edges_offset ||
	header.edges_offset + header.edge_count * sizeof(OnibiREdge) >
	    header.actions_offset ||
	header.start_edge_count > header.edge_count ||
	(uint64_t)header.start_edge_base + (uint64_t)header.start_edge_count >
	    header.edge_count ||
	header.start_edge_base != header.edge_count - header.start_edge_count ||
	header.actions_offset + header.action_count * sizeof(OnibiRAction) >
	    header.blob_size ||
	(header.classes_offset & 3U) != 0 ||
	(header.literals_offset & 3U) != 0 ||
	(header.descriptors_offset & 3U) != 0 ||
	(header.subprograms_offset & 3U) != 0 ||
	(header.classes_offset &&
	 header.classes_offset < header.actions_offset) ||
	(header.literals_offset &&
	 header.literals_offset < header.classes_offset) ||
	(header.descriptors_offset &&
	 header.descriptors_offset < header.literals_offset) ||
	(header.subprograms_offset &&
	 header.subprograms_offset < header.descriptors_offset) ||
	header.classes_offset > header.blob_size ||
	header.literals_offset > header.blob_size ||
	header.descriptors_offset > header.blob_size ||
	header.subprograms_offset > header.blob_size ||
	header.classes_offset +
		(uint64_t)header.class_count * (sizeof(OnibiClassDesc) + 32U) >
	    header.literals_offset ||
	header.descriptors_offset + (uint64_t)NUM2UINT(onibi_hash_value_id(
					semantic, id_key_literal_count)) *
					sizeof(OnibiLiteralDesc) >
	    header.subprograms_offset ||
	header.subprograms_offset + (uint64_t)header.subprogram_count *
					sizeof(OnibiSubprogramDesc) >
	    header.blob_size)
	rb_raise(rb_eArgError, "invalid Onibi RSeq blob");
    for (long i = 0; i < RARRAY_LEN(semantic_subprograms); i++) {
	VALUE descriptor = rb_ary_entry(semantic_subprograms, i);
	VALUE entry_state = RB_TYPE_P(descriptor, T_HASH)
				? onibi_hash_value_id(descriptor, id_key_entry)
				: Qnil;
	VALUE accept_state =
	    RB_TYPE_P(descriptor, T_HASH)
		? onibi_hash_value_id(descriptor, id_key_accept)
		: Qnil;
	VALUE flags = RB_TYPE_P(descriptor, T_HASH)
			  ? onibi_hash_value_id(descriptor, id_key_flags)
			  : Qnil;
	if (NIL_P(entry_state) || NIL_P(accept_state) || NIL_P(flags) ||
	    NUM2LONG(entry_state) < 0 ||
	    NUM2LONG(entry_state) >= (long)header.state_count ||
	    NUM2LONG(accept_state) < 0 ||
	    NUM2LONG(accept_state) >= (long)header.state_count ||
	    NUM2LONG(flags) < 0)
	    rb_raise(rb_eArgError, "invalid RSeq subprogram descriptor");
	const OnibiSubprogramDesc *physical =
	    (const OnibiSubprogramDesc *)(RSTRING_PTR(blob) +
					  header.subprograms_offset) +
	    i;
	if (physical->entry != (OnibiStateId)NUM2ULONG(entry_state) ||
	    physical->accept != (OnibiStateId)NUM2ULONG(accept_state) ||
	    physical->flags != (uint32_t)NUM2ULONG(flags))
	    rb_raise(
		rb_eArgError,
		"RSeq subprogram descriptor disagrees with semantic table");
    }
    const OnibiRState *states =
	(const OnibiRState *)(RSTRING_PTR(blob) + header.states_offset);
    for (uint32_t i = 0; i < header.state_count; i++) {
	VALUE semantic_state = rb_ary_entry(semantic_states, i);
	if (!RB_TYPE_P(semantic_state, T_HASH) ||
	    !RTEST(rb_obj_frozen_p(semantic_state)) ||
	    !RTEST(rb_obj_frozen_p(
		onibi_hash_value_id(semantic_state, id_key_payload))))
	    rb_raise(rb_eArgError, "invalid semantic RSeq state");
	ID semantic_op = SYM2ID(onibi_hash_value_id(semantic_state, id_key_op));
	uint8_t expected_op = semantic_op == id_g_accept     ? 0
			      : semantic_op == id_g_char     ? ONIBI_RS_CHAR
			      : semantic_op == id_g_class    ? ONIBI_RS_CLASS
			      : semantic_op == id_g_any	     ? ONIBI_RS_ANY
			      : semantic_op == id_g_grapheme ? ONIBI_RS_GRAPHEME
			      : semantic_op == id_g_backref  ? ONIBI_RS_BACKREF
			      : semantic_op == id_g_call     ? ONIBI_RS_CALL
			      : semantic_op == id_g_atomic   ? ONIBI_RS_ATOMIC
			      : semantic_op == id_g_absent   ? ONIBI_RS_ABSENT
							     : 0xff;
	if (expected_op == 0xff || states[i].op != expected_op)
	    rb_raise(rb_eArgError,
		     "RSeq semantic and physical states disagree");
	if (!NIL_P(physical_graph)) {
	    VALUE cached_state = rb_ary_entry(
		onibi_hash_value_id(physical_graph, id_key_states), i);
	    if (!RB_TYPE_P(cached_state, T_HASH) ||
		SYM2ID(onibi_hash_value_id(cached_state, id_key_op)) !=
		    semantic_op ||
		!rb_equal(onibi_hash_value_id(cached_state, id_key_payload),
			  onibi_hash_value_id(semantic_state, id_key_payload)))
		rb_raise(rb_eArgError,
			 "cached RSeq state disagrees with semantic state");
	}
	if (semantic_op == id_g_class) {
	    VALUE bitmap = onibi_hash_value_id(
		onibi_hash_value_id(semantic_state, id_key_payload),
		id_key_bitmap);
	    if (!RB_TYPE_P(bitmap, T_STRING) || RSTRING_LEN(bitmap) != 32)
		rb_raise(rb_eArgError,
			 "RSeq class state has no compiled bitmap");
	}
	if (semantic_op == id_g_char) {
	    VALUE byte = onibi_hash_value_id(
		onibi_hash_value_id(semantic_state, id_key_payload),
		id_key_byte);
	    if (NIL_P(byte) || NUM2LONG(byte) < 0 || NUM2LONG(byte) > 255)
		rb_raise(rb_eArgError,
			 "RSeq character state has an invalid byte");
	}
	if (states[i].op > ONIBI_RS_RUN_ANY)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq state opcode");
	if ((uint64_t)states[i].edge_base + states[i].edge_count >
	    header.edge_count - header.start_edge_count)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq state edge range");
	if (states[i].op == ONIBI_RS_CLASS &&
	    states[i].payload >= header.class_count)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq class descriptor id");
	if (states[i].op == ONIBI_RS_CHAR &&
	    states[i].payload >=
		NUM2UINT(onibi_hash_value_id(semantic, id_key_literal_count)))
	    rb_raise(rb_eArgError, "invalid Onibi RSeq literal descriptor id");
    }
    const OnibiREdge *edges =
	(const OnibiREdge *)(RSTRING_PTR(blob) + header.edges_offset);
    uint32_t edge_total = header.edge_count;
    for (uint32_t i = 0; i < edge_total; i++) {
	if (edges[i].destination != ONIBI_ACCEPT_STATE &&
	    edges[i].destination >= header.state_count)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq edge destination");
	if (edges[i].action_offset != 0 &&
	    (edges[i].action_offset < sizeof(OnibiRAction) ||
	     edges[i].action_offset % sizeof(OnibiRAction) != 0 ||
	     edges[i].action_offset >=
		 header.blob_size - header.actions_offset))
	    rb_raise(rb_eArgError, "invalid Onibi RSeq edge action offset");
    }
    for (uint32_t i = 0; i < header.edge_count - header.start_edge_count; i++) {
	VALUE semantic_edge = rb_ary_entry(semantic_edges, i);
	if (!RB_TYPE_P(semantic_edge, T_HASH) ||
	    !RTEST(rb_obj_frozen_p(semantic_edge)) ||
	    !RTEST(rb_obj_frozen_p(
		onibi_hash_value_id(semantic_edge, id_key_actions))))
	    rb_raise(rb_eArgError, "invalid semantic RSeq edge");
	VALUE semantic_edge_actions =
	    onibi_hash_value_id(semantic_edge, id_key_actions);
	if (RARRAY_LEN(semantic_edge_actions) > 0) {
	    VALUE terminator = rb_ary_entry(
		semantic_edge_actions, RARRAY_LEN(semantic_edge_actions) - 1);
	    VALUE terminator_op =
		RB_TYPE_P(terminator, T_HASH)
		    ? onibi_hash_value_id(terminator, id_key_op)
		    : Qnil;
	    if (!SYMBOL_P(terminator_op) || SYM2ID(terminator_op) != id_a_end)
		rb_raise(rb_eArgError,
			 "RSeq edge action program is not terminated");
	}
	uint32_t destination =
	    (uint32_t)NUM2ULONG(onibi_hash_value_id(semantic_edge, id_key_to));
	if (destination == header.state_count - 1)
	    destination = ONIBI_ACCEPT_STATE;
	uint32_t action_index = (uint32_t)NUM2ULONG(
	    onibi_hash_value_id(semantic_edge, id_key_action_offset));
	uint32_t expected_offset =
	    action_index == 0 && RARRAY_LEN(semantic_edge_actions) == 0
		? 0
		: (uint32_t)(sizeof(OnibiRAction) * (action_index + 1));
	if (edges[i].destination != destination ||
	    edges[i].action_offset != expected_offset)
	    rb_raise(rb_eArgError, "RSeq edge disagrees with semantic edge");
	if (!NIL_P(physical_graph)) {
	    VALUE cached_edge = rb_ary_entry(
		onibi_hash_value_id(physical_graph, id_key_edges), i);
	    uint32_t cached_to = RB_TYPE_P(cached_edge, T_HASH)
				     ? (uint32_t)NUM2ULONG(onibi_hash_value_id(
					   cached_edge, id_key_to))
				     : UINT32_MAX;
	    VALUE cached_actions =
		RB_TYPE_P(cached_edge, T_HASH)
		    ? onibi_hash_value_id(cached_edge, id_key_actions)
		    : Qnil;
	    if (!RB_TYPE_P(cached_edge, T_HASH) ||
		cached_to != (destination == ONIBI_ACCEPT_STATE
				  ? header.state_count - 1
				  : destination) ||
		!RB_TYPE_P(cached_actions, T_ARRAY) ||
		RARRAY_LEN(cached_actions) != RARRAY_LEN(semantic_edge_actions))
		rb_raise(rb_eArgError,
			 "cached RSeq edge disagrees with physical edge");
	    for (long a = 0; a < RARRAY_LEN(semantic_edge_actions); a++) {
		if (!rb_equal(rb_ary_entry(cached_actions, a),
			      rb_ary_entry(semantic_edge_actions, a)))
		    rb_raise(rb_eArgError, "cached RSeq action program "
					   "disagrees with semantic edge");
	    }
	}
    }
    if (NIL_P(semantic_start_edges) ||
	!RB_TYPE_P(semantic_start_edges, T_ARRAY) ||
	RARRAY_LEN(semantic_start_edges) != header.start_edge_count)
	rb_raise(rb_eArgError, "RSeq start edges are invalid");
    for (uint32_t i = 0; i < header.start_edge_count; i++) {
	VALUE semantic_edge = rb_ary_entry(semantic_start_edges, i);
	if (!RB_TYPE_P(semantic_edge, T_HASH) ||
	    !RTEST(rb_obj_frozen_p(semantic_edge)) ||
	    !RTEST(rb_obj_frozen_p(
		onibi_hash_value_id(semantic_edge, id_key_actions))))
	    rb_raise(rb_eArgError, "invalid semantic RSeq start edge");
	VALUE semantic_edge_actions =
	    onibi_hash_value_id(semantic_edge, id_key_actions);
	if (RARRAY_LEN(semantic_edge_actions) > 0) {
	    VALUE terminator = rb_ary_entry(
		semantic_edge_actions, RARRAY_LEN(semantic_edge_actions) - 1);
	    VALUE terminator_op =
		RB_TYPE_P(terminator, T_HASH)
		    ? onibi_hash_value_id(terminator, id_key_op)
		    : Qnil;
	    if (!SYMBOL_P(terminator_op) || SYM2ID(terminator_op) != id_a_end)
		rb_raise(rb_eArgError,
			 "RSeq start-edge action program is not terminated");
	}
	uint32_t destination =
	    (uint32_t)NUM2ULONG(onibi_hash_value_id(semantic_edge, id_key_to));
	uint32_t action_index = (uint32_t)NUM2ULONG(
	    onibi_hash_value_id(semantic_edge, id_key_action_offset));
	uint32_t expected_offset =
	    RARRAY_LEN(semantic_edge_actions) == 0
		? 0
		: (uint32_t)(sizeof(OnibiRAction) * (action_index + 1));
	if (edges[header.edge_count - header.start_edge_count + i]
		    .destination != destination ||
	    edges[header.edge_count - header.start_edge_count + i]
		    .action_offset != expected_offset)
	    rb_raise(rb_eArgError,
		     "RSeq edge disagrees with semantic start edge");
	if (!NIL_P(physical_graph)) {
	    VALUE cached_edge = rb_ary_entry(
		onibi_hash_value_id(physical_graph, id_key_start_edges), i);
	    VALUE cached_actions =
		RB_TYPE_P(cached_edge, T_HASH)
		    ? onibi_hash_value_id(cached_edge, id_key_actions)
		    : Qnil;
	    uint32_t cached_to = RB_TYPE_P(cached_edge, T_HASH)
				     ? (uint32_t)NUM2ULONG(onibi_hash_value_id(
					   cached_edge, id_key_to))
				     : UINT32_MAX;
	    if (!RB_TYPE_P(cached_edge, T_HASH) || cached_to != destination ||
		!RB_TYPE_P(cached_actions, T_ARRAY) ||
		RARRAY_LEN(cached_actions) != RARRAY_LEN(semantic_edge_actions))
		rb_raise(rb_eArgError,
			 "cached RSeq start edge disagrees with physical edge");
	    for (long a = 0; a < RARRAY_LEN(semantic_edge_actions); a++) {
		if (!rb_equal(rb_ary_entry(cached_actions, a),
			      rb_ary_entry(semantic_edge_actions, a)))
		    rb_raise(rb_eArgError, "cached RSeq start action program "
					   "disagrees with semantic edge");
	    }
	}
    }
    const OnibiRAction *actions =
	(const OnibiRAction *)(RSTRING_PTR(blob) + header.actions_offset);
    for (uint32_t i = 0; i < header.action_count; i++) {
	VALUE semantic_action = rb_ary_entry(semantic_actions, i);
	if (!RB_TYPE_P(semantic_action, T_HASH) ||
	    !RTEST(rb_obj_frozen_p(semantic_action)))
	    rb_raise(rb_eArgError, "invalid semantic RSeq action");
	ID op = SYM2ID(onibi_hash_value_id(semantic_action, id_key_op));
	uint8_t expected_op =
	    (op == id_capture_open || op == id_capture_close) ? ONIBI_RA_CAPTURE
	    : op == id_match_reset ? ONIBI_RA_MATCH_RESET
	    : (op == id_a_assert_begin_buffer || op == id_a_assert_end_buffer ||
	       op == id_a_assert_begin_line || op == id_a_assert_end_line ||
	       op == id_a_assert_semi_end_buffer ||
	       op == id_a_assert_search_origin ||
	       op == id_a_assert_word_boundary ||
	       op == id_a_assert_nonword_boundary ||
	       op == id_a_assert_lookahead || op == id_a_assert_lookbehind)
		? ONIBI_RA_ASSERT_POSITION
	    : op == id_a_test_capture	   ? ONIBI_RA_TEST_CAPTURE
	    : op == id_a_counter_init	   ? ONIBI_RA_COUNTER_SET
	    : op == id_a_counter_increment ? ONIBI_RA_COUNTER_ADD
	    : (op == id_a_test_counter_lt || op == id_a_test_counter_ge)
		? ONIBI_RA_COUNTER_TEST
	    : op == id_a_end ? ONIBI_RA_END
			     : 0xff;
	VALUE slot = onibi_hash_value_id(semantic_action, id_key_slot);
	VALUE limit = onibi_hash_value_id(semantic_action, id_key_limit);
	VALUE value = onibi_hash_value_id(semantic_action, id_key_value);
	VALUE width = onibi_hash_value_id(semantic_action, id_key_width);
	if (op == id_a_assert_lookahead || op == id_a_assert_lookbehind) {
	    VALUE predicates =
		onibi_hash_value_id(semantic_action, id_key_predicates);
	    if (!RB_TYPE_P(predicates, T_ARRAY) ||
		!RTEST(rb_obj_frozen_p(predicates)) || NIL_P(width) ||
		NUM2LONG(width) != RARRAY_LEN(predicates))
		rb_raise(rb_eArgError,
			 "RSeq lookaround predicates are invalid");
	    for (long p = 0; p < RARRAY_LEN(predicates); p++) {
		VALUE predicate = rb_ary_entry(predicates, p);
		VALUE kind_code =
		    onibi_hash_value_id(predicate, id_key_predicate_code);
		if (!RB_TYPE_P(predicate, T_HASH) ||
		    !RTEST(rb_obj_frozen_p(predicate)) || NIL_P(kind_code) ||
		    NUM2UINT(kind_code) > ONIBI_PRED_ANY)
		    rb_raise(rb_eArgError,
			     "RSeq lookaround predicate has an invalid kind");
		if (NUM2UINT(kind_code) == ONIBI_PRED_BYTE) {
		    VALUE byte = onibi_hash_value_id(predicate, id_key_byte);
		    if (NIL_P(byte) || NUM2LONG(byte) < 0 ||
			NUM2LONG(byte) > 255)
			rb_raise(rb_eArgError,
				 "RSeq lookaround byte predicate is invalid");
		}
		else if (NUM2UINT(kind_code) == ONIBI_PRED_BITMAP) {
		    VALUE bitmap =
			onibi_hash_value_id(predicate, id_key_bitmap);
		    if (!RB_TYPE_P(bitmap, T_STRING) ||
			RSTRING_LEN(bitmap) != 32 ||
			!RTEST(rb_obj_frozen_p(bitmap)))
			rb_raise(rb_eArgError,
				 "RSeq lookaround bitmap predicate is invalid");
		}
	    }
	}
	uint32_t expected_arg32 =
	    !NIL_P(width)
		? (uint32_t)NUM2ULONG(width)
		: (!NIL_P(limit)
		       ? (uint32_t)NUM2ULONG(limit)
		       : (!NIL_P(value) ? (uint32_t)NUM2ULONG(value) : 0));
	uint8_t expected_flags = onibi_rseq_action_flags(op);
	if (op == id_a_test_capture &&
	    !RTEST(onibi_hash_value_id(semantic_action, id_key_set)))
	    expected_flags = ONIBI_RA_TEST_CAPTURE_UNSET;
	VALUE assert_kind =
	    onibi_hash_value_id(semantic_action, id_key_assert_kind);
	uint16_t expected_arg16 =
	    !NIL_P(slot)
		? (uint16_t)NUM2ULONG(slot)
		: (NIL_P(assert_kind) ? onibi_rseq_assert_kind(op)
				      : (uint16_t)NUM2ULONG(assert_kind));
	if (op == id_a_assert_lookahead || op == id_a_assert_lookbehind) {
	    int positive =
		RTEST(onibi_hash_value_id(semantic_action, id_key_positive));
	    expected_flags = op == id_a_assert_lookahead ? (positive ? 1 : 2)
							 : (positive ? 5 : 6);
	}
	if (expected_op == 0xff || actions[i].op != expected_op ||
	    actions[i].flags != expected_flags ||
	    actions[i].arg16 != expected_arg16 ||
	    ((!NIL_P(width) || !NIL_P(limit) || !NIL_P(value)) &&
	     actions[i].arg32 != expected_arg32))
	    rb_raise(rb_eArgError,
		     "RSeq action disagrees with semantic action");
	if (actions[i].op > ONIBI_RA_PROGRESS)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq action opcode");
    }
    const OnibiClassDesc *classes =
	(const OnibiClassDesc *)(RSTRING_PTR(blob) + header.classes_offset);
    uint64_t class_data_start =
	(uint64_t)header.classes_offset +
	(uint64_t)header.class_count * sizeof(OnibiClassDesc);
    for (uint32_t i = 0; i < header.class_count; i++) {
	if (classes[i].data_length != 32 || classes[i].kind != 0 ||
	    (classes[i].flags & ~1U) != 0)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq class descriptor");
	if (classes[i].data_offset < class_data_start ||
	    (uint64_t)classes[i].data_offset + classes[i].data_length >
		header.literals_offset)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq class descriptor range");
    }
    const OnibiLiteralDesc *literals =
	(const OnibiLiteralDesc *)(RSTRING_PTR(blob) +
				   header.descriptors_offset);
    for (uint32_t i = 0;
	 i < NUM2UINT(onibi_hash_value_id(semantic, id_key_literal_count));
	 i++) {
	if (literals[i].data_length != 1 || (literals[i].flags & ~1U) != 0)
	    rb_raise(rb_eArgError, "invalid Onibi RSeq literal descriptor");
	if (literals[i].data_offset < header.literals_offset ||
	    (uint64_t)literals[i].data_offset + literals[i].data_length >
		header.descriptors_offset)
	    rb_raise(rb_eArgError,
		     "invalid Onibi RSeq literal descriptor range");
    }
    for (uint32_t i = 0; i < header.state_count; i++) {
	VALUE state = rb_ary_entry(semantic_states, i);
	ID op = SYM2ID(onibi_hash_value_id(state, id_key_op));
	VALUE payload = onibi_hash_value_id(state, id_key_payload);
	if (op == id_g_class) {
	    uint32_t id = ((const OnibiRState *)(RSTRING_PTR(blob) +
						 header.states_offset))[i]
			      .payload;
	    VALUE bitmap = onibi_hash_value_id(payload, id_key_bitmap);
	    if (id >= header.class_count ||
		memcmp(RSTRING_PTR(bitmap),
		       RSTRING_PTR(blob) + classes[id].data_offset, 32) != 0 ||
		((classes[id].flags & 1U) !=
		 (RTEST(onibi_hash_value_id(payload, id_key_negated)) ? 1U
								      : 0U)))
		rb_raise(
		    rb_eArgError,
		    "RSeq class descriptor disagrees with semantic payload");
	}
	else if (op == id_g_char) {
	    uint32_t id = ((const OnibiRState *)(RSTRING_PTR(blob) +
						 header.states_offset))[i]
			      .payload;
	    VALUE byte = onibi_hash_value_id(payload, id_key_byte);
	    if (id >= NUM2UINT(onibi_hash_value_id(semantic,
						   id_key_literal_count)) ||
		(unsigned char)RSTRING_PTR(blob)[literals[id].data_offset] !=
		    (unsigned char)NUM2INT(byte) ||
		((literals[id].flags & 1U) !=
		 (RTEST(onibi_hash_value_id(payload, id_key_ignorecase)) ? 1U
									 : 0U)))
		rb_raise(
		    rb_eArgError,
		    "RSeq literal descriptor disagrees with semantic payload");
	}
    }
}

/* Build the regular execution view from the published RSeq blob.  Semantic
   payloads remain Ruby values, but state operations and edge destinations
   come from the physical layout.  This keeps the VM on the RSeq contract. */

