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
onibi_rseq_class_raw_hit(const OnibiRSeqView *view, const OnibiClassDesc *klass,
			 OnigCodePoint codepoint, rb_encoding *encoding,
			 unsigned char *stack, size_t stack_capacity)
{
    const unsigned char *data = view->blob + klass->data_offset;
    if (klass->kind == ONIBI_CLASS_ASCII_BITMAP)
	return codepoint < 256 &&
	       (data[codepoint >> 3] & (1U << (codepoint & 7))) != 0;
    if (klass->kind == ONIBI_CLASS_ENCODING_CTYPE) {
	uint32_t ctype;
	memcpy(&ctype, data, sizeof(ctype));
	return ONIGENC_IS_CODE_CTYPE(encoding, codepoint, (OnigCtype)ctype) !=
	       0;
    }
    if (klass->kind == ONIBI_CLASS_CODEPOINT_RANGES) {
	const OnibiCodepointRange *ranges = (const OnibiCodepointRange *)data;
	size_t low = 0;
	size_t high = klass->data_length / sizeof(*ranges);
	while (low < high) {
	    size_t middle = low + (high - low) / 2U;
	    if (codepoint < ranges[middle].first)
		high = middle;
	    else if (codepoint > ranges[middle].last)
		low = middle + 1U;
	    else
		return 1;
	}
	return 0;
    }
    const OnibiClassExpr *expr = (const OnibiClassExpr *)data;
    size_t count = klass->data_length / sizeof(*expr);
    if (!stack || count > stack_capacity) return 0;
    size_t depth = 0;
    for (size_t i = 0; i < count; i++) {
	if (expr[i].op == ONIBI_CLASS_EXPR_RANGE) {
	    stack[depth++] =
		codepoint >= expr[i].arg0 && codepoint <= expr[i].arg1;
	}
	else if (expr[i].op == ONIBI_CLASS_EXPR_CTYPE) {
	    stack[depth++] =
		ONIGENC_IS_CODE_CTYPE(encoding, codepoint,
				      (OnigCtype)expr[i].arg0) != 0;
	}
	else if (expr[i].op == ONIBI_CLASS_EXPR_NEGATE) {
	    stack[depth - 1U] = !stack[depth - 1U];
	}
	else {
	    unsigned char right = stack[--depth];
	    if (expr[i].op == ONIBI_CLASS_EXPR_UNION)
		stack[depth - 1U] = stack[depth - 1U] || right;
	    else
		stack[depth - 1U] = stack[depth - 1U] && right;
	}
    }
    return stack[0] != 0;
}

static int
onibi_rseq_class_hit(const OnibiRSeqView *view, const OnibiClassDesc *klass,
		     OnigCodePoint codepoint, rb_encoding *encoding,
		     unsigned char *stack, size_t stack_capacity)
{
    int hit = onibi_rseq_class_raw_hit(view, klass, codepoint, encoding, stack,
				       stack_capacity);
    if ((klass->flags & ONIBI_RSEQ_CLASS_FLAG_NEGATED) != 0) hit = !hit;
    return hit;
}

static int
onibi_rseq_decode_character(VALUE str, long position, rb_encoding *encoding,
			    OnibiEncodingMode mode, OnigCodePoint *codepoint,
			    long *width)
{
    if (position < 0 || position >= RSTRING_LEN(str)) return 0;
    const unsigned char *begin =
	(const unsigned char *)RSTRING_PTR(str) + position;
    const unsigned char *end =
	(const unsigned char *)RSTRING_PTR(str) + RSTRING_LEN(str);
    if (mode == ONIBI_ENC_ASCII_7BIT) {
	*codepoint = *begin;
	*width = 1;
	return 1;
    }
    int length =
	rb_enc_precise_mbclen((const char *)begin, (const char *)end, encoding);
    if (!MBCLEN_CHARFOUND_P(length)) return 0;
    *width = MBCLEN_CHARFOUND_LEN(length);
    *codepoint = ONIGENC_MBC_TO_CODE(encoding, begin, end);
    return 1;
}

/* One semantic consume operation for the encoding-aware RSeq primitives. */
static int
onibi_rseq_consume_character(const OnibiRSeqView *view,
			     const OnibiRState *state, VALUE str, long position,
			     rb_encoding *encoding, OnibiEncodingMode mode,
			     long *next_position, unsigned char *class_stack,
			     size_t class_stack_capacity)
{
    if (position < 0 || position >= RSTRING_LEN(str)) return 0;
    const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(str);
    if (state->op == ONIBI_RS_CHAR) {
	const OnibiLiteralDesc *literal = &view->literals[state->payload];
	if (position + literal->data_length > RSTRING_LEN(str) ||
	    !onibi_ascii_literal_equal(
		bytes + position, view->blob + literal->data_offset,
		literal->data_length,
		(literal->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0))
	    return 0;
	*next_position = position + literal->data_length;
	return 1;
    }
    if (state->op == ONIBI_RS_CLASS) {
	const OnibiClassDesc *klass = &view->classes[state->payload];
	OnigCodePoint codepoint;
	long width;
	if (!onibi_rseq_decode_character(str, position, encoding, mode,
					 &codepoint, &width) ||
	    !onibi_rseq_class_hit(view, klass, codepoint, encoding, class_stack,
				  class_stack_capacity))
	    return 0;
	*next_position = position + width;
	return 1;
    }
    if (state->op == ONIBI_RS_ANY) {
	OnigCodePoint codepoint;
	long width;
	if (!onibi_rseq_decode_character(str, position, encoding, mode,
					 &codepoint, &width))
	    return 0;
	(void)codepoint;
	int multiline =
	    (state->flags & ONIBI_RSEQ_STATE_FLAG_NEGATED) != 0 ||
	    (view->header->flags & ONIBI_RSEQ_HEADER_FLAG_MULTILINE) != 0;
	if (!multiline && ONIGENC_IS_MBC_NEWLINE(encoding, bytes + position,
						 bytes + RSTRING_LEN(str)))
	    return 0;
	*next_position = position + width;
	return 1;
    }
    return 0;
}

static int
onibi_rseq_word_at(VALUE str, long position, rb_encoding *encoding,
		   OnibiEncodingMode mode)
{
    OnigCodePoint codepoint;
    long width;
    return onibi_rseq_decode_character(str, position, encoding, mode,
				       &codepoint, &width) &&
	   ONIGENC_IS_CODE_CTYPE(encoding, codepoint, ONIGENC_CTYPE_WORD) != 0;
}

static int
onibi_rseq_word_before(VALUE str, long position, rb_encoding *encoding,
		       OnibiEncodingMode mode)
{
    if (position <= 0) return 0;
    if (mode == ONIBI_ENC_ASCII_7BIT)
	return onibi_rseq_word_at(str, position - 1, encoding, mode);
    const char *begin = RSTRING_PTR(str);
    const char *current = begin + position;
    const char *end = begin + RSTRING_LEN(str);
    const char *previous = rb_enc_prev_char(begin, current, end, encoding);
    if (!previous) return 0;
    return onibi_rseq_word_at(str, previous - begin, encoding, mode);
}

static int
onibi_rseq_position_assertion_hit(OnibiRAssertKind kind, VALUE str, long pos,
				  long search_origin, rb_encoding *encoding,
				  OnibiEncodingMode mode)
{
    int hit = 0;
    switch (kind) {
    case ONIBI_RAP_BEGIN_BUFFER: hit = pos == 0; break;
    case ONIBI_RAP_END_BUFFER: hit = pos == RSTRING_LEN(str); break;
    case ONIBI_RAP_BEGIN_LINE:
	hit = pos == 0 || RSTRING_PTR(str)[pos - 1] == '\n';
	break;
    case ONIBI_RAP_END_LINE:
	hit = pos == RSTRING_LEN(str) || RSTRING_PTR(str)[pos] == '\n';
	break;
    case ONIBI_RAP_SEMI_END_BUFFER:
	hit = pos == RSTRING_LEN(str) ||
	      (pos + 1 == RSTRING_LEN(str) && RSTRING_PTR(str)[pos] == '\n');
	break;
    case ONIBI_RAP_SEARCH_ORIGIN: hit = pos == search_origin; break;
    case ONIBI_RAP_WORD_BOUNDARY:
    case ONIBI_RAP_NONWORD_BOUNDARY: {
	int left = onibi_rseq_word_before(str, pos, encoding, mode);
	int right = pos < RSTRING_LEN(str) &&
		    onibi_rseq_word_at(str, pos, encoding, mode);
	hit = left != right;
	if (kind == ONIBI_RAP_NONWORD_BOUNDARY) hit = !hit;
	break;
    }
    default: return 0;
    }
    return hit;
}

static void
onibi_semantic_arena_reset(OnibiSemanticArena *arena)
{
    arena->register_count = 0;
    arena->tag_count = 0;
    arena->call_count = 0;
    arena->atomic_count = 0;
    arena->absence_count = 0;
    arena->frame_count = 0;
    arena->key_count = 0;
    arena->key_generation++;
    if (arena->key_generation == 0) {
	if (arena->key_buckets)
	    memset(arena->key_buckets, 0,
		   arena->key_capacity * sizeof(*arena->key_buckets));
	arena->key_generation = 1;
    }
}

static void
onibi_semantic_arena_release(OnibiSemanticArena *arena)
{
    ruby_xfree(arena->registers);
    ruby_xfree(arena->tags);
    ruby_xfree(arena->calls);
    ruby_xfree(arena->atomic);
    ruby_xfree(arena->absence);
    ruby_xfree(arena->live_capture_slots);
    ruby_xfree(arena->live_capture_bitmap);
    ruby_xfree(arena->frames);
    ruby_xfree(arena->key_buckets);
    memset(arena, 0, sizeof(*arena));
}

static void *
onibi_semantic_arena_reserve(void *items, size_t *capacity, size_t count,
			     size_t item_size)
{
    if (count < *capacity) return items;
    size_t new_capacity = *capacity == 0 ? 32U : *capacity * 2U;
    if (new_capacity < *capacity || new_capacity > UINT32_MAX ||
	new_capacity > SIZE_MAX / item_size)
	rb_memerror();
    *capacity = new_capacity;
    return ruby_xrealloc(items, new_capacity * item_size);
}

static void
onibi_semantic_live_captures_begin(OnibiSemanticArena *arena,
				   uint32_t capture_count)
{
    if (capture_count > arena->live_capture_bitmap_capacity) {
	arena->live_capture_bitmap =
	    ruby_xrealloc(arena->live_capture_bitmap, capture_count);
	arena->live_capture_bitmap_capacity = capture_count;
    }
    if (capture_count != 0)
	memset(arena->live_capture_bitmap, 0, capture_count);
    arena->live_capture_count = 0;
}

static void
onibi_semantic_live_capture_add(OnibiSemanticArena *arena, uint32_t capture_id)
{
    if (capture_id >= arena->live_capture_bitmap_capacity ||
	arena->live_capture_bitmap[capture_id])
	return;
    arena->live_capture_bitmap[capture_id] = 1;
    arena->live_capture_slots = onibi_semantic_arena_reserve(
	arena->live_capture_slots, &arena->live_capture_capacity,
	arena->live_capture_count, sizeof(*arena->live_capture_slots));
    arena->live_capture_slots[arena->live_capture_count++] = capture_id * 2U;
    arena->live_capture_slots = onibi_semantic_arena_reserve(
	arena->live_capture_slots, &arena->live_capture_capacity,
	arena->live_capture_count, sizeof(*arena->live_capture_slots));
    arena->live_capture_slots[arena->live_capture_count++] =
	capture_id * 2U + 1U;
}

static void
onibi_semantic_live_captures_prepare(OnibiSemanticArena *arena,
				     const OnibiRSeqView *view)
{
    onibi_semantic_live_captures_begin(arena, view->header->capture_count);
    for (uint32_t i = 0; i < view->header->state_count; i++)
	if (view->states[i].op == ONIBI_RS_BACKREF)
	    onibi_semantic_live_capture_add(arena, view->states[i].payload);
    for (uint32_t i = 0; i < view->header->action_count; i++)
	if (view->actions[i].op == ONIBI_RA_TEST_CAPTURE)
	    onibi_semantic_live_capture_add(arena, view->actions[i].arg16);
}

enum {
    ONIBI_SEMANTIC_HASH_CAPTURE = 1,
    ONIBI_SEMANTIC_HASH_COUNTER = 2,
    ONIBI_SEMANTIC_HASH_PROGRESS = 3,
    ONIBI_SEMANTIC_HASH_CALL = 4,
    ONIBI_SEMANTIC_HASH_ATOMIC = 5,
    ONIBI_SEMANTIC_HASH_ABSENCE = 6
};

static uint64_t
onibi_semantic_hash_value(uint64_t hash, uint64_t value)
{
    hash ^= value + UINT64_C(0x9e3779b97f4a7c15) + (hash << 6) + (hash >> 2);
    return hash;
}

static uint64_t
onibi_semantic_register_base_hash(uint64_t domain, uint32_t slot_count,
				  OnigPosition default_value)
{
    uint64_t hash =
	onibi_semantic_hash_value(UINT64_C(0xcbf29ce484222325), domain);
    hash = onibi_semantic_hash_value(hash, slot_count);
    return onibi_semantic_hash_value(hash, (uint64_t)default_value);
}

static uint64_t
onibi_semantic_register_slot_hash(uint64_t domain, uint32_t slot,
				  OnigPosition value)
{
    uint64_t hash =
	onibi_semantic_hash_value(UINT64_C(0x84222325cbf29ce4), domain);
    hash = onibi_semantic_hash_value(hash, slot);
    return onibi_semantic_hash_value(hash, (uint64_t)value);
}

static OnibiSemanticState
onibi_semantic_state_initial(const OnibiSemanticArena *arena,
			     OnigPosition reported_start,
			     uint32_t capture_slots, uint32_t counter_slots,
			     uint32_t progress_slots)
{
    OnibiSemanticState state;
    memset(&state, 0, sizeof(state));
    state.reported_start = reported_start;
    state.semantic_captures = (OnibiSemanticCaptureFile){
	UINT32_MAX, capture_slots,
	onibi_semantic_register_base_hash(ONIBI_SEMANTIC_HASH_CAPTURE,
					  capture_slots, -1)};
    state.counters =
	(OnibiCounterFile){UINT32_MAX, counter_slots,
			   onibi_semantic_register_base_hash(
			       ONIBI_SEMANTIC_HASH_COUNTER, counter_slots, 0)};
    state.progress = (OnibiProgressState){
	UINT32_MAX, progress_slots,
	onibi_semantic_register_base_hash(ONIBI_SEMANTIC_HASH_PROGRESS,
					  progress_slots, -1)};
    if (arena)
	state.semantic_captures.hash = onibi_semantic_hash_value(
	    state.semantic_captures.hash, arena->live_capture_count);
    state.calls = (OnibiCallStack){UINT32_MAX, 0};
    state.atomic = (OnibiAtomicState){UINT32_MAX, 0};
    state.absence = (OnibiAbsenceState){UINT32_MAX, 0};
    state.tag_history = UINT32_MAX;
    return state;
}

static OnigPosition
onibi_semantic_register_read(OnibiSemanticArena *arena, uint32_t root,
			     uint32_t slot, OnigPosition default_value)
{
    arena->register_read_count++;
    while (root != UINT32_MAX) {
	if (root >= arena->register_count) return default_value;
	const OnibiSemanticRegisterDelta *delta = &arena->registers[root];
	if (delta->slot == slot) return delta->value;
	root = delta->parent;
    }
    return default_value;
}

static uint32_t
onibi_semantic_register_append(OnibiSemanticArena *arena, uint32_t parent,
			       uint32_t slot, OnigPosition value)
{
    arena->registers = onibi_semantic_arena_reserve(
	arena->registers, &arena->register_capacity, arena->register_count,
	sizeof(*arena->registers));
    uint32_t id = (uint32_t)arena->register_count++;
    arena->registers[id] = (OnibiSemanticRegisterDelta){parent, slot, value};
    return id;
}

static void
onibi_semantic_register_file_write(OnibiSemanticArena *arena, uint32_t *root,
				   uint64_t *hash, uint64_t domain,
				   uint32_t slot, OnigPosition value,
				   OnigPosition default_value, int hash_slot)
{
    OnigPosition old_value =
	onibi_semantic_register_read(arena, *root, slot, default_value);
    if (old_value == value) return;
    *root = onibi_semantic_register_append(arena, *root, slot, value);
    if (!hash_slot) return;
    *hash ^= onibi_semantic_register_slot_hash(domain, slot, old_value);
    *hash ^= onibi_semantic_register_slot_hash(domain, slot, value);
}

static int
onibi_semantic_capture_slot_live(const OnibiSemanticArena *arena, uint32_t slot)
{
    uint32_t capture_id = slot / 2U;
    return capture_id < arena->live_capture_bitmap_capacity &&
	   arena->live_capture_bitmap[capture_id];
}

static void
onibi_semantic_capture_write(OnibiSemanticArena *arena,
			     OnibiSemanticCaptureFile *file, uint32_t slot,
			     OnigPosition value)
{
    onibi_semantic_register_file_write(
	arena, &file->root, &file->hash, ONIBI_SEMANTIC_HASH_CAPTURE, slot,
	value, -1, onibi_semantic_capture_slot_live(arena, slot));
}

static void
onibi_semantic_counter_write(OnibiSemanticArena *arena, OnibiCounterFile *file,
			     uint32_t slot, OnigPosition value)
{
    onibi_semantic_register_file_write(arena, &file->root, &file->hash,
				       ONIBI_SEMANTIC_HASH_COUNTER, slot, value,
				       0, 1);
}

static void
onibi_semantic_progress_write(OnibiSemanticArena *arena,
			      OnibiProgressState *file, uint32_t slot,
			      OnigPosition value)
{
    onibi_semantic_register_file_write(arena, &file->root, &file->hash,
				       ONIBI_SEMANTIC_HASH_PROGRESS, slot,
				       value, -1, 1);
}

static OnibiTagEventId
onibi_semantic_tag_append(OnibiSemanticArena *arena, OnibiTagEventId parent,
			  uint32_t slot, OnigPosition position)
{
    arena->tags =
	onibi_semantic_arena_reserve(arena->tags, &arena->tag_capacity,
				     arena->tag_count, sizeof(*arena->tags));
    OnibiTagEventId id = (OnibiTagEventId)arena->tag_count++;
    uint64_t hash = parent == UINT32_MAX ? UINT64_C(0x84222325cbf29ce4)
					 : arena->tags[parent].hash;
    hash = onibi_semantic_hash_value(hash, slot);
    hash = onibi_semantic_hash_value(hash, (uint64_t)position);
    arena->tags[id] = (OnibiSemanticTagEvent){parent, slot, position, hash};
    onibi_diagnostics.tag_events++;
    return id;
}

static uint32_t
onibi_semantic_call_push(OnibiSemanticArena *arena, uint32_t parent,
			 const OnibiCallFrame *frame)
{
    arena->calls =
	onibi_semantic_arena_reserve(arena->calls, &arena->call_capacity,
				     arena->call_count, sizeof(*arena->calls));
    uint32_t id = (uint32_t)arena->call_count++;
    uint64_t hash = parent == UINT32_MAX ? UINT64_C(0xcbf29ce484222325)
					 : arena->calls[parent].hash;
    hash = onibi_semantic_hash_value(hash, ONIBI_SEMANTIC_HASH_CALL);
    hash = onibi_semantic_hash_value(hash, frame->subprogram_id);
    hash = onibi_semantic_hash_value(hash, frame->continuation);
    hash = onibi_semantic_hash_value(
	hash, frame->tag_history == UINT32_MAX
		  ? UINT64_C(0x84222325cbf29ce4)
		  : arena->tags[frame->tag_history].hash);
    hash = onibi_semantic_hash_value(hash, frame->recursion_depth);
    arena->calls[id] = (OnibiOwnedCallFrame){parent, *frame, hash};
    return id;
}

static uint32_t
onibi_semantic_scope_push(OnibiSemanticArena *arena, OnibiSemanticScope **nodes,
			  size_t *count, size_t *capacity, uint32_t parent,
			  OnibiSubprogramId subprogram_id, OnigPosition begin,
			  OnigPosition end, OnibiTagEventId tag_history,
			  uint32_t flags, uint64_t domain)
{
    *nodes =
	onibi_semantic_arena_reserve(*nodes, capacity, *count, sizeof(**nodes));
    uint32_t id = (uint32_t)(*count)++;
    uint64_t hash = parent == UINT32_MAX ? UINT64_C(0x84222325cbf29ce4)
					 : (*nodes)[parent].hash;
    hash = onibi_semantic_hash_value(hash, domain);
    hash = onibi_semantic_hash_value(hash, subprogram_id);
    hash = onibi_semantic_hash_value(hash, (uint64_t)begin);
    hash = onibi_semantic_hash_value(hash, (uint64_t)end);
    hash = onibi_semantic_hash_value(hash, tag_history == UINT32_MAX
					       ? UINT64_C(0x84222325cbf29ce4)
					       : arena->tags[tag_history].hash);
    hash = onibi_semantic_hash_value(hash, flags);
    (*nodes)[id] = (OnibiSemanticScope){parent,	     subprogram_id, begin, end,
					tag_history, flags,	    hash};
    return id;
}

static int
onibi_semantic_register_file_equal(OnibiSemanticArena *arena, uint32_t left,
				   uint32_t right, uint64_t left_hash,
				   uint64_t right_hash, uint32_t slot_count,
				   OnigPosition default_value)
{
    if (left_hash != right_hash) return 0;
    if (left == right) return 1;
    for (uint32_t slot = 0; slot < slot_count; slot++)
	if (onibi_semantic_register_read(arena, left, slot, default_value) !=
	    onibi_semantic_register_read(arena, right, slot, default_value))
	    return 0;
    return 1;
}

static int
onibi_semantic_capture_file_equal(OnibiSemanticArena *arena,
				  const OnibiSemanticCaptureFile *left,
				  const OnibiSemanticCaptureFile *right)
{
    if (left->hash != right->hash) return 0;
    if (left->root == right->root) return 1;
    for (size_t i = 0; i < arena->live_capture_count; i++) {
	uint32_t slot = arena->live_capture_slots[i];
	if (onibi_semantic_register_read(arena, left->root, slot, -1) !=
	    onibi_semantic_register_read(arena, right->root, slot, -1))
	    return 0;
    }
    return 1;
}

static int
onibi_semantic_tags_equal(const OnibiSemanticArena *arena, uint32_t left,
			  uint32_t right)
{
    if (left == right) return 1;
    uint64_t left_hash = left == UINT32_MAX ? UINT64_C(0x84222325cbf29ce4)
			 : left < arena->tag_count ? arena->tags[left].hash
						   : 0;
    uint64_t right_hash = right == UINT32_MAX ? UINT64_C(0x84222325cbf29ce4)
			  : right < arena->tag_count ? arena->tags[right].hash
						     : 0;
    if (left_hash != right_hash) return 0;
    while (left != UINT32_MAX && right != UINT32_MAX) {
	if (left >= arena->tag_count || right >= arena->tag_count) return 0;
	const OnibiSemanticTagEvent *a = &arena->tags[left];
	const OnibiSemanticTagEvent *b = &arena->tags[right];
	if (a->slot != b->slot || a->position != b->position) return 0;
	left = a->parent;
	right = b->parent;
    }
    return left == right;
}

static int
onibi_semantic_calls_equal(const OnibiSemanticArena *arena, uint32_t left,
			   uint32_t right)
{
    if (left == right) return 1;
    if ((left == UINT32_MAX ? UINT64_C(0xcbf29ce484222325)
	 : left < arena->call_count
	     ? arena->calls[left].hash
	     : 0) != (right == UINT32_MAX	  ? UINT64_C(0xcbf29ce484222325)
		      : right < arena->call_count ? arena->calls[right].hash
						  : 0))
	return 0;
    while (left != UINT32_MAX && right != UINT32_MAX) {
	if (left >= arena->call_count || right >= arena->call_count) return 0;
	const OnibiOwnedCallFrame *a = &arena->calls[left];
	const OnibiOwnedCallFrame *b = &arena->calls[right];
	if (a->frame.subprogram_id != b->frame.subprogram_id ||
	    a->frame.continuation != b->frame.continuation ||
	    a->frame.recursion_depth != b->frame.recursion_depth ||
	    !onibi_semantic_tags_equal(arena, a->frame.tag_history,
				       b->frame.tag_history))
	    return 0;
	left = a->parent;
	right = b->parent;
    }
    return left == right;
}

static uint64_t
onibi_semantic_calls_hash(const OnibiSemanticArena *arena, uint32_t root)
{
    if (root == UINT32_MAX) return UINT64_C(0xcbf29ce484222325);
    return root < arena->call_count ? arena->calls[root].hash : 0;
}

static int
onibi_semantic_scopes_equal(const OnibiSemanticArena *arena,
			    const OnibiSemanticScope *nodes, size_t count,
			    uint32_t left, uint32_t right)
{
    if (left == right) return 1;
    if ((left == UINT32_MAX ? UINT64_C(0x84222325cbf29ce4)
	 : left < count
	     ? nodes[left].hash
	     : 0) != (right == UINT32_MAX ? UINT64_C(0x84222325cbf29ce4)
		      : right < count	  ? nodes[right].hash
					  : 0))
	return 0;
    while (left != UINT32_MAX && right != UINT32_MAX) {
	if (left >= count || right >= count) return 0;
	const OnibiSemanticScope *a = &nodes[left];
	const OnibiSemanticScope *b = &nodes[right];
	if (a->subprogram_id != b->subprogram_id || a->begin != b->begin ||
	    a->end != b->end || a->flags != b->flags ||
	    !onibi_semantic_tags_equal(arena, a->tag_history, b->tag_history))
	    return 0;
	left = a->parent;
	right = b->parent;
    }
    return left == right;
}

static uint64_t
onibi_semantic_scopes_hash(const OnibiSemanticArena *arena,
			   const OnibiSemanticScope *nodes, size_t count,
			   uint32_t root)
{
    (void)arena;
    if (root == UINT32_MAX) return UINT64_C(0x84222325cbf29ce4);
    return root < count ? nodes[root].hash : 0;
}

static uint64_t
onibi_dynamic_thread_key_hash(OnibiSemanticArena *arena,
			      const OnibiDynamicThreadKey *key)
{
    arena->key_hash_count++;
    const OnibiSemanticState *state = &key->semantic;
    uint64_t hash =
	onibi_semantic_hash_value(UINT64_C(0xcbf29ce484222325), key->state_id);
    hash = onibi_semantic_hash_value(hash, (uint64_t)key->position);
    hash = onibi_semantic_hash_value(hash, (uint64_t)state->reported_start);
    hash = onibi_semantic_hash_value(hash, state->semantic_captures.hash);
    hash = onibi_semantic_hash_value(hash, state->counters.hash);
    hash = onibi_semantic_hash_value(hash, state->progress.hash);
    hash = onibi_semantic_hash_value(
	hash, onibi_semantic_calls_hash(arena, state->calls.root));
    hash = onibi_semantic_hash_value(
	hash,
	onibi_semantic_scopes_hash(arena, arena->atomic, arena->atomic_count,
				   state->atomic.root));
    hash = onibi_semantic_hash_value(
	hash,
	onibi_semantic_scopes_hash(arena, arena->absence, arena->absence_count,
				   state->absence.root));
    return hash;
}

static int
onibi_dynamic_thread_key_equal(OnibiSemanticArena *arena,
			       const OnibiDynamicThreadKey *left,
			       const OnibiDynamicThreadKey *right)
{
    const OnibiSemanticState *a = &left->semantic;
    const OnibiSemanticState *b = &right->semantic;
    return left->hash == right->hash && left->state_id == right->state_id &&
	   left->position == right->position &&
	   a->reported_start == b->reported_start &&
	   a->semantic_captures.slot_count == b->semantic_captures.slot_count &&
	   a->counters.slot_count == b->counters.slot_count &&
	   a->progress.slot_count == b->progress.slot_count &&
	   a->calls.depth == b->calls.depth &&
	   a->atomic.depth == b->atomic.depth &&
	   a->absence.depth == b->absence.depth &&
	   onibi_semantic_capture_file_equal(arena, &a->semantic_captures,
					     &b->semantic_captures) &&
	   onibi_semantic_register_file_equal(
	       arena, a->counters.root, b->counters.root, a->counters.hash,
	       b->counters.hash, a->counters.slot_count, 0) &&
	   onibi_semantic_register_file_equal(
	       arena, a->progress.root, b->progress.root, a->progress.hash,
	       b->progress.hash, a->progress.slot_count, -1) &&
	   onibi_semantic_calls_equal(arena, a->calls.root, b->calls.root) &&
	   onibi_semantic_scopes_equal(arena, arena->atomic,
				       arena->atomic_count, a->atomic.root,
				       b->atomic.root) &&
	   onibi_semantic_scopes_equal(arena, arena->absence,
				       arena->absence_count, a->absence.root,
				       b->absence.root);
}

static void
onibi_dynamic_key_set_grow(OnibiSemanticArena *arena)
{
    size_t capacity = arena->key_capacity == 0 ? 64U : arena->key_capacity * 2U;
    if (capacity < arena->key_capacity ||
	capacity > SIZE_MAX / sizeof(*arena->key_buckets))
	rb_memerror();
    OnibiDynamicKeyBucket *buckets = ruby_xcalloc(capacity, sizeof(*buckets));
    for (size_t i = 0; i < arena->key_capacity; i++) {
	if (arena->key_buckets[i].generation != arena->key_generation) continue;
	size_t index = (size_t)arena->key_buckets[i].key.hash & (capacity - 1U);
	while (buckets[index].generation == arena->key_generation)
	    index = (index + 1U) & (capacity - 1U);
	buckets[index] = arena->key_buckets[i];
    }
    ruby_xfree(arena->key_buckets);
    arena->key_buckets = buckets;
    arena->key_capacity = capacity;
}

static int
onibi_dynamic_key_seen(OnibiSemanticArena *arena, uint32_t state_id,
		       OnigPosition position,
		       const OnibiSemanticState *semantic)
{
    if (arena->key_capacity == 0 ||
	arena->key_count >= arena->key_capacity - arena->key_capacity / 4U)
	onibi_dynamic_key_set_grow(arena);
    OnibiDynamicThreadKey key = {state_id, position, *semantic, 0};
    key.hash = onibi_dynamic_thread_key_hash(arena, &key);
    size_t index = (size_t)key.hash & (arena->key_capacity - 1U);
    for (;;) {
	OnibiDynamicKeyBucket *bucket = &arena->key_buckets[index];
	if (bucket->generation != arena->key_generation) {
	    bucket->key = key;
	    bucket->generation = arena->key_generation;
	    arena->key_count++;
	    return 0;
	}
	if (bucket->key.hash == key.hash &&
	    onibi_dynamic_thread_key_equal(arena, &bucket->key, &key))
	    return 1;
	index = (index + 1U) & (arena->key_capacity - 1U);
    }
}

static void
onibi_dynamic_stack_push(OnibiSemanticArena *arena, OnibiDynamicFrame frame)
{
    arena->frames = onibi_semantic_arena_reserve(
	arena->frames, &arena->frame_capacity, arena->frame_count,
	sizeof(*arena->frames));
    arena->frames[arena->frame_count++] = frame;
}

typedef struct {
    size_t register_count;
    size_t tag_count;
    size_t call_count;
    size_t atomic_count;
    size_t absence_count;
} OnibiSemanticCheckpoint;

static OnibiActionResult
onibi_apply_action_program(const OnibiRSeqView *view, const OnibiREdge *edge,
			   VALUE str, long pos, long search_origin,
			   rb_encoding *encoding, OnibiEncodingMode mode,
			   OnibiSemanticArena *arena,
			   const OnibiSemanticState *predecessor,
			   OnibiSemanticState *successor)
{
    OnibiSemanticCheckpoint checkpoint = {
	arena->register_count, arena->tag_count, arena->call_count,
	arena->atomic_count, arena->absence_count};
    OnibiSemanticState working = *predecessor;
    if (edge->action_offset == 0) {
	*successor = working;
	return ONIBI_ACTION_SUCCESS;
    }
    uint32_t index = edge->action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
    for (; index < view->header->action_count; index++) {
	const OnibiRAction *action = &view->actions[index];
	if (action->op == ONIBI_RA_END) {
	    *successor = working;
	    return ONIBI_ACTION_SUCCESS;
	}
	if (action->op == ONIBI_RA_CAPTURE) {
	    if (action->arg16 >= working.semantic_captures.slot_count)
		goto fail;
	    onibi_semantic_capture_write(arena, &working.semantic_captures,
					 action->arg16, pos);
	    working.tag_history = onibi_semantic_tag_append(
		arena, working.tag_history, action->arg16, pos);
	    continue;
	}
	if (action->op == ONIBI_RA_TEST_CAPTURE) {
	    uint32_t begin = (uint32_t)action->arg16 * 2U;
	    if (begin + 1U >= working.semantic_captures.slot_count) goto fail;
	    int set =
		onibi_semantic_register_read(
		    arena, working.semantic_captures.root, begin, -1) >= 0 &&
		onibi_semantic_register_read(
		    arena, working.semantic_captures.root, begin + 1U, -1) >= 0;
	    if ((action->flags == ONIBI_RA_TEST_CAPTURE_SET && !set) ||
		(action->flags == ONIBI_RA_TEST_CAPTURE_UNSET && set))
		goto fail;
	    continue;
	}
	if (action->op == ONIBI_RA_MATCH_RESET) {
	    working.reported_start = pos;
	    continue;
	}
	if (action->op == ONIBI_RA_PROGRESS) {
	    if (action->arg16 >= working.progress.slot_count) goto fail;
	    if (onibi_semantic_register_read(arena, working.progress.root,
					     action->arg16, -1) == pos)
		goto fail;
	    onibi_semantic_progress_write(arena, &working.progress,
					  action->arg16, pos);
	    continue;
	}
	if (action->op == ONIBI_RA_COUNTER_SET ||
	    action->op == ONIBI_RA_COUNTER_ADD ||
	    action->op == ONIBI_RA_COUNTER_TEST) {
	    if (action->arg16 >= working.counters.slot_count) goto fail;
	    OnigPosition current = onibi_semantic_register_read(
		arena, working.counters.root, action->arg16, 0);
	    if (action->op == ONIBI_RA_COUNTER_SET)
		onibi_semantic_counter_write(arena, &working.counters,
					     action->arg16,
					     (OnigPosition)action->arg32);
	    else if (action->op == ONIBI_RA_COUNTER_ADD)
		onibi_semantic_counter_write(arena, &working.counters,
					     action->arg16, current + 1);
	    else {
		int hit = action->flags == ONIBI_RA_COUNTER_GE
			      ? current >= (OnigPosition)action->arg32
			      : current < (OnigPosition)action->arg32;
		if (!hit) goto fail;
	    }
	    continue;
	}
	if (action->op != ONIBI_RA_ASSERT_POSITION) goto fail;
	if (!onibi_rseq_position_assertion_hit((OnibiRAssertKind)action->arg16,
					       str, pos, search_origin,
					       encoding, mode))
	    goto fail;
    }
fail:
    arena->register_count = checkpoint.register_count;
    arena->tag_count = checkpoint.tag_count;
    arena->call_count = checkpoint.call_count;
    arena->atomic_count = checkpoint.atomic_count;
    arena->absence_count = checkpoint.absence_count;
    return ONIBI_ACTION_FAIL;
}

/* This private hook tests the native state contract.  Ruby hashes are only
 * reports.  Native state remains the semantic source. */
static VALUE
onibi_semantic_state_diagnostics(VALUE self, VALUE scenario_value)
{
    (void)self;
    ID scenario = rb_to_id(scenario_value);
    OnibiSemanticArena arena;
    memset(&arena, 0, sizeof(arena));
    VALUE subject = rb_str_new_cstr("abc");
    rb_encoding *encoding = rb_enc_get(subject);
    OnibiSemanticState predecessor =
	onibi_semantic_state_initial(&arena, 1, 2, 1, 1);
    OnibiSemanticState sibling = predecessor;
    VALUE result = rb_hash_new();

    if (scenario == rb_intern("transaction_success") ||
	scenario == rb_intern("transaction_failure")) {
	OnibiRAction actions[6] = {
	    {ONIBI_RA_CAPTURE, 0, 0, 0},     {ONIBI_RA_MATCH_RESET, 0, 0, 0},
	    {ONIBI_RA_COUNTER_SET, 0, 0, 7}, {ONIBI_RA_PROGRESS, 0, 0, 0},
	    {ONIBI_RA_END, 0, 0, 0},	     {ONIBI_RA_END, 0, 0, 0},
	};
	uint32_t action_count = 5;
	if (scenario == rb_intern("transaction_failure")) {
	    actions[4] = (OnibiRAction){ONIBI_RA_ASSERT_POSITION, 0,
					ONIBI_RAP_END_BUFFER, 0};
	    action_count = 6;
	}
	OnibiRSeqHeader header;
	memset(&header, 0, sizeof(header));
	header.action_count = action_count;
	OnibiRSeqView view;
	memset(&view, 0, sizeof(view));
	view.header = &header;
	view.actions = actions;
	OnibiREdge edge = {ONIBI_ACCEPT_STATE, sizeof(OnibiRAction)};
	OnibiSemanticState successor = predecessor;
	OnibiActionResult status = onibi_apply_action_program(
	    &view, &edge, subject, 2, 0, encoding, ONIBI_ENC_ASCII_7BIT, &arena,
	    &predecessor, &successor);
	rb_hash_aset(result, ID2SYM(rb_intern("success")),
		     status == ONIBI_ACTION_SUCCESS ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("predecessor_reported_start")),
		     LONG2NUM(predecessor.reported_start));
	rb_hash_aset(result, ID2SYM(rb_intern("sibling_reported_start")),
		     LONG2NUM(sibling.reported_start));
	rb_hash_aset(result, ID2SYM(rb_intern("successor_reported_start")),
		     LONG2NUM(successor.reported_start));
	rb_hash_aset(result, ID2SYM(rb_intern("predecessor_capture")),
		     LONG2NUM(onibi_semantic_register_read(
			 &arena, predecessor.semantic_captures.root, 0, -1)));
	rb_hash_aset(result, ID2SYM(rb_intern("sibling_capture")),
		     LONG2NUM(onibi_semantic_register_read(
			 &arena, sibling.semantic_captures.root, 0, -1)));
	rb_hash_aset(result, ID2SYM(rb_intern("successor_capture")),
		     LONG2NUM(onibi_semantic_register_read(
			 &arena, successor.semantic_captures.root, 0, -1)));
	rb_hash_aset(result, ID2SYM(rb_intern("successor_counter")),
		     LONG2NUM(onibi_semantic_register_read(
			 &arena, successor.counters.root, 0, 0)));
	rb_hash_aset(result, ID2SYM(rb_intern("successor_progress")),
		     LONG2NUM(onibi_semantic_register_read(
			 &arena, successor.progress.root, 0, -1)));
	rb_hash_aset(result, ID2SYM(rb_intern("register_delta_count")),
		     SIZET2NUM(arena.register_count));
	rb_hash_aset(result, ID2SYM(rb_intern("tag_event_count")),
		     SIZET2NUM(arena.tag_count));
	rb_hash_aset(result, ID2SYM(rb_intern("full_file_copies")), INT2NUM(0));
	rb_hash_aset(result, ID2SYM(rb_intern("published_reported_start")),
		     LONG2NUM(status == ONIBI_ACTION_SUCCESS
				  ? successor.reported_start
				  : predecessor.reported_start));
	onibi_semantic_arena_release(&arena);
	return result;
    }

    if (scenario == rb_intern("dynamic_key")) {
	onibi_semantic_live_captures_begin(&arena, 1024);
	onibi_semantic_live_capture_add(&arena, 0);
	predecessor = onibi_semantic_state_initial(&arena, 1, 2048, 1024, 1024);
	OnibiDynamicThreadKey base = {3, 5, predecessor, 0};
	size_t hash_read_start = arena.register_read_count;
	base.hash = onibi_dynamic_thread_key_hash(&arena, &base);
	size_t key_hash_register_reads =
	    arena.register_read_count - hash_read_start;
	const char *names[] = {"state",	   "position", "reported_start",
			       "captures", "counters", "progress",
			       "calls",	   "atomic",   "absence"};
	OnibiDynamicThreadKey variants[10];
	for (size_t i = 0; i < 10; i++)
	    variants[i] = base;
	variants[0].state_id++;
	variants[1].position++;
	variants[2].semantic.reported_start++;
	onibi_semantic_capture_write(
	    &arena, &variants[3].semantic.semantic_captures, 0, 9);
	size_t update_read_start = arena.register_read_count;
	onibi_semantic_counter_write(&arena, &variants[4].semantic.counters, 0,
				     9);
	size_t one_slot_update_register_reads =
	    arena.register_read_count - update_read_start;
	onibi_semantic_progress_write(&arena, &variants[5].semantic.progress, 0,
				      9);
	OnibiCallFrame call = {1, 2, UINT32_MAX, 1, UINT32_MAX};
	variants[6].semantic.calls.root =
	    onibi_semantic_call_push(&arena, UINT32_MAX, &call);
	variants[6].semantic.calls.depth = 1;
	variants[7].semantic.atomic.root = onibi_semantic_scope_push(
	    &arena, &arena.atomic, &arena.atomic_count, &arena.atomic_capacity,
	    UINT32_MAX, 1, 2, 3, UINT32_MAX, 4, ONIBI_SEMANTIC_HASH_ATOMIC);
	variants[7].semantic.atomic.depth = 1;
	variants[8].semantic.absence.root = onibi_semantic_scope_push(
	    &arena, &arena.absence, &arena.absence_count,
	    &arena.absence_capacity, UINT32_MAX, 1, 2, 3, UINT32_MAX, 4,
	    ONIBI_SEMANTIC_HASH_ABSENCE);
	variants[8].semantic.absence.depth = 1;
	variants[9].semantic.tag_history =
	    onibi_semantic_tag_append(&arena, UINT32_MAX, 0, 9);
	VALUE equality = rb_hash_new();
	VALUE hashes = rb_hash_new();
	for (size_t i = 0; i < 9; i++) {
	    variants[i].hash =
		onibi_dynamic_thread_key_hash(&arena, &variants[i]);
	    rb_hash_aset(
		equality, ID2SYM(rb_intern(names[i])),
		onibi_dynamic_thread_key_equal(&arena, &base, &variants[i])
		    ? Qfalse
		    : Qtrue);
	    rb_hash_aset(hashes, ID2SYM(rb_intern(names[i])),
			 variants[i].hash != base.hash ? Qtrue : Qfalse);
	}
	OnibiSemanticState equal_state = predecessor;
	onibi_semantic_capture_write(&arena, &equal_state.semantic_captures, 0,
				     9);
	onibi_semantic_capture_write(&arena, &equal_state.semantic_captures, 0,
				     -1);
	onibi_semantic_counter_write(&arena, &equal_state.counters, 0, 9);
	onibi_semantic_counter_write(&arena, &equal_state.counters, 0, 0);
	onibi_semantic_progress_write(&arena, &equal_state.progress, 0, 9);
	onibi_semantic_progress_write(&arena, &equal_state.progress, 0, -1);
	OnibiDynamicThreadKey equal_key = {3, 5, equal_state, 0};
	equal_key.hash = onibi_dynamic_thread_key_hash(&arena, &equal_key);
	rb_hash_aset(result, ID2SYM(rb_intern("distinguishes")), equality);
	rb_hash_aset(result, ID2SYM(rb_intern("hash_distinguishes")), hashes);
	rb_hash_aset(result, ID2SYM(rb_intern("equal_values_equal")),
		     onibi_dynamic_thread_key_equal(&arena, &base, &equal_key)
			 ? Qtrue
			 : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("equal_values_hash_equal")),
		     base.hash == equal_key.hash ? Qtrue : Qfalse);
	rb_hash_aset(
	    result, ID2SYM(rb_intern("different_delta_histories")),
	    equal_state.semantic_captures.root !=
			predecessor.semantic_captures.root &&
		    equal_state.counters.root != predecessor.counters.root &&
		    equal_state.progress.root != predecessor.progress.root
		? Qtrue
		: Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("key_hash_register_reads")),
		     SIZET2NUM(key_hash_register_reads));
	rb_hash_aset(result, ID2SYM(rb_intern("key_hash_count")),
		     SIZET2NUM(arena.key_hash_count));
	rb_hash_aset(result, ID2SYM(rb_intern("cached_file_hash_changed")),
		     predecessor.counters.hash !=
			     variants[4].semantic.counters.hash
			 ? Qtrue
			 : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("one_slot_key_hash_changed")),
		     base.hash != variants[4].hash ? Qtrue : Qfalse);
	rb_hash_aset(result,
		     ID2SYM(rb_intern("one_slot_update_register_reads")),
		     SIZET2NUM(one_slot_update_register_reads));
	variants[9].hash = onibi_dynamic_thread_key_hash(&arena, &variants[9]);
	rb_hash_aset(
	    result, ID2SYM(rb_intern("output_history_ignored")),
	    onibi_dynamic_thread_key_equal(&arena, &base, &variants[9]) &&
		    base.hash == variants[9].hash
		? Qtrue
		: Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("capture_slot_count")),
		     UINT2NUM(predecessor.semantic_captures.slot_count));
	rb_hash_aset(result, ID2SYM(rb_intern("counter_slot_count")),
		     UINT2NUM(predecessor.counters.slot_count));
	rb_hash_aset(result, ID2SYM(rb_intern("register_delta_count")),
		     SIZET2NUM(arena.register_count));
	VALUE representations = rb_ary_new_from_args(
	    7, ID2SYM(rb_intern("captures")), ID2SYM(rb_intern("counters")),
	    ID2SYM(rb_intern("progress")), ID2SYM(rb_intern("calls")),
	    ID2SYM(rb_intern("atomic")), ID2SYM(rb_intern("absence")),
	    ID2SYM(rb_intern("tag_history")));
	rb_hash_aset(result, ID2SYM(rb_intern("representations")),
		     representations);
	onibi_semantic_arena_release(&arena);
	return result;
    }

    if (scenario == rb_intern("dedup_growth")) {
	enum { THREAD_COUNT = 2048 };
	onibi_semantic_arena_reset(&arena);
	onibi_semantic_live_captures_begin(&arena, 1);
	onibi_semantic_live_capture_add(&arena, 0);
	predecessor = onibi_semantic_state_initial(&arena, 1, 2, 1, 1);
	size_t inserted = 0;
	OnibiSemanticState last = predecessor;
	for (uint32_t i = 0; i < THREAD_COUNT; i++) {
	    OnibiSemanticState semantic = predecessor;
	    onibi_semantic_counter_write(&arena, &semantic.counters, 0,
					 (OnigPosition)i + 1);
	    if (!onibi_dynamic_key_seen(&arena, 7, 11, &semantic)) inserted++;
	    onibi_dynamic_stack_push(&arena,
				     (OnibiDynamicFrame){7, 11, semantic});
	    last = semantic;
	}
	int stack_valid = arena.frame_count == THREAD_COUNT;
	int same_location = stack_valid;
	for (uint32_t i = 0; i < THREAD_COUNT && (stack_valid || same_location);
	     i++) {
	    if (arena.frames[i].state != 7 || arena.frames[i].position != 11)
		same_location = 0;
	    if (onibi_semantic_register_read(
		    &arena, arena.frames[i].semantic.counters.root, 0, 0) !=
		(OnigPosition)i + 1)
		stack_valid = 0;
	}
	int duplicate_seen = onibi_dynamic_key_seen(&arena, 7, 11, &last);
	rb_hash_aset(result, ID2SYM(rb_intern("requested")),
		     UINT2NUM(THREAD_COUNT));
	rb_hash_aset(result, ID2SYM(rb_intern("inserted")),
		     SIZET2NUM(inserted));
	rb_hash_aset(result, ID2SYM(rb_intern("key_count")),
		     SIZET2NUM(arena.key_count));
	rb_hash_aset(result, ID2SYM(rb_intern("key_capacity")),
		     SIZET2NUM(arena.key_capacity));
	rb_hash_aset(result, ID2SYM(rb_intern("duplicate_seen")),
		     duplicate_seen ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("same_location")),
		     same_location ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("frame_count")),
		     SIZET2NUM(arena.frame_count));
	rb_hash_aset(result, ID2SYM(rb_intern("frame_capacity")),
		     SIZET2NUM(arena.frame_capacity));
	rb_hash_aset(result, ID2SYM(rb_intern("stack_valid")),
		     stack_valid ? Qtrue : Qfalse);
	onibi_semantic_arena_release(&arena);
	return result;
    }

    onibi_semantic_arena_release(&arena);
    rb_raise(rb_eArgError, "unknown semantic-state diagnostic scenario");
}

static int
onibi_rseq_backtracking_match(VALUE rseq, const OnibiRSeqView *cached_view,
			      VALUE str, long start, long search_origin,
			      long *matched_end,
			      OnibiSemanticState *accepted_state,
			      OnibiSemanticArena *semantic_arena,
			      unsigned char *class_stack,
			      size_t class_stack_capacity)
{
    onibi_diagnostics.dfs++;
    OnibiRSeqView local_view;
    const OnibiRSeqView *view = cached_view;
    if (!view) {
	if (!onibi_rseq_view_init(rseq, &local_view)) return -1;
	onibi_rseq_view_prepare(&local_view);
	view = &local_view;
	onibi_semantic_live_captures_prepare(semantic_arena, view);
    }
    const OnibiRSeqHeader *header = view->header;
    if (!view->regular_capable) return -1;
    if (header->capture_count > UINT32_MAX / 2U) return -1;
    rb_encoding *encoding = rb_enc_get(str);
    OnibiEncodingMode encoding_mode = onibi_encoding_mode_for(str, encoding);
    const OnibiRState *states = view->states;
    const OnibiREdge *edges = view->edges;
    OnibiSemanticArena *arena = semantic_arena;
    onibi_semantic_arena_reset(arena);
    OnibiSemanticState initial = onibi_semantic_state_initial(
	arena, start, header->capture_count * 2U, header->counter_count,
	header->counter_count);

    for (uint32_t i = header->start_edge_count; i > 0; i--) {
	const OnibiREdge *edge = &edges[header->start_edge_base + (i - 1U)];
	OnibiSemanticState branch;
	if (onibi_apply_action_program(view, edge, str, start, search_origin,
				       encoding, encoding_mode, arena, &initial,
				       &branch) == ONIBI_ACTION_FAIL)
	    continue;
	if (edge->destination == ONIBI_ACCEPT_STATE) {
	    *matched_end = start;
	    *accepted_state = branch;
	    return 1;
	}
	if (edge->destination < header->state_count)
	    onibi_dynamic_stack_push(
		arena, (OnibiDynamicFrame){edge->destination, start, branch});
    }

    while (arena->frame_count > 0) {
	OnibiDynamicFrame frame = arena->frames[--arena->frame_count];
	if (frame.position < 0 || frame.position > RSTRING_LEN(str) ||
	    frame.state >= header->state_count)
	    continue;
	if (onibi_dynamic_key_seen(arena, frame.state, frame.position,
				   &frame.semantic))
	    continue;
	const OnibiRState *state = &states[frame.state];
	long next_position = frame.position;
	int hit = 1;
	if (state->op == 0) {
	    if (frame.semantic.calls.depth == 0) {
		*matched_end = frame.position;
		*accepted_state = frame.semantic;
		return 1;
	    }
	    uint32_t call_id = frame.semantic.calls.root;
	    if (call_id >= arena->call_count) return -1;
	    const OnibiOwnedCallFrame *call = &arena->calls[call_id];
	    uint32_t edge_index = call->frame.continuation;
	    if (edge_index >= header->start_edge_base) return -1;
	    OnibiSemanticState returned = frame.semantic;
	    returned.calls.root = call->parent;
	    returned.calls.depth--;
	    OnibiSemanticState branch;
	    const OnibiREdge *edge = &edges[edge_index];
	    if (onibi_apply_action_program(view, edge, str, frame.position,
					   search_origin, encoding,
					   encoding_mode, arena, &returned,
					   &branch) == ONIBI_ACTION_FAIL)
		continue;
	    if (edge->destination == ONIBI_ACCEPT_STATE) {
		*matched_end = frame.position;
		*accepted_state = branch;
		return 1;
	    }
	    if (edge->destination < header->state_count)
		onibi_dynamic_stack_push(
		    arena, (OnibiDynamicFrame){edge->destination,
					       frame.position, branch});
	    continue;
	}
	if (state->op == ONIBI_RS_CALL) {
	    const OnibiSubprogramDesc *subprogram =
		&view->subprograms[state->payload];
	    for (uint32_t e = state->edge_count; e > 0; e--) {
		for (uint32_t s = subprogram->entry_edge_count; s > 0; s--) {
		    const OnibiREdge *entry =
			&edges[subprogram->entry_edge_base + (s - 1U)];
		    OnibiSemanticState branch;
		    if (onibi_apply_action_program(
			    view, entry, str, frame.position, search_origin,
			    encoding, encoding_mode, arena, &frame.semantic,
			    &branch) == ONIBI_ACTION_FAIL)
			continue;
		    OnibiCallFrame call = {
			state->payload, state->edge_base + (e - 1U),
			branch.tag_history, branch.calls.depth + 1U,
			branch.calls.root};
		    branch.calls.root = onibi_semantic_call_push(
			arena, branch.calls.root, &call);
		    branch.calls.depth++;
		    if (entry->destination < header->state_count)
			onibi_dynamic_stack_push(
			    arena, (OnibiDynamicFrame){entry->destination,
						       frame.position, branch});
		}
	    }
	    continue;
	}
	if (state->op == ONIBI_RS_GRAPHEME) {
	    long width = onibi_grapheme_width(str, frame.position);
	    if (width <= 0)
		hit = 0;
	    else
		next_position += width;
	}
	else if (state->op == ONIBI_RS_BACKREF) {
	    uint32_t begin = state->payload * 2U;
	    OnigPosition capture_begin = onibi_semantic_register_read(
		arena, frame.semantic.semantic_captures.root, begin, -1);
	    OnigPosition capture_end = onibi_semantic_register_read(
		arena, frame.semantic.semantic_captures.root, begin + 1U, -1);
	    if (begin + 1U >= frame.semantic.semantic_captures.slot_count ||
		capture_begin < 0 || capture_end < capture_begin)
		hit = 0;
	    else {
		long length = capture_end - capture_begin;
		if (frame.position + length > RSTRING_LEN(str) ||
		    memcmp(RSTRING_PTR(str) + frame.position,
			   RSTRING_PTR(str) + capture_begin,
			   (size_t)length) != 0)
		    hit = 0;
		else
		    next_position += length;
	    }
	}
	else if (state->op == ONIBI_RS_CHAR || state->op == ONIBI_RS_CLASS ||
		 state->op == ONIBI_RS_ANY) {
	    hit = onibi_rseq_consume_character(
		view, state, str, frame.position, encoding, encoding_mode,
		&next_position, class_stack, class_stack_capacity);
	}
	else
	    hit = 0;
	if (!hit) continue;
	for (uint32_t e = state->edge_count; e > 0; e--) {
	    const OnibiREdge *edge = &edges[state->edge_base + (e - 1U)];
	    OnibiSemanticState branch;
	    if (onibi_apply_action_program(
		    view, edge, str, next_position, search_origin, encoding,
		    encoding_mode, arena, &frame.semantic,
		    &branch) == ONIBI_ACTION_FAIL)
		continue;
	    if (edge->destination == ONIBI_ACCEPT_STATE) {
		*matched_end = next_position;
		*accepted_state = branch;
		return 1;
	    }
	    if (edge->destination < header->state_count)
		onibi_dynamic_stack_push(
		    arena, (OnibiDynamicFrame){edge->destination, next_position,
					       branch});
	}
    }
    return 0;
}

/* Regular execution uses ordered frontiers.  It has no DFS stack and keeps
 * one membership bitset for each frontier.  Dynamic programs stay in the
 * isolated compatibility walker above. */
typedef struct {
    uint32_t parent;
    uint32_t slot;
    long position;
} onibi_regular_tag_event_t;

typedef struct {
    size_t checkpoint;
    uint32_t history;
} onibi_regular_action_transaction_t;

static onibi_regular_tag_event_t *
onibi_regular_tag_events(OnibiTagArena *arena)
{
    return (onibi_regular_tag_event_t *)arena->data;
}

static void
onibi_regular_tag_arena_grow(OnibiTagArena *arena)
{
    size_t capacity = arena->capacity == 0 ? 256U : arena->capacity * 2U;
    if (capacity < arena->capacity ||
	capacity > SIZE_MAX / sizeof(onibi_regular_tag_event_t))
	rb_memerror();
    arena->data = ruby_xrealloc(arena->data,
				capacity * sizeof(onibi_regular_tag_event_t));
    arena->capacity = capacity;
}

static uint32_t
onibi_regular_tag_append(OnibiTagArena *arena, uint32_t parent, uint32_t slot,
			 long position)
{
    if (arena->count >= UINT32_MAX) rb_memerror();
    if (arena->count == arena->capacity) onibi_regular_tag_arena_grow(arena);
    uint32_t id = (uint32_t)arena->count++;
    onibi_regular_tag_events(arena)[id] =
	(onibi_regular_tag_event_t){parent, slot, position};
    onibi_diagnostics.tag_events++;
    return id;
}

static int
onibi_regular_apply_actions(const OnibiRSeqView *view, const OnibiREdge *edge,
			    VALUE str, long position, long search_origin,
			    rb_encoding *encoding, OnibiEncodingMode mode,
			    uint32_t parent, uint32_t capture_slots,
			    int capture_mode, OnibiTagArena *arena,
			    uint32_t *history)
{
    onibi_regular_action_transaction_t transaction = {arena->count, parent};
    if (edge->action_offset == 0) {
	*history = parent;
	return 1;
    }
    uint32_t index = edge->action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
    for (; index < view->header->action_count; index++) {
	const OnibiRAction *action = &view->actions[index];
	if (action->op == ONIBI_RA_END) {
	    *history = transaction.history;
	    return 1;
	}
	if (action->op == ONIBI_RA_ASSERT_POSITION &&
	    (action->arg16 == ONIBI_RAP_WORD_BOUNDARY ||
	     action->arg16 == ONIBI_RAP_NONWORD_BOUNDARY)) {
	    if (!onibi_rseq_position_assertion_hit(
		    (OnibiRAssertKind)action->arg16, str, position,
		    search_origin, encoding, mode)) {
		arena->count = transaction.checkpoint;
		return 0;
	    }
	    continue;
	}
	if (action->op != ONIBI_RA_CAPTURE || action->arg16 >= capture_slots) {
	    arena->count = transaction.checkpoint;
	    return 0;
	}
	if (capture_mode)
	    transaction.history = onibi_regular_tag_append(
		arena, transaction.history, action->arg16, position);
    }
    arena->count = transaction.checkpoint;
    return 0;
}

static void
onibi_regular_materialize_tags(const OnibiTagArena *arena, uint32_t history,
			       long *captures, uint32_t capture_slots)
{
    const onibi_regular_tag_event_t *events =
	(const onibi_regular_tag_event_t *)arena->data;
    for (uint32_t i = 0; i < capture_slots; i++)
	captures[i] = -1;
    while (history != UINT32_MAX && history < arena->count) {
	const onibi_regular_tag_event_t *event = &events[history];
	if (event->slot < capture_slots && captures[event->slot] < 0)
	    captures[event->slot] = event->position;
	history = event->parent;
    }
}

static int
onibi_regular_accept_history(const OnibiRSeqView *view,
			     const OnibiRState *state, VALUE str, long position,
			     long search_origin, rb_encoding *encoding,
			     OnibiEncodingMode mode, uint32_t parent,
			     uint32_t capture_slots, int capture_mode,
			     OnibiTagArena *arena, uint32_t *history)
{
    for (uint32_t i = 0; i < state->edge_count; i++) {
	const OnibiREdge *edge = &view->edges[state->edge_base + i];
	if (edge->destination != ONIBI_ACCEPT_STATE) continue;
	return onibi_regular_apply_actions(
	    view, edge, str, position, search_origin, encoding, mode, parent,
	    capture_slots, capture_mode, arena, history);
    }
    *history = parent;
    return 1;
}

static int
onibi_rseq_regular_match(OnibiExecCtx *ctx)
{
    const OnibiRSeqView *view = ctx->view;
    const OnibiRSeqHeader *header = view->header;
    if (!view->regular_capable) return -2;
    uint32_t count = header->state_count;
    if (count == 0) return 0;
    VALUE str = ctx->subject;
    long start = ctx->attempt_start;
    uint32_t capture_slots = header->capture_count * 2U;
    int capture_mode =
	onibi_regular_capture_result != NULL && capture_slots != 0;
    ctx->tags.count = 0;
    size_t bits_size = ((size_t)count + 7U) / 8U;
    uint32_t *current = ALLOCA_N(uint32_t, count);
    uint32_t *next = ALLOCA_N(uint32_t, count);
    uint32_t *current_histories =
	capture_mode ? ALLOCA_N(uint32_t, count) : NULL;
    uint32_t *next_histories = capture_mode ? ALLOCA_N(uint32_t, count) : NULL;
    unsigned char *current_bits = ALLOCA_N(unsigned char, bits_size);
    unsigned char *next_bits = ALLOCA_N(unsigned char, bits_size);
    size_t current_count = 0;
    long best_end = -1;
    uint32_t best_history = UINT32_MAX;
    memset(current_bits, 0, bits_size);
    for (uint32_t i = 0; i < header->start_edge_count; i++) {
	const OnibiREdge *edge = &view->edges[header->start_edge_base + i];
	if (edge->destination == ONIBI_ACCEPT_STATE) {
	    if (!onibi_regular_apply_actions(
		    view, edge, str, start, ctx->search_origin, ctx->encoding,
		    ctx->encoding_mode, UINT32_MAX, capture_slots, capture_mode,
		    &ctx->tags, &best_history))
		continue;
	    best_end = start;
	    break;
	}
	if (edge->destination >= count) continue;
	uint32_t state = edge->destination;
	if ((current_bits[state >> 3] & (1U << (state & 7))) == 0) {
	    uint32_t history;
	    if (!onibi_regular_apply_actions(
		    view, edge, str, start, ctx->search_origin, ctx->encoding,
		    ctx->encoding_mode, UINT32_MAX, capture_slots, capture_mode,
		    &ctx->tags, &history))
		continue;
	    current_bits[state >> 3] |= (unsigned char)(1U << (state & 7));
	    current[current_count] = state;
	    if (capture_mode) current_histories[current_count] = history;
	    current_count++;
	}
    }
    long position = start;
    for (;;) {
	long step_width = 1;
	size_t next_count = 0;
	memset(next_bits, 0, bits_size);
	int have_fallback = 0;
	long fallback_end = 0;
	uint32_t fallback_history = UINT32_MAX;
	for (size_t i = 0; i < current_count; i++) {
	    uint32_t state_id = current[i];
	    uint32_t thread_history =
		capture_mode ? current_histories[i] : UINT32_MAX;
	    const OnibiRState *state = &view->states[state_id];
	    if (state->op == 0) {
		uint32_t accept_history;
		if (!onibi_regular_accept_history(
			view, state, str, position, ctx->search_origin,
			ctx->encoding, ctx->encoding_mode, thread_history,
			capture_slots, capture_mode, &ctx->tags,
			&accept_history))
		    continue;
		if (!next_count) {
		    if (capture_mode)
			onibi_regular_materialize_tags(
			    &ctx->tags, accept_history,
			    onibi_regular_capture_result, capture_slots);
		    ctx->matched_end = position;
		    return 1;
		}
		if (!have_fallback) {
		    have_fallback = 1;
		    fallback_end = position;
		    fallback_history = accept_history;
		    best_end = fallback_end;
		    best_history = fallback_history;
		}
		goto frontier_complete;
	    }
	    if (position >= RSTRING_LEN(str)) continue;
	    long next_position = position;
	    int hit = onibi_rseq_consume_character(
		view, state, str, position, ctx->encoding, ctx->encoding_mode,
		&next_position, ctx->class_stack, ctx->class_stack_capacity);
	    if (hit) step_width = next_position - position;
	    if (!hit) continue;
	    uint32_t base = state->edge_base;
	    for (uint32_t e = 0; e < state->edge_count; e++) {
		const OnibiREdge *edge = &view->edges[base + e];
		if (edge->destination == ONIBI_ACCEPT_STATE) {
		    uint32_t accept_history;
		    if (!onibi_regular_apply_actions(
			    view, edge, str, next_position, ctx->search_origin,
			    ctx->encoding, ctx->encoding_mode, thread_history,
			    capture_slots, capture_mode, &ctx->tags,
			    &accept_history))
			continue;
		    /* Keep scanning this state's edges. A later continuation
		     * can still win at the next position. */
		    if (next_count == 0) {
			if (capture_mode)
			    onibi_regular_materialize_tags(
				&ctx->tags, accept_history,
				onibi_regular_capture_result, capture_slots);
			ctx->matched_end = next_position;
			return 1;
		    }
		    if (!have_fallback) {
			have_fallback = 1;
			fallback_end = next_position;
			fallback_history = accept_history;
			best_end = fallback_end;
			best_history = fallback_history;
		    }
		    goto frontier_complete;
		}
		if (edge->destination >= count) continue;
		uint32_t destination = edge->destination;
		if ((next_bits[destination >> 3] & (1U << (destination & 7))) ==
		    0) {
		    uint32_t history;
		    if (!onibi_regular_apply_actions(
			    view, edge, str, next_position, ctx->search_origin,
			    ctx->encoding, ctx->encoding_mode, thread_history,
			    capture_slots, capture_mode, &ctx->tags, &history))
			continue;
		    next_bits[destination >> 3] |=
			(unsigned char)(1U << (destination & 7));
		    next[next_count] = destination;
		    if (capture_mode) next_histories[next_count] = history;
		    next_count++;
		}
	    }
	}
    frontier_complete:
	if (!next_count) {
	    if (have_fallback) {
		if (capture_mode)
		    onibi_regular_materialize_tags(&ctx->tags, fallback_history,
						   onibi_regular_capture_result,
						   capture_slots);
		ctx->matched_end = fallback_end;
		return 1;
	    }
	    if (best_end >= 0) {
		if (capture_mode)
		    onibi_regular_materialize_tags(&ctx->tags, best_history,
						   onibi_regular_capture_result,
						   capture_slots);
		ctx->matched_end = best_end;
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
	if (capture_mode) {
	    uint32_t *histories_tmp = current_histories;
	    current_histories = next_histories;
	    next_histories = histories_tmp;
	}
	current_count = next_count;
	position += step_width;
    }
}

static OnibiExecStatus
onibi_exec_dynamic(OnibiExecCtx *ctx)
{
    onibi_diagnostics.dynamic++;
    OnibiSemanticState accepted;
    int result = onibi_rseq_backtracking_match(
	ctx->rseq, ctx->view, ctx->subject, ctx->attempt_start,
	ctx->search_origin, &ctx->matched_end, &accepted, &ctx->semantic_arena,
	ctx->class_stack, ctx->class_stack_capacity);
    if (result < 0) {
	onibi_diagnostics.fallback++;
	return ONIBI_EXEC_STATUS_FALLBACK;
    }
    if (result > 0) ctx->reported_start = accepted.reported_start;
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
    if (onibi_inject_internal_error) {
	onibi_inject_internal_error = 0;
	return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
    }
    switch ((OnibiExecutionKind)ctx->program->exec_kind) {
    case ONIBI_EXEC_REGULAR: return onibi_exec_regular(ctx);
    case ONIBI_EXEC_TAGGED: return onibi_exec_tagged(ctx);
    case ONIBI_EXEC_DYNAMIC: return onibi_exec_dynamic(ctx);
    default: return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
    }
}
/* DYNAMIC interpreter and its isolated compatibility traversal. */
