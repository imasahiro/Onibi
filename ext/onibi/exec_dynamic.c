#include "onibi_encoding_internal.h"
#include "onibi_exec_internal.h"
#include "onibi_rseq_internal.h"

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

/* Compare two complete byte spans after encoding-aware case folding.  The
 * caller can require equal source codepoint counts for backreferences. */
static int
onibi_casefold_bytes_equal(const unsigned char *left, long left_length,
			   const unsigned char *right, long right_length,
			   rb_encoding *encoding, int require_same_units,
			   OnibiExecCtx *ctx, VALUE subject,
			   OnibiBytePos left_subject_offset,
			   OnibiBytePos right_subject_offset)
{
    if (left_length < 0 || right_length < 0) return 0;
    const unsigned char *left_base = left;
    const unsigned char *right_base = right;
    long left_consumed = 0, right_consumed = 0;
    unsigned char left_fold[ONIGENC_MBC_CASE_FOLD_MAXLEN];
    unsigned char right_fold[ONIGENC_MBC_CASE_FOLD_MAXLEN];
    int left_fold_length = 0, right_fold_length = 0;
    int left_offset = 0, right_offset = 0;
    size_t left_units = 0, right_units = 0;
    while (left_consumed < left_length || left_fold_length > left_offset) {
	if (left_fold_length == left_offset) {
	    onibi_exec_charge_work(ctx, 1);
	    const unsigned char *left_pointer =
		left_subject_offset >= 0
		    ? (const unsigned char *)RSTRING_PTR(subject) +
			  left_subject_offset + left_consumed
		    : left_base + left_consumed;
	    const OnigUChar *left_cursor = (const OnigUChar *)left_pointer;
	    const OnigUChar *left_limit =
		left_cursor + (left_length - left_consumed);
	    const OnigUChar *before = left_cursor;
	    left_fold_length =
		ONIGENC_MBC_CASE_FOLD(encoding,
				      ONIGENC_CASE_FOLD_DEFAULT |
					  INTERNAL_ONIGENC_CASE_FOLD_MULTI_CHAR,
				      &left_cursor, left_limit, left_fold);
	    left_offset = 0;
	    left_units++;
	    if (left_fold_length <= 0 || left_cursor <= before) return 0;
	    left_consumed += (long)(left_cursor - before);
	}
	if (right_fold_length == right_offset) {
	    if (right_consumed >= right_length) return 0;
	    onibi_exec_charge_work(ctx, 1);
	    const unsigned char *right_pointer =
		right_subject_offset >= 0
		    ? (const unsigned char *)RSTRING_PTR(subject) +
			  right_subject_offset + right_consumed
		    : right_base + right_consumed;
	    const OnigUChar *right_cursor = (const OnigUChar *)right_pointer;
	    const OnigUChar *right_limit =
		right_cursor + (right_length - right_consumed);
	    const OnigUChar *before = right_cursor;
	    right_fold_length =
		ONIGENC_MBC_CASE_FOLD(encoding,
				      ONIGENC_CASE_FOLD_DEFAULT |
					  INTERNAL_ONIGENC_CASE_FOLD_MULTI_CHAR,
				      &right_cursor, right_limit, right_fold);
	    right_offset = 0;
	    right_units++;
	    if (right_fold_length <= 0 || right_cursor <= before) return 0;
	    right_consumed += (long)(right_cursor - before);
	}
	int left_available = left_fold_length - left_offset;
	int right_available = right_fold_length - right_offset;
	int count =
	    left_available < right_available ? left_available : right_available;
	onibi_exec_charge_work(ctx, (uint64_t)count);
	if (memcmp(left_fold + left_offset, right_fold + right_offset,
		   (size_t)count) != 0)
	    return 0;
	left_offset += count;
	right_offset += count;
    }
    return left_consumed == left_length && left_fold_length == left_offset &&
	   right_consumed == right_length &&
	   right_fold_length == right_offset &&
	   (!require_same_units || left_units == right_units);
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
onibi_rseq_decode_character(VALUE str, OnibiBytePos position,
			    rb_encoding *encoding, OnibiEncodingMode mode,
			    OnigCodePoint *codepoint, long *width)
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
			     const OnibiRState *state, VALUE str,
			     OnibiBytePos position, rb_encoding *encoding,
			     OnibiEncodingMode mode,
			     OnibiBytePos *next_position,
			     unsigned char *class_stack,
			     size_t class_stack_capacity, OnibiExecCtx *ctx)
{
    if (position < 0 || position >= RSTRING_LEN(str)) return 0;
    if (state->op == ONIBI_RS_CHAR) {
	const OnibiLiteralDesc *literal = &view->literals[state->payload];
	const unsigned char *literal_bytes = view->blob + literal->data_offset;
	if ((literal->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) == 0) {
	    if (position + literal->data_length > RSTRING_LEN(str) ||
		!onibi_ascii_literal_equal(
		    (const unsigned char *)RSTRING_PTR(str) + position,
		    literal_bytes, literal->data_length, 0))
		return 0;
	    *next_position = position + literal->data_length;
	    return 1;
	}
	/* A case-folded literal can consume a different number of bytes from
	 * its source.  Try each character boundary until the full span folds.
	 */
	OnibiBytePos candidate = position;
	while (candidate < RSTRING_LEN(str)) {
	    OnigCodePoint codepoint;
	    long width;
	    if (!onibi_rseq_decode_character(str, candidate, encoding, mode,
					     &codepoint, &width))
		return 0;
	    (void)codepoint;
	    candidate += width;
	    if (onibi_casefold_bytes_equal(literal_bytes, literal->data_length,
					   NULL, candidate - position, encoding,
					   0, ctx, str, -1, position)) {
		*next_position = candidate;
		return 1;
	    }
	}
	return 0;
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
	if (!multiline &&
	    ONIGENC_IS_MBC_NEWLINE(
		encoding, (const unsigned char *)RSTRING_PTR(str) + position,
		(const unsigned char *)RSTRING_PTR(str) + RSTRING_LEN(str)))
	    return 0;
	*next_position = position + width;
	return 1;
    }
    return 0;
}

static int
onibi_rseq_word_at(VALUE str, OnibiBytePos position, rb_encoding *encoding,
		   OnibiEncodingMode mode)
{
    OnigCodePoint codepoint;
    long width;
    return onibi_rseq_decode_character(str, position, encoding, mode,
				       &codepoint, &width) &&
	   ONIGENC_IS_CODE_CTYPE(encoding, codepoint, ONIGENC_CTYPE_WORD) != 0;
}

static int
onibi_rseq_word_before(VALUE str, OnibiBytePos position, rb_encoding *encoding,
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

/* Compare two byte spans after encoding-aware case folding.  A folded
 * character can have a different width from its source character. */
static int
onibi_rseq_casefold_span_equal(VALUE str, OnibiBytePos left,
			       OnibiBytePos left_end, OnibiBytePos right,
			       OnibiBytePos right_end, rb_encoding *encoding,
			       OnibiExecCtx *ctx)
{
    if (left < 0 || left_end < left || right < 0 || right_end < right ||
	left_end > RSTRING_LEN(str) || right_end > RSTRING_LEN(str))
	return 0;
    return onibi_casefold_bytes_equal(NULL, left_end - left, NULL,
				      right_end - right, encoding, 1, ctx, str,
				      left, right);
}

static int
onibi_rseq_backref_consume(VALUE str, OnibiBytePos position,
			   OnibiBytePos capture_begin, OnibiBytePos capture_end,
			   rb_encoding *encoding, OnibiEncodingMode mode,
			   int ignorecase, OnibiBytePos *next_position,
			   OnibiExecCtx *ctx)
{
    if (!ignorecase) {
	long length = capture_end - capture_begin;
	if (length < 0 || position < 0 || position + length > RSTRING_LEN(str))
	    return 0;
	for (long offset = 0; offset < length;) {
	    long remaining = length - offset;
	    long chunk =
		remaining < ONIBI_POLL_WORK ? remaining : ONIBI_POLL_WORK;
	    if (ctx) ctx->current_position = position + offset;
	    onibi_exec_charge_work(ctx, (uint64_t)chunk);
	    /* Reload both subject pointers after each bounded charge. */
	    if (memcmp((const unsigned char *)RSTRING_PTR(str) + position +
			   offset,
		       (const unsigned char *)RSTRING_PTR(str) + capture_begin +
			   offset,
		       (size_t)chunk) != 0)
		return 0;
	    offset += chunk;
	}
	*next_position = position + length;
	return 1;
    }
    if (capture_begin == capture_end) {
	*next_position = position;
	return 1;
    }
    OnibiBytePos candidate = position;
    while (candidate < RSTRING_LEN(str)) {
	OnigCodePoint codepoint;
	long width;
	if (!onibi_rseq_decode_character(str, candidate, encoding, mode,
					 &codepoint, &width))
	    return 0;
	candidate += width;
	int equal =
	    onibi_rseq_casefold_span_equal(str, capture_begin, capture_end,
					   position, candidate, encoding, ctx);
	if (equal) {
	    *next_position = candidate;
	    return 1;
	}
    }
    return 0;
}

static int
onibi_rseq_position_assertion_hit(OnibiRAssertKind kind, VALUE str,
				  OnibiBytePos pos, OnibiBytePos search_origin,
				  rb_encoding *encoding, OnibiEncodingMode mode)
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
    arena->order_count = 0;
    arena->capture_event_count = 0;
    arena->capture_event_root_count = 0;
    arena->capture_event_owner_count = 0;
    if (arena->order_buckets)
	memset(arena->order_buckets, 0,
	       arena->order_bucket_capacity * sizeof(uint32_t));
    arena->register_count = 0;
    arena->tag_count = 0;
    arena->call_count = 0;
    arena->atomic_count = 0;
    arena->absence_count = 0;
    arena->frame_count = 0;
    arena->cycle_count = 0;
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
    ruby_xfree(arena->order_nodes);
    ruby_xfree(arena->order_buckets);
    ruby_xfree(arena->capture_events);
    ruby_xfree(arena->capture_event_roots);
    ruby_xfree(arena->capture_event_owners);
    ruby_xfree(arena->registers);
    ruby_xfree(arena->tags);
    ruby_xfree(arena->calls);
    ruby_xfree(arena->subprogram_local_slots);
    ruby_xfree(arena->local_slots);
    ruby_xfree(arena->local_slot_visited);
    ruby_xfree(arena->local_slot_queued);
    ruby_xfree(arena->local_slot_work);
    ruby_xfree(arena->local_slot_used);
    ruby_xfree(arena->local_slot_nullable);
    ruby_xfree(arena->atomic);
    ruby_xfree(arena->absence);
    ruby_xfree(arena->live_capture_slots);
    ruby_xfree(arena->live_capture_bitmap);
    ruby_xfree(arena->future_capture_slots);
    ruby_xfree(arena->future_capture_bitmap);
    ruby_xfree(arena->frames);
    ruby_xfree(arena->cycles);
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

/* These immutable nodes retain conceptual edge order. Hash interning joins
 * common epsilon prefixes; it never joins semantic thread state. */
static uint64_t
onibi_capture_order_hash(uint32_t parent, uint32_t label)
{
    return ((uint64_t)parent * UINT64_C(0x9e3779b185ebca87)) ^
	   ((uint64_t)label * UINT64_C(0xc2b2ae3d27d4eb4f));
}

static uint32_t
onibi_capture_order_append(OnibiSemanticArena *arena, uint32_t parent,
			   uint32_t label)
{
    if (arena->order_count + 1U >= arena->order_bucket_capacity / 2U) {
	size_t size = arena->order_bucket_capacity
			  ? arena->order_bucket_capacity * 2U
			  : 64U;
	if (size < arena->order_bucket_capacity ||
	    size > SIZE_MAX / sizeof(uint32_t))
	    rb_memerror();
	uint32_t *buckets = ruby_xcalloc(size, sizeof(uint32_t));
	for (size_t i = 0; i < arena->order_count; i++) {
	    const OnibiCaptureOrderNode *node = &arena->order_nodes[i];
	    size_t slot =
		onibi_capture_order_hash(node->parent[0], node->label) &
		(size - 1U);
	    while (buckets[slot])
		slot = (slot + 1U) & (size - 1U);
	    buckets[slot] = (uint32_t)i + 1U;
	}
	ruby_xfree(arena->order_buckets);
	arena->order_buckets = buckets;
	arena->order_bucket_capacity = size;
    }
    size_t slot = onibi_capture_order_hash(parent, label) &
		  (arena->order_bucket_capacity - 1U);
    while (arena->order_buckets[slot]) {
	uint32_t id = arena->order_buckets[slot] - 1U;
	const OnibiCaptureOrderNode *node = &arena->order_nodes[id];
	if (node->parent[0] == parent && node->label == label) return id;
	slot = (slot + 1U) & (arena->order_bucket_capacity - 1U);
    }
    arena->order_nodes = onibi_semantic_arena_reserve(
	arena->order_nodes, &arena->order_capacity, arena->order_count,
	sizeof(*arena->order_nodes));
    if (arena->order_count >= UINT32_MAX) rb_memerror();
    uint32_t id = (uint32_t)arena->order_count++;
    OnibiCaptureOrderNode *node = &arena->order_nodes[id];
    node->parent[0] = parent;
    node->depth =
	parent == UINT32_MAX ? 1U : arena->order_nodes[parent].depth + 1U;
    if (!node->depth) rb_memerror();
    node->label = label;
    for (unsigned i = 1; i < 32; i++)
	node->parent[i] =
	    node->parent[i - 1U] == UINT32_MAX
		? UINT32_MAX
		: arena->order_nodes[node->parent[i - 1U]].parent[i - 1U];
    arena->order_buckets[slot] = id + 1U;
    return id;
}

static int
onibi_capture_order_is_ancestor(const OnibiSemanticArena *arena,
				uint32_t ancestor, uint32_t descendant)
{
    if (ancestor == UINT32_MAX)
	return descendant == UINT32_MAX || descendant < arena->order_count;
    if (ancestor >= arena->order_count) return 0;
    while (descendant != UINT32_MAX) {
	if (descendant >= arena->order_count) return 0;
	if (descendant == ancestor) return 1;
	descendant = arena->order_nodes[descendant].parent[0];
    }
    return 0;
}

static int
onibi_capture_order_compare(const OnibiSemanticArena *arena, uint32_t left,
			    uint32_t right)
{
    if (left == right) return 0;
    if (left == UINT32_MAX) return -1;
    if (right == UINT32_MAX) return 1;
    uint32_t a = left, b = right;
    uint32_t da = arena->order_nodes[a].depth;
    uint32_t db = arena->order_nodes[b].depth;
    uint32_t difference = da > db ? da - db : db - da;
    for (unsigned i = 0; difference; i++, difference >>= 1U) {
	if (!(difference & 1U)) continue;
	if (da > db)
	    a = arena->order_nodes[a].parent[i];
	else
	    b = arena->order_nodes[b].parent[i];
    }
    if (a == b) return da < db ? -1 : 1;
    for (int i = 31; i >= 0; i--) {
	uint32_t pa = arena->order_nodes[a].parent[i];
	uint32_t pb = arena->order_nodes[b].parent[i];
	if (pa != pb) {
	    a = pa;
	    b = pb;
	}
    }
    return arena->order_nodes[a].label < arena->order_nodes[b].label ? -1 : 1;
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
onibi_semantic_future_captures_begin(OnibiSemanticArena *arena,
				     uint32_t capture_count)
{
    if (capture_count > arena->future_capture_bitmap_capacity) {
	arena->future_capture_bitmap =
	    ruby_xrealloc(arena->future_capture_bitmap, capture_count);
	arena->future_capture_bitmap_capacity = capture_count;
    }
    if (capture_count != 0)
	memset(arena->future_capture_bitmap, 0, capture_count);
    arena->future_capture_count = 0;
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
onibi_semantic_future_capture_add(OnibiSemanticArena *arena,
				  uint32_t capture_id)
{
    if (capture_id >= arena->future_capture_bitmap_capacity ||
	arena->future_capture_bitmap[capture_id])
	return;
    arena->future_capture_bitmap[capture_id] = 1;
    arena->future_capture_slots = onibi_semantic_arena_reserve(
	arena->future_capture_slots, &arena->future_capture_capacity,
	arena->future_capture_count, sizeof(*arena->future_capture_slots));
    arena->future_capture_slots[arena->future_capture_count++] =
	capture_id * 2U;
    arena->future_capture_slots = onibi_semantic_arena_reserve(
	arena->future_capture_slots, &arena->future_capture_capacity,
	arena->future_capture_count, sizeof(*arena->future_capture_slots));
    arena->future_capture_slots[arena->future_capture_count++] =
	capture_id * 2U + 1U;
}

static void
onibi_semantic_live_captures_prepare(OnibiSemanticArena *arena,
				     const OnibiRSeqView *view)
{
    onibi_semantic_live_captures_begin(arena, view->header->capture_count);
    onibi_semantic_future_captures_begin(arena, view->header->capture_count);
    for (uint32_t i = 0; i < view->header->state_count; i++) {
	if (view->states[i].op == ONIBI_RS_BACKREF &&
	    view->states[i].payload < view->header->backref_count) {
	    const OnibiBackrefDesc *descriptor =
		&view->backrefs[view->states[i].payload];
	    if (descriptor->capture_list_off <
		view->header->backref_lists_offset)
		continue;
	    uint32_t list_index = (descriptor->capture_list_off -
				   view->header->backref_lists_offset) /
				  (uint32_t)sizeof(uint32_t);
	    for (uint16_t j = 0; j < descriptor->capture_count; j++) {
		uint32_t capture = view->backref_capture_ids[list_index + j];
		onibi_semantic_live_capture_add(arena, capture);
		onibi_semantic_future_capture_add(arena, capture);
	    }
	}
    }
    for (uint32_t i = 0; i < view->header->action_count; i++)
	if (view->actions[i].op == ONIBI_RA_TEST_CAPTURE) {
	    onibi_semantic_live_capture_add(arena, view->actions[i].arg16);
	    onibi_semantic_future_capture_add(arena, view->actions[i].arg16);
	}
	else if (view->actions[i].op == ONIBI_RA_NULL_CAPTURE)
	    onibi_semantic_live_capture_add(arena, view->actions[i].arg32);
}

enum {
    ONIBI_SEMANTIC_HASH_CAPTURE = 1,
    ONIBI_SEMANTIC_HASH_COUNTER = 2,
    ONIBI_SEMANTIC_HASH_PROGRESS = 3,
    ONIBI_SEMANTIC_HASH_CALL = 4,
    ONIBI_SEMANTIC_HASH_ATOMIC = 5,
    ONIBI_SEMANTIC_HASH_ABSENCE = 6,
};

static uint64_t
onibi_semantic_hash_value(uint64_t hash, uint64_t value)
{
    hash ^= value + UINT64_C(0x9e3779b97f4a7c15) + (hash << 6) + (hash >> 2);
    return hash;
}

static uint64_t
onibi_semantic_register_base_hash(uint64_t domain, uint32_t slot_count,
				  OnibiRegisterValue default_value)
{
    uint64_t hash =
	onibi_semantic_hash_value(UINT64_C(0xcbf29ce484222325), domain);
    hash = onibi_semantic_hash_value(hash, slot_count);
    return onibi_semantic_hash_value(hash, (uint64_t)default_value);
}

static uint64_t
onibi_semantic_register_slot_hash(uint64_t domain, uint32_t slot,
				  OnibiRegisterValue value)
{
    uint64_t hash =
	onibi_semantic_hash_value(UINT64_C(0x84222325cbf29ce4), domain);
    hash = onibi_semantic_hash_value(hash, slot);
    return onibi_semantic_hash_value(hash, (uint64_t)value);
}

static OnibiSemanticState
onibi_semantic_state_initial(const OnibiSemanticArena *arena,
			     OnibiBytePos reported_start,
			     uint32_t capture_slots, uint32_t counter_slots,
			     uint32_t progress_slots)
{
    OnibiSemanticState state;
    memset(&state, 0, sizeof(state));
    state.order = UINT32_MAX;
    state.reported_start = reported_start;
    state.semantic_captures = (OnibiSemanticCaptureFile){
	UINT32_MAX, capture_slots,
	onibi_semantic_register_base_hash(ONIBI_SEMANTIC_HASH_CAPTURE,
					  capture_slots, -1)};
    state.condition_captures = (OnibiSemanticCaptureFile){
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
    state.capture_event_history = UINT32_MAX;
    state.capture_event_dependency = UINT32_MAX;
    return state;
}

static OnibiRegisterValue
onibi_semantic_register_read(OnibiSemanticArena *arena, uint32_t root,
			     uint32_t slot, OnibiRegisterValue default_value)
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
			       uint32_t slot, OnibiRegisterValue value)
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
				   uint32_t slot, OnibiRegisterValue value,
				   OnibiRegisterValue default_value,
				   int hash_slot)
{
    OnibiRegisterValue old_value =
	onibi_semantic_register_read(arena, *root, slot, default_value);
    if (old_value == value) return;
    *root = onibi_semantic_register_append(arena, *root, slot, value);
    if (!hash_slot) return;
    *hash ^= onibi_semantic_register_slot_hash(domain, slot, old_value);
    *hash ^= onibi_semantic_register_slot_hash(domain, slot, value);
}

/* The linked register arena stores one neutral signed value type.  These
 * helpers keep subject positions and repeat counts distinct at each file
 * boundary while preserving the compact shared representation. */
static OnibiBytePos
onibi_semantic_position_read(OnibiSemanticArena *arena, uint32_t root,
			     uint32_t slot, OnibiBytePos default_value)
{
    return (OnibiBytePos)onibi_semantic_register_read(
	arena, root, slot, (OnibiRegisterValue)default_value);
}

static OnibiRepeatCount
onibi_semantic_counter_read(OnibiSemanticArena *arena, uint32_t root,
			    uint32_t slot, OnibiRepeatCount default_value)
{
    return (OnibiRepeatCount)onibi_semantic_register_read(
	arena, root, slot, (OnibiRegisterValue)default_value);
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
			     OnibiBytePos value)
{
    onibi_semantic_register_file_write(
	arena, &file->root, &file->hash, ONIBI_SEMANTIC_HASH_CAPTURE, slot,
	value, -1, onibi_semantic_capture_slot_live(arena, slot));
}

static void
onibi_semantic_condition_capture_write(OnibiSemanticArena *arena,
				       OnibiSemanticCaptureFile *file,
				       uint32_t slot, OnibiBytePos value)
{
    onibi_semantic_register_file_write(
	arena, &file->root, &file->hash, ONIBI_SEMANTIC_HASH_CAPTURE, slot,
	value, -1, onibi_semantic_capture_slot_live(arena, slot));
}

static void
onibi_semantic_counter_write(OnibiSemanticArena *arena, OnibiCounterFile *file,
			     uint32_t slot, OnibiRepeatCount value)
{
    onibi_semantic_register_file_write(arena, &file->root, &file->hash,
				       ONIBI_SEMANTIC_HASH_COUNTER, slot, value,
				       0, 1);
}

static void
onibi_semantic_progress_write(OnibiSemanticArena *arena,
			      OnibiProgressState *file, uint32_t slot,
			      OnibiBytePos value)
{
    onibi_semantic_register_file_write(arena, &file->root, &file->hash,
				       ONIBI_SEMANTIC_HASH_PROGRESS, slot,
				       value, -1, 1);
}

static OnibiTagEventId
onibi_semantic_tag_append(OnibiSemanticArena *arena, OnibiTagEventId parent,
			  uint32_t slot, OnibiBytePos position)
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
onibi_semantic_capture_event_append(OnibiSemanticArena *arena, uint32_t parent,
				    uint32_t order, uint32_t slot,
				    OnibiBytePos position)
{
    arena->capture_events = onibi_semantic_arena_reserve(
	arena->capture_events, &arena->capture_event_capacity,
	arena->capture_event_count, sizeof(*arena->capture_events));
    if (arena->capture_event_count >= UINT32_MAX) rb_memerror();
    uint32_t id = (uint32_t)arena->capture_event_count++;
    arena->capture_events[id] =
	(OnibiUnscopedCaptureEvent){parent, order, slot, position};
    return id;
}

static uint32_t
onibi_semantic_capture_event_root_append(OnibiSemanticArena *arena,
					 uint32_t history, uint32_t next)
{
    arena->capture_event_roots = onibi_semantic_arena_reserve(
	arena->capture_event_roots, &arena->capture_event_root_capacity,
	arena->capture_event_root_count, sizeof(*arena->capture_event_roots));
    if (arena->capture_event_root_count >= UINT32_MAX) rb_memerror();
    uint32_t id = (uint32_t)arena->capture_event_root_count++;
    arena->capture_event_roots[id] = (OnibiCaptureEventRoot){history, next};
    return id;
}

static uint32_t
onibi_semantic_capture_event_owner_append(OnibiSemanticArena *arena,
					  uint32_t event_history)
{
    arena->capture_event_owners = onibi_semantic_arena_reserve(
	arena->capture_event_owners, &arena->capture_event_owner_capacity,
	arena->capture_event_owner_count, sizeof(*arena->capture_event_owners));
    if (arena->capture_event_owner_count >= UINT32_MAX) rb_memerror();
    uint32_t id = (uint32_t)arena->capture_event_owner_count++;
    uint32_t roots = event_history == UINT32_MAX
			 ? UINT32_MAX
			 : onibi_semantic_capture_event_root_append(
			       arena, event_history, UINT32_MAX);
    arena->capture_event_owners[id] =
	(OnibiCaptureEventOwner){roots, UINT32_MAX, 0};
    return id;
}

static int
onibi_semantic_capture_event_owner_add(OnibiSemanticArena *arena,
				       uint32_t owner, uint32_t history)
{
    if (history == UINT32_MAX || owner >= arena->capture_event_owner_count)
	return 0;
    uint32_t roots = arena->capture_event_owners[owner].event_roots;
    if (roots != UINT32_MAX &&
	arena->capture_event_roots[roots].history == history)
	return 0;
    arena->capture_event_owners[owner].event_roots =
	onibi_semantic_capture_event_root_append(arena, history, roots);
    return 1;
}

static int
onibi_semantic_capture_event_owner_resolve(OnibiSemanticArena *arena,
					   uint32_t owner,
					   uint32_t failure_owner)
{
    if (owner >= arena->capture_event_owner_count ||
	arena->capture_event_owners[owner].resolved)
	return 0;
    if (failure_owner != UINT32_MAX &&
	failure_owner >= arena->capture_event_owner_count)
	return 0;
    arena->capture_event_owners[owner].resolved_owner = failure_owner;
    arena->capture_event_owners[owner].resolved = 1;
    return 1;
}

/* Build the local counter map from the validated physical RSeq graph.  A
 * nullable owner is local only when its entry action occurs in this graph.
 * NULL_CAPTURE actions can therefore carry an inherited outer owner without
 * causing that owner to be reset on child entry or return. */
static void
onibi_semantic_local_slots_prepare(OnibiSemanticArena *arena,
				   const OnibiRSeqView *view)
{
    const OnibiRSeqHeader *header = view->header;
    if (arena->subprogram_local_header == header &&
	arena->subprogram_local_count == header->subprogram_count)
	return;

    ruby_xfree(arena->subprogram_local_slots);
    ruby_xfree(arena->local_slots);
    arena->subprogram_local_slots = NULL;
    arena->local_slots = NULL;
    arena->subprogram_local_count = 0;
    arena->local_slot_count = 0;
    arena->local_slot_capacity = 0;
    arena->subprogram_local_header = NULL;
    ruby_xfree(arena->local_slot_visited);
    ruby_xfree(arena->local_slot_queued);
    ruby_xfree(arena->local_slot_work);
    ruby_xfree(arena->local_slot_used);
    ruby_xfree(arena->local_slot_nullable);
    arena->local_slot_visited = NULL;
    arena->local_slot_queued = NULL;
    arena->local_slot_work = NULL;
    arena->local_slot_used = NULL;
    arena->local_slot_nullable = NULL;

    if (header->subprogram_count >
	    SIZE_MAX / sizeof(*arena->subprogram_local_slots) ||
	(header->state_count != 0 &&
	 (size_t)header->state_count > SIZE_MAX / sizeof(uint32_t)))
	rb_memerror();
    arena->subprogram_local_slots = ruby_xcalloc(
	header->subprogram_count, sizeof(*arena->subprogram_local_slots));
    arena->local_slot_visited =
	header->state_count == 0 ? NULL : ruby_xcalloc(header->state_count, 1);
    arena->local_slot_queued =
	header->state_count == 0 ? NULL : ruby_xcalloc(header->state_count, 1);
    arena->local_slot_work =
	header->state_count == 0
	    ? NULL
	    : ruby_xmalloc((size_t)header->state_count * sizeof(uint32_t));
    arena->local_slot_used = header->counter_count == 0
				 ? NULL
				 : ruby_xcalloc(header->counter_count, 1);
    arena->local_slot_nullable = header->counter_count == 0
				     ? NULL
				     : ruby_xcalloc(header->counter_count, 1);

    for (uint32_t subprogram_id = 0; subprogram_id < header->subprogram_count;
	 subprogram_id++) {
	if (header->state_count != 0) {
	    memset(arena->local_slot_visited, 0, header->state_count);
	    memset(arena->local_slot_queued, 0, header->state_count);
	}
	if (header->counter_count != 0) {
	    memset(arena->local_slot_used, 0, header->counter_count);
	    memset(arena->local_slot_nullable, 0, header->counter_count);
	}
	size_t work_count = 0;
	const OnibiSubprogramDesc *subprogram =
	    &view->subprograms[subprogram_id];
	uint32_t entry_base = subprogram_id == 0 ? header->start_edge_base
						 : subprogram->entry_edge_base;
	uint32_t entry_count = subprogram_id == 0
				   ? header->start_edge_count
				   : subprogram->entry_edge_count;

#define ONIBI_MARK_ACTIONS(_offset)                                            \
    do {                                                                       \
	uint32_t _index =                                                      \
	    (_offset) == 0 ? UINT32_MAX                                        \
			   : (_offset) / (uint32_t)sizeof(OnibiRAction) - 1U;  \
	if (_index != UINT32_MAX) {                                            \
	    for (; _index < header->action_count; _index++) {                  \
		const OnibiRAction *_action = &view->actions[_index];          \
		if (_action->op == ONIBI_RA_END) break;                        \
		switch (_action->op) {                                         \
		case ONIBI_RA_COUNTER_SET:                                     \
		case ONIBI_RA_COUNTER_ADD:                                     \
		case ONIBI_RA_COUNTER_TEST:                                    \
		case ONIBI_RA_PROGRESS:                                        \
		    arena->local_slot_used[_action->arg16] = 1;                \
		    break;                                                     \
		case ONIBI_RA_NULL_ENTER:                                      \
		    arena->local_slot_nullable[_action->arg16] = 1;            \
		    arena->local_slot_nullable[_action->arg16 + 1U] = 1;       \
		    break;                                                     \
		default: break;                                                \
		}                                                              \
	    }                                                                  \
	}                                                                      \
    } while (0)

	for (uint32_t i = 0; i < entry_count; i++) {
	    const OnibiREdge *edge = &view->edges[entry_base + i];
	    ONIBI_MARK_ACTIONS(edge->action_offset);
	    if (edge->destination < header->state_count)
		if (!arena->local_slot_queued[edge->destination]) {
		    arena->local_slot_queued[edge->destination] = 1;
		    arena->local_slot_work[work_count++] = edge->destination;
		}
	}
	while (work_count != 0) {
	    uint32_t state_id = arena->local_slot_work[--work_count];
	    if (state_id >= header->state_count ||
		arena->local_slot_visited[state_id])
		continue;
	    arena->local_slot_visited[state_id] = 1;
	    const OnibiRState *state = &view->states[state_id];
	    for (uint32_t i = 0; i < state->edge_count; i++) {
		const OnibiREdge *edge = &view->edges[state->edge_base + i];
		ONIBI_MARK_ACTIONS(edge->action_offset);
		if (edge->destination < header->state_count &&
		    !arena->local_slot_queued[edge->destination]) {
		    arena->local_slot_queued[edge->destination] = 1;
		    arena->local_slot_work[work_count++] = edge->destination;
		}
	    }
	}
#undef ONIBI_MARK_ACTIONS

	OnibiSubprogramLocalSlots *slots =
	    &arena->subprogram_local_slots[subprogram_id];
	slots->slot_offset = (uint32_t)arena->local_slot_count;
	for (uint32_t slot = 0; slot < header->counter_count; slot++) {
	    if (!arena->local_slot_used[slot] &&
		!arena->local_slot_nullable[slot])
		continue;
	    if (arena->local_slot_count >= UINT32_MAX) rb_memerror();
	    arena->local_slots = onibi_semantic_arena_reserve(
		arena->local_slots, &arena->local_slot_capacity,
		arena->local_slot_count, sizeof(*arena->local_slots));
	    arena->local_slots[arena->local_slot_count++] = slot;
	}
	slots->slot_count =
	    (uint32_t)arena->local_slot_count - slots->slot_offset;
    }
    arena->subprogram_local_count = header->subprogram_count;
    arena->subprogram_local_header = header;
}

static void
onibi_semantic_local_slots_reset(OnibiSemanticArena *arena,
				 uint32_t subprogram_id,
				 OnibiSemanticState *state)
{
    if (subprogram_id >= arena->subprogram_local_count) return;
    const OnibiSubprogramLocalSlots *slots =
	&arena->subprogram_local_slots[subprogram_id];
    for (uint32_t i = 0; i < slots->slot_count; i++) {
	uint32_t slot = arena->local_slots[slots->slot_offset + i];
	onibi_semantic_counter_write(arena, &state->counters, slot, 0);
	onibi_semantic_progress_write(arena, &state->progress, slot, -1);
    }
}

static void
onibi_semantic_local_slots_restore(OnibiSemanticArena *arena,
				   uint32_t subprogram_id,
				   OnibiSemanticState *state,
				   OnibiCounterFile caller_counters,
				   OnibiProgressState caller_progress)
{
    if (subprogram_id >= arena->subprogram_local_count) return;
    const OnibiSubprogramLocalSlots *slots =
	&arena->subprogram_local_slots[subprogram_id];
    for (uint32_t i = 0; i < slots->slot_count; i++) {
	uint32_t slot = arena->local_slots[slots->slot_offset + i];
	onibi_semantic_counter_write(
	    arena, &state->counters, slot,
	    onibi_semantic_counter_read(arena, caller_counters.root, slot, 0));
	onibi_semantic_progress_write(
	    arena, &state->progress, slot,
	    onibi_semantic_position_read(arena, caller_progress.root, slot,
					 -1));
    }
}

static int
onibi_semantic_capture_is_active(const OnibiSemanticArena *arena,
				 OnibiTagEventId tag_history,
				 uint32_t begin_slot, uint32_t end_slot)
{
    while (tag_history != UINT32_MAX) {
	const OnibiSemanticTagEvent *event = &arena->tags[tag_history];
	if (event->slot == begin_slot) return 1;
	if (event->slot == end_slot) return 0;
	tag_history = event->parent;
    }
    return 0;
}

static void
onibi_semantic_restore_active_captures(OnibiSemanticArena *arena,
				       OnibiSemanticState *state,
				       const OnibiSemanticCaptureFile *caller,
				       OnibiTagEventId caller_tag_history)
{
    for (uint32_t capture = 0;
	 capture * 2U + 1U < state->semantic_captures.slot_count; capture++) {
	uint32_t begin_slot = capture * 2U;
	uint32_t end_slot = begin_slot + 1U;
	OnibiBytePos begin =
	    onibi_semantic_position_read(arena, caller->root, begin_slot, -1);
	if (onibi_semantic_capture_is_active(arena, caller_tag_history,
					     begin_slot, end_slot)) {
	    OnibiBytePos end =
		onibi_semantic_position_read(arena, caller->root, end_slot, -1);
	    onibi_semantic_capture_write(arena, &state->semantic_captures,
					 begin_slot, begin);
	    onibi_semantic_capture_write(arena, &state->semantic_captures,
					 end_slot, end);
	}
    }
}

static void
onibi_semantic_restore_active_conditions(OnibiSemanticArena *arena,
					 OnibiSemanticState *state,
					 const OnibiSemanticCaptureFile *caller,
					 OnibiTagEventId caller_tag_history)
{
    for (uint32_t capture = 0;
	 capture * 2U + 1U < state->condition_captures.slot_count; capture++) {
	uint32_t begin_slot = capture * 2U;
	uint32_t end_slot = begin_slot + 1U;
	if (onibi_semantic_capture_is_active(arena, caller_tag_history,
					     begin_slot, end_slot)) {
	    onibi_semantic_condition_capture_write(
		arena, &state->condition_captures, begin_slot,
		onibi_semantic_position_read(arena, caller->root, begin_slot,
					     -1));
	    onibi_semantic_condition_capture_write(
		arena, &state->condition_captures, end_slot,
		onibi_semantic_position_read(arena, caller->root, end_slot,
					     -1));
	}
    }
}

static void
onibi_semantic_restore_active_capture_tags(
    OnibiSemanticArena *arena, OnibiSemanticState *state,
    const OnibiSemanticCaptureFile *caller, OnibiTagEventId caller_tag_history)
{
    for (uint32_t capture = 0;
	 capture * 2U + 1U < state->semantic_captures.slot_count; capture++) {
	uint32_t slot = capture * 2U;
	OnibiBytePos begin =
	    onibi_semantic_position_read(arena, caller->root, slot, -1);
	if (onibi_semantic_capture_is_active(arena, caller_tag_history, slot,
					     slot + 1U))
	    state->tag_history = onibi_semantic_tag_append(
		arena, state->tag_history, slot, begin);
    }
}

static uint32_t
onibi_semantic_call_push(OnibiSemanticArena *arena, uint32_t parent,
			 const OnibiCallFrame *frame,
			 OnibiTagEventId caller_tag_history,
			 OnibiSemanticCaptureFile caller_captures,
			 OnibiSemanticCaptureFile caller_condition_captures,
			 OnibiCounterFile caller_counters,
			 OnibiProgressState caller_progress)
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
    hash = onibi_semantic_hash_value(hash, caller_captures.slot_count);
    hash = onibi_semantic_hash_value(hash, caller_captures.hash);
    hash =
	onibi_semantic_hash_value(hash, caller_condition_captures.slot_count);
    hash = onibi_semantic_hash_value(hash, caller_condition_captures.hash);
    hash = onibi_semantic_hash_value(hash, caller_counters.slot_count);
    hash = onibi_semantic_hash_value(hash, caller_counters.hash);
    hash = onibi_semantic_hash_value(hash, caller_progress.slot_count);
    hash = onibi_semantic_hash_value(hash, caller_progress.hash);
    arena->calls[id] = (OnibiOwnedCallFrame){parent,
					     *frame,
					     caller_tag_history,
					     caller_captures,
					     caller_condition_captures,
					     caller_counters,
					     caller_progress,
					     hash};
    return id;
}

static uint32_t
onibi_semantic_scope_push(OnibiSemanticArena *arena, OnibiSemanticScope **nodes,
			  size_t *count, size_t *capacity, uint32_t parent,
			  OnibiSubprogramId subprogram_id, OnibiBytePos begin,
			  OnibiBytePos end, OnibiTagEventId tag_history,
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
				   OnibiRegisterValue default_value)
{
    if (left_hash != right_hash) return 0;
    if (left == right) return 1;
    uint32_t root = left;
    while (root != UINT32_MAX) {
	if (root >= arena->register_count) return 0;
	const OnibiSemanticRegisterDelta *delta = &arena->registers[root];
	if (delta->slot >= slot_count ||
	    onibi_semantic_register_read(arena, left, delta->slot,
					 default_value) !=
		onibi_semantic_register_read(arena, right, delta->slot,
					     default_value))
	    return 0;
	root = delta->parent;
    }
    root = right;
    while (root != UINT32_MAX) {
	if (root >= arena->register_count) return 0;
	const OnibiSemanticRegisterDelta *delta = &arena->registers[root];
	if (delta->slot >= slot_count ||
	    onibi_semantic_register_read(arena, left, delta->slot,
					 default_value) !=
		onibi_semantic_register_read(arena, right, delta->slot,
					     default_value))
	    return 0;
	root = delta->parent;
    }
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
	if (onibi_semantic_position_read(arena, left->root, slot, -1) !=
	    onibi_semantic_position_read(arena, right->root, slot, -1))
	    return 0;
    }
    return 1;
}

static int
onibi_semantic_condition_capture_file_equal(
    OnibiSemanticArena *arena, const OnibiSemanticCaptureFile *left,
    const OnibiSemanticCaptureFile *right)
{
    if (left->slot_count != right->slot_count || left->hash != right->hash)
	return 0;
    if (left->root == right->root) return 1;
    for (size_t i = 0; i < arena->live_capture_count; i++) {
	uint32_t slot = arena->live_capture_slots[i];
	if (onibi_semantic_position_read(arena, left->root, slot, -1) !=
	    onibi_semantic_position_read(arena, right->root, slot, -1))
	    return 0;
    }
    return 1;
}

static int
onibi_semantic_future_capture_file_equal(OnibiSemanticArena *arena,
					 const OnibiSemanticCaptureFile *left,
					 const OnibiSemanticCaptureFile *right)
{
    if (left->root == right->root) return 1;
    for (size_t i = 0; i < arena->future_capture_count; i++) {
	uint32_t slot = arena->future_capture_slots[i];
	if (onibi_semantic_position_read(arena, left->root, slot, -1) !=
	    onibi_semantic_position_read(arena, right->root, slot, -1))
	    return 0;
    }
    return 1;
}

/* TAGGED identity excludes output-only tag history.  The semantic parts of
 * call and scope stacks still affect future edges and therefore remain in the
 * key.  Equality checks the complete linked state after the hash bucket
 * matches. */
static uint64_t
onibi_tagged_calls_hash(const OnibiSemanticArena *arena, uint32_t root)
{
    uint64_t hash = UINT64_C(0xcbf29ce484222325);
    uint32_t depth = 0;
    while (root != UINT32_MAX) {
	if (root >= arena->call_count) return 0;
	const OnibiCallFrame *frame = &arena->calls[root].frame;
	hash = onibi_semantic_hash_value(hash, frame->subprogram_id);
	hash = onibi_semantic_hash_value(hash, frame->continuation);
	hash = onibi_semantic_hash_value(hash, frame->recursion_depth);
	hash = onibi_semantic_hash_value(
	    hash,
	    arena->calls[root].caller_tag_history == UINT32_MAX
		? UINT64_C(0x84222325cbf29ce4)
		: arena->tags[arena->calls[root].caller_tag_history].hash);
	hash = onibi_semantic_hash_value(
	    hash, arena->calls[root].caller_captures.slot_count);
	hash = onibi_semantic_hash_value(
	    hash, arena->calls[root].caller_captures.hash);
	hash = onibi_semantic_hash_value(
	    hash, arena->calls[root].caller_condition_captures.slot_count);
	hash = onibi_semantic_hash_value(
	    hash, arena->calls[root].caller_condition_captures.hash);
	hash = onibi_semantic_hash_value(
	    hash, arena->calls[root].caller_counters.slot_count);
	hash = onibi_semantic_hash_value(
	    hash, arena->calls[root].caller_counters.hash);
	hash = onibi_semantic_hash_value(
	    hash, arena->calls[root].caller_progress.slot_count);
	hash = onibi_semantic_hash_value(
	    hash, arena->calls[root].caller_progress.hash);
	root = arena->calls[root].parent;
	depth++;
    }
    return onibi_semantic_hash_value(hash, depth);
}

static int
onibi_semantic_tag_history_equal(const OnibiSemanticArena *arena,
				 OnibiTagEventId left, OnibiTagEventId right)
{
    while (left != UINT32_MAX && right != UINT32_MAX) {
	const OnibiSemanticTagEvent *a = &arena->tags[left];
	const OnibiSemanticTagEvent *b = &arena->tags[right];
	if (a->slot != b->slot || a->position != b->position) return 0;
	left = a->parent;
	right = b->parent;
    }
    return left == right;
}

static int
onibi_tagged_calls_equal(OnibiSemanticArena *arena, uint32_t left,
			 uint32_t right)
{
    while (left != UINT32_MAX && right != UINT32_MAX) {
	if (left >= arena->call_count || right >= arena->call_count) return 0;
	const OnibiCallFrame *a = &arena->calls[left].frame;
	const OnibiCallFrame *b = &arena->calls[right].frame;
	if (a->subprogram_id != b->subprogram_id ||
	    a->continuation != b->continuation ||
	    a->recursion_depth != b->recursion_depth ||
	    !onibi_semantic_tag_history_equal(
		arena, arena->calls[left].caller_tag_history,
		arena->calls[right].caller_tag_history) ||
	    arena->calls[left].caller_captures.slot_count !=
		arena->calls[right].caller_captures.slot_count ||
	    !onibi_semantic_register_file_equal(
		arena, arena->calls[left].caller_captures.root,
		arena->calls[right].caller_captures.root,
		arena->calls[left].caller_captures.hash,
		arena->calls[right].caller_captures.hash,
		arena->calls[left].caller_captures.slot_count, -1) ||
	    !onibi_semantic_condition_capture_file_equal(
		arena, &arena->calls[left].caller_condition_captures,
		&arena->calls[right].caller_condition_captures) ||
	    arena->calls[left].caller_counters.slot_count !=
		arena->calls[right].caller_counters.slot_count ||
	    arena->calls[left].caller_progress.slot_count !=
		arena->calls[right].caller_progress.slot_count ||
	    !onibi_semantic_register_file_equal(
		arena, arena->calls[left].caller_counters.root,
		arena->calls[right].caller_counters.root,
		arena->calls[left].caller_counters.hash,
		arena->calls[right].caller_counters.hash,
		arena->calls[left].caller_counters.slot_count, 0) ||
	    !onibi_semantic_register_file_equal(
		arena, arena->calls[left].caller_progress.root,
		arena->calls[right].caller_progress.root,
		arena->calls[left].caller_progress.hash,
		arena->calls[right].caller_progress.hash,
		arena->calls[left].caller_progress.slot_count, -1))
	    return 0;
	left = arena->calls[left].parent;
	right = arena->calls[right].parent;
    }
    return left == right;
}

static uint64_t
onibi_tagged_scopes_hash(const OnibiSemanticScope *nodes, size_t count,
			 uint32_t root, uint64_t domain)
{
    uint64_t hash =
	onibi_semantic_hash_value(UINT64_C(0x84222325cbf29ce4), domain);
    uint32_t depth = 0;
    while (root != UINT32_MAX) {
	if (root >= count) return 0;
	const OnibiSemanticScope *scope = &nodes[root];
	hash = onibi_semantic_hash_value(hash, scope->subprogram_id);
	hash = onibi_semantic_hash_value(hash, (uint64_t)scope->begin);
	hash = onibi_semantic_hash_value(hash, (uint64_t)scope->end);
	hash = onibi_semantic_hash_value(hash, scope->flags);
	root = scope->parent;
	depth++;
    }
    return onibi_semantic_hash_value(hash, depth);
}

static int
onibi_tagged_scopes_equal(const OnibiSemanticScope *nodes, size_t count,
			  uint32_t left, uint32_t right)
{
    while (left != UINT32_MAX && right != UINT32_MAX) {
	if (left >= count || right >= count) return 0;
	const OnibiSemanticScope *a = &nodes[left];
	const OnibiSemanticScope *b = &nodes[right];
	if (a->subprogram_id != b->subprogram_id || a->begin != b->begin ||
	    a->end != b->end || a->flags != b->flags)
	    return 0;
	left = a->parent;
	right = b->parent;
    }
    return left == right;
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
    hash = onibi_semantic_hash_value(hash, state->condition_captures.hash);
    hash = onibi_semantic_hash_value(hash, state->counters.hash);
    hash = onibi_semantic_hash_value(hash, state->progress.hash);
    hash = onibi_semantic_hash_value(
	hash, onibi_tagged_calls_hash(arena, state->calls.root));
    hash = onibi_semantic_hash_value(
	hash, onibi_tagged_scopes_hash(arena->atomic, arena->atomic_count,
				       state->atomic.root,
				       ONIBI_SEMANTIC_HASH_ATOMIC));
    hash = onibi_semantic_hash_value(
	hash, onibi_tagged_scopes_hash(arena->absence, arena->absence_count,
				       state->absence.root,
				       ONIBI_SEMANTIC_HASH_ABSENCE));
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
	   a->condition_captures.slot_count ==
	       b->condition_captures.slot_count &&
	   a->counters.slot_count == b->counters.slot_count &&
	   a->progress.slot_count == b->progress.slot_count &&
	   a->calls.depth == b->calls.depth &&
	   a->atomic.depth == b->atomic.depth &&
	   a->absence.depth == b->absence.depth &&
	   onibi_semantic_capture_file_equal(arena, &a->semantic_captures,
					     &b->semantic_captures) &&
	   onibi_semantic_condition_capture_file_equal(
	       arena, &a->condition_captures, &b->condition_captures) &&
	   onibi_semantic_register_file_equal(
	       arena, a->counters.root, b->counters.root, a->counters.hash,
	       b->counters.hash, a->counters.slot_count, 0) &&
	   onibi_semantic_register_file_equal(
	       arena, a->progress.root, b->progress.root, a->progress.hash,
	       b->progress.hash, a->progress.slot_count, -1) &&
	   onibi_tagged_calls_equal(arena, a->calls.root, b->calls.root) &&
	   onibi_tagged_scopes_equal(arena->atomic, arena->atomic_count,
				     a->atomic.root, b->atomic.root) &&
	   onibi_tagged_scopes_equal(arena->absence, arena->absence_count,
				     a->absence.root, b->absence.root);
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
		       OnibiBytePos position,
		       const OnibiSemanticState *semantic)
{
    if (arena->key_capacity == 0 ||
	arena->key_count >= arena->key_capacity - arena->key_capacity / 4U) {
	onibi_dynamic_key_set_grow(arena);
    }
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

/* Keep a separate path-local guard for zero-width cycles.  The global key set
 * removes equivalent sibling work.  It must not erase semantic state that a
 * later edge can observe. */
static int
onibi_dynamic_cycle_seen(OnibiSemanticArena *arena,
			 const OnibiDynamicThreadKey *key, uint32_t parent,
			 uint32_t *cycle_root)
{
    for (uint32_t cursor = parent; cursor != UINT32_MAX;) {
	if (cursor >= arena->cycle_count) return 1;
	const OnibiDynamicCycleNode *node = &arena->cycles[cursor];
	if (onibi_dynamic_thread_key_equal(arena, &node->key, key)) return 1;
	cursor = node->parent;
    }
    arena->cycles = onibi_semantic_arena_reserve(
	arena->cycles, &arena->cycle_capacity, arena->cycle_count,
	sizeof(*arena->cycles));
    uint32_t index = (uint32_t)arena->cycle_count++;
    arena->cycles[index] = (OnibiDynamicCycleNode){parent, *key};
    *cycle_root = index;
    return 0;
}

/* This predicate is not a thread identity test.  It only identifies a
 * zero-width re-entry whose future state is unchanged apart from repeat
 * counters.  Order and event histories only materialize output after accept.
 * Keep every value that a later edge can read; the caller may remove the
 * re-entry only after it has a non-cyclic successor. */
static int
onibi_dynamic_cycle_non_counter_equal(OnibiSemanticArena *arena,
				      const OnibiSemanticState *left,
				      const OnibiSemanticState *right)
{
    if (left->reported_start != right->reported_start ||
	left->semantic_captures.slot_count !=
	    right->semantic_captures.slot_count ||
	left->condition_captures.slot_count !=
	    right->condition_captures.slot_count ||
	left->progress.slot_count != right->progress.slot_count ||
	left->calls.depth != right->calls.depth ||
	left->atomic.depth != right->atomic.depth ||
	left->absence.depth != right->absence.depth) {
	return 0;
    }
    return onibi_semantic_future_capture_file_equal(
	       arena, &left->semantic_captures, &right->semantic_captures) &&
	   onibi_semantic_condition_capture_file_equal(
	       arena, &left->condition_captures, &right->condition_captures) &&
	   onibi_semantic_register_file_equal(
	       arena, left->progress.root, right->progress.root,
	       left->progress.hash, right->progress.hash,
	       left->progress.slot_count, -1) &&
	   onibi_tagged_calls_equal(arena, left->calls.root,
				    right->calls.root) &&
	   onibi_tagged_scopes_equal(arena->atomic, arena->atomic_count,
				     left->atomic.root, right->atomic.root) &&
	   onibi_tagged_scopes_equal(arena->absence, arena->absence_count,
				     left->absence.root, right->absence.root);
}

static int
onibi_dynamic_cycle_redundant(OnibiSemanticArena *arena,
			      const OnibiDynamicFrame *frame)
{
    for (uint32_t cursor = frame->cycle_root; cursor != UINT32_MAX;) {
	if (cursor >= arena->cycle_count) return 1;
	const OnibiDynamicCycleNode *node = &arena->cycles[cursor];
	if (node->key.state_id == frame->state &&
	    node->key.position == frame->position &&
	    onibi_dynamic_cycle_non_counter_equal(arena, &node->key.semantic,
						  &frame->semantic))
	    return 1;
	cursor = node->parent;
    }
    return 0;
}

/* Remove redundant cycle re-entries only when this expansion also produced a
 * non-cyclic successor.  The global key still keeps every counter value.
 * This local omission is safe only after an exit path is ready; if the
 * expansion has only cycle re-entries, keep them so the compiled repeat
 * bound can advance. */
static void
onibi_dynamic_cycle_prune_redundant(OnibiSemanticArena *arena, size_t base)
{
    int have_noncycle = 0;
    for (size_t i = base; i < arena->frame_count; i++)
	if (!onibi_dynamic_cycle_redundant(arena, &arena->frames[i])) {
	    have_noncycle = 1;
	    break;
	}
    if (!have_noncycle) return;
    size_t write = base;
    for (size_t i = base; i < arena->frame_count; i++)
	if (!onibi_dynamic_cycle_redundant(arena, &arena->frames[i]))
	    arena->frames[write++] = arena->frames[i];
    arena->frame_count = write;
}

/* TAGGED_ORDERED keeps every value that can change a later edge or the
 * reported match.  Ordinary output tags and their order history use the first
 * path's priority and do not split equivalent threads. */
static uint64_t
onibi_tagged_thread_key_hash(OnibiSemanticArena *arena,
			     const OnibiDynamicThreadKey *key)
{
    arena->key_hash_count++;
    uint64_t hash =
	onibi_semantic_hash_value(UINT64_C(0xcbf29ce484222325), key->state_id);
    hash =
	onibi_semantic_hash_value(hash, (uint64_t)key->semantic.reported_start);
    hash = onibi_semantic_hash_value(hash, key->semantic.counters.hash);
    hash =
	onibi_semantic_hash_value(hash, key->semantic.semantic_captures.hash);
    hash =
	onibi_semantic_hash_value(hash, key->semantic.condition_captures.hash);
    hash = onibi_semantic_hash_value(hash, key->semantic.progress.hash);
    hash = onibi_semantic_hash_value(hash, key->semantic.calls.depth);
    hash = onibi_semantic_hash_value(
	hash, onibi_tagged_calls_hash(arena, key->semantic.calls.root));
    hash = onibi_semantic_hash_value(hash, key->semantic.atomic.depth);
    hash = onibi_semantic_hash_value(
	hash, onibi_tagged_scopes_hash(arena->atomic, arena->atomic_count,
				       key->semantic.atomic.root,
				       ONIBI_SEMANTIC_HASH_ATOMIC));
    hash = onibi_semantic_hash_value(hash, key->semantic.absence.depth);
    return onibi_semantic_hash_value(
	hash, onibi_tagged_scopes_hash(arena->absence, arena->absence_count,
				       key->semantic.absence.root,
				       ONIBI_SEMANTIC_HASH_ABSENCE));
}

static int
onibi_tagged_thread_key_equal(OnibiSemanticArena *arena,
			      const OnibiDynamicThreadKey *left,
			      const OnibiDynamicThreadKey *right)
{
    const OnibiSemanticState *a = &left->semantic;
    const OnibiSemanticState *b = &right->semantic;
    return left->hash == right->hash && left->state_id == right->state_id &&
	   a->reported_start == b->reported_start &&
	   a->semantic_captures.slot_count == b->semantic_captures.slot_count &&
	   a->condition_captures.slot_count ==
	       b->condition_captures.slot_count &&
	   a->counters.slot_count == b->counters.slot_count &&
	   a->progress.slot_count == b->progress.slot_count &&
	   a->calls.depth == b->calls.depth &&
	   a->atomic.depth == b->atomic.depth &&
	   a->absence.depth == b->absence.depth &&
	   onibi_semantic_capture_file_equal(arena, &a->semantic_captures,
					     &b->semantic_captures) &&
	   onibi_semantic_condition_capture_file_equal(
	       arena, &a->condition_captures, &b->condition_captures) &&
	   onibi_semantic_register_file_equal(
	       arena, a->counters.root, b->counters.root, a->counters.hash,
	       b->counters.hash, a->counters.slot_count, 0) &&
	   onibi_semantic_register_file_equal(
	       arena, a->progress.root, b->progress.root, a->progress.hash,
	       b->progress.hash, a->progress.slot_count, -1) &&
	   onibi_tagged_calls_equal(arena, a->calls.root, b->calls.root) &&
	   onibi_tagged_scopes_equal(arena->atomic, arena->atomic_count,
				     a->atomic.root, b->atomic.root) &&
	   onibi_tagged_scopes_equal(arena->absence, arena->absence_count,
				     a->absence.root, b->absence.root);
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
    size_t capture_event_count;
    size_t capture_event_root_count;
    size_t capture_event_owner_count;
    size_t register_count;
    size_t tag_count;
    size_t call_count;
    size_t atomic_count;
    size_t absence_count;
} OnibiSemanticCheckpoint;

static OnibiSemanticCheckpoint
onibi_semantic_checkpoint_save(const OnibiSemanticArena *arena)
{
    return (OnibiSemanticCheckpoint){
	.capture_event_count = arena->capture_event_count,
	.capture_event_root_count = arena->capture_event_root_count,
	.capture_event_owner_count = arena->capture_event_owner_count,
	.register_count = arena->register_count,
	.tag_count = arena->tag_count,
	.call_count = arena->call_count,
	.atomic_count = arena->atomic_count,
	.absence_count = arena->absence_count};
}

static void
onibi_semantic_checkpoint_restore(OnibiSemanticArena *arena,
				  const OnibiSemanticCheckpoint *checkpoint);

static OnibiActionResult onibi_tagged_assert_subprogram(
    OnibiExecCtx *ctx, const OnibiRAction *action, OnibiBytePos position,
    const OnibiSemanticState *predecessor, OnibiSemanticState *successor);
static OnibiActionResult onibi_dynamic_assert_subprogram(
    OnibiExecCtx *ctx, const OnibiRAction *action, OnibiBytePos position,
    const OnibiSemanticState *predecessor, OnibiSemanticState *successor);
static int onibi_dynamic_absence_consume(
    VALUE rseq, const OnibiRSeqView *view, VALUE str, OnibiBytePos position,
    uint32_t subprogram_id, const OnibiSemanticState *input,
    OnibiSemanticArena *arena, unsigned char *class_stack,
    size_t class_stack_capacity, OnibiExecCtx *ctx, OnibiBytePos *next_position,
    OnibiBytePos *minimum_position, OnibiSemanticState *output);
static int onibi_tagged_lookbehind_start(OnibiExecCtx *ctx,
					 OnibiBytePos position, uint32_t width,
					 OnibiBytePos *start);
static void onibi_tagged_frontier_reset(OnibiFrontier *frontier,
					uint32_t state_count);
static int onibi_tagged_frontier_add(OnibiFrontier *frontier,
				     OnibiSemanticArena *arena, uint32_t state,
				     const OnibiSemanticState *semantic,
				     uint32_t *retained_owner);
static int onibi_tagged_materialize_tags(OnibiSemanticArena *arena,
					 const OnibiSemanticState *accepted,
					 OnibiRawMatch *raw_match,
					 uint32_t capture_slots);

static OnibiTagEventId
onibi_dynamic_capture_open_id(const OnibiSemanticArena *arena,
			      OnibiTagEventId history, uint32_t capture)
{
    uint32_t begin = capture * 2U;
    uint32_t end = begin + 1U;
    int closed = 0;
    while (history != UINT32_MAX) {
	const OnibiSemanticTagEvent *event = &arena->tags[history];
	if (!closed && event->slot == end)
	    closed = 1;
	else if (closed && event->slot == begin)
	    return history;
	history = event->parent;
    }
    return UINT32_MAX;
}

static void
onibi_dynamic_absence_filter_captures(OnibiSemanticArena *arena,
				      OnibiSemanticState *accepted,
				      const OnibiSemanticState *terminal)
{
    uint32_t slots = accepted->semantic_captures.slot_count;
    unsigned char *clear = slots == 0 ? NULL : ruby_xcalloc(slots, 1);
    for (uint32_t capture = 0; capture * 2U + 1U < slots; capture++) {
	OnibiTagEventId open = onibi_dynamic_capture_open_id(
	    arena, accepted->tag_history, capture);
	OnibiTagEventId terminal_open = onibi_dynamic_capture_open_id(
	    arena, terminal->tag_history, capture);
	if (open != UINT32_MAX && open != terminal_open)
	    clear[capture * 2U] = clear[capture * 2U + 1U] = 1;
    }
    int any = 0;
    for (uint32_t slot = 0; slot < slots; slot++)
	if (clear[slot]) any = 1;
    if (any) {
	OnibiTagEventId *events = NULL;
	size_t count = 0;
	for (OnibiTagEventId id = accepted->tag_history; id != UINT32_MAX;
	     id = arena->tags[id].parent)
	    count++;
	if (count != 0) events = ruby_xmalloc(count * sizeof(*events));
	size_t index = 0;
	for (OnibiTagEventId id = accepted->tag_history; id != UINT32_MAX;
	     id = arena->tags[id].parent)
	    events[index++] = id;
	accepted->tag_history = UINT32_MAX;
	while (index != 0) {
	    const OnibiSemanticTagEvent *event = &arena->tags[events[--index]];
	    if (event->slot < slots && clear[event->slot]) continue;
	    accepted->tag_history = onibi_semantic_tag_append(
		arena, accepted->tag_history, event->slot, event->position);
	}
	for (uint32_t slot = 0; slot < slots; slot++)
	    if (clear[slot])
		onibi_semantic_capture_write(
		    arena, &accepted->semantic_captures, slot, -1);
	ruby_xfree(events);
    }
    ruby_xfree(clear);
}

static OnibiActionResult
onibi_apply_action_program(const OnibiRSeqView *view, const OnibiREdge *edge,
			   VALUE str, OnibiBytePos pos,
			   OnibiBytePos search_origin, rb_encoding *encoding,
			   OnibiEncodingMode mode, OnibiSemanticArena *arena,
			   const OnibiSemanticState *predecessor,
			   OnibiSemanticState *successor, OnibiExecCtx *ctx)
{
    OnibiSemanticCheckpoint checkpoint = onibi_semantic_checkpoint_save(arena);
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
	if (action->op == ONIBI_RA_ORDER) {
	    working.order =
		onibi_capture_order_append(arena, working.order, action->arg32);
	    continue;
	}
	if (working.order != UINT32_MAX)
	    working.order = onibi_capture_order_append(arena, working.order, 0);
	if (action->op == ONIBI_RA_CAPTURE) {
	    if (action->arg16 >= working.semantic_captures.slot_count)
		goto fail;
	    uint32_t previous_capture_root = working.semantic_captures.root;
	    OnibiBytePos previous_condition = onibi_semantic_position_read(
		arena, working.condition_captures.root, action->arg16, -1);
	    onibi_semantic_capture_write(arena, &working.semantic_captures,
					 action->arg16, pos);
	    if (working.condition_captures.root == previous_capture_root) {
		/* The condition file can share the capture file until an
		 * absence filter removes a value from the semantic file. */
		working.condition_captures.root =
		    working.semantic_captures.root;
		if (onibi_semantic_capture_slot_live(arena, action->arg16) &&
		    previous_condition != pos) {
		    working.condition_captures.hash ^=
			onibi_semantic_register_slot_hash(
			    ONIBI_SEMANTIC_HASH_CAPTURE, action->arg16,
			    previous_condition);
		    working.condition_captures.hash ^=
			onibi_semantic_register_slot_hash(
			    ONIBI_SEMANTIC_HASH_CAPTURE, action->arg16, pos);
		}
	    }
	    else
		onibi_semantic_condition_capture_write(
		    arena, &working.condition_captures, action->arg16, pos);
	    if (action->flags == ONIBI_RA_CAPTURE_OPEN_UNSCOPED) {
		working.capture_event_history =
		    onibi_semantic_capture_event_append(
			arena, working.capture_event_history, working.order,
			action->arg16, pos);
	    }
	    working.tag_history = onibi_semantic_tag_append(
		arena, working.tag_history, action->arg16, pos);
	    continue;
	}
	if (action->op >= ONIBI_RA_NULL_ENTER &&
	    action->op <= ONIBI_RA_NULL_STOP) {
	    uint32_t slot = action->arg16;
	    if (slot + 1U >= working.progress.slot_count) goto fail;
	    OnibiBytePos status = onibi_semantic_position_read(
		arena, working.progress.root, slot + 1U, -1);
	    if (action->op == ONIBI_RA_NULL_ENTER) {
		onibi_semantic_progress_write(arena, &working.progress, slot,
					      pos);
		onibi_semantic_progress_write(arena, &working.progress,
					      slot + 1U, 1);
	    }
	    else if (action->op == ONIBI_RA_NULL_CAPTURE) {
		uint32_t capture = action->arg32 * 2U;
		OnibiBytePos begin = onibi_semantic_position_read(
		    arena, working.semantic_captures.root, capture, -1);
		OnibiBytePos end = onibi_semantic_position_read(
		    arena, working.semantic_captures.root, capture + 1U, -1);
		if (status != 0) {
		    if (end < 0 || begin != end)
			status = 0;
		    else if (end != pos)
			status = -1;
		    onibi_semantic_progress_write(arena, &working.progress,
						  slot + 1U, status);
		}
	    }
	    else {
		OnibiBytePos entry = onibi_semantic_position_read(
		    arena, working.progress.root, slot, -1);
		int continuing = entry != pos || status == 0;
		if ((entry == pos && status < 0) ||
		    (action->op == ONIBI_RA_NULL_CONTINUE ? !continuing
							  : continuing))
		    goto fail;
	    }
	    continue;
	}
	if (action->op == ONIBI_RA_TEST_CAPTURE) {
	    uint32_t begin = (uint32_t)action->arg16 * 2U;
	    if (begin + 1U >= working.semantic_captures.slot_count) goto fail;
	    int set =
		onibi_semantic_position_read(
		    arena, working.condition_captures.root, begin, -1) >= 0 &&
		onibi_semantic_position_read(arena,
					     working.condition_captures.root,
					     begin + 1U, -1) >= 0;
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
	    if (onibi_semantic_position_read(arena, working.progress.root,
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
	    OnibiRepeatCount current = onibi_semantic_counter_read(
		arena, working.counters.root, action->arg16, 0);
	    if (action->op == ONIBI_RA_COUNTER_SET)
		onibi_semantic_counter_write(arena, &working.counters,
					     action->arg16,
					     (OnibiRepeatCount)action->arg32);
	    else if (action->op == ONIBI_RA_COUNTER_ADD)
		onibi_semantic_counter_write(arena, &working.counters,
					     action->arg16, current + 1);
	    else {
		int hit = action->flags == ONIBI_RA_COUNTER_GE
			      ? current >= (OnibiRepeatCount)action->arg32
			      : current < (OnibiRepeatCount)action->arg32;
		if (!hit) goto fail;
	    }
	    continue;
	}
	if (action->op == ONIBI_RA_ASSERT_SUBPROGRAM) {
	    OnibiSemanticState assertion_state;
	    if (ctx == NULL ||
		((ctx->program != NULL &&
			  ctx->program->exec_kind == ONIBI_EXEC_DYNAMIC
		      ? onibi_dynamic_assert_subprogram
		      : onibi_tagged_assert_subprogram)(
		     ctx, action, pos, &working, &assertion_state) ==
		 ONIBI_ACTION_FAIL))
		goto fail;
	    working = assertion_state;
	    continue;
	}
	if (action->op != ONIBI_RA_ASSERT_POSITION) goto fail;
	if (!onibi_rseq_position_assertion_hit((OnibiRAssertKind)action->arg16,
					       str, pos, search_origin,
					       encoding, mode))
	    goto fail;
    }
fail:
    onibi_semantic_checkpoint_restore(arena, &checkpoint);
    return ONIBI_ACTION_FAIL;
}

typedef enum {
    ONIBI_ASSERT_DIAG_FAILED_TRIAL,
    ONIBI_ASSERT_DIAG_NEGATIVE_SUCCESS,
    ONIBI_ASSERT_DIAG_NEGATIVE_FAILURE,
    ONIBI_ASSERT_DIAG_LOOKBEHIND_TRIAL,
    ONIBI_ASSERT_DIAG_PARENT_FAILURE,
    ONIBI_ASSERT_DIAG_POSITIVE_SUCCESS
} OnibiAssertionDiagnosticKind;

typedef struct {
    OnibiActionResult status;
    size_t capture_event_count;
    OnibiBytePos capture_begin;
} OnibiAssertionDiagnostic;

static OnibiAssertionDiagnostic
onibi_assertion_event_diagnostic(OnibiAssertionDiagnosticKind kind)
{
    int lookbehind = kind == ONIBI_ASSERT_DIAG_LOOKBEHIND_TRIAL;
    int parent_failure = kind == ONIBI_ASSERT_DIAG_PARENT_FAILURE;
    int failed_trial = kind == ONIBI_ASSERT_DIAG_FAILED_TRIAL ||
		       kind == ONIBI_ASSERT_DIAG_NEGATIVE_SUCCESS;
    int positive = kind != ONIBI_ASSERT_DIAG_NEGATIVE_SUCCESS &&
		   kind != ONIBI_ASSERT_DIAG_NEGATIVE_FAILURE;
    int direct_success = !failed_trial && !lookbehind;
    OnibiAssertionDiagnostic diagnostic = {ONIBI_ACTION_FAIL, 0, -1};
    OnibiExecCtx ctx;
    memset(&ctx, 0, sizeof(ctx));
    OnibiSemanticArena *arena = &ctx.semantic_arena;
    OnibiFrontier frontiers[2];
    memset(frontiers, 0, sizeof(frontiers));
    OnibiRSeqHeader header;
    memset(&header, 0, sizeof(header));
    OnibiRState states[2];
    memset(states, 0, sizeof(states));
    OnibiREdge edges[4];
    memset(edges, 0, sizeof(edges));
    OnibiRAction actions[6] = {
	{ONIBI_RA_ORDER, 0, 0, 0},
	{ONIBI_RA_CAPTURE, ONIBI_RA_CAPTURE_OPEN_UNSCOPED, 0, 0},
	{ONIBI_RA_END, 0, 0, 0},
	{ONIBI_RA_ASSERT_SUBPROGRAM, positive ? 1 : 2,
	 (uint16_t)(lookbehind ? ONIBI_RAP_LOOKBEHIND : ONIBI_RAP_LOOKAHEAD),
	 1},
	{ONIBI_RA_END, 0, 0, 0},
	{ONIBI_RA_END, 0, 0, 0}};
    OnibiSubprogramDesc subprograms[2];
    memset(subprograms, 0, sizeof(subprograms));
    uint32_t lookbehind_widths[2] = {1, 2};
    OnibiLiteralDesc literal = {0, 1, 0};
    unsigned char literal_blob[1] = {'b'};
    VALUE subject = rb_str_new_cstr(lookbehind ? "ab" : "abc");
    rb_encoding *encoding = rb_enc_get(subject);
    OnibiBytePos position = lookbehind ? 2 : 0;

    if (parent_failure)
	actions[4] = (OnibiRAction){ONIBI_RA_ASSERT_POSITION, 0,
				    ONIBI_RAP_END_BUFFER, 0};
    header.state_count = direct_success ? 1 : 2;
    header.edge_count = direct_success ? 2 : lookbehind ? 4 : 3;
    header.action_count = parent_failure ? 6 : 3;
    header.subprogram_count = 2;
    header.capture_count = 1;
    header.lookbehind_width_count = lookbehind ? 2 : 0;
    if (direct_success) {
	edges[0] = (OnibiREdge){ONIBI_ACCEPT_STATE, sizeof(OnibiRAction)};
	edges[1] = (OnibiREdge){ONIBI_ACCEPT_STATE, 4U * sizeof(OnibiRAction)};
    }
    else if (lookbehind) {
	edges[0] = (OnibiREdge){0, 0};
	edges[1] = (OnibiREdge){1, sizeof(OnibiRAction)};
	edges[2] = (OnibiREdge){ONIBI_ACCEPT_STATE, 0};
	edges[3] = (OnibiREdge){ONIBI_ACCEPT_STATE, 4U * sizeof(OnibiRAction)};
	states[0] = (OnibiRState){1, 0, 1, ONIBI_RS_ANY, 0};
	states[1] = (OnibiRState){2, 0, 1, ONIBI_RS_CHAR, 0};
    }
    else {
	edges[0] = (OnibiREdge){0, 0};
	edges[1] = (OnibiREdge){1, sizeof(OnibiRAction)};
	edges[2] = (OnibiREdge){ONIBI_ACCEPT_STATE, 4U * sizeof(OnibiRAction)};
	states[0] = (OnibiRState){1, 0, 1, ONIBI_RS_ANY, 0};
	states[1] = (OnibiRState){0, 0, 0, ONIBI_RS_ANY, 0};
    }
    subprograms[1].entry = 0;
    subprograms[1].accept = direct_success ? 0 : 1;
    subprograms[1].entry_edge_base = 0;
    subprograms[1].entry_edge_count = 1;
    subprograms[1].width_count = lookbehind ? 2 : 0;
    subprograms[1].kind =
	lookbehind ? ONIBI_SUBPROGRAM_LOOKBEHIND : ONIBI_SUBPROGRAM_LOOKAHEAD;
    subprograms[1].effects = positive
				 ? ONIBI_SUBPROGRAM_EFFECT_POSITIVE |
				       ONIBI_SUBPROGRAM_EFFECT_PUBLISH_CAPTURES
				 : 0;

    OnibiRSeqView view;
    memset(&view, 0, sizeof(view));
    view.blob = literal_blob;
    view.header = &header;
    view.states = states;
    view.edges = edges;
    view.actions = actions;
    view.literals = &literal;
    view.subprograms = subprograms;
    view.lookbehind_widths = lookbehind_widths;
    ctx.subject = subject;
    ctx.view = &view;
    ctx.search_origin = 0;
    ctx.encoding = encoding;
    ctx.encoding_mode = onibi_encoding_mode_for(subject, encoding);
    ctx.assertion_frontiers = frontiers;
    ctx.assertion_frontier_count = 2;
    onibi_semantic_live_captures_begin(arena, 1);
    onibi_semantic_live_capture_add(arena, 0);
    OnibiSemanticState predecessor =
	onibi_semantic_state_initial(arena, 0, 2, 0, 0);
    OnibiSemanticState successor;
    if (parent_failure) {
	diagnostic.status = onibi_apply_action_program(
	    &view, &edges[1], subject, position, 0, encoding, ctx.encoding_mode,
	    arena, &predecessor, &successor, &ctx);
    }
    else {
	diagnostic.status = onibi_tagged_assert_subprogram(
	    &ctx, &actions[3], position, &predecessor, &successor);
    }
    diagnostic.capture_event_count = arena->capture_event_count;
    if (diagnostic.status == ONIBI_ACTION_SUCCESS)
	diagnostic.capture_begin = onibi_semantic_position_read(
	    arena, successor.semantic_captures.root, 0, -1);

    for (size_t i = 0; i < 2; i++) {
	ruby_xfree(frontiers[i].states);
	ruby_xfree(frontiers[i].semantics);
	ruby_xfree(frontiers[i].failure_owners);
	ruby_xfree(frontiers[i].hashes);
	ruby_xfree(frontiers[i].key_buckets);
	ruby_xfree(frontiers[i].membership);
    }
    onibi_semantic_arena_release(arena);
    return diagnostic;
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
	    &predecessor, &successor, NULL);
	rb_hash_aset(result, ID2SYM(rb_intern("success")),
		     status == ONIBI_ACTION_SUCCESS ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("predecessor_reported_start")),
		     LONG2NUM(predecessor.reported_start));
	rb_hash_aset(result, ID2SYM(rb_intern("sibling_reported_start")),
		     LONG2NUM(sibling.reported_start));
	rb_hash_aset(result, ID2SYM(rb_intern("successor_reported_start")),
		     LONG2NUM(successor.reported_start));
	rb_hash_aset(result, ID2SYM(rb_intern("predecessor_capture")),
		     LONG2NUM(onibi_semantic_position_read(
			 &arena, predecessor.semantic_captures.root, 0, -1)));
	rb_hash_aset(result, ID2SYM(rb_intern("sibling_capture")),
		     LONG2NUM(onibi_semantic_position_read(
			 &arena, sibling.semantic_captures.root, 0, -1)));
	rb_hash_aset(result, ID2SYM(rb_intern("successor_capture")),
		     LONG2NUM(onibi_semantic_position_read(
			 &arena, successor.semantic_captures.root, 0, -1)));
	rb_hash_aset(result, ID2SYM(rb_intern("successor_counter")),
		     LONG2NUM(onibi_semantic_counter_read(
			 &arena, successor.counters.root, 0, 0)));
	rb_hash_aset(result, ID2SYM(rb_intern("successor_progress")),
		     LONG2NUM(onibi_semantic_position_read(
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
	variants[6].semantic.calls.root = onibi_semantic_call_push(
	    &arena, UINT32_MAX, &call, UINT32_MAX,
	    predecessor.semantic_captures, predecessor.condition_captures,
	    predecessor.counters, predecessor.progress);
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

    if (scenario == rb_intern("capture_key_observability")) {
	onibi_semantic_live_captures_begin(&arena, 2);
	onibi_semantic_live_capture_add(&arena, 1);
	predecessor = onibi_semantic_state_initial(&arena, 0, 4, 0, 0);
	OnibiDynamicThreadKey dynamic_base = {3, 5, predecessor, 0};
	OnibiDynamicThreadKey dynamic_output = dynamic_base;
	OnibiDynamicThreadKey dynamic_condition = dynamic_base;
	OnibiSemanticState *output_state = &dynamic_output.semantic;
	OnibiSemanticState *condition_state = &dynamic_condition.semantic;
	onibi_semantic_condition_capture_write(
	    &arena, &output_state->condition_captures, 0, 7);
	onibi_semantic_condition_capture_write(
	    &arena, &condition_state->condition_captures, 2, 7);
	dynamic_base.hash =
	    onibi_dynamic_thread_key_hash(&arena, &dynamic_base);
	dynamic_output.hash =
	    onibi_dynamic_thread_key_hash(&arena, &dynamic_output);
	dynamic_condition.hash =
	    onibi_dynamic_thread_key_hash(&arena, &dynamic_condition);
	OnibiDynamicThreadKey tagged_base = dynamic_base;
	OnibiDynamicThreadKey tagged_output = dynamic_output;
	OnibiDynamicThreadKey tagged_condition = dynamic_condition;
	tagged_base.hash = onibi_tagged_thread_key_hash(&arena, &tagged_base);
	tagged_output.hash =
	    onibi_tagged_thread_key_hash(&arena, &tagged_output);
	tagged_condition.hash =
	    onibi_tagged_thread_key_hash(&arena, &tagged_condition);
	VALUE dynamic = rb_hash_new();
	VALUE tagged = rb_hash_new();
	rb_hash_aset(dynamic, ID2SYM(rb_intern("output_equal")),
		     onibi_dynamic_thread_key_equal(&arena, &dynamic_base,
						    &dynamic_output)
			 ? Qtrue
			 : Qfalse);
	rb_hash_aset(dynamic, ID2SYM(rb_intern("output_hash_equal")),
		     dynamic_base.hash == dynamic_output.hash ? Qtrue : Qfalse);
	rb_hash_aset(dynamic, ID2SYM(rb_intern("condition_distinct")),
		     onibi_dynamic_thread_key_equal(&arena, &dynamic_base,
						    &dynamic_condition)
			 ? Qfalse
			 : Qtrue);
	rb_hash_aset(dynamic, ID2SYM(rb_intern("condition_hash_distinct")),
		     dynamic_base.hash != dynamic_condition.hash ? Qtrue
								 : Qfalse);
	rb_hash_aset(
	    tagged, ID2SYM(rb_intern("output_equal")),
	    onibi_tagged_thread_key_equal(&arena, &tagged_base, &tagged_output)
		? Qtrue
		: Qfalse);
	rb_hash_aset(tagged, ID2SYM(rb_intern("output_hash_equal")),
		     tagged_base.hash == tagged_output.hash ? Qtrue : Qfalse);
	rb_hash_aset(tagged, ID2SYM(rb_intern("condition_distinct")),
		     onibi_tagged_thread_key_equal(&arena, &tagged_base,
						   &tagged_condition)
			 ? Qfalse
			 : Qtrue);
	rb_hash_aset(tagged, ID2SYM(rb_intern("condition_hash_distinct")),
		     tagged_base.hash != tagged_condition.hash ? Qtrue
							       : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("dynamic")), dynamic);
	rb_hash_aset(result, ID2SYM(rb_intern("tagged")), tagged);
	rb_hash_aset(result, ID2SYM(rb_intern("live_capture_id")), UINT2NUM(1));
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
					 (OnibiRepeatCount)i + 1);
	    if (!onibi_dynamic_key_seen(&arena, 7, 11, &semantic)) inserted++;
	    onibi_dynamic_stack_push(
		&arena, (OnibiDynamicFrame){7, 11, semantic, UINT32_MAX});
	    last = semantic;
	}
	int stack_valid = arena.frame_count == THREAD_COUNT;
	int same_location = stack_valid;
	for (uint32_t i = 0; i < THREAD_COUNT && (stack_valid || same_location);
	     i++) {
	    if (arena.frames[i].state != 7 || arena.frames[i].position != 11)
		same_location = 0;
	    if (onibi_semantic_counter_read(
		    &arena, arena.frames[i].semantic.counters.root, 0, 0) !=
		(OnibiRepeatCount)i + 1)
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

    if (scenario == rb_intern("tagged_frontier")) {
	OnibiRAction actions[12] = {
	    {ONIBI_RA_COUNTER_SET, 0, 0, 1},
	    {ONIBI_RA_PROGRESS, 0, 0, 0},
	    {ONIBI_RA_END, 0, 0, 0},
	    {ONIBI_RA_COUNTER_SET, 0, 0, 2},
	    {ONIBI_RA_PROGRESS, 0, 0, 0},
	    {ONIBI_RA_END, 0, 0, 0},
	    {ONIBI_RA_COUNTER_SET, 0, 0, 9},
	    {ONIBI_RA_PROGRESS, 0, 0, 0},
	    {ONIBI_RA_COUNTER_TEST, ONIBI_RA_COUNTER_GE, 0, 10},
	    {ONIBI_RA_END, 0, 0, 0},
	    {ONIBI_RA_PROGRESS, 0, 0, 0},
	    {ONIBI_RA_END, 0, 0, 0},
	};
	OnibiRSeqHeader header;
	memset(&header, 0, sizeof(header));
	header.exec_kind = ONIBI_EXEC_TAGGED;
	header.action_count = 12;
	header.counter_count = 1;
	OnibiRSeqView view;
	memset(&view, 0, sizeof(view));
	view.header = &header;
	view.actions = actions;
	OnibiREdge edges[4] = {
	    {7, sizeof(OnibiRAction)},
	    {7, 4U * sizeof(OnibiRAction)},
	    {7, 7U * sizeof(OnibiRAction)},
	    {7, 11U * sizeof(OnibiRAction)},
	};
	predecessor = onibi_semantic_state_initial(&arena, 0, 0, 1, 1);
	OnibiSemanticState first = predecessor;
	OnibiSemanticState second = predecessor;
	OnibiActionResult first_status = onibi_apply_action_program(
	    &view, &edges[0], subject, 2, 0, encoding, ONIBI_ENC_ASCII_7BIT,
	    &arena, &predecessor, &first, NULL);
	OnibiActionResult second_status = onibi_apply_action_program(
	    &view, &edges[1], subject, 2, 0, encoding, ONIBI_ENC_ASCII_7BIT,
	    &arena, &predecessor, &second, NULL);
	OnibiFrontier frontier;
	memset(&frontier, 0, sizeof(frontier));
	onibi_tagged_frontier_reset(&frontier, 8);
	int first_added =
	    onibi_tagged_frontier_add(&frontier, &arena, 7, &first, NULL);
	int second_added =
	    onibi_tagged_frontier_add(&frontier, &arena, 7, &second, NULL);
	int duplicate_added =
	    onibi_tagged_frontier_add(&frontier, &arena, 7, &first, NULL);

	OnibiSemanticState failed = predecessor;
	OnibiActionResult failed_status = onibi_apply_action_program(
	    &view, &edges[2], subject, 2, 0, encoding, ONIBI_ENC_ASCII_7BIT,
	    &arena, &predecessor, &failed, NULL);
	OnibiSemanticState repeated = first;
	OnibiActionResult repeated_status = onibi_apply_action_program(
	    &view, &edges[3], subject, 2, 0, encoding, ONIBI_ENC_ASCII_7BIT,
	    &arena, &first, &repeated, NULL);

	rb_hash_aset(result, ID2SYM(rb_intern("action_success")),
		     first_status == ONIBI_ACTION_SUCCESS &&
			     second_status == ONIBI_ACTION_SUCCESS
			 ? Qtrue
			 : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("frontier_count")),
		     SIZET2NUM(frontier.count));
	rb_hash_aset(result, ID2SYM(rb_intern("distinct_counters_kept")),
		     first_added && second_added && frontier.count == 2
			 ? Qtrue
			 : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("duplicate_merged")),
		     duplicate_added ? Qfalse : Qtrue);
	rb_hash_aset(result, ID2SYM(rb_intern("first_counter")),
		     LONG2NUM(onibi_semantic_counter_read(
			 &arena, first.counters.root, 0, 0)));
	rb_hash_aset(result, ID2SYM(rb_intern("second_counter")),
		     LONG2NUM(onibi_semantic_counter_read(
			 &arena, second.counters.root, 0, 0)));
	rb_hash_aset(result, ID2SYM(rb_intern("failed_transaction")),
		     failed_status == ONIBI_ACTION_FAIL ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("failed_counter")),
		     LONG2NUM(onibi_semantic_counter_read(
			 &arena, failed.counters.root, 0, 0)));
	rb_hash_aset(result, ID2SYM(rb_intern("failed_progress")),
		     LONG2NUM(onibi_semantic_position_read(
			 &arena, failed.progress.root, 0, -1)));
	rb_hash_aset(result, ID2SYM(rb_intern("repeated_progress_rejected")),
		     repeated_status == ONIBI_ACTION_FAIL ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("key_capacity")),
		     SIZET2NUM(frontier.key_capacity));
	rb_hash_aset(result, ID2SYM(rb_intern("full_file_copies")), INT2NUM(0));
	ruby_xfree(frontier.states);
	ruby_xfree(frontier.semantics);
	ruby_xfree(frontier.failure_owners);
	ruby_xfree(frontier.hashes);
	ruby_xfree(frontier.key_buckets);
	ruby_xfree(frontier.membership);
	onibi_semantic_arena_release(&arena);
	return result;
    }

    if (scenario == rb_intern("tagged_capture_state")) {
	onibi_semantic_live_captures_begin(&arena, 1);
	onibi_semantic_live_capture_add(&arena, 0);
	predecessor = onibi_semantic_state_initial(&arena, 0, 2, 2, 2);
	OnibiSemanticState first = predecessor, second = predecessor;
	onibi_semantic_capture_write(&arena, &first.semantic_captures, 0, 0);
	onibi_semantic_capture_write(&arena, &first.semantic_captures, 1, 0);
	onibi_semantic_capture_write(&arena, &second.semantic_captures, 0, 0);
	onibi_semantic_capture_write(&arena, &second.semantic_captures, 1, 1);
	OnibiFrontier frontier = {0};
	onibi_tagged_frontier_reset(&frontier, 8);
	int a = onibi_tagged_frontier_add(&frontier, &arena, 7, &first, NULL);
	int b = onibi_tagged_frontier_add(&frontier, &arena, 7, &second, NULL);
	int duplicate =
	    onibi_tagged_frontier_add(&frontier, &arena, 7, &first, NULL);
	OnibiSemanticState output = first;
	output.tag_history =
	    onibi_semantic_tag_append(&arena, first.tag_history, 0, 7);
	int output_added =
	    onibi_tagged_frontier_add(&frontier, &arena, 7, &output, NULL);
	rb_hash_aset(result, ID2SYM(rb_intern("frontier_count")),
		     SIZET2NUM(frontier.count));
	rb_hash_aset(result, ID2SYM(rb_intern("distinct_live_captures_kept")),
		     a && b ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("duplicate_merged")),
		     duplicate ? Qfalse : Qtrue);
	rb_hash_aset(result, ID2SYM(rb_intern("output_history_ignored")),
		     output_added ? Qfalse : Qtrue);
	OnibiRAction actions[] = {
	    {ONIBI_RA_ORDER, 0, 0, 0},
	    {ONIBI_RA_NULL_ENTER, 0, 0, 0},
	    {ONIBI_RA_NULL_CAPTURE, 0, 0, 0},
	    {ONIBI_RA_CAPTURE, ONIBI_RA_CAPTURE_OPEN_UNSCOPED, 0, 0},
	    {ONIBI_RA_ASSERT_POSITION, 0, ONIBI_RAP_END_BUFFER, 0},
	    {ONIBI_RA_END, 0, 0, 0}};
	OnibiRSeqHeader header = {0};
	header.capture_count = 1;
	header.counter_count = 2;
	header.action_count = 6;
	OnibiRSeqView view = {0};
	view.header = &header;
	view.actions = actions;
	OnibiREdge edge = {7, sizeof(OnibiRAction)};
	OnibiSemanticState failed = first;
	size_t checkpoint = arena.register_count;
	OnibiActionResult status = onibi_apply_action_program(
	    &view, &edge, subject, 2, 0, encoding, ONIBI_ENC_ASCII_7BIT, &arena,
	    &first, &failed, NULL);
	rb_hash_aset(result, ID2SYM(rb_intern("failed_transaction")),
		     status == ONIBI_ACTION_FAIL ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("capture_event_rollback")),
		     arena.capture_event_count == 0 ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("state_rollback")),
		     arena.register_count == checkpoint &&
			     failed.progress.root == first.progress.root &&
			     failed.semantic_captures.root ==
				 first.semantic_captures.root
			 ? Qtrue
			 : Qfalse);
	ruby_xfree(frontier.states);
	ruby_xfree(frontier.semantics);
	ruby_xfree(frontier.failure_owners);
	ruby_xfree(frontier.hashes);
	ruby_xfree(frontier.key_buckets);
	ruby_xfree(frontier.membership);
	onibi_semantic_arena_release(&arena);
	return result;
    }

    if (scenario == rb_intern("tagged_identity")) {
	onibi_semantic_live_captures_begin(&arena, 1);
	onibi_semantic_live_capture_add(&arena, 0);
	predecessor = onibi_semantic_state_initial(&arena, 3, 2, 1, 1);
	OnibiSemanticState variants[9];
	variants[0] = predecessor;
	variants[1] = predecessor;
	variants[1].reported_start++;
	variants[2] = predecessor;
	onibi_semantic_capture_write(&arena, &variants[2].semantic_captures, 0,
				     9);
	variants[3] = predecessor;
	onibi_semantic_counter_write(&arena, &variants[3].counters, 0, 1);
	variants[4] = predecessor;
	onibi_semantic_progress_write(&arena, &variants[4].progress, 0, 9);
	variants[5] = predecessor;
	OnibiCallFrame call = {1, 2, UINT32_MAX, 1, UINT32_MAX};
	variants[5].calls.root = onibi_semantic_call_push(
	    &arena, UINT32_MAX, &call, UINT32_MAX,
	    predecessor.semantic_captures, predecessor.condition_captures,
	    predecessor.counters, predecessor.progress);
	variants[5].calls.depth = 1;
	variants[6] = predecessor;
	variants[6].atomic.root = onibi_semantic_scope_push(
	    &arena, &arena.atomic, &arena.atomic_count, &arena.atomic_capacity,
	    UINT32_MAX, 1, 2, 3, UINT32_MAX, 4, ONIBI_SEMANTIC_HASH_ATOMIC);
	variants[6].atomic.depth = 1;
	variants[7] = predecessor;
	variants[7].absence.root = onibi_semantic_scope_push(
	    &arena, &arena.absence, &arena.absence_count,
	    &arena.absence_capacity, UINT32_MAX, 1, 2, 3, UINT32_MAX, 4,
	    ONIBI_SEMANTIC_HASH_ABSENCE);
	variants[7].absence.depth = 1;
	variants[8] = predecessor;
	variants[8].tag_history =
	    onibi_semantic_tag_append(&arena, UINT32_MAX, 2, 9);
	OnibiFrontier frontier = {0};
	onibi_tagged_frontier_reset(&frontier, 16);
	VALUE distinctions = rb_hash_new();
	VALUE hash_distinctions = rb_hash_new();
	const char *names[] = {"reported_start", "captures", "counters",
			       "progress",	 "calls",    "atomic",
			       "absence"};
	for (size_t i = 1; i <= 7; i++) {
	    OnibiDynamicThreadKey base_key = {7, 0, variants[0], 0};
	    OnibiDynamicThreadKey variant_key = {7, 0, variants[i], 0};
	    base_key.hash = onibi_tagged_thread_key_hash(&arena, &base_key);
	    variant_key.hash =
		onibi_tagged_thread_key_hash(&arena, &variant_key);
	    rb_hash_aset(
		distinctions, ID2SYM(rb_intern(names[i - 1])),
		onibi_tagged_thread_key_equal(&arena, &base_key, &variant_key)
		    ? Qfalse
		    : Qtrue);
	    rb_hash_aset(hash_distinctions, ID2SYM(rb_intern(names[i - 1])),
			 base_key.hash != variant_key.hash ? Qtrue : Qfalse);
	}
	int base_added =
	    onibi_tagged_frontier_add(&frontier, &arena, 7, &variants[0], NULL);
	int state_added =
	    onibi_tagged_frontier_add(&frontier, &arena, 8, &variants[0], NULL);
	for (size_t i = 2; i <= 7; i++)
	    (void)onibi_tagged_frontier_add(&frontier, &arena, 7, &variants[i],
					    NULL);
	int output_added =
	    onibi_tagged_frontier_add(&frontier, &arena, 7, &variants[8], NULL);
	rb_hash_aset(result, ID2SYM(rb_intern("distinguishes")), distinctions);
	rb_hash_aset(result, ID2SYM(rb_intern("hash_distinguishes")),
		     hash_distinctions);
	rb_hash_aset(result, ID2SYM(rb_intern("base_added")),
		     base_added ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("state_added")),
		     state_added ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("frontier_count")),
		     SIZET2NUM(frontier.count));
	rb_hash_aset(result, ID2SYM(rb_intern("output_history_merged")),
		     output_added ? Qfalse : Qtrue);
	rb_hash_aset(result, ID2SYM(rb_intern("key_capacity")),
		     SIZET2NUM(frontier.key_capacity));
	ruby_xfree(frontier.states);
	ruby_xfree(frontier.semantics);
	ruby_xfree(frontier.failure_owners);
	ruby_xfree(frontier.hashes);
	ruby_xfree(frontier.key_buckets);
	ruby_xfree(frontier.membership);
	onibi_semantic_arena_release(&arena);
	return result;
    }

    if (scenario == rb_intern("tagged_output_priority")) {
	onibi_semantic_live_captures_begin(&arena, 2);
	predecessor = onibi_semantic_state_initial(&arena, 0, 4, 0, 0);
	OnibiSemanticState first = predecessor;
	OnibiSemanticState second = predecessor;
	first.tag_history = onibi_semantic_tag_append(&arena, UINT32_MAX, 0, 0);
	second.tag_history =
	    onibi_semantic_tag_append(&arena, UINT32_MAX, 2, 1);
	OnibiFrontier frontier = {0};
	onibi_tagged_frontier_reset(&frontier, 8);
	int first_added =
	    onibi_tagged_frontier_add(&frontier, &arena, 7, &first, NULL);
	int second_added =
	    onibi_tagged_frontier_add(&frontier, &arena, 7, &second, NULL);
	OnibiBytePos capture_beg[3], capture_end[3];
	OnibiRawMatch raw_match = {.begin_byte = -1,
				   .end_byte = -1,
				   .num_regs = 3,
				   .beg = capture_beg,
				   .end = capture_end};
	if (frontier.count == 0)
	    rb_raise(rb_eRuntimeError,
		     "TAGGED output diagnostic lost its thread");
	onibi_tagged_materialize_tags(&arena, &frontier.semantics[0],
				      &raw_match, 4);
	VALUE capture_ranges = rb_ary_new_capa(4);
	for (uint32_t i = 1; i < raw_match.num_regs; i++) {
	    rb_ary_push(capture_ranges, LONG2NUM(raw_match.beg[i]));
	    rb_ary_push(capture_ranges, LONG2NUM(raw_match.end[i]));
	}
	rb_hash_aset(result, ID2SYM(rb_intern("frontier_count")),
		     SIZET2NUM(frontier.count));
	rb_hash_aset(result, ID2SYM(rb_intern("first_path_added")),
		     first_added ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("second_path_merged")),
		     second_added ? Qfalse : Qtrue);
	rb_hash_aset(result, ID2SYM(rb_intern("captures")), capture_ranges);
	rb_hash_aset(result, ID2SYM(rb_intern("first_capture")),
		     LONG2NUM(raw_match.beg[1]));
	rb_hash_aset(result, ID2SYM(rb_intern("second_capture")),
		     LONG2NUM(raw_match.beg[2]));
	ruby_xfree(frontier.states);
	ruby_xfree(frontier.semantics);
	ruby_xfree(frontier.failure_owners);
	ruby_xfree(frontier.hashes);
	ruby_xfree(frontier.key_buckets);
	ruby_xfree(frontier.membership);
	onibi_semantic_arena_release(&arena);
	return result;
    }

    if (scenario == rb_intern("tagged_event_lineage")) {
	onibi_semantic_live_captures_begin(&arena, 1);
	predecessor = onibi_semantic_state_initial(&arena, 0, 2, 0, 0);
	OnibiSemanticState rejected = predecessor;
	OnibiSemanticState accepted = predecessor;
	rejected.order = onibi_capture_order_append(&arena, UINT32_MAX, 0);
	accepted.order = onibi_capture_order_append(&arena, UINT32_MAX, 1);
	rejected.capture_event_history = onibi_semantic_capture_event_append(
	    &arena, UINT32_MAX, rejected.order, 0, 77);
	OnibiBytePos capture_beg[2], capture_end[2];
	OnibiRawMatch raw_match = {.begin_byte = -1,
				   .end_byte = -1,
				   .num_regs = 2,
				   .beg = capture_beg,
				   .end = capture_end};
	onibi_tagged_materialize_tags(&arena, &accepted, &raw_match, 2);
	rb_hash_aset(result, ID2SYM(rb_intern("sibling_orders")),
		     !onibi_capture_order_is_ancestor(&arena, rejected.order,
						      accepted.order)
			 ? Qtrue
			 : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("accepted_has_no_tag_history")),
		     accepted.tag_history == UINT32_MAX ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("capture")),
		     LONG2NUM(raw_match.beg[1]));
	rb_hash_aset(result, ID2SYM(rb_intern("rejected_capture_unpublished")),
		     raw_match.beg[1] < 0 ? Qtrue : Qfalse);
	OnibiSemanticState first = predecessor;
	OnibiSemanticState second = predecessor;
	first.order = onibi_capture_order_append(&arena, UINT32_MAX, 0);
	first.capture_event_history = onibi_semantic_capture_event_append(
	    &arena, UINT32_MAX, first.order, 0, 11);
	second.order = onibi_capture_order_append(&arena, UINT32_MAX, 1);
	second.capture_event_history = onibi_semantic_capture_event_append(
	    &arena, UINT32_MAX, second.order, 0, 22);
	OnibiFrontier merged_frontier = {0};
	onibi_tagged_frontier_reset(&merged_frontier, 8);
	uint32_t merged_owner = UINT32_MAX;
	int first_inserted = onibi_tagged_frontier_add(
	    &merged_frontier, &arena, 7, &first, &merged_owner);
	int second_inserted = onibi_tagged_frontier_add(
	    &merged_frontier, &arena, 7, &second, &merged_owner);
	int owner_resolved = onibi_semantic_capture_event_owner_resolve(
	    &arena, merged_owner, UINT32_MAX);
	OnibiSemanticState merged = predecessor;
	merged.order = onibi_capture_order_append(&arena, UINT32_MAX, 2);
	merged.capture_event_dependency = merged_owner;
	OnibiBytePos merged_beg[2], merged_end[2];
	OnibiRawMatch merged_match = {.begin_byte = -1,
				      .end_byte = -1,
				      .num_regs = 2,
				      .beg = merged_beg,
				      .end = merged_end};
	int merged_materialized =
	    onibi_tagged_materialize_tags(&arena, &merged, &merged_match, 2);
	rb_hash_aset(result, ID2SYM(rb_intern("duplicate_owner_kept")),
		     first_inserted && !second_inserted && owner_resolved
			 ? Qtrue
			 : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("merged_capture")),
		     LONG2NUM(merged_materialized ? merged_match.beg[1] : -1));
	ruby_xfree(merged_frontier.states);
	ruby_xfree(merged_frontier.semantics);
	ruby_xfree(merged_frontier.failure_owners);
	ruby_xfree(merged_frontier.hashes);
	ruby_xfree(merged_frontier.key_buckets);
	ruby_xfree(merged_frontier.membership);
	onibi_semantic_arena_release(&arena);
	return result;
    }

    if (scenario == rb_intern("assertion_transactions")) {
	OnibiAssertionDiagnostic failed_trial =
	    onibi_assertion_event_diagnostic(ONIBI_ASSERT_DIAG_FAILED_TRIAL);
	OnibiAssertionDiagnostic negative_success =
	    onibi_assertion_event_diagnostic(
		ONIBI_ASSERT_DIAG_NEGATIVE_SUCCESS);
	OnibiAssertionDiagnostic negative_failure =
	    onibi_assertion_event_diagnostic(
		ONIBI_ASSERT_DIAG_NEGATIVE_FAILURE);
	OnibiAssertionDiagnostic lookbehind_trial =
	    onibi_assertion_event_diagnostic(
		ONIBI_ASSERT_DIAG_LOOKBEHIND_TRIAL);
	OnibiAssertionDiagnostic parent_failure =
	    onibi_assertion_event_diagnostic(ONIBI_ASSERT_DIAG_PARENT_FAILURE);
	OnibiAssertionDiagnostic positive_success =
	    onibi_assertion_event_diagnostic(
		ONIBI_ASSERT_DIAG_POSITIVE_SUCCESS);
	rb_hash_aset(result, ID2SYM(rb_intern("failed_trial_failed")),
		     failed_trial.status == ONIBI_ACTION_FAIL ? Qtrue : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("failed_trial_events")),
		     SIZET2NUM(failed_trial.capture_event_count));
	rb_hash_aset(result, ID2SYM(rb_intern("negative_success_succeeded")),
		     negative_success.status == ONIBI_ACTION_SUCCESS ? Qtrue
								     : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("negative_success_events")),
		     SIZET2NUM(negative_success.capture_event_count));
	rb_hash_aset(result, ID2SYM(rb_intern("negative_failure_failed")),
		     negative_failure.status == ONIBI_ACTION_FAIL ? Qtrue
								  : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("negative_failure_events")),
		     SIZET2NUM(negative_failure.capture_event_count));
	rb_hash_aset(result, ID2SYM(rb_intern("lookbehind_succeeded")),
		     lookbehind_trial.status == ONIBI_ACTION_SUCCESS ? Qtrue
								     : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("lookbehind_events")),
		     SIZET2NUM(lookbehind_trial.capture_event_count));
	rb_hash_aset(result, ID2SYM(rb_intern("parent_failure_failed")),
		     parent_failure.status == ONIBI_ACTION_FAIL ? Qtrue
								: Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("parent_failure_events")),
		     SIZET2NUM(parent_failure.capture_event_count));
	rb_hash_aset(result, ID2SYM(rb_intern("positive_success_succeeded")),
		     positive_success.status == ONIBI_ACTION_SUCCESS ? Qtrue
								     : Qfalse);
	rb_hash_aset(result, ID2SYM(rb_intern("positive_success_events")),
		     SIZET2NUM(positive_success.capture_event_count));
	rb_hash_aset(result, ID2SYM(rb_intern("positive_capture_begin")),
		     LONG2NUM(positive_success.capture_begin));
	onibi_semantic_arena_release(&arena);
	return result;
    }

    rb_raise(rb_eArgError, "unknown semantic-state diagnostic scenario");
}

static int
onibi_rseq_dynamic_run(
    VALUE rseq, const OnibiRSeqView *cached_view, VALUE str, OnibiBytePos start,
    OnibiBytePos search_origin, uint32_t entry_edge_base,
    uint32_t entry_edge_count, uint32_t local_subprogram_id,
    OnibiBytePos required_end, int force_exhaustion,
    const OnibiSemanticState *initial_state, OnibiSemanticState *failed_state,
    OnibiBytePos *failed_position, int reset_arena, OnibiBytePos *matched_end,
    OnibiSemanticState *accepted_state, OnibiSemanticArena *semantic_arena,
    unsigned char *class_stack, size_t class_stack_capacity, OnibiExecCtx *ctx)
{
    OnibiRSeqView local_view;
    const OnibiRSeqView *view = cached_view;
    if (!view) {
	if (!onibi_rseq_view_init(rseq, &local_view)) return -1;
	onibi_rseq_view_prepare(&local_view);
	view = &local_view;
	onibi_semantic_live_captures_prepare(semantic_arena, view);
    }
    const OnibiRSeqHeader *header = view->header;
    if (header->capture_count > UINT32_MAX / 2U) return -1;
    rb_encoding *encoding = rb_enc_get(str);
    OnibiEncodingMode encoding_mode = onibi_encoding_mode_for(str, encoding);
    const OnibiRState *states = view->states;
    const OnibiREdge *edges = view->edges;
    OnibiSemanticArena *arena = semantic_arena;
    size_t frame_base = arena->frame_count;
    OnibiDynamicKeyBucket *saved_key_buckets = arena->key_buckets;
    size_t saved_key_capacity = arena->key_capacity;
    uint32_t saved_key_generation = arena->key_generation;
    size_t saved_key_count = arena->key_count;
    size_t saved_cycle_count = arena->cycle_count;
    if (reset_arena) {
	onibi_semantic_arena_reset(arena);
	frame_base = 0;
	initial_state = NULL;
    }
    else {
	arena->frame_count = frame_base;
	/* A nested run gets a private key table.  Keep the outer table intact;
	 * generation markers alone cannot restore buckets overwritten by
	 * growth. */
	arena->key_buckets = NULL;
	arena->key_capacity = 0;
	arena->key_count = 0;
	arena->key_generation = 1;
    }
    onibi_semantic_local_slots_prepare(arena, view);
    OnibiSemanticState initial =
	initial_state ? *initial_state
		      : onibi_semantic_state_initial(
			    arena, start, header->capture_count * 2U,
			    header->counter_count, header->counter_count);
    OnibiSemanticState caller_state = initial;
    if (local_subprogram_id != UINT32_MAX)
	onibi_semantic_local_slots_reset(arena, local_subprogram_id, &initial);
#define ONIBI_DYNAMIC_RUN_RETURN(value)                                        \
    do {                                                                       \
	arena->frame_count = frame_base;                                       \
	if (!reset_arena) {                                                    \
	    ruby_xfree(arena->key_buckets);                                    \
	    arena->key_buckets = saved_key_buckets;                            \
	    arena->key_capacity = saved_key_capacity;                          \
	    arena->key_generation = saved_key_generation;                      \
	    arena->key_count = saved_key_count;                                \
	}                                                                      \
	arena->cycle_count = saved_cycle_count;                                \
	return (value);                                                        \
    } while (0)

    if (entry_edge_base == UINT32_MAX) {
	if (header->subprogram_count == 0 ||
	    view->subprograms[0].entry >= header->state_count)
	    ONIBI_DYNAMIC_RUN_RETURN(-1);
	onibi_dynamic_stack_push(
	    arena, (OnibiDynamicFrame){view->subprograms[0].entry, start,
				       initial, UINT32_MAX});
    }
    for (uint32_t i = entry_edge_count; i > 0; i--) {
	const OnibiREdge *edge = &edges[entry_edge_base + (i - 1U)];
	OnibiSemanticState branch;
	if (onibi_apply_action_program(view, edge, str, start, search_origin,
				       encoding, encoding_mode, arena, &initial,
				       &branch, ctx) == ONIBI_ACTION_FAIL)
	    continue;
	if (edge->destination == ONIBI_ACCEPT_STATE &&
	    (required_end < 0 || start == required_end)) {
	    onibi_dynamic_stack_push(
		arena, (OnibiDynamicFrame){ONIBI_ACCEPT_STATE, start, branch,
					   UINT32_MAX});
	    continue;
	}
	if (edge->destination < header->state_count)
	    onibi_dynamic_stack_push(
		arena, (OnibiDynamicFrame){edge->destination, start, branch,
					   UINT32_MAX});
    }

    while (arena->frame_count > frame_base) {
	OnibiDynamicFrame frame = arena->frames[--arena->frame_count];
	if (ctx) ctx->current_position = frame.position;
	onibi_exec_charge_work(ctx, 1);
	if (frame.state == ONIBI_ACCEPT_STATE) {
	    if (force_exhaustion && required_end >= 0 &&
		frame.position == required_end)
		continue;
	    if (required_end < 0 || frame.position == required_end) {
		*matched_end = frame.position;
		*accepted_state = frame.semantic;
		if (local_subprogram_id != UINT32_MAX)
		    onibi_semantic_local_slots_restore(
			arena, local_subprogram_id, accepted_state,
			caller_state.counters, caller_state.progress);
		ONIBI_DYNAMIC_RUN_RETURN(1);
	    }
	    continue;
	}
	if (!force_exhaustion && failed_state && failed_position &&
	    frame.position >= *failed_position) {
	    *failed_state = frame.semantic;
	    if (local_subprogram_id != UINT32_MAX)
		onibi_semantic_local_slots_restore(
		    arena, local_subprogram_id, failed_state,
		    caller_state.counters, caller_state.progress);
	    *failed_position = frame.position;
	}
	if (frame.position < 0 || frame.position > RSTRING_LEN(str) ||
	    frame.state >= header->state_count)
	    continue;
	const OnibiRState *state = &states[frame.state];
#define ONIBI_RECORD_FAILURE()                                                 \
    do {                                                                       \
	if (failed_state && failed_position &&                                 \
	    frame.position >= *failed_position) {                              \
	    *failed_state = frame.semantic;                                    \
	    *failed_position = frame.position;                                 \
	}                                                                      \
    } while (0)
	uint32_t cycle_root = frame.cycle_root;
	OnibiDynamicThreadKey cycle_key = {frame.state, frame.position,
					   frame.semantic, 0};
	cycle_key.hash = onibi_dynamic_thread_key_hash(arena, &cycle_key);
	if (onibi_dynamic_cycle_seen(arena, &cycle_key, frame.cycle_root,
				     &cycle_root))
	    continue;
	if (onibi_dynamic_key_seen(arena, frame.state, frame.position,
				   &frame.semantic))
	    continue;
	OnibiBytePos next_position = frame.position;
	int hit = 1;
	if (state->op == 0) {
	    if (frame.semantic.calls.depth == 0) {
		if (force_exhaustion && required_end >= 0 &&
		    frame.position == required_end) {
		    ONIBI_RECORD_FAILURE();
		    continue;
		}
		if (required_end < 0 || frame.position == required_end) {
		    *matched_end = frame.position;
		    *accepted_state = frame.semantic;
		    if (local_subprogram_id != UINT32_MAX)
			onibi_semantic_local_slots_restore(
			    arena, local_subprogram_id, accepted_state,
			    caller_state.counters, caller_state.progress);
		    ONIBI_DYNAMIC_RUN_RETURN(1);
		}
		continue;
	    }
	    uint32_t call_id = frame.semantic.calls.root;
	    if (call_id >= arena->call_count) ONIBI_DYNAMIC_RUN_RETURN(-1);
	    const OnibiOwnedCallFrame *call = &arena->calls[call_id];
	    uint32_t edge_index = call->frame.continuation;
	    if (edge_index >= header->edge_count) ONIBI_DYNAMIC_RUN_RETURN(-1);
	    OnibiSemanticState returned = frame.semantic;
	    returned.calls.root = call->parent;
	    returned.calls.depth--;
	    onibi_semantic_local_slots_restore(arena, call->frame.subprogram_id,
					       &returned, call->caller_counters,
					       call->caller_progress);
	    onibi_semantic_restore_active_captures(arena, &returned,
						   &call->caller_captures,
						   call->caller_tag_history);
	    onibi_semantic_restore_active_conditions(
		arena, &returned, &call->caller_condition_captures,
		call->caller_tag_history);
	    onibi_semantic_restore_active_capture_tags(
		arena, &returned, &call->caller_captures,
		call->caller_tag_history);
	    OnibiSemanticState branch;
	    const OnibiREdge *edge = &edges[edge_index];
	    if (onibi_apply_action_program(view, edge, str, frame.position,
					   search_origin, encoding,
					   encoding_mode, arena, &returned,
					   &branch, ctx) == ONIBI_ACTION_FAIL)
		continue;
	    if (edge->destination == ONIBI_ACCEPT_STATE &&
		(required_end < 0 || frame.position == required_end)) {
		size_t child_frame_base = arena->frame_count;
		onibi_dynamic_stack_push(
		    arena,
		    (OnibiDynamicFrame){ONIBI_ACCEPT_STATE, frame.position,
					branch, cycle_root});
		onibi_dynamic_cycle_prune_redundant(arena, child_frame_base);
		continue;
	    }
	    if (edge->destination < header->state_count) {
		size_t child_frame_base = arena->frame_count;
		onibi_dynamic_stack_push(
		    arena,
		    (OnibiDynamicFrame){edge->destination, frame.position,
					branch, cycle_root});
		onibi_dynamic_cycle_prune_redundant(arena, child_frame_base);
	    }
	    continue;
	}
	if (state->op == ONIBI_RS_CALL) {
	    const OnibiSubprogramDesc *subprogram =
		&view->subprograms[state->payload];
	    size_t child_frame_base = arena->frame_count;
	    for (uint32_t pass = 0; pass < state->edge_count; pass++) {
		uint32_t e = state->edge_count - pass;
		for (uint32_t s = subprogram->entry_edge_count; s > 0; s--) {
		    const OnibiREdge *entry =
			&edges[subprogram->entry_edge_base + (s - 1U)];
		    OnibiSemanticState branch = frame.semantic;
		    onibi_semantic_local_slots_reset(arena, state->payload,
						     &branch);
		    if (onibi_apply_action_program(
			    view, entry, str, frame.position, search_origin,
			    encoding, encoding_mode, arena, &branch, &branch,
			    ctx) == ONIBI_ACTION_FAIL)
			continue;
		    OnibiCallFrame call = {
			state->payload, state->edge_base + (e - 1U),
			branch.tag_history, branch.calls.depth + 1U,
			branch.calls.root};
		    branch.calls.root = onibi_semantic_call_push(
			arena, branch.calls.root, &call,
			frame.semantic.tag_history,
			frame.semantic.semantic_captures,
			frame.semantic.condition_captures,
			frame.semantic.counters, frame.semantic.progress);
		    branch.calls.depth++;
		    if (entry->destination < header->state_count)
			onibi_dynamic_stack_push(
			    arena, (OnibiDynamicFrame){entry->destination,
						       frame.position, branch,
						       cycle_root});
		}
	    }
	    onibi_dynamic_cycle_prune_redundant(arena, child_frame_base);
	    continue;
	}
	OnibiSemanticState transition_semantic = frame.semantic;
	if (state->op == ONIBI_RS_ABSENT) {
	    OnibiBytePos minimum_position = frame.position;
	    int absence_status = onibi_dynamic_absence_consume(
		rseq, view, str, frame.position, state->payload,
		&frame.semantic, arena, class_stack, class_stack_capacity, ctx,
		&next_position, &minimum_position, &transition_semantic);
	    if (absence_status < 0) ONIBI_DYNAMIC_RUN_RETURN(-1);
	    if (absence_status == 0) continue;
	    /* An absence transition is an ordered range of complement
	     * endpoints. Push every endpoint so a following edge can backtrack
	     * to the next shorter complement.  The stack pops the longest
	     * endpoint first. */
	    if (minimum_position < frame.position ||
		minimum_position > next_position ||
		next_position > RSTRING_LEN(str))
		ONIBI_DYNAMIC_RUN_RETURN(-1);
	    size_t child_frame_base = arena->frame_count;
	    for (OnibiBytePos candidate = minimum_position;; candidate++) {
		if (ctx) ctx->current_position = candidate;
		onibi_exec_charge_work(ctx, 1);
		int forced_failure = 0;
		if (candidate == frame.position) {
		    for (uint32_t i = 0; i < state->edge_count; i++)
			if (edges[state->edge_base + i].destination ==
			    frame.state) {
			    forced_failure = 1;
			    break;
			}
		}
		for (uint32_t pass = 0; pass < state->edge_count; pass++) {
		    uint32_t e = state->edge_count - pass;
		    const OnibiREdge *edge =
			&edges[state->edge_base + (e - 1U)];
		    OnibiSemanticState branch;
		    const OnibiSemanticState *edge_input =
			forced_failure && edge->destination != frame.state
			    ? &frame.semantic
			    : &transition_semantic;
		    if (onibi_apply_action_program(
			    view, edge, str, candidate, search_origin, encoding,
			    encoding_mode, arena, edge_input, &branch,
			    ctx) == ONIBI_ACTION_FAIL)
			continue;
		    if (edge->destination == ONIBI_ACCEPT_STATE) {
			onibi_dynamic_stack_push(
			    arena,
			    (OnibiDynamicFrame){
				ONIBI_ACCEPT_STATE, candidate, branch,
				candidate == frame.position ? cycle_root
							    : UINT32_MAX});
			continue;
		    }
		    if (edge->destination < header->state_count)
			onibi_dynamic_stack_push(
			    arena,
			    (OnibiDynamicFrame){
				edge->destination, candidate, branch,
				candidate == frame.position ? cycle_root
							    : UINT32_MAX});
		}
		if (candidate >= next_position) break;
	    }
	    onibi_dynamic_cycle_prune_redundant(arena, child_frame_base);
	    continue;
	}
	else if (state->op == ONIBI_RS_ATOMIC) {
	    if (state->payload >= header->subprogram_count)
		ONIBI_DYNAMIC_RUN_RETURN(-1);
	    const OnibiSubprogramDesc *subprogram =
		&view->subprograms[state->payload];
	    if (subprogram->kind != ONIBI_SUBPROGRAM_ATOMIC_GROUP)
		ONIBI_DYNAMIC_RUN_RETURN(-1);
	    OnibiSemanticCheckpoint checkpoint =
		onibi_semantic_checkpoint_save(arena);
	    OnibiSemanticState atomic_result;
	    OnibiBytePos atomic_end = frame.position;
	    int atomic_status = onibi_rseq_dynamic_run(
		rseq, view, str, frame.position, search_origin,
		subprogram->entry_edge_base, subprogram->entry_edge_count,
		state->payload, -1, 0, &frame.semantic, NULL, NULL, 0,
		&atomic_end, &atomic_result, arena, class_stack,
		class_stack_capacity, ctx);
	    if (atomic_status < 0) ONIBI_DYNAMIC_RUN_RETURN(-1);
	    if (atomic_status == 0) {
		onibi_semantic_checkpoint_restore(arena, &checkpoint);
		continue;
	    }
	    transition_semantic = atomic_result;
	    next_position = atomic_end;
	}
	else if (state->op == ONIBI_RS_GRAPHEME) {
	    long width = onibi_grapheme_width(str, frame.position);
	    if (width <= 0)
		hit = 0;
	    else
		next_position += width;
	}
	else if (state->op == ONIBI_RS_BACKREF) {
	    if (state->payload >= header->backref_count) {
		ONIBI_DYNAMIC_RUN_RETURN(-1);
	    }
	    const OnibiBackrefDesc *descriptor =
		&view->backrefs[state->payload];
	    uint32_t list_index = (descriptor->capture_list_off -
				   view->header->backref_lists_offset) /
				  (uint32_t)sizeof(uint32_t);
	    hit = 0;
	    for (uint16_t j = 0; j < descriptor->capture_count; j++) {
		uint32_t capture = view->backref_capture_ids[list_index + j];
		uint32_t begin = capture * 2U;
		if (begin + 1U >= frame.semantic.semantic_captures.slot_count)
		    continue;
		OnibiBytePos capture_begin = onibi_semantic_position_read(
		    arena, frame.semantic.semantic_captures.root, begin, -1);
		OnibiBytePos capture_end = onibi_semantic_position_read(
		    arena, frame.semantic.semantic_captures.root, begin + 1U,
		    -1);
		if (capture_begin < 0 || capture_end < capture_begin) continue;
		if (onibi_rseq_backref_consume(
			str, frame.position, capture_begin, capture_end,
			encoding, encoding_mode,
			(descriptor->flags & ONIBI_BACKREF_FLAG_IGNORE_CASE) !=
			    0,
			&next_position, ctx)) {
		    hit = 1;
		    break;
		}
	    }
	}
	else if (state->op == ONIBI_RS_CHAR || state->op == ONIBI_RS_CLASS ||
		 state->op == ONIBI_RS_ANY) {
	    hit = onibi_rseq_consume_character(
		view, state, str, frame.position, encoding, encoding_mode,
		&next_position, class_stack, class_stack_capacity, ctx);
	}
	else
	    hit = 0;
	if (!hit) {
	    ONIBI_RECORD_FAILURE();
	    continue;
	}
	uint32_t child_cycle_root =
	    next_position == frame.position ? cycle_root : UINT32_MAX;
	size_t child_frame_base = arena->frame_count;
	for (uint32_t pass = 0; pass < state->edge_count; pass++) {
	    uint32_t e = state->edge_count - pass;
	    const OnibiREdge *edge = &edges[state->edge_base + (e - 1U)];
	    OnibiSemanticState branch;
	    if (onibi_apply_action_program(
		    view, edge, str, next_position, search_origin, encoding,
		    encoding_mode, arena, &transition_semantic, &branch,
		    ctx) == ONIBI_ACTION_FAIL)
		continue;
	    if (edge->destination == ONIBI_ACCEPT_STATE) {
		if (required_end < 0 || next_position == required_end) {
		    onibi_dynamic_stack_push(
			arena,
			(OnibiDynamicFrame){ONIBI_ACCEPT_STATE, next_position,
					    branch, child_cycle_root});
		    continue;
		}
	    }
	    if (edge->destination < header->state_count)
		onibi_dynamic_stack_push(
		    arena, (OnibiDynamicFrame){edge->destination, next_position,
					       branch, child_cycle_root});
	}
	onibi_dynamic_cycle_prune_redundant(arena, child_frame_base);
#undef ONIBI_RECORD_FAILURE
    }
    ONIBI_DYNAMIC_RUN_RETURN(0);
#undef ONIBI_DYNAMIC_RUN_RETURN
}

static int
onibi_rseq_backtracking_match(
    VALUE rseq, const OnibiRSeqView *cached_view, VALUE str, OnibiBytePos start,
    OnibiBytePos search_origin, OnibiBytePos *matched_end,
    OnibiSemanticState *accepted_state, OnibiSemanticArena *semantic_arena,
    unsigned char *class_stack, size_t class_stack_capacity, OnibiExecCtx *ctx)
{
    const OnibiRSeqView *view = cached_view;
    OnibiRSeqView local_view;
    if (!view) {
	if (!onibi_rseq_view_init(rseq, &local_view)) return -1;
	onibi_rseq_view_prepare(&local_view);
	view = &local_view;
    }
    uint32_t edge_base = view->header->start_edge_base;
    uint32_t edge_count = view->header->start_edge_count;
    if ((view->header->features & ONIBI_FEATURE_ABSENCE) != 0) {
	edge_base = UINT32_MAX;
	edge_count = 0;
    }
    return onibi_rseq_dynamic_run(
	rseq, view, str, start, search_origin, edge_base, edge_count,
	UINT32_MAX, -1, 0, NULL, NULL, NULL, 1, matched_end, accepted_state,
	semantic_arena, class_stack, class_stack_capacity, ctx);
}

/* Execute the forbidden subprogram at bounded probe positions.  A consuming
 * hit limits the complement to the byte before that hit.  The caller keeps
 * every endpoint in that range so a following edge can backtrack. */
static int
onibi_dynamic_absence_consume(
    VALUE rseq, const OnibiRSeqView *view, VALUE str, OnibiBytePos position,
    uint32_t subprogram_id, const OnibiSemanticState *input,
    OnibiSemanticArena *arena, unsigned char *class_stack,
    size_t class_stack_capacity, OnibiExecCtx *ctx, OnibiBytePos *next_position,
    OnibiBytePos *minimum_position, OnibiSemanticState *output)
{
    if (view->header->subprogram_count == 0) return -1;
    if (subprogram_id == 0 || subprogram_id >= view->header->subprogram_count)
	return -1;
    const OnibiSubprogramDesc *subprogram = &view->subprograms[subprogram_id];
    OnibiBytePos limit = RSTRING_LEN(str);
    OnibiBytePos absence_end = limit;
    OnibiBytePos first_zero = -1;
    OnibiBytePos first_nonzero = -1;
    OnibiBytePos next_zero = -1;
    OnibiBytePos first_positive_probe = -1;
    OnibiSemanticState first_zero_state = *input;
    OnibiSemanticState first_positive_state = *input;
    OnibiSemanticState furthest_failure_state = *input;
    OnibiBytePos furthest_failure_position = -1;
    int zero_at_position = 0;

    for (OnibiBytePos probe = position; probe <= limit; probe++) {
	if (ctx) ctx->current_position = probe;
	onibi_exec_charge_work(ctx, 1);
	if (probe > absence_end) break;
	if (probe < limit && !onibi_character_boundary(str, probe)) continue;
	OnibiSemanticState body_result;
	OnibiSemanticState failed_result = *input;
	OnibiBytePos body_end = probe;
	OnibiBytePos failed_end = probe;
	int result = onibi_rseq_dynamic_run(
	    rseq, view, str, probe, ctx->search_origin,
	    subprogram->entry_edge_base, subprogram->entry_edge_count,
	    subprogram_id, -1, 0, input, &failed_result, &failed_end, 0,
	    &body_end, &body_result, arena, class_stack, class_stack_capacity,
	    ctx);
	if (result < 0) return -1;
	if (result > 0) {
	    OnibiSemanticState terminal_state = *input;
	    OnibiBytePos terminal_position = probe;
	    OnibiBytePos forced_end = body_end;
	    OnibiSemanticState forced_accept;
	    int forced_status = onibi_rseq_dynamic_run(
		rseq, view, str, probe, ctx->search_origin,
		subprogram->entry_edge_base, subprogram->entry_edge_count,
		subprogram_id, body_end, 0, input, &terminal_state,
		&terminal_position, 0, &forced_end, &forced_accept, arena,
		class_stack, class_stack_capacity, ctx);
	    if (forced_status > 0) terminal_state = forced_accept;
	    onibi_dynamic_absence_filter_captures(arena, &body_result,
						  &terminal_state);
	    if (body_end > probe) {
		/* The absence loop narrows its end after every consuming body
		 * result.  Re-run a greedy body that crossed that end at the
		 * greatest endpoint that is still inside the narrowed range. */
		if (body_end > absence_end) {
		    int bounded = 0;
		    for (OnibiBytePos candidate = absence_end;
			 candidate > probe; candidate--) {
			if (candidate < limit &&
			    !onibi_character_boundary(str, candidate))
			    continue;
			OnibiSemanticState bounded_result;
			OnibiSemanticState bounded_failed = *input;
			OnibiBytePos bounded_end = candidate;
			OnibiBytePos bounded_failed_end = candidate;
			int bounded_status = onibi_rseq_dynamic_run(
			    rseq, view, str, probe, ctx->search_origin,
			    subprogram->entry_edge_base,
			    subprogram->entry_edge_count, subprogram_id,
			    candidate, 0, input, &bounded_failed,
			    &bounded_failed_end, 0, &bounded_end,
			    &bounded_result, arena, class_stack,
			    class_stack_capacity, ctx);
			if (bounded_status < 0) return -1;
			if (bounded_status > 0 && bounded_end > probe) {
			    body_end = bounded_end;
			    body_result = bounded_result;
			    bounded = 1;
			    break;
			}
		    }
		    if (!bounded) result = 0;
		}
		if (result > 0) {
		    if (first_positive_probe < 0) first_positive_probe = probe;
		    first_positive_state = body_result;
		    OnibiBytePos previous =
			body_end > 0 ? body_end - 1 : body_end;
		    while (previous > 0 &&
			   !onibi_character_boundary(str, previous))
			previous--;
		    if (previous < absence_end) absence_end = previous;
		    continue;
		}
	    }
	    if (result > 0) {
		if (first_zero < 0) {
		    first_zero = probe;
		    first_zero_state = body_result;
		}
		if (probe == position) zero_at_position = 1;
		if (first_nonzero >= 0 && next_zero < 0 &&
		    probe > first_nonzero)
		    next_zero = probe;
		continue;
	    }
	}
	/* A failed zero-width probe is a non-zero point for the complement. */
	if (first_nonzero < 0) first_nonzero = probe;
	/* MRI exposes captures from a failed body only when that body reaches
	 * the end of the current search subject.  Keep the state from the
	 * furthest failed probe so a later conditional can observe it. */
	if (failed_end > furthest_failure_position) {
	    furthest_failure_position = failed_end;
	    furthest_failure_state = failed_result;
	}
    }

    /* A consuming body hit at the current position still yields the
     * zero-width complement endpoint.  A zero-width hit at the current
     * position remains a failure when a later consuming hit exists. */
    if (zero_at_position && first_positive_probe > position) return 0;
    if (first_positive_probe >= 0) {
	*minimum_position = position;
	*next_position = absence_end;
	*output = first_positive_state;
	return 1;
    }

    if (first_zero >= 0) {
	if (first_zero == position) {
	    /* A zero-width body defines a shifted interval.  Leave the
	     * current attempt to the outer search when a later point does
	     * not match the body. */
	    OnibiBytePos shifted_start =
		first_nonzero >= 0 ? first_nonzero : limit;
	    OnibiBytePos shifted_end = shifted_start;
	    if (shifted_start < limit) {
		shifted_end = next_zero >= 0 ? next_zero : limit;
	    }
	    *minimum_position = shifted_end;
	    *next_position = shifted_end;
	    *output = first_zero_state;
	    output->reported_start = shifted_start;
	    return 1;
	}
	/* No match at the current point.  Stop before the first later
	 * zero-width hit. */
	*minimum_position = position;
	*next_position = first_zero;
	*output = first_zero_state;
	return 1;
    }

    *minimum_position = position;
    *next_position = limit;
    *output =
	furthest_failure_position == limit ? furthest_failure_state : *input;
    return 1;
}

static OnibiActionResult
onibi_dynamic_assert_subprogram(OnibiExecCtx *ctx, const OnibiRAction *action,
				OnibiBytePos position,
				const OnibiSemanticState *predecessor,
				OnibiSemanticState *successor)
{
    if (action->arg32 == 0 ||
	action->arg32 >= ctx->view->header->subprogram_count)
	return ONIBI_ACTION_FAIL;
    const OnibiSubprogramDesc *subprogram =
	&ctx->view->subprograms[action->arg32];
    int positive = action->flags == 1 || action->flags == 5;
    int lookbehind = action->arg16 == ONIBI_RAP_LOOKBEHIND;
    OnibiSemanticArena *arena = &ctx->semantic_arena;
    OnibiSemanticCheckpoint checkpoint = onibi_semantic_checkpoint_save(arena);
    uint32_t trial_count = lookbehind ? subprogram->width_count : 1U;
    for (uint32_t i = 0; i < trial_count; i++) {
	OnibiBytePos trial_start = position;
	OnibiBytePos required_end = -1;
	if (lookbehind) {
	    uint32_t width =
		ctx->view->lookbehind_widths[subprogram->width_base + i];
	    if (!onibi_tagged_lookbehind_start(ctx, position, width,
					       &trial_start))
		continue;
	    required_end = position;
	}
	OnibiSemanticState assertion_result;
	OnibiBytePos assertion_end = trial_start;
	int result = onibi_rseq_dynamic_run(
	    ctx->rseq, ctx->view, ctx->subject, trial_start, ctx->search_origin,
	    subprogram->entry_edge_base, subprogram->entry_edge_count,
	    action->arg32, required_end, 0, predecessor, NULL, NULL, 0,
	    &assertion_end, &assertion_result, arena, ctx->class_stack,
	    ctx->class_stack_capacity, ctx);
	if (result < 0) {
	    onibi_semantic_checkpoint_restore(arena, &checkpoint);
	    return ONIBI_ACTION_FAIL;
	}
	if (result > 0) {
	    if (!positive) {
		onibi_semantic_checkpoint_restore(arena, &checkpoint);
		return ONIBI_ACTION_FAIL;
	    }
	    *successor = *predecessor;
	    if ((subprogram->effects &
		 ONIBI_SUBPROGRAM_EFFECT_PUBLISH_CAPTURES) != 0) {
		successor->semantic_captures =
		    assertion_result.semantic_captures;
		successor->condition_captures =
		    assertion_result.condition_captures;
		successor->tag_history = assertion_result.tag_history;
		successor->order = assertion_result.order;
		successor->capture_event_history =
		    assertion_result.capture_event_history;
		successor->capture_event_dependency =
		    assertion_result.capture_event_dependency;
	    }
	    return ONIBI_ACTION_SUCCESS;
	}
	onibi_semantic_checkpoint_restore(arena, &checkpoint);
    }
    if (positive) return ONIBI_ACTION_FAIL;
    *successor = *predecessor;
    return ONIBI_ACTION_SUCCESS;
}

/* Regular execution uses ordered frontiers.  It has no DFS stack and keeps
 * one membership bitset for each frontier.  Dynamic programs use the native
 * explicit-stack interpreter above. */
typedef struct {
    uint32_t parent;
    uint32_t slot;
    OnibiBytePos position;
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
			 OnibiBytePos position)
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
			    VALUE str, OnibiBytePos position,
			    OnibiBytePos search_origin, rb_encoding *encoding,
			    OnibiEncodingMode mode, uint32_t parent,
			    uint32_t capture_slots, int capture_mode,
			    OnibiTagArena *arena, uint32_t *history)
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
			       OnibiRawMatch *raw_match, uint32_t capture_slots)
{
    const onibi_regular_tag_event_t *events =
	(const onibi_regular_tag_event_t *)arena->data;
    for (uint32_t i = 1; i < raw_match->num_regs; i++) {
	raw_match->beg[i] = -1;
	raw_match->end[i] = -1;
    }
    while (history != UINT32_MAX && history < arena->count) {
	const onibi_regular_tag_event_t *event = &events[history];
	if (event->slot < capture_slots) {
	    uint32_t reg = event->slot / 2U + 1U;
	    OnibiBytePos position = (event->slot & 1U) == 0
					? raw_match->beg[reg]
					: raw_match->end[reg];
	    if (position < 0)
		onibi_raw_match_capture_write(raw_match, event->slot,
					      event->position);
	}
	history = event->parent;
    }
}

static int
onibi_regular_accept_history(const OnibiRSeqView *view,
			     const OnibiRState *state, VALUE str,
			     OnibiBytePos position, OnibiBytePos search_origin,
			     rb_encoding *encoding, OnibiEncodingMode mode,
			     uint32_t parent, uint32_t capture_slots,
			     int capture_mode, OnibiTagArena *arena,
			     uint32_t *history)
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

static void
onibi_tagged_frontier_reset(OnibiFrontier *frontier, uint32_t state_count)
{
    size_t membership_size = ((size_t)state_count + 7U) / 8U;
    if (membership_size > frontier->membership_capacity) {
	frontier->membership =
	    ruby_xrealloc(frontier->membership, membership_size);
	frontier->membership_capacity = membership_size;
    }
    if (membership_size != 0) memset(frontier->membership, 0, membership_size);
    if (frontier->key_capacity != 0)
	memset(frontier->key_buckets, 0,
	       frontier->key_capacity * sizeof(*frontier->key_buckets));
    frontier->count = 0;
}

static void
onibi_tagged_frontier_reserve(OnibiFrontier *frontier)
{
    if (frontier->count < frontier->capacity) return;
    size_t capacity = frontier->capacity == 0 ? 32U : frontier->capacity * 2U;
    if (capacity < frontier->capacity ||
	capacity > SIZE_MAX / sizeof(*frontier->states) ||
	capacity > SIZE_MAX / sizeof(*frontier->semantics) ||
	capacity > SIZE_MAX / sizeof(*frontier->failure_owners) ||
	capacity > SIZE_MAX / sizeof(*frontier->hashes))
	rb_memerror();
    frontier->states =
	ruby_xrealloc(frontier->states, capacity * sizeof(*frontier->states));
    frontier->semantics = ruby_xrealloc(
	frontier->semantics, capacity * sizeof(*frontier->semantics));
    frontier->failure_owners = ruby_xrealloc(
	frontier->failure_owners, capacity * sizeof(*frontier->failure_owners));
    frontier->hashes =
	ruby_xrealloc(frontier->hashes, capacity * sizeof(*frontier->hashes));
    frontier->capacity = capacity;
}

static void
onibi_tagged_frontier_key_grow(OnibiFrontier *frontier)
{
    size_t capacity =
	frontier->key_capacity == 0 ? 64U : frontier->key_capacity * 2U;
    if (capacity < frontier->key_capacity ||
	capacity > SIZE_MAX / sizeof(*frontier->key_buckets))
	rb_memerror();
    uint32_t *buckets = ruby_xcalloc(capacity, sizeof(*buckets));
    for (size_t i = 0; i < frontier->count; i++) {
	size_t slot = (size_t)frontier->hashes[i] & (capacity - 1U);
	while (buckets[slot] != 0)
	    slot = (slot + 1U) & (capacity - 1U);
	buckets[slot] = (uint32_t)i + 1U;
    }
    ruby_xfree(frontier->key_buckets);
    frontier->key_buckets = buckets;
    frontier->key_capacity = capacity;
}

static int
onibi_tagged_frontier_add(OnibiFrontier *frontier, OnibiSemanticArena *arena,
			  uint32_t state, const OnibiSemanticState *semantic,
			  uint32_t *retained_owner)
{
    unsigned char mask = (unsigned char)(1U << (state & 7));
    if (frontier->key_capacity == 0 ||
	frontier->count + 1U >=
	    frontier->key_capacity - frontier->key_capacity / 4U)
	onibi_tagged_frontier_key_grow(frontier);
    OnibiSemanticState ordered = *semantic;
    OnibiDynamicThreadKey candidate = {state, 0, ordered, 0};
    candidate.hash = onibi_tagged_thread_key_hash(arena, &candidate);
    size_t slot = (size_t)candidate.hash & (frontier->key_capacity - 1U);
    while (frontier->key_buckets[slot] != 0) {
	size_t index = (size_t)frontier->key_buckets[slot] - 1U;
	if (frontier->hashes[index] == candidate.hash &&
	    frontier->states[index] == state) {
	    OnibiDynamicThreadKey existing = {
		state, 0, frontier->semantics[index], frontier->hashes[index]};
	    if (onibi_tagged_thread_key_equal(arena, &existing, &candidate)) {
		onibi_semantic_capture_event_owner_add(
		    arena, frontier->failure_owners[index],
		    ordered.capture_event_history);
		if (retained_owner != NULL)
		    *retained_owner = frontier->failure_owners[index];
		return 0;
	    }
	}
	slot = (slot + 1U) & (frontier->key_capacity - 1U);
    }
    if (frontier->count >= UINT32_MAX) rb_memerror();
    onibi_tagged_frontier_reserve(frontier);
    uint32_t failure_owner = onibi_semantic_capture_event_owner_append(
	arena, ordered.capture_event_history);
    frontier->states[frontier->count] = state;
    frontier->semantics[frontier->count] = ordered;
    frontier->failure_owners[frontier->count] = failure_owner;
    frontier->hashes[frontier->count] = candidate.hash;
    frontier->key_buckets[slot] = (uint32_t)frontier->count + 1U;
    frontier->count++;
    frontier->membership[state >> 3] |= mask;
    if (retained_owner != NULL) *retained_owner = failure_owner;
    return 1;
}

static int
onibi_tagged_materialize_event_chain(const OnibiSemanticArena *arena,
				     uint32_t history, OnibiRawMatch *raw_match,
				     uint32_t capture_slots, uint32_t *orders,
				     uint32_t accepted_order,
				     unsigned char *visited)
{
    if (history == UINT32_MAX) return 1;
    while (history != UINT32_MAX) {
	if (history >= arena->capture_event_count) return 0;
	if (visited[history]) break;
	visited[history] = 1;
	onibi_diagnostics.materialization_event_visits++;
	const OnibiUnscopedCaptureEvent *event =
	    &arena->capture_events[history];
	if (event->slot < capture_slots &&
	    !onibi_semantic_capture_slot_live(arena, event->slot) &&
	    event->order != UINT32_MAX &&
	    (accepted_order == UINT32_MAX ||
	     onibi_capture_order_compare(arena, event->order, accepted_order) <=
		 0) &&
	    (orders[event->slot] == UINT32_MAX ||
	     onibi_capture_order_compare(arena, event->order,
					 orders[event->slot]) > 0)) {
	    orders[event->slot] = event->order;
	    onibi_raw_match_capture_write(raw_match, event->slot,
					  event->position);
	}
	history = event->parent;
    }
    return 1;
}

static int
onibi_tagged_materialize_tags(OnibiSemanticArena *arena,
			      const OnibiSemanticState *accepted,
			      OnibiRawMatch *raw_match, uint32_t capture_slots)
{
    if (capture_slots > SIZE_MAX / sizeof(uint32_t)) return 0;
    for (uint32_t i = 1; i < raw_match->num_regs; i++) {
	raw_match->beg[i] = -1;
	raw_match->end[i] = -1;
    }
    OnibiTagEventId history = accepted->tag_history;
    while (history != UINT32_MAX) {
	if (history >= arena->tag_count) {
	    return 0;
	}
	const OnibiSemanticTagEvent *event = &arena->tags[history];
	if (event->slot < capture_slots) {
	    uint32_t reg = event->slot / 2U + 1U;
	    OnibiBytePos position = (event->slot & 1U) == 0
					? raw_match->beg[reg]
					: raw_match->end[reg];
	    if (position < 0)
		onibi_raw_match_capture_write(raw_match, event->slot,
					      event->position);
	}
	history = event->parent;
    }

    uint32_t *orders =
	capture_slots == 0
	    ? NULL
	    : ruby_xmalloc((size_t)capture_slots * sizeof(*orders));
    if (arena->capture_event_count > SIZE_MAX / sizeof(unsigned char)) {
	ruby_xfree(orders);
	return 0;
    }
    unsigned char *visited =
	arena->capture_event_count == 0
	    ? NULL
	    : ruby_xcalloc(arena->capture_event_count, sizeof(*visited));
    for (uint32_t i = 0; i < capture_slots; i++)
	orders[i] = UINT32_MAX;
    if (!onibi_tagged_materialize_event_chain(
	    arena, accepted->capture_event_history, raw_match, capture_slots,
	    orders, accepted->order, visited)) {
	ruby_xfree(orders);
	ruby_xfree(visited);
	return 0;
    }

    uint32_t owner = accepted->capture_event_dependency;
    size_t owner_steps = 0;
    while (owner != UINT32_MAX) {
	if (owner >= arena->capture_event_owner_count ||
	    ++owner_steps > arena->capture_event_owner_count) {
	    ruby_xfree(orders);
	    ruby_xfree(visited);
	    return 0;
	}
	const OnibiCaptureEventOwner *cell =
	    &arena->capture_event_owners[owner];
	if (!cell->resolved) {
	    ruby_xfree(orders);
	    ruby_xfree(visited);
	    return 0;
	}
	uint32_t root = cell->event_roots;
	size_t root_steps = 0;
	while (root != UINT32_MAX) {
	    if (root >= arena->capture_event_root_count ||
		++root_steps > arena->capture_event_root_count) {
		ruby_xfree(orders);
		ruby_xfree(visited);
		return 0;
	    }
	    if (!onibi_tagged_materialize_event_chain(
		    arena, arena->capture_event_roots[root].history, raw_match,
		    capture_slots, orders, accepted->order, visited)) {
		ruby_xfree(orders);
		ruby_xfree(visited);
		return 0;
	    }
	    root = arena->capture_event_roots[root].next;
	}
	owner = cell->resolved_owner;
    }
    ruby_xfree(orders);
    ruby_xfree(visited);
    return 1;
}

static int
onibi_tagged_accept_state(OnibiExecCtx *ctx, const OnibiRSeqView *view,
			  const OnibiRState *state, VALUE str,
			  OnibiBytePos position, OnibiBytePos search_origin,
			  rb_encoding *encoding, OnibiEncodingMode mode,
			  OnibiSemanticArena *arena,
			  const OnibiSemanticState *predecessor,
			  OnibiSemanticState *accepted)
{
    for (uint32_t i = 0; i < state->edge_count; i++) {
	const OnibiREdge *edge = &view->edges[state->edge_base + i];
	if (edge->destination != ONIBI_ACCEPT_STATE) continue;
	if (onibi_apply_action_program(view, edge, str, position, search_origin,
				       encoding, mode, arena, predecessor,
				       accepted, ctx) == ONIBI_ACTION_SUCCESS) {
	    return 1;
	}
    }
    if (state->edge_count != 0) return 0;
    *accepted = *predecessor;
    return 1;
}

static int
onibi_rseq_tagged_run(OnibiExecCtx *ctx, uint32_t edge_base,
		      uint32_t edge_count, OnibiBytePos start,
		      OnibiBytePos required_end,
		      const OnibiSemanticState *initial, OnibiFrontier *current,
		      OnibiFrontier *next, OnibiSemanticState *accepted,
		      OnibiBytePos *matched_end)
{
    const OnibiRSeqView *view = ctx->view;
    const OnibiRSeqHeader *header = view->header;
    if (header->state_count == 0) return -1;
    VALUE str = ctx->subject;
    OnibiSemanticArena *arena = &ctx->semantic_arena;
    onibi_tagged_frontier_reset(current, header->state_count);

    int have_best = 0;
    OnibiBytePos best_end = start;
    OnibiSemanticState best = *initial;
    uint32_t prior = initial->capture_event_dependency;
    for (uint32_t i = 0; i < edge_count; i++) {
	const OnibiREdge *edge = &view->edges[edge_base + i];
	OnibiSemanticState predecessor = *initial;
	predecessor.capture_event_dependency = prior;
	OnibiSemanticState branch;
	if (onibi_apply_action_program(view, edge, str, start,
				       ctx->search_origin, ctx->encoding,
				       ctx->encoding_mode, arena, &predecessor,
				       &branch, ctx) == ONIBI_ACTION_FAIL)
	    continue;
	if (edge->destination == ONIBI_ACCEPT_STATE) {
	    if (required_end >= 0 && start != required_end) continue;
	    if (current->count == 0) {
		*accepted = branch;
		*matched_end = start;
		return 1;
	    }
	    have_best = 1;
	    best_end = start;
	    best = branch;
	    break;
	}
	if (edge->destination >= header->state_count) return -1;
	uint32_t retained_owner = UINT32_MAX;
	(void)onibi_tagged_frontier_add(current, arena, edge->destination,
					&branch, &retained_owner);
	prior = retained_owner;
    }
    if (current->count == 0) {
	if (!have_best) return 0;
	*accepted = best;
	*matched_end = best_end;
	return 1;
    }

    OnibiBytePos position = start;
    for (;;) {
	onibi_tagged_frontier_reset(next, header->state_count);
	int have_frontier_accept = 0;
	OnibiBytePos frontier_accept_end = position;
	OnibiSemanticState frontier_accept = *initial;
	long step_width = 0;
	for (size_t i = 0; i < current->count; i++) {
	    ctx->current_position = position;
	    onibi_exec_charge_work(ctx, 1);
	    uint32_t state_id = current->states[i];
	    if (state_id >= header->state_count) return -1;
	    const OnibiRState *state = &view->states[state_id];
	    const OnibiSemanticState *semantic = &current->semantics[i];
	    uint32_t source_owner = current->failure_owners[i];
	    uint32_t source_prior = semantic->capture_event_dependency;
	    if (state->op == 0) {
		OnibiSemanticState predecessor = *semantic;
		predecessor.capture_event_dependency = source_prior;
		OnibiSemanticState accept_state;
		if (!onibi_tagged_accept_state(
			ctx, view, state, str, position, ctx->search_origin,
			ctx->encoding, ctx->encoding_mode, arena, &predecessor,
			&accept_state)) {
		    if (!onibi_semantic_capture_event_owner_resolve(
			    arena, source_owner, source_prior))
			return -1;
		    continue;
		}
		if (required_end >= 0 && position != required_end) {
		    if (!onibi_semantic_capture_event_owner_resolve(
			    arena, source_owner, source_prior))
			return -1;
		    continue;
		}
		if (!onibi_semantic_capture_event_owner_resolve(
			arena, source_owner, source_prior))
		    return -1;
		if (next->count == 0) {
		    *accepted = accept_state;
		    *matched_end = position;
		    return 1;
		}
		have_frontier_accept = 1;
		frontier_accept_end = position;
		frontier_accept = accept_state;
		goto frontier_complete;
	    }
	    if (state->op != ONIBI_RS_CHAR && state->op != ONIBI_RS_CLASS &&
		state->op != ONIBI_RS_ANY)
		return -1;
	    OnibiBytePos next_position = position;
	    if (!onibi_rseq_consume_character(view, state, str, position,
					      ctx->encoding, ctx->encoding_mode,
					      &next_position, ctx->class_stack,
					      ctx->class_stack_capacity, ctx)) {
		if (!onibi_semantic_capture_event_owner_resolve(
			arena, source_owner, source_prior))
		    return -1;
		continue;
	    }
	    long width = next_position - position;
	    if (step_width == 0)
		step_width = width;
	    else if (step_width != width)
		return -1;
	    uint32_t edge_prior = source_prior;
	    int have_child = 0;
	    for (uint32_t e = 0; e < state->edge_count; e++) {
		const OnibiREdge *edge = &view->edges[state->edge_base + e];
		OnibiSemanticState predecessor = *semantic;
		predecessor.capture_event_dependency =
		    have_child ? edge_prior : source_prior;
		OnibiSemanticState branch;
		if (onibi_apply_action_program(
			view, edge, str, next_position, ctx->search_origin,
			ctx->encoding, ctx->encoding_mode, arena, &predecessor,
			&branch, ctx) == ONIBI_ACTION_FAIL)
		    continue;
		if (edge->destination == ONIBI_ACCEPT_STATE) {
		    if (required_end >= 0 && next_position != required_end)
			continue;
		    if (!onibi_semantic_capture_event_owner_resolve(
			    arena, source_owner, edge_prior))
			return -1;
		    if (next->count == 0) {
			*accepted = branch;
			*matched_end = next_position;
			return 1;
		    }
		    have_frontier_accept = 1;
		    frontier_accept_end = next_position;
		    frontier_accept = branch;
		    goto frontier_complete;
		}
		if (edge->destination >= header->state_count) return -1;
		uint32_t retained_owner = UINT32_MAX;
		(void)onibi_tagged_frontier_add(next, arena, edge->destination,
						&branch, &retained_owner);
		edge_prior = retained_owner;
		have_child = 1;
	    }
	    if (!onibi_semantic_capture_event_owner_resolve(
		    arena, source_owner,
		    have_child ? edge_prior : source_prior))
		return -1;
	}
    frontier_complete:
	if (have_frontier_accept) {
	    have_best = 1;
	    best_end = frontier_accept_end;
	    best = frontier_accept;
	}
	if (next->count == 0) {
	    if (!have_best) return 0;
	    *accepted = best;
	    *matched_end = best_end;
	    return 1;
	}
	OnibiFrontier *temporary = current;
	current = next;
	next = temporary;
	position += step_width;
    }
}

static int
onibi_rseq_tagged_match(OnibiExecCtx *ctx, OnibiSemanticState *accepted)
{
    const OnibiRSeqHeader *header = ctx->view->header;
    if (header->capture_count > UINT32_MAX / 2U) return -1;
    if (header->subprogram_count > SIZE_MAX / (2U * sizeof(OnibiFrontier)))
	return -1;
    size_t frontier_count = (size_t)header->subprogram_count * 2U;
    if (frontier_count > ctx->assertion_frontier_capacity) {
	ctx->assertion_frontiers = ruby_xrealloc(
	    ctx->assertion_frontiers, frontier_count * sizeof(OnibiFrontier));
	memset(ctx->assertion_frontiers + ctx->assertion_frontier_capacity, 0,
	       (frontier_count - ctx->assertion_frontier_capacity) *
		   sizeof(OnibiFrontier));
	ctx->assertion_frontier_capacity = frontier_count;
    }
    ctx->assertion_frontier_count = frontier_count;
    ctx->assertion_depth = 0;
    OnibiSemanticArena *arena = &ctx->semantic_arena;
    onibi_semantic_arena_reset(arena);
    OnibiSemanticState initial = onibi_semantic_state_initial(
	arena, ctx->attempt_start, header->capture_count * 2U,
	header->counter_count, header->counter_count);
    return onibi_rseq_tagged_run(ctx, header->start_edge_base,
				 header->start_edge_count, ctx->attempt_start,
				 -1, &initial, &ctx->current, &ctx->next,
				 accepted, &ctx->matched_end);
}

static void
onibi_semantic_checkpoint_restore(OnibiSemanticArena *arena,
				  const OnibiSemanticCheckpoint *checkpoint)
{
    arena->capture_event_count = checkpoint->capture_event_count;
    arena->capture_event_root_count = checkpoint->capture_event_root_count;
    arena->capture_event_owner_count = checkpoint->capture_event_owner_count;
    arena->register_count = checkpoint->register_count;
    arena->tag_count = checkpoint->tag_count;
    arena->call_count = checkpoint->call_count;
    arena->atomic_count = checkpoint->atomic_count;
    arena->absence_count = checkpoint->absence_count;
}

static OnibiFrontier *
onibi_tagged_assertion_frontiers(OnibiExecCtx *ctx)
{
    size_t base = ctx->assertion_depth * 2U;
    if (base > ctx->assertion_frontier_count ||
	ctx->assertion_frontier_count - base < 2U)
	return NULL;
    return ctx->assertion_frontiers + base;
}

static int
onibi_tagged_lookbehind_start(OnibiExecCtx *ctx, OnibiBytePos position,
			      uint32_t width, OnibiBytePos *start)
{
    OnibiBytePos current_position = position;
    for (uint32_t i = 0; i < width; i++) {
	ctx->current_position = current_position;
	onibi_exec_charge_work(ctx, 1);
	const char *begin = RSTRING_PTR(ctx->subject);
	const char *end = begin + RSTRING_LEN(ctx->subject);
	const char *current = begin + current_position;
	const char *previous =
	    rb_enc_prev_char(begin, current, end, ctx->encoding);
	if (previous == NULL) return 0;
	current_position = previous - begin;
    }
    *start = current_position;
    return 1;
}

static OnibiActionResult
onibi_tagged_assert_subprogram(OnibiExecCtx *ctx, const OnibiRAction *action,
			       OnibiBytePos position,
			       const OnibiSemanticState *predecessor,
			       OnibiSemanticState *successor)
{
    if (action->arg32 == 0 ||
	action->arg32 >= ctx->view->header->subprogram_count)
	return ONIBI_ACTION_FAIL;
    const OnibiSubprogramDesc *subprogram =
	&ctx->view->subprograms[action->arg32];
    int positive = action->flags == 1 || action->flags == 5;
    int lookbehind = action->arg16 == ONIBI_RAP_LOOKBEHIND;
    OnibiSemanticArena *arena = &ctx->semantic_arena;
    OnibiSemanticCheckpoint checkpoint = onibi_semantic_checkpoint_save(arena);
    OnibiFrontier *frontiers = onibi_tagged_assertion_frontiers(ctx);
    if (frontiers == NULL) return ONIBI_ACTION_FAIL;
    ctx->assertion_depth++;
    uint32_t trial_count = lookbehind ? subprogram->width_count : 1U;
    for (uint32_t i = 0; i < trial_count; i++) {
	OnibiBytePos start = position;
	OnibiBytePos required_end = -1;
	if (lookbehind) {
	    uint32_t width =
		ctx->view->lookbehind_widths[subprogram->width_base + i];
	    if (!onibi_tagged_lookbehind_start(ctx, position, width, &start))
		continue;
	    required_end = position;
	}
	OnibiSemanticState assertion_result;
	OnibiBytePos assertion_end = start;
	int result = onibi_rseq_tagged_run(
	    ctx, subprogram->entry_edge_base, subprogram->entry_edge_count,
	    start, required_end, predecessor, &frontiers[0], &frontiers[1],
	    &assertion_result, &assertion_end);
	if (result < 0) {
	    ctx->assertion_depth--;
	    onibi_semantic_checkpoint_restore(arena, &checkpoint);
	    return ONIBI_ACTION_FAIL;
	}
	if (result > 0) {
	    ctx->assertion_depth--;
	    if (!positive) {
		onibi_semantic_checkpoint_restore(arena, &checkpoint);
		return ONIBI_ACTION_FAIL;
	    }
	    *successor = *predecessor;
	    if ((subprogram->effects &
		 ONIBI_SUBPROGRAM_EFFECT_PUBLISH_CAPTURES) != 0) {
		successor->semantic_captures =
		    assertion_result.semantic_captures;
		successor->condition_captures =
		    assertion_result.condition_captures;
		successor->tag_history = assertion_result.tag_history;
		successor->order = assertion_result.order;
		successor->capture_event_history =
		    assertion_result.capture_event_history;
		successor->capture_event_dependency =
		    assertion_result.capture_event_dependency;
	    }
	    return ONIBI_ACTION_SUCCESS;
	}
	onibi_semantic_checkpoint_restore(arena, &checkpoint);
    }
    ctx->assertion_depth--;
    if (positive) return ONIBI_ACTION_FAIL;
    *successor = *predecessor;
    return ONIBI_ACTION_SUCCESS;
}

static int
onibi_rseq_regular_match(OnibiExecCtx *ctx)
{
    const OnibiRSeqView *view = ctx->view;
    const OnibiRSeqHeader *header = view->header;
    if (!view->regular_capable) return -1;
    uint32_t count = header->state_count;
    if (count == 0) return 0;
    VALUE str = ctx->subject;
    OnibiBytePos start = ctx->attempt_start;
    uint32_t capture_slots = header->capture_count * 2U;
    int capture_mode =
	onibi_raw_match_capture_mode(ctx->raw_match, header->capture_count) &&
	capture_slots != 0;
    ctx->tags.count = 0;
    onibi_regular_frontier_prepare(&ctx->current, (size_t)count, capture_mode);
    onibi_regular_frontier_prepare(&ctx->next, (size_t)count, capture_mode);
    size_t bits_size = (size_t)count / 8U + ((count % 8U) == 0 ? 0U : 1U);
    uint32_t *current = ctx->current.states;
    uint32_t *next = ctx->next.states;
    uint32_t *current_histories = capture_mode ? ctx->current.histories : NULL;
    uint32_t *next_histories = capture_mode ? ctx->next.histories : NULL;
    unsigned char *current_bits = ctx->current.membership;
    unsigned char *next_bits = ctx->next.membership;
    size_t current_count = 0;
    OnibiBytePos best_end = -1;
    uint32_t best_history = UINT32_MAX;
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
    OnibiBytePos position = start;
    for (;;) {
	long step_width = 1;
	size_t next_count = 0;
	memset(next_bits, 0, bits_size);
	int have_fallback = 0;
	OnibiBytePos fallback_end = 0;
	uint32_t fallback_history = UINT32_MAX;
	for (size_t i = 0; i < current_count; i++) {
	    uint32_t state_id = current[i];
	    uint32_t thread_history =
		capture_mode ? current_histories[i] : UINT32_MAX;
	    ctx->current_position = position;
	    onibi_exec_charge_work(ctx, 1);
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
			    &ctx->tags, accept_history, ctx->raw_match,
			    capture_slots);
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
	    OnibiBytePos next_position = position;
	    int hit = onibi_rseq_consume_character(
		view, state, str, position, ctx->encoding, ctx->encoding_mode,
		&next_position, ctx->class_stack, ctx->class_stack_capacity,
		ctx);
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
				&ctx->tags, accept_history, ctx->raw_match,
				capture_slots);
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
						   ctx->raw_match,
						   capture_slots);
		ctx->matched_end = fallback_end;
		return 1;
	    }
	    if (best_end >= 0) {
		if (capture_mode)
		    onibi_regular_materialize_tags(&ctx->tags, best_history,
						   ctx->raw_match,
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
	ctx->class_stack, ctx->class_stack_capacity, ctx);
    if (result < 0) {
	onibi_diagnostics.executor_error_kind = ONIBI_EXECUTOR_ERROR_UNEXPECTED;
	return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
    }
    if (result > 0) {
	ctx->reported_start = accepted.reported_start;
	if (onibi_raw_match_capture_mode(ctx->raw_match,
					 ctx->program->capture_count) &&
	    !onibi_tagged_materialize_tags(&ctx->semantic_arena, &accepted,
					   ctx->raw_match,
					   ctx->program->capture_count * 2U)) {
	    onibi_diagnostics.executor_error_kind =
		ONIBI_EXECUTOR_ERROR_MALFORMED_PROGRAM;
	    return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
	}
    }
    return result > 0 ? ONIBI_EXEC_STATUS_MATCH : ONIBI_EXEC_STATUS_NO_MATCH;
}

static OnibiExecStatus
onibi_exec_tagged(OnibiExecCtx *ctx)
{
    onibi_diagnostics.tagged++;
    OnibiSemanticState accepted;
    int result = onibi_rseq_tagged_match(ctx, &accepted);
    onibi_diagnostics.order_nodes = ctx->semantic_arena.order_count;
    onibi_diagnostics.capture_events = ctx->semantic_arena.capture_event_count;
    onibi_diagnostics.capture_event_roots =
	ctx->semantic_arena.capture_event_root_count;
    onibi_diagnostics.capture_event_owners =
	ctx->semantic_arena.capture_event_owner_count;
    if (result < 0) {
	onibi_diagnostics.executor_error_kind = ONIBI_EXECUTOR_ERROR_UNEXPECTED;
	return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
    }
    if (result > 0) {
	ctx->reported_start = accepted.reported_start;
	if (onibi_raw_match_capture_mode(ctx->raw_match,
					 ctx->program->capture_count) &&
	    !onibi_tagged_materialize_tags(&ctx->semantic_arena, &accepted,
					   ctx->raw_match,
					   ctx->program->capture_count * 2U)) {
	    onibi_diagnostics.executor_error_kind =
		ONIBI_EXECUTOR_ERROR_MALFORMED_PROGRAM;
	    return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
	}
    }
    return result > 0 ? ONIBI_EXEC_STATUS_MATCH : ONIBI_EXEC_STATUS_NO_MATCH;
}

static OnibiExecStatus
onibi_execute(OnibiExecCtx *ctx)
{
    if (onibi_inject_internal_error) {
	onibi_inject_internal_error = 0;
	onibi_diagnostics.executor_error_kind = ONIBI_EXECUTOR_ERROR_UNEXPECTED;
	return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
    }
    OnibiExecStatus status;
    switch ((OnibiExecutionKind)ctx->program->exec_kind) {
    case ONIBI_EXEC_REGULAR: status = onibi_exec_regular(ctx); break;
    case ONIBI_EXEC_TAGGED: status = onibi_exec_tagged(ctx); break;
    case ONIBI_EXEC_DYNAMIC: status = onibi_exec_dynamic(ctx); break;
    default:
	onibi_diagnostics.executor_error_kind = ONIBI_EXECUTOR_ERROR_CONTRACT;
	return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
    }
    if (status == ONIBI_EXEC_STATUS_MATCH &&
	!onibi_raw_match_record(ctx->raw_match, ctx->reported_start,
				ctx->matched_end)) {
	onibi_diagnostics.executor_error_kind = ONIBI_EXECUTOR_ERROR_CONTRACT;
	return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
    }
    if (status != ONIBI_EXEC_STATUS_MATCH &&
	status != ONIBI_EXEC_STATUS_INTERNAL_ERROR &&
	status != ONIBI_EXEC_STATUS_NO_MATCH) {
	/* An executor cannot select MRI.  A violation is an internal contract
	 * error, not another compatibility decision. */
	onibi_diagnostics.executor_error_kind = ONIBI_EXECUTOR_ERROR_CONTRACT;
	return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
    }
    return status;
}
/* DYNAMIC interpreter. */
