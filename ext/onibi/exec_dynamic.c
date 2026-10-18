#include "onibi_encoding_internal.h"
#include "onibi_exec_internal.h"
#include "onibi_rseq_internal.h"

/* Failure continuations use this reserved value in the cycle-root slot. */
#define ONIBI_DYNAMIC_FAILURE_FRAME_MARKER (UINT32_MAX - UINT32_C(1))

typedef struct OnibiDynamicAbsenceCaptureWriteLog
    OnibiDynamicAbsenceCaptureWriteLog;

static void onibi_dynamic_absence_capture_write_clone(
    OnibiDynamicAbsenceCaptureWriteLog *log, OnibiSemanticArena *arena,
    OnibiTagEventId source, OnibiTagEventId destination, OnibiExecCtx *ctx);
static void onibi_dynamic_absence_capture_write_publish(
    OnibiDynamicAbsenceCaptureWriteLog *log, OnibiSemanticArena *arena,
    OnibiTagEventId tag_id, uint16_t slot, OnibiBytePos position,
    OnibiExecCtx *ctx);

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

static OnibiBytePos
onibi_dynamic_previous_position(VALUE str, OnibiBytePos position,
				rb_encoding *encoding, OnibiEncodingMode mode)
{
    if (position < 0) return -1;
    if (position == 0) return 0;
    if (position > RSTRING_LEN(str) || !onibi_character_boundary(str, position))
	return -1;
    if (mode == ONIBI_ENC_ASCII_7BIT) return position - 1;
    const char *begin = RSTRING_PTR(str);
    const char *end = begin + RSTRING_LEN(str);
    const char *previous =
	rb_enc_prev_char(begin, begin + position, end, encoding);
    return previous == NULL ? 0 : (OnibiBytePos)(previous - begin);
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
	int multiline = (state->flags & ONIBI_RSEQ_STATE_FLAG_NEGATED) != 0;
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
    long subject_length = RSTRING_LEN(str);
    if (capture_begin < 0 || capture_end < capture_begin ||
	capture_end > subject_length || position < 0 ||
	position > subject_length)
	return 0;
    long capture_length = capture_end - capture_begin;
    /* MRI requires at least the captured byte length before folding. */
    if (capture_length > subject_length - position) return 0;
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
onibi_rseq_begin_line_hit(VALUE str, OnibiBytePos pos, rb_encoding *encoding,
			  OnibiEncodingMode mode)
{
    if (pos == 0) return 1;
    if (pos < 0 || pos >= RSTRING_LEN(str)) return 0;

    OnibiBytePos previous =
	onibi_dynamic_previous_position(str, pos, encoding, mode);
    if (previous < 0 || previous >= pos) return 0;

    OnigCodePoint codepoint;
    long width;
    return onibi_rseq_decode_character(str, previous, encoding, mode,
				       &codepoint, &width) &&
	   previous + width == pos && codepoint == '\n';
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
	hit = onibi_rseq_begin_line_hit(str, pos, encoding, mode);
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
    arena->next_tag_identity = 1;
    arena->call_count = 0;
    arena->atomic_count = 0;
    arena->absence_count = 0;
    arena->frame_count = 0;
    arena->absence_endpoint_count = 0;
    arena->output_root.undo_count = 0;
    arena->output_root.transcript_count = 0;
    arena->active_output_state = NULL;
    arena->active_output_batch = 0;
    arena->output_batch_count = 0;
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
    ruby_xfree(arena->absence_endpoints);
    ruby_xfree(arena->output_root.slots);
    ruby_xfree(arena->output_root.undo);
    ruby_xfree(arena->output_root.direct_starts);
    ruby_xfree(arena->output_root.direct_start_rehash);
    ruby_xfree(arena->output_root.transcript);
    for (size_t i = 0; i < arena->output_batch_capacity; i++)
	ruby_xfree(arena->output_batches[i].writes);
    ruby_xfree(arena->output_batches);
    for (size_t i = 0; i < arena->output_scope_count; i++) {
	OnibiDynamicOutputState *state = arena->output_scopes[i].state;
	if (state == NULL) continue;
	ruby_xfree(state->slots);
	ruby_xfree(state->undo);
	ruby_xfree(state->direct_starts);
	ruby_xfree(state->direct_start_rehash);
	ruby_xfree(state->transcript);
	ruby_xfree(state);
    }
    ruby_xfree(arena->output_scopes);
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

static uint64_t
onibi_dynamic_output_start_identity_hash(
    const OnibiDynamicOutputStartIdentity *identity)
{
    uint64_t hash = (uint64_t)identity->capture_order;
    hash ^= (uint64_t)identity->slot * UINT64_C(0x9e3779b185ebca87);
    hash ^= (uint64_t)identity->position * UINT64_C(0xc2b2ae3d27d4eb4f);
    hash ^= hash >> 30U;
    hash *= UINT64_C(0xbf58476d1ce4e5b9);
    hash ^= hash >> 27U;
    hash *= UINT64_C(0x94d049bb133111eb);
    hash ^= hash >> 31U;
    return hash;
}

static int
onibi_dynamic_output_start_identity_equal(
    const OnibiDynamicOutputStartIdentity *left,
    const OnibiDynamicOutputStartIdentity *right)
{
    return left->capture_order == right->capture_order &&
	   left->slot == right->slot && left->position == right->position;
}

static void
onibi_dynamic_output_start_identities_copy(
    OnibiDynamicOutputState *target, const OnibiDynamicOutputState *source,
    OnibiExecCtx *ctx)
{
    if (source->direct_start_capacity == 0) {
	if (target->direct_starts != NULL)
	    memset(target->direct_starts, 0,
		   target->direct_start_capacity *
		       sizeof(*target->direct_starts));
	target->direct_start_count = 0;
	return;
    }
    if (source->direct_start_capacity >
	SIZE_MAX / sizeof(*target->direct_starts))
	rb_memerror();
    if (target->direct_start_capacity != source->direct_start_capacity) {
	onibi_exec_charge_work(ctx, source->direct_start_capacity);
	OnibiDynamicOutputStartIdentity *copy =
	    ruby_xmalloc(source->direct_start_capacity * sizeof(*copy));
	ruby_xfree(target->direct_starts);
	target->direct_starts = copy;
	target->direct_start_capacity = source->direct_start_capacity;
    }
    onibi_exec_charge_work(ctx, source->direct_start_capacity);
    memcpy(target->direct_starts, source->direct_starts,
	   source->direct_start_capacity * sizeof(*target->direct_starts));
    target->direct_start_count = source->direct_start_count;
}

static void
onibi_dynamic_output_state_clear(OnibiDynamicOutputState *state)
{
    ruby_xfree(state->slots);
    ruby_xfree(state->undo);
    ruby_xfree(state->direct_starts);
    ruby_xfree(state->direct_start_rehash);
    ruby_xfree(state->transcript);
    memset(state, 0, sizeof(*state));
}

static void
onibi_dynamic_output_state_reset(OnibiDynamicOutputState *state,
				 uint32_t slot_count, OnibiExecCtx *ctx)
{
    if (slot_count > SIZE_MAX / sizeof(*state->slots)) rb_memerror();
    if (slot_count > state->slot_count) {
	onibi_exec_charge_work(ctx, slot_count - state->slot_count);
	state->slots = ruby_xrealloc(state->slots, (size_t)slot_count *
						       sizeof(*state->slots));
    }
    state->slot_count = slot_count;
    state->undo_count = 0;
    state->direct_start_count = 0;
    if (state->direct_start_capacity != 0)
	memset(state->direct_starts, 0,
	       state->direct_start_capacity * sizeof(*state->direct_starts));
    state->transcript_count = 0;
    state->record_transcript = 0;
    for (uint32_t slot = 0; slot < slot_count; slot++) {
	onibi_exec_charge_work(ctx, 1);
	state->slots[slot] = -1;
    }
}

static OnibiDynamicOutputState *
onibi_dynamic_output_scope_new(OnibiSemanticArena *arena,
			       const OnibiDynamicOutputState *source,
			       int record_transcript, OnibiExecCtx *ctx)
{
    size_t index;
    int append = arena->output_scope_free_head == 0;
    if (append) {
	index = arena->output_scope_count;
	if (index == arena->output_scope_capacity) {
	    size_t capacity = arena->output_scope_capacity == 0
				  ? 32U
				  : arena->output_scope_capacity * 2U;
	    if (capacity < arena->output_scope_capacity ||
		capacity > SIZE_MAX / sizeof(*arena->output_scopes))
		rb_memerror();
	    onibi_exec_charge_work(ctx,
				   capacity - arena->output_scope_capacity);
	    arena->output_scopes = ruby_xrealloc(
		arena->output_scopes, capacity * sizeof(*arena->output_scopes));
	    arena->output_scope_capacity = capacity;
	}
    }
    else {
	index = arena->output_scope_free_head - 1U;
	if (index >= arena->output_scope_count ||
	    arena->output_scopes[index].state != NULL)
	    rb_raise(eRegexpError, "dynamic output scope free list is invalid");
    }
    onibi_exec_charge_work(ctx, 1);
    onibi_exec_charge_work(ctx, 1);
    OnibiDynamicOutputState *state = ruby_xcalloc(1, sizeof(*state));
    if (append) {
	arena->output_scope_count++;
	arena->output_scopes[index].next_free_plus_one = 0;
    }
    else {
	arena->output_scope_free_head =
	    arena->output_scopes[index].next_free_plus_one;
	arena->output_scopes[index].next_free_plus_one = 0;
    }
    state->registry_index = index;
    arena->output_scopes[index].state = state;
    if (source != NULL) {
	if (source->slot_count > SIZE_MAX / sizeof(*state->slots) ||
	    source->undo_count > SIZE_MAX / sizeof(*state->undo))
	    rb_memerror();
	if (source->slot_count != 0) {
	    onibi_exec_charge_work(ctx, source->slot_count);
	    state->slots = ruby_xmalloc((size_t)source->slot_count *
					sizeof(*state->slots));
	    memcpy(state->slots, source->slots,
		   (size_t)source->slot_count * sizeof(*state->slots));
	}
	state->slot_count = source->slot_count;
	if (source->undo_count != 0) {
	    onibi_exec_charge_work(ctx, source->undo_count);
	    state->undo =
		ruby_xmalloc(source->undo_count * sizeof(*state->undo));
	    memcpy(state->undo, source->undo,
		   source->undo_count * sizeof(*state->undo));
	    state->undo_count = state->undo_capacity = source->undo_count;
	}
	onibi_dynamic_output_start_identities_copy(state, source, ctx);
    }
    state->record_transcript = (uint8_t)(record_transcript != 0);
    return state;
}

static void
onibi_dynamic_output_scope_release(OnibiSemanticArena *arena,
				   OnibiDynamicOutputState *state)
{
    if (state == NULL || arena->output_scopes == NULL) return;
    size_t index = state->registry_index;
    if (index >= arena->output_scope_count ||
	arena->output_scopes[index].state != state)
	return;
    arena->output_scopes[index].state = NULL;
    arena->output_scopes[index].next_free_plus_one =
	arena->output_scope_free_head;
    arena->output_scope_free_head = index + 1U;
    onibi_dynamic_output_state_clear(state);
    ruby_xfree(state);
}

static OnibiDynamicOutputBatch *
onibi_dynamic_output_batch_get(OnibiSemanticArena *arena, uint32_t reference)
{
    if (reference == 0 || reference > arena->output_batch_count)
	rb_raise(eRegexpError, "dynamic output batch reference is invalid");
    return &arena->output_batches[reference - 1U];
}

static uint32_t
onibi_dynamic_output_batch_new(OnibiSemanticArena *arena, OnibiExecCtx *ctx)
{
    if (arena->output_batch_count >= UINT32_MAX) rb_memerror();
    size_t old_capacity = arena->output_batch_capacity;
    if (arena->output_batch_count == arena->output_batch_capacity) {
	size_t capacity = arena->output_batch_capacity == 0
			      ? 32U
			      : arena->output_batch_capacity * 2U;
	if (capacity < arena->output_batch_capacity || capacity > UINT32_MAX ||
	    capacity > SIZE_MAX / sizeof(*arena->output_batches))
	    rb_memerror();
	onibi_exec_charge_work(ctx, capacity - old_capacity);
	arena->output_batches = ruby_xrealloc(
	    arena->output_batches, capacity * sizeof(*arena->output_batches));
	arena->output_batch_capacity = capacity;
    }
    if (arena->output_batch_capacity > old_capacity) {
	memset(arena->output_batches + old_capacity, 0,
	       (arena->output_batch_capacity - old_capacity) *
		   sizeof(*arena->output_batches));
    }
    OnibiDynamicOutputBatch *batch =
	&arena->output_batches[arena->output_batch_count++];
    batch->count = 0;
    onibi_exec_charge_work(ctx, 1);
    return (uint32_t)arena->output_batch_count;
}

static void
onibi_dynamic_output_batch_append(OnibiSemanticArena *arena, uint32_t reference,
				  OnibiDynamicOutputWrite write,
				  OnibiExecCtx *ctx)
{
    OnibiDynamicOutputBatch *batch =
	onibi_dynamic_output_batch_get(arena, reference);
    if (batch->count == batch->capacity) {
	size_t capacity = batch->capacity == 0 ? 8U : batch->capacity * 2U;
	if (capacity < batch->capacity ||
	    capacity > SIZE_MAX / sizeof(*batch->writes))
	    rb_memerror();
	onibi_exec_charge_work(ctx, capacity - batch->capacity);
	batch->writes =
	    ruby_xrealloc(batch->writes, capacity * sizeof(*batch->writes));
	batch->capacity = capacity;
    }
    onibi_exec_charge_work(ctx, 1);
    batch->writes[batch->count++] = write;
}

static void
onibi_dynamic_output_batch_append_transcript(
    OnibiSemanticArena *arena, uint32_t reference,
    const OnibiDynamicOutputState *state, OnibiExecCtx *ctx)
{
    if (reference == 0) return;
    for (size_t i = 0; i < state->transcript_count; i++)
	onibi_dynamic_output_batch_append(arena, reference,
					  state->transcript[i], ctx);
}

static uint32_t
onibi_dynamic_output_batch_from_state(OnibiSemanticArena *arena,
				      const OnibiDynamicOutputState *state,
				      OnibiExecCtx *ctx)
{
    uint32_t reference = onibi_dynamic_output_batch_new(arena, ctx);
    onibi_dynamic_output_batch_append_transcript(arena, reference, state, ctx);
    return reference;
}

static void
onibi_dynamic_output_state_log(OnibiDynamicOutputState *state,
			       OnibiDynamicOutputWrite write, OnibiExecCtx *ctx)
{
    if (!state->record_transcript) return;
    if (state->transcript_count == state->transcript_capacity) {
	size_t capacity = state->transcript_capacity == 0
			      ? 16U
			      : state->transcript_capacity * 2U;
	if (capacity < state->transcript_capacity ||
	    capacity > SIZE_MAX / sizeof(*state->transcript))
	    rb_memerror();
	onibi_exec_charge_work(ctx, capacity - state->transcript_capacity);
	state->transcript = ruby_xrealloc(
	    state->transcript, capacity * sizeof(*state->transcript));
	state->transcript_capacity = capacity;
    }
    onibi_exec_charge_work(ctx, 1);
    state->transcript[state->transcript_count++] = write;
}

static void
onibi_dynamic_output_undo_reserve(OnibiDynamicOutputState *state,
				  OnibiExecCtx *ctx)
{
    if (state->undo_count < state->undo_capacity) return;
    size_t capacity =
	state->undo_capacity == 0 ? 8U : state->undo_capacity * 2U;
    if (capacity < state->undo_capacity ||
	capacity > SIZE_MAX / sizeof(*state->undo))
	rb_memerror();
    onibi_exec_charge_work(ctx, capacity - state->undo_capacity);
    state->undo = ruby_xrealloc(state->undo, capacity * sizeof(*state->undo));
    state->undo_capacity = capacity;
}

static void
onibi_dynamic_output_start_identity_reserve(OnibiDynamicOutputState *state,
					    OnibiExecCtx *ctx)
{
    if (state->direct_start_count == SIZE_MAX) rb_memerror();
    size_t required = state->direct_start_count + 1U;
    if (state->direct_start_capacity != 0 &&
	required <= state->direct_start_capacity / 2U)
	return;
    size_t capacity = state->direct_start_capacity == 0
			  ? 16U
			  : state->direct_start_capacity * 2U;
    while (required > capacity / 2U) {
	if (capacity > SIZE_MAX / 2U) rb_memerror();
	capacity *= 2U;
    }
    if (capacity > SIZE_MAX / sizeof(*state->direct_starts)) rb_memerror();
    if (state->direct_start_rehash != NULL)
	rb_raise(eRegexpError,
		 "dynamic output identity rehash is already active");
    onibi_exec_charge_work(ctx, (uint64_t)capacity);
    state->direct_start_rehash =
	ruby_xcalloc(capacity, sizeof(*state->direct_start_rehash));
    for (size_t i = 0; i < state->direct_start_capacity; i++) {
	onibi_exec_charge_work(ctx, 1);
	const OnibiDynamicOutputStartIdentity *old = &state->direct_starts[i];
	if (!old->occupied) continue;
	size_t slot = (size_t)onibi_dynamic_output_start_identity_hash(old) &
		      (capacity - 1U);
	for (;;) {
	    onibi_exec_charge_work(ctx, 1);
	    if (!state->direct_start_rehash[slot].occupied) break;
	    slot = (slot + 1U) & (capacity - 1U);
	}
	state->direct_start_rehash[slot] = *old;
    }
    OnibiDynamicOutputStartIdentity *previous = state->direct_starts;
    state->direct_starts = state->direct_start_rehash;
    state->direct_start_rehash = NULL;
    state->direct_start_capacity = capacity;
    ruby_xfree(previous);
}

static int
onibi_dynamic_output_start_identity_record(OnibiDynamicOutputState *state,
					   const OnibiDynamicOutputWrite *write,
					   OnibiExecCtx *ctx)
{
    if ((write->kind != ONIBI_DYNAMIC_OUTPUT_ACTION &&
	 write->kind != ONIBI_DYNAMIC_OUTPUT_DIRECT) ||
	(write->flags & ONIBI_RA_CAPTURE_OPEN_UNSCOPED) == 0 ||
	(write->flags & ONIBI_RA_CAPTURE_OPEN_START_PUSH) != 0 ||
	write->capture_order == UINT32_MAX)
	return 0;
    if ((write->slot & 1U) != 0)
	rb_raise(eRegexpError, "dynamic unscoped output start is invalid");
    onibi_dynamic_output_start_identity_reserve(state, ctx);
    OnibiDynamicOutputStartIdentity key = {.capture_order =
					       write->capture_order,
					   .slot = write->slot,
					   .occupied = 1,
					   .position = write->position};
    size_t slot = (size_t)onibi_dynamic_output_start_identity_hash(&key) &
		  (state->direct_start_capacity - 1U);
    for (;;) {
	onibi_exec_charge_work(ctx, 1);
	if (!state->direct_starts[slot].occupied) {
	    state->direct_starts[slot] = key;
	    state->direct_start_count++;
	    return 0;
	}
	if (onibi_dynamic_output_start_identity_equal(
		&state->direct_starts[slot], &key)) {
	    return 1;
	}
	slot = (slot + 1U) & (state->direct_start_capacity - 1U);
    }
}

static void
onibi_dynamic_output_apply_write(OnibiDynamicOutputState *state,
				 OnibiDynamicOutputWrite write,
				 OnibiExecCtx *ctx)
{
    if (write.slot >= state->slot_count ||
	(write.kind != ONIBI_DYNAMIC_OUTPUT_RESTORE && write.position < 0))
	rb_raise(eRegexpError, "dynamic output capture write is invalid");
    if (onibi_dynamic_output_start_identity_record(state, &write, ctx)) return;
    if (write.kind == ONIBI_DYNAMIC_OUTPUT_ACTION) {
	if ((write.flags & ONIBI_RA_CAPTURE_OPEN_START_PUSH) != 0) {
	    if ((write.slot & 1U) != 0 || write.slot + 1U >= state->slot_count)
		rb_raise(eRegexpError, "dynamic pushed output slot is invalid");
	    uint32_t capture = write.slot / 2U;
	    OnibiDynamicOutputUndo undo = {capture, state->slots[write.slot],
					   state->slots[write.slot + 1U]};
	    onibi_dynamic_output_undo_reserve(state, ctx);
	    state->undo[state->undo_count++] = undo;
	    state->slots[write.slot] = write.position;
	    write.kind = ONIBI_DYNAMIC_OUTPUT_PUSH;
	    write.previous_begin = undo.begin;
	    write.previous_end = undo.end;
	}
	else {
	    if ((write.slot & 1U) == 0) {
		if (write.slot + 1U >= state->slot_count)
		    rb_raise(eRegexpError,
			     "dynamic output start slot is invalid");
		state->slots[write.slot + 1U] = -1;
	    }
	    state->slots[write.slot] = write.position;
	    write.kind = ONIBI_DYNAMIC_OUTPUT_DIRECT;
	}
    }
    else if (write.kind == ONIBI_DYNAMIC_OUTPUT_DIRECT) {
	if ((write.slot & 1U) == 0) {
	    if (write.slot + 1U >= state->slot_count)
		rb_raise(eRegexpError, "dynamic output start slot is invalid");
	    state->slots[write.slot + 1U] = -1;
	}
	state->slots[write.slot] = write.position;
    }
    else if (write.kind == ONIBI_DYNAMIC_OUTPUT_PUSH) {
	if ((write.slot & 1U) != 0 || write.slot + 1U >= state->slot_count ||
	    (write.previous_begin < 0 && write.previous_begin != -1) ||
	    (write.previous_end < 0 && write.previous_end != -1))
	    rb_raise(eRegexpError, "dynamic pushed output snapshot is invalid");
	OnibiDynamicOutputUndo undo = {write.slot / 2U, write.previous_begin,
				       write.previous_end};
	onibi_dynamic_output_undo_reserve(state, ctx);
	state->undo[state->undo_count++] = undo;
	state->slots[write.slot] = write.position;
    }
    else if (write.kind == ONIBI_DYNAMIC_OUTPUT_RESTORE) {
	if ((write.slot & 1U) != 0 || write.slot + 1U >= state->slot_count ||
	    state->undo_count == 0)
	    rb_raise(eRegexpError, "dynamic pushed output restore is invalid");
	OnibiDynamicOutputUndo undo = state->undo[--state->undo_count];
	if (undo.capture != write.slot / 2U ||
	    undo.begin != write.previous_begin ||
	    undo.end != write.previous_end)
	    rb_raise(eRegexpError,
		     "dynamic pushed output restore does not match");
	state->slots[write.slot] = write.previous_begin;
	state->slots[write.slot + 1U] = write.previous_end;
    }
    else
	rb_raise(eRegexpError, "dynamic output write kind is invalid");
    onibi_dynamic_output_state_log(state, write, ctx);
}

static void
onibi_dynamic_output_publish_slot(OnibiSemanticArena *arena,
				  OnibiDynamicOutputState *state,
				  uint32_t batch_reference, uint16_t slot,
				  OnibiBytePos position, OnibiExecCtx *ctx)
{
    OnibiDynamicOutputWrite write = {.slot = slot,
				     .flags = 0,
				     .kind = ONIBI_DYNAMIC_OUTPUT_DIRECT,
				     .position = position,
				     .previous_begin = -1,
				     .previous_end = -1,
				     .source_state = UINT32_MAX,
				     .edge_index = UINT32_MAX,
				     .destination = UINT32_MAX,
				     .action_index = UINT32_MAX,
				     .capture_order = UINT32_MAX};
    if (batch_reference != 0)
	onibi_dynamic_output_batch_append(arena, batch_reference, write, ctx);
    else if (state != NULL) {
	onibi_dynamic_output_apply_write(state, write, ctx);
	onibi_exec_charge_work(ctx, 1);
    }
}

static void
onibi_dynamic_output_restore_to(OnibiDynamicOutputState *state, size_t mark,
				OnibiExecCtx *ctx)
{
    if (mark > state->undo_count)
	rb_raise(eRegexpError, "dynamic output rollback mark is invalid");
    while (state->undo_count > mark) {
	OnibiDynamicOutputUndo undo = state->undo[--state->undo_count];
	if (undo.capture > (UINT32_MAX - 1U) / 2U)
	    rb_raise(eRegexpError,
		     "dynamic output rollback capture is invalid");
	uint32_t slot = undo.capture * 2U;
	if (slot + 1U >= state->slot_count)
	    rb_raise(eRegexpError, "dynamic output rollback slot is invalid");
	state->slots[slot] = undo.begin;
	state->slots[slot + 1U] = undo.end;
	onibi_dynamic_output_state_log(
	    state,
	    (OnibiDynamicOutputWrite){.slot = (uint16_t)slot,
				      .flags = 0,
				      .kind = ONIBI_DYNAMIC_OUTPUT_RESTORE,
				      .position = undo.begin,
				      .previous_begin = undo.begin,
				      .previous_end = undo.end,
				      .source_state = UINT32_MAX,
				      .edge_index = UINT32_MAX,
				      .destination = UINT32_MAX,
				      .action_index = UINT32_MAX,
				      .capture_order = UINT32_MAX},
	    ctx);
	onibi_exec_charge_work(ctx, 1);
    }
}

static void
onibi_dynamic_output_apply_batch(OnibiDynamicOutputState *state,
				 OnibiSemanticArena *arena, uint32_t reference,
				 OnibiExecCtx *ctx)
{
    if (reference == 0) return;
    OnibiDynamicOutputBatch *batch =
	onibi_dynamic_output_batch_get(arena, reference);
    for (size_t i = 0; i < batch->count; i++) {
	onibi_dynamic_output_apply_write(state, batch->writes[i], ctx);
	onibi_exec_charge_work(ctx, 1);
    }
}

static void
onibi_dynamic_output_replay_transcript(OnibiDynamicOutputState *target,
				       const OnibiDynamicOutputState *source,
				       OnibiExecCtx *ctx)
{
    for (size_t i = 0; i < source->transcript_count; i++) {
	onibi_dynamic_output_apply_write(target, source->transcript[i], ctx);
	onibi_exec_charge_work(ctx, 1);
    }
}

static void
onibi_dynamic_output_copy_registers(OnibiDynamicOutputState *target,
				    const OnibiDynamicOutputState *source,
				    OnibiExecCtx *ctx)
{
    if (target->slot_count != source->slot_count)
	rb_raise(eRegexpError, "dynamic output slot counts do not match");
    if (source->undo_count > target->undo_capacity) {
	if (source->undo_count > SIZE_MAX / sizeof(*target->undo))
	    rb_memerror();
	onibi_exec_charge_work(ctx, source->undo_count - target->undo_capacity);
	target->undo = ruby_xrealloc(target->undo, source->undo_count *
						       sizeof(*target->undo));
	target->undo_capacity = source->undo_count;
    }
    if (target->slot_count != 0) {
	onibi_exec_charge_work(ctx, target->slot_count);
	memcpy(target->slots, source->slots,
	       (size_t)target->slot_count * sizeof(*target->slots));
    }
    onibi_dynamic_output_start_identities_copy(target, source, ctx);
    if (source->undo_count != 0) {
	onibi_exec_charge_work(ctx, source->undo_count);
	memcpy(target->undo, source->undo,
	       source->undo_count * sizeof(*target->undo));
    }
    target->undo_count = source->undo_count;
}

static void
onibi_dynamic_output_batch_copy(OnibiSemanticArena *arena, uint32_t destination,
				uint32_t source, OnibiExecCtx *ctx)
{
    if (source == 0) return;
    OnibiDynamicOutputBatch *from =
	onibi_dynamic_output_batch_get(arena, source);
    for (size_t i = 0; i < from->count; i++)
	onibi_dynamic_output_batch_append(arena, destination, from->writes[i],
					  ctx);
}

static void
onibi_dynamic_output_filter_transcript_captures(
    OnibiDynamicOutputState *state, const unsigned char *clear,
    uint32_t slot_count, const unsigned char *pushed_captures,
    OnibiExecCtx *ctx)
{
    if (state == NULL) return;
    size_t retained = 0;
    for (size_t i = 0; i < state->transcript_count; i++) {
	OnibiDynamicOutputWrite write = state->transcript[i];
	if (write.slot >= slot_count)
	    rb_raise(eRegexpError, "dynamic output transcript slot is invalid");
	uint32_t begin_slot = (write.slot / 2U) * 2U;
	uint32_t end_slot = begin_slot + 1U;
	int discard = clear != NULL && (clear[begin_slot] || clear[end_slot]);
	if (pushed_captures != NULL && pushed_captures[write.slot / 2U])
	    discard = 1;
	onibi_exec_charge_work(ctx, 1);
	if (discard) continue;
	state->transcript[retained++] = write;
    }
    state->transcript_count = retained;
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
    if (arena->next_tag_identity == 0) arena->next_tag_identity = 1;
    if (arena->next_tag_identity == UINT64_MAX) rb_memerror();
    arena->tags[id] = (OnibiSemanticTagEvent){parent, slot, position, hash,
					      arena->next_tag_identity++};
    onibi_diagnostics.tag_events++;
    return id;
}

static OnibiTagEventId
onibi_semantic_tag_clone(OnibiSemanticArena *arena, OnibiTagEventId parent,
			 const OnibiSemanticTagEvent *source)
{
    uint32_t slot = source->slot;
    OnibiBytePos position = source->position;
    uint64_t logical_id = source->logical_id;
    OnibiTagEventId id =
	onibi_semantic_tag_append(arena, parent, slot, position);
    arena->tags[id].logical_id = logical_id;
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
				 uint32_t begin_slot, uint32_t end_slot,
				 OnibiExecCtx *ctx)
{
    size_t traversed = 0;
    while (tag_history != UINT32_MAX) {
	if (ctx != NULL) {
	    if ((size_t)tag_history >= arena->tag_count ||
		traversed >= arena->tag_count)
		rb_raise(eRegexpError,
			 "dynamic call output capture tag history is invalid");
	    onibi_exec_charge_work(ctx, 1);
	    traversed++;
	}
	const OnibiSemanticTagEvent *event = &arena->tags[tag_history];
	if (event->slot == begin_slot) return 1;
	if (event->slot == end_slot) return 0;
	tag_history = event->parent;
    }
    return 0;
}

static void
onibi_dynamic_output_restore_active_captures(
    OnibiSemanticArena *arena, OnibiDynamicOutputState *output,
    uint32_t batch_reference, const OnibiSemanticCaptureFile *caller_captures,
    OnibiTagEventId caller_tag_history, OnibiExecCtx *ctx)
{
    if (output == NULL) return;
    if (output->slot_count != caller_captures->slot_count)
	rb_raise(eRegexpError,
		 "dynamic call output capture slots do not match");
    for (uint32_t capture = 0; capture * 2U + 1U < output->slot_count;
	 capture++) {
	onibi_exec_charge_work(ctx, 1);
	uint32_t begin_slot = capture * 2U;
	uint32_t end_slot = begin_slot + 1U;
	if (!onibi_semantic_capture_is_active(arena, caller_tag_history,
					      begin_slot, end_slot, ctx))
	    continue;
	if (end_slot > UINT16_MAX)
	    rb_raise(eRegexpError,
		     "dynamic call output capture slot is invalid");
	OnibiBytePos begin = onibi_semantic_position_read(
	    arena, caller_captures->root, begin_slot, -1);
	OnibiBytePos end = onibi_semantic_position_read(
	    arena, caller_captures->root, end_slot, -1);
	if (begin < 0 || end < -1)
	    rb_raise(eRegexpError,
		     "dynamic call output capture pair is invalid");
	onibi_dynamic_output_publish_slot(arena, output, batch_reference,
					  (uint16_t)begin_slot, begin, ctx);
	if (end >= 0)
	    onibi_dynamic_output_publish_slot(arena, output, batch_reference,
					      (uint16_t)end_slot, end, ctx);
    }
}

static OnibiTagEventId
onibi_semantic_tag_latest_for_slot(const OnibiSemanticArena *arena,
				   OnibiTagEventId tag_history, uint32_t slot)
{
    while (tag_history != UINT32_MAX) {
	const OnibiSemanticTagEvent *event = &arena->tags[tag_history];
	if (event->slot == slot) return tag_history;
	tag_history = event->parent;
    }
    return UINT32_MAX;
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
					     begin_slot, end_slot, NULL)) {
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
					     begin_slot, end_slot, NULL)) {
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
    OnibiTagEventId caller_tag_history,
    OnibiDynamicAbsenceCaptureWriteLog *capture_writes, OnibiExecCtx *ctx)
{
    for (uint32_t capture = 0;
	 capture * 2U + 1U < state->semantic_captures.slot_count; capture++) {
	uint32_t slot = capture * 2U;
	if (onibi_semantic_capture_is_active(arena, caller_tag_history, slot,
					     slot + 1U, NULL)) {
	    OnibiTagEventId source_id = onibi_semantic_tag_latest_for_slot(
		arena, caller_tag_history, slot);
	    if (source_id == UINT32_MAX)
		rb_raise(eRegexpError, "active capture has no start tag");
	    OnibiSemanticTagEvent source = arena->tags[source_id];
	    OnibiTagEventId restored_id =
		onibi_semantic_tag_clone(arena, state->tag_history, &source);
	    state->tag_history = restored_id;
	    onibi_dynamic_absence_capture_write_clone(
		capture_writes, arena, source_id, restored_id, ctx);
	}
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
    hash = onibi_semantic_hash_value(hash, (uint64_t)key->previous_position);
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
	   left->previous_position == right->previous_position &&
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
		       OnibiBytePos position, OnibiBytePos previous_position,
		       const OnibiSemanticState *semantic)
{
    if (arena->key_capacity == 0 ||
	arena->key_count >= arena->key_capacity - arena->key_capacity / 4U) {
	onibi_dynamic_key_set_grow(arena);
    }
    OnibiDynamicThreadKey key = {state_id, position, *semantic, 0};
    key.previous_position = previous_position;
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
    if (arena->cycle_count >= (size_t)ONIBI_DYNAMIC_FAILURE_FRAME_MARKER)
	rb_memerror();
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
	    node->key.previous_position == frame->previous_position &&
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
	if (arena->frames[i].cycle_root != ONIBI_DYNAMIC_FAILURE_FRAME_MARKER &&
	    !onibi_dynamic_cycle_redundant(arena, &arena->frames[i])) {
	    have_noncycle = 1;
	    break;
	}
    if (!have_noncycle) return;
    size_t write = base;
    for (size_t i = base; i < arena->frame_count; i++)
	if (arena->frames[i].cycle_root == ONIBI_DYNAMIC_FAILURE_FRAME_MARKER ||
	    !onibi_dynamic_cycle_redundant(arena, &arena->frames[i]))
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
    frame.output_mark = arena->active_output_state == NULL
			    ? 0
			    : arena->active_output_state->undo_count;
    arena->frames = onibi_semantic_arena_reserve(
	arena->frames, &arena->frame_capacity, arena->frame_count,
	sizeof(*arena->frames));
    arena->frames[arena->frame_count++] = frame;
}

static void
onibi_dynamic_output_queue_only(OnibiSemanticArena *arena,
				uint32_t output_batch, OnibiExecCtx *ctx)
{
    if (output_batch == 0) return;
    OnibiDynamicOutputBatch *batch =
	onibi_dynamic_output_batch_get(arena, output_batch);
    if (batch->count == 0) return;
    onibi_exec_charge_work(ctx, 1);
    onibi_dynamic_stack_push(
	arena, (OnibiDynamicFrame){
		   .state = 0,
		   .position = ctx != NULL ? ctx->current_position : 0,
		   .cycle_root = UINT32_MAX,
		   .previous_position =
		       ctx != NULL ? ctx->current_previous_position : 0,
		   .output_batch = output_batch,
		   .output_only = 1});
}

static void
onibi_dynamic_absence_endpoint_push(OnibiSemanticArena *arena,
				    OnibiBytePos position,
				    OnibiBytePos previous_position,
				    const OnibiSemanticState *semantic,
				    uint32_t output_batch)
{
    arena->absence_endpoints = onibi_semantic_arena_reserve(
	arena->absence_endpoints, &arena->absence_endpoint_capacity,
	arena->absence_endpoint_count, sizeof(*arena->absence_endpoints));
    arena->absence_endpoints[arena->absence_endpoint_count++] =
	(OnibiDynamicAbsenceEndpoint){position, previous_position, *semantic,
				      output_batch};
}

static void
onibi_dynamic_absence_endpoint_publish_body_captures(
    OnibiDynamicAbsenceEndpoint *endpoint,
    const OnibiSemanticState *body_result)
{
    endpoint->semantic.condition_captures = body_result->condition_captures;
    endpoint->semantic.tag_history = body_result->tag_history;
    endpoint->semantic.capture_event_history =
	body_result->capture_event_history;
    endpoint->semantic.capture_event_dependency =
	body_result->capture_event_dependency;
    endpoint->semantic.order = body_result->order;
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
    const OnibiSemanticState *predecessor, OnibiSemanticState *successor,
    OnibiDynamicAbsenceCaptureWriteLog *capture_writes,
    int capture_failure_owner);
static int onibi_dynamic_absence_consume(
    VALUE rseq, const OnibiRSeqView *view, VALUE str, OnibiBytePos position,
    OnibiBytePos previous_position, OnibiBytePos active_bound,
    OnibiBytePos search_origin, uint32_t subprogram_id,
    const OnibiSemanticState *input, OnibiSemanticArena *arena,
    unsigned char *class_stack, size_t class_stack_capacity, OnibiExecCtx *ctx,
    size_t *endpoint_base, size_t *endpoint_count,
    OnibiDynamicAbsenceCaptureWriteLog *parent_capture_writes,
    int parent_capture_failure_owner);
typedef enum {
    ONIBI_ABSENCE_CAPTURE_WRITE_NONE = 0,
    ONIBI_ABSENCE_CAPTURE_WRITE_ACTION = 1,
    ONIBI_ABSENCE_CAPTURE_WRITE_PUBLISHED = 2
} OnibiAbsenceCaptureWriteKind;
typedef struct {
    OnibiTagEventId tag_id;
    uint64_t logical_id;
    uint32_t source_state;
    uint32_t edge_index;
    uint32_t destination;
    uint32_t action_index;
    uint16_t slot;
    uint8_t flags;
    uint8_t kind;
    uint8_t valid;
    OnibiBytePos position;
} OnibiDynamicAbsenceCaptureWrite;
typedef struct {
    uint64_t logical_id;
    uint32_t action_index;
    uint16_t slot;
    uint8_t flags;
    uint8_t kind;
    OnibiBytePos position;
} OnibiDynamicAbsenceCaptureWriteIdentity;
typedef struct {
    uint32_t destination;
    uint32_t next;
} OnibiDynamicAbsenceRelationSuffix;
typedef struct {
    size_t path_begin;
    size_t path_count;
    uint32_t output_batch;
} OnibiDynamicAbsenceFailurePrefix;
struct OnibiDynamicAbsenceCaptureWriteLog {
    VALUE subject;
    unsigned char *class_stack;
    size_t class_stack_capacity;
    OnibiDynamicAbsenceCaptureWriteLog *registry_parent;
    unsigned char registry_parent_failure_owner;
    OnibiDynamicAbsenceCaptureWrite *events;
    size_t event_capacity;
    OnibiDynamicAbsenceCaptureWrite *journal;
    size_t journal_count;
    size_t journal_capacity;
    OnibiDynamicOutputWrite *output_journal;
    size_t output_journal_count;
    size_t output_journal_capacity;
    OnibiTagEventId *path;
    size_t path_capacity;
    size_t path_count;
    OnibiDynamicAbsenceCaptureWriteIdentity *previous_path;
    size_t previous_path_capacity;
    size_t previous_path_count;
    OnibiDynamicAbsenceCaptureWriteIdentity *failure_paths;
    size_t failure_path_capacity;
    size_t failure_path_count;
    OnibiDynamicAbsenceFailurePrefix *failure_prefixes;
    size_t failure_prefix_capacity;
    size_t failure_prefix_count;
    uint32_t capture_count;
    unsigned char *pending_failure_captures;
    uint64_t base_history_identity;
    uint32_t *relation_suffix_heads;
    OnibiDynamicAbsenceRelationSuffix *relation_suffixes;
    size_t relation_suffix_count;
    size_t relation_suffix_capacity;
    size_t relation_count;
    uint32_t owner_subprogram_id;
    unsigned char relation_suffix_ready;
};
typedef struct {
    VALUE rseq;
    const OnibiRSeqView *view;
    VALUE str;
    OnibiBytePos position;
    OnibiBytePos previous_position;
    OnibiBytePos active_bound;
    OnibiBytePos search_origin;
    uint32_t subprogram_id;
    const OnibiSemanticState *input;
    OnibiSemanticArena *arena;
    unsigned char *class_stack;
    size_t class_stack_capacity;
    OnibiExecCtx *ctx;
    size_t *endpoint_base;
    size_t *endpoint_count;
    OnibiDynamicOutputState *saved_output_state;
    OnibiDynamicOutputState *scan_output;
    uint32_t saved_output_batch;
    unsigned char *pushed_captures;
    OnibiDynamicAbsenceCaptureWriteLog capture_writes;
    int result;
} OnibiDynamicAbsenceCall;
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
					 uint32_t capture_slots,
					 int require_complete_pairs,
					 OnibiExecCtx *ctx);

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

typedef struct {
    OnibiSemanticArena *arena;
    OnibiSemanticState *state;
    unsigned char *clear;
    uint32_t slots;
    int clear_semantic;
    int owns_clear;
    OnibiTagEventId *events;
    OnibiDynamicAbsenceCaptureWriteLog *capture_writes;
    OnibiDynamicOutputState *output_state;
    const unsigned char *pushed_captures;
    OnibiExecCtx *ctx;
} OnibiDynamicAbsenceCaptureFilter;

static VALUE
onibi_dynamic_absence_filter_capture_slots_body(VALUE opaque)
{
    OnibiDynamicAbsenceCaptureFilter *filter =
	(OnibiDynamicAbsenceCaptureFilter *)(uintptr_t)opaque;
    OnibiSemanticArena *arena = filter->arena;
    OnibiSemanticState *state = filter->state;
    int any = 0;
    for (uint32_t slot = 0; slot < filter->slots; slot++) {
	onibi_exec_charge_work(filter->ctx, 1);
	if (filter->clear[slot]) any = 1;
    }
    onibi_dynamic_output_filter_transcript_captures(
	filter->output_state, filter->clear, filter->slots,
	filter->pushed_captures, filter->ctx);
    if (!any) return Qnil;

    size_t count = 0;
    for (OnibiTagEventId id = state->tag_history; id != UINT32_MAX;
	 id = arena->tags[id].parent) {
	if (id >= arena->tag_count || count >= arena->tag_count)
	    rb_raise(eRegexpError, "absence capture history is invalid");
	onibi_exec_charge_work(filter->ctx, 1);
	count++;
    }
    if (count > SIZE_MAX / sizeof(*filter->events)) rb_memerror();
    onibi_exec_charge_work(filter->ctx, count);
    if (count != 0)
	filter->events = ruby_xmalloc(count * sizeof(*filter->events));
    size_t index = 0;
    for (OnibiTagEventId id = state->tag_history; id != UINT32_MAX;
	 id = arena->tags[id].parent) {
	filter->events[index++] = id;
	onibi_exec_charge_work(filter->ctx, 1);
    }
    state->tag_history = UINT32_MAX;
    while (index != 0) {
	onibi_exec_charge_work(filter->ctx, 1);
	OnibiTagEventId source_id = filter->events[--index];
	OnibiSemanticTagEvent event = arena->tags[source_id];
	if (event.slot < filter->slots && filter->clear[event.slot]) continue;
	OnibiTagEventId cloned =
	    onibi_semantic_tag_clone(arena, state->tag_history, &event);
	state->tag_history = cloned;
	onibi_dynamic_absence_capture_write_clone(
	    filter->capture_writes, arena, source_id, cloned, filter->ctx);
    }

    for (uint32_t slot = 0; slot < filter->slots; slot++)
	if (filter->clear_semantic && filter->clear[slot])
	    onibi_semantic_capture_write(arena, &state->semantic_captures, slot,
					 -1);
    return Qnil;
}

static VALUE
onibi_dynamic_absence_filter_capture_slots_ensure(VALUE opaque)
{
    OnibiDynamicAbsenceCaptureFilter *filter =
	(OnibiDynamicAbsenceCaptureFilter *)(uintptr_t)opaque;
    ruby_xfree(filter->events);
    if (filter->owns_clear) ruby_xfree(filter->clear);
    filter->events = NULL;
    filter->clear = NULL;
    return Qnil;
}

static void
onibi_dynamic_absence_filter_capture_slots(
    OnibiSemanticArena *arena, OnibiSemanticState *state, unsigned char *clear,
    uint32_t slots, int clear_semantic, int owns_clear,
    OnibiDynamicAbsenceCaptureWriteLog *capture_writes, OnibiExecCtx *ctx,
    OnibiDynamicOutputState *output_state, const unsigned char *pushed_captures)
{
    OnibiDynamicAbsenceCaptureFilter filter = {
	arena,		state,		 clear, slots,
	clear_semantic, owns_clear,	 NULL,	capture_writes,
	output_state,	pushed_captures, ctx};
    rb_ensure(onibi_dynamic_absence_filter_capture_slots_body,
	      (VALUE)(uintptr_t)&filter,
	      onibi_dynamic_absence_filter_capture_slots_ensure,
	      (VALUE)(uintptr_t)&filter);
}

static int
onibi_dynamic_absence_has_active_nullable_repeat(
    const OnibiRSeqView *view, OnibiSemanticArena *arena,
    const OnibiSemanticState *state)
{
    for (uint32_t i = 0; i < view->header->action_count; i++) {
	const OnibiRAction *action = &view->actions[i];
	if (action->op != ONIBI_RA_NULL_ENTER ||
	    action->arg16 + 1U >= state->progress.slot_count)
	    continue;
	OnibiBytePos begin = onibi_semantic_position_read(
	    arena, state->progress.root, action->arg16, -1);
	OnibiBytePos status = onibi_semantic_position_read(
	    arena, state->progress.root, action->arg16 + 1U, -1);
	if (begin >= 0 && status >= 0) return 1;
    }
    return 0;
}

static void
onibi_dynamic_absence_filter_captures(
    OnibiSemanticArena *arena, OnibiSemanticState *accepted,
    const OnibiSemanticState *terminal, int nullable_repeat_active,
    OnibiDynamicAbsenceCaptureWriteLog *capture_writes,
    OnibiDynamicOutputState *output_state, const unsigned char *pushed_captures,
    OnibiExecCtx *ctx)
{
    uint32_t slots = accepted->semantic_captures.slot_count;
    unsigned char *clear = slots == 0 ? NULL : ruby_xcalloc(slots, 1);
    for (uint32_t capture = 0; capture * 2U + 1U < slots; capture++) {
	OnibiTagEventId open = onibi_dynamic_capture_open_id(
	    arena, accepted->tag_history, capture);
	OnibiTagEventId terminal_open = onibi_dynamic_capture_open_id(
	    arena, terminal->tag_history, capture);
	/* A live nullable owner identifies a capture by its event node. A
	 * forced replay can allocate different nodes for the same capture
	 * history. */
	int same_capture =
	    nullable_repeat_active
		? open == terminal_open
		: onibi_semantic_tag_history_equal(arena, open, terminal_open);
	if (open != UINT32_MAX &&
	    (terminal_open == UINT32_MAX || !same_capture))
	    clear[capture * 2U] = clear[capture * 2U + 1U] = 1;
    }
    onibi_dynamic_absence_filter_capture_slots(arena, accepted, clear, slots, 1,
					       1, capture_writes, ctx,
					       output_state, pushed_captures);
}

static void
onibi_dynamic_absence_restore_pushed_capture_files(
    OnibiSemanticArena *arena, OnibiSemanticState *state,
    const OnibiSemanticState *snapshot, const unsigned char *pushed_captures,
    uint32_t capture_count, int restore_semantic)
{
    if (pushed_captures == NULL) return;
    for (uint32_t capture = 0; capture < capture_count; capture++) {
	if (!pushed_captures[capture]) continue;
	uint32_t begin = capture * 2U;
	uint32_t end = begin + 1U;
	if (end >= state->condition_captures.slot_count ||
	    end >= snapshot->condition_captures.slot_count)
	    continue;
	OnibiBytePos condition_begin = onibi_semantic_position_read(
	    arena, snapshot->condition_captures.root, begin, -1);
	OnibiBytePos condition_end = onibi_semantic_position_read(
	    arena, snapshot->condition_captures.root, end, -1);
	onibi_semantic_condition_capture_write(
	    arena, &state->condition_captures, begin, condition_begin);
	onibi_semantic_condition_capture_write(
	    arena, &state->condition_captures, end, condition_end);
	if (restore_semantic && end < state->semantic_captures.slot_count &&
	    end < snapshot->semantic_captures.slot_count) {
	    OnibiBytePos semantic_begin = onibi_semantic_position_read(
		arena, snapshot->semantic_captures.root, begin, -1);
	    OnibiBytePos semantic_end = onibi_semantic_position_read(
		arena, snapshot->semantic_captures.root, end, -1);
	    onibi_semantic_capture_write(arena, &state->semantic_captures,
					 begin, semantic_begin);
	    onibi_semantic_capture_write(arena, &state->semantic_captures, end,
					 semantic_end);
	}
    }
}

typedef struct {
    OnibiSemanticArena *arena;
    OnibiSemanticState *state;
    const OnibiSemanticState *snapshot;
    const unsigned char *pushed_captures;
    OnibiDynamicAbsenceCaptureWriteLog *capture_writes;
    OnibiExecCtx *ctx;
    uint32_t capture_count;
    unsigned char *clear;
    unsigned char *seen;
    unsigned char *latest;
    OnibiBytePos *positions;
    OnibiTagEventId *ids;
} OnibiDynamicAbsenceTagRollback;

static VALUE
onibi_dynamic_absence_restore_pushed_tags_body(VALUE opaque)
{
    OnibiDynamicAbsenceTagRollback *rollback =
	(OnibiDynamicAbsenceTagRollback *)(uintptr_t)opaque;
    uint32_t slots = rollback->state->semantic_captures.slot_count;
    if (rollback->pushed_captures == NULL || slots == 0) return Qnil;
    if ((uint64_t)rollback->capture_count * 2U > slots ||
	(size_t)slots > SIZE_MAX / sizeof(*rollback->positions))
	rb_raise(eRegexpError, "absence capture slot range is invalid");

    rollback->clear = ruby_xcalloc(slots, 1);
    rollback->seen = ruby_xcalloc(slots, 1);
    rollback->latest = ruby_xcalloc(rollback->capture_count, 1);
    rollback->positions =
	ruby_xmalloc((size_t)slots * sizeof(*rollback->positions));
    rollback->ids = ruby_xmalloc((size_t)slots * sizeof(*rollback->ids));
    for (uint32_t capture = 0; capture < rollback->capture_count; capture++) {
	if (!rollback->pushed_captures[capture]) continue;
	rollback->clear[capture * 2U] = 1;
	rollback->clear[capture * 2U + 1U] = 1;
    }
    for (OnibiTagEventId id = rollback->snapshot->tag_history; id != UINT32_MAX;
	 id = rollback->arena->tags[id].parent) {
	const OnibiSemanticTagEvent *event = &rollback->arena->tags[id];
	uint32_t slot = event->slot;
	if (slot >= slots || slot / 2U >= rollback->capture_count ||
	    !rollback->pushed_captures[slot / 2U] || rollback->seen[slot])
	    continue;
	rollback->seen[slot] = 1;
	rollback->positions[slot] = event->position;
	rollback->ids[slot] = id;
	if (rollback->latest[slot / 2U] == 0)
	    rollback->latest[slot / 2U] = (slot & 1U) == 0 ? 1 : 2;
    }

    unsigned char *clear = rollback->clear;
    rollback->clear = NULL;
    onibi_dynamic_absence_filter_capture_slots(
	rollback->arena, rollback->state, clear, slots, 0, 1,
	rollback->capture_writes, rollback->ctx, NULL, NULL);

    for (uint32_t capture = 0; capture < rollback->capture_count; capture++) {
	if (!rollback->pushed_captures[capture]) continue;
	uint32_t begin = capture * 2U;
	uint32_t end = begin + 1U;
	if (rollback->latest[capture] == 1) {
	    if (rollback->seen[end]) {
		OnibiSemanticTagEvent event =
		    rollback->arena->tags[rollback->ids[end]];
		OnibiTagEventId restored = onibi_semantic_tag_clone(
		    rollback->arena, rollback->state->tag_history, &event);
		rollback->state->tag_history = restored;
		onibi_dynamic_absence_capture_write_clone(
		    rollback->capture_writes, rollback->arena,
		    rollback->ids[end], restored, rollback->ctx);
	    }
	    if (rollback->seen[begin]) {
		OnibiSemanticTagEvent event =
		    rollback->arena->tags[rollback->ids[begin]];
		OnibiTagEventId restored = onibi_semantic_tag_clone(
		    rollback->arena, rollback->state->tag_history, &event);
		rollback->state->tag_history = restored;
		onibi_dynamic_absence_capture_write_clone(
		    rollback->capture_writes, rollback->arena,
		    rollback->ids[begin], restored, rollback->ctx);
	    }
	}
	else {
	    if (rollback->seen[begin]) {
		OnibiSemanticTagEvent event =
		    rollback->arena->tags[rollback->ids[begin]];
		OnibiTagEventId restored = onibi_semantic_tag_clone(
		    rollback->arena, rollback->state->tag_history, &event);
		rollback->state->tag_history = restored;
		onibi_dynamic_absence_capture_write_clone(
		    rollback->capture_writes, rollback->arena,
		    rollback->ids[begin], restored, rollback->ctx);
	    }
	    if (rollback->seen[end]) {
		OnibiSemanticTagEvent event =
		    rollback->arena->tags[rollback->ids[end]];
		OnibiTagEventId restored = onibi_semantic_tag_clone(
		    rollback->arena, rollback->state->tag_history, &event);
		rollback->state->tag_history = restored;
		onibi_dynamic_absence_capture_write_clone(
		    rollback->capture_writes, rollback->arena,
		    rollback->ids[end], restored, rollback->ctx);
	    }
	}
    }
    return Qnil;
}

static VALUE
onibi_dynamic_absence_restore_pushed_tags_ensure(VALUE opaque)
{
    OnibiDynamicAbsenceTagRollback *rollback =
	(OnibiDynamicAbsenceTagRollback *)(uintptr_t)opaque;
    ruby_xfree(rollback->clear);
    ruby_xfree(rollback->seen);
    ruby_xfree(rollback->latest);
    ruby_xfree(rollback->positions);
    ruby_xfree(rollback->ids);
    return Qnil;
}

static void
onibi_dynamic_absence_restore_pushed_tags(
    OnibiSemanticArena *arena, OnibiSemanticState *state,
    const OnibiSemanticState *snapshot, const unsigned char *pushed_captures,
    uint32_t capture_count, OnibiDynamicAbsenceCaptureWriteLog *capture_writes,
    OnibiExecCtx *ctx)
{
    OnibiDynamicAbsenceTagRollback rollback = {
	arena,		state, snapshot,      pushed_captures,
	capture_writes, ctx,   capture_count, NULL,
	NULL,		NULL,  NULL,	      NULL};
    rb_ensure(onibi_dynamic_absence_restore_pushed_tags_body,
	      (VALUE)(uintptr_t)&rollback,
	      onibi_dynamic_absence_restore_pushed_tags_ensure,
	      (VALUE)(uintptr_t)&rollback);
}

typedef struct {
    OnibiSemanticArena *arena;
    OnibiSemanticState *state;
    uint32_t snapshot_history;
    const unsigned char *pushed_captures;
    uint32_t capture_count;
    uint32_t *events;
} OnibiDynamicAbsenceCaptureEventFilter;

static VALUE
onibi_dynamic_absence_filter_capture_events_body(VALUE opaque)
{
    OnibiDynamicAbsenceCaptureEventFilter *filter =
	(OnibiDynamicAbsenceCaptureEventFilter *)(uintptr_t)opaque;
    OnibiSemanticArena *arena = filter->arena;
    if (filter->pushed_captures == NULL) return Qnil;

    size_t body_count = 0;
    uint32_t id = filter->state->capture_event_history;
    while (id != UINT32_MAX) {
	if (id >= arena->capture_event_count)
	    rb_raise(eRegexpError, "absence capture event history is invalid");
	body_count++;
	id = arena->capture_events[id].parent;
    }
    size_t snapshot_count = 0;
    for (id = filter->snapshot_history; id != UINT32_MAX;
	 id = arena->capture_events[id].parent) {
	if (id >= arena->capture_event_count)
	    rb_raise(eRegexpError, "absence capture event snapshot is invalid");
	snapshot_count++;
    }
    if (body_count > SIZE_MAX - snapshot_count ||
	body_count + snapshot_count > SIZE_MAX / sizeof(*filter->events))
	rb_memerror();
    size_t total = body_count + snapshot_count;
    if (total == 0) return Qnil;
    filter->events = ruby_xmalloc(total * sizeof(*filter->events));
    id = filter->state->capture_event_history;
    for (size_t i = 0; i < body_count; i++) {
	filter->events[i] = id;
	id = arena->capture_events[id].parent;
    }
    id = filter->snapshot_history;
    for (size_t i = 0; i < snapshot_count; i++) {
	filter->events[body_count + i] = id;
	id = arena->capture_events[id].parent;
    }

    filter->state->capture_event_history = UINT32_MAX;
    for (size_t i = body_count; i > 0; i--) {
	const OnibiUnscopedCaptureEvent event =
	    arena->capture_events[filter->events[i - 1U]];
	if (event.slot / 2U < filter->capture_count &&
	    filter->pushed_captures[event.slot / 2U])
	    continue;
	filter->state->capture_event_history =
	    onibi_semantic_capture_event_append(
		arena, filter->state->capture_event_history, event.order,
		event.slot, event.position);
    }
    for (size_t i = body_count + snapshot_count; i > body_count; i--) {
	const OnibiUnscopedCaptureEvent event =
	    arena->capture_events[filter->events[i - 1U]];
	if (event.slot / 2U >= filter->capture_count ||
	    !filter->pushed_captures[event.slot / 2U])
	    continue;
	filter->state->capture_event_history =
	    onibi_semantic_capture_event_append(
		arena, filter->state->capture_event_history, event.order,
		event.slot, event.position);
    }
    return Qnil;
}

static VALUE
onibi_dynamic_absence_filter_capture_events_ensure(VALUE opaque)
{
    OnibiDynamicAbsenceCaptureEventFilter *filter =
	(OnibiDynamicAbsenceCaptureEventFilter *)(uintptr_t)opaque;
    ruby_xfree(filter->events);
    filter->events = NULL;
    return Qnil;
}

static void
onibi_dynamic_absence_filter_capture_events(
    OnibiSemanticArena *arena, OnibiSemanticState *state,
    uint32_t snapshot_history, const unsigned char *pushed_captures,
    uint32_t capture_count)
{
    OnibiDynamicAbsenceCaptureEventFilter filter = {
	arena, state, snapshot_history, pushed_captures, capture_count, NULL};
    rb_ensure(onibi_dynamic_absence_filter_capture_events_body,
	      (VALUE)(uintptr_t)&filter,
	      onibi_dynamic_absence_filter_capture_events_ensure,
	      (VALUE)(uintptr_t)&filter);
}

static void
onibi_dynamic_absence_capture_write_event_store(
    OnibiDynamicAbsenceCaptureWriteLog *log, OnibiSemanticArena *arena,
    const OnibiDynamicAbsenceCaptureWrite *event, OnibiExecCtx *ctx)
{
    if (log == NULL) return;
    if (event->tag_id >= arena->tag_count || !event->valid ||
	arena->tags[event->tag_id].logical_id != event->logical_id ||
	arena->tags[event->tag_id].slot != event->slot ||
	arena->tags[event->tag_id].position != event->position)
	rb_raise(eRegexpError, "absence capture write provenance is invalid");
    size_t id = (size_t)event->tag_id;
    if (id >= log->event_capacity) {
	size_t capacity = log->event_capacity == 0 ? 16U : log->event_capacity;
	while (capacity <= id) {
	    if (capacity > SIZE_MAX / 2U) rb_memerror();
	    capacity *= 2U;
	}
	if (capacity > SIZE_MAX / sizeof(*log->events)) rb_memerror();
	onibi_exec_charge_work(ctx, capacity - log->event_capacity);
	size_t added = capacity - log->event_capacity;
	log->events =
	    ruby_xrealloc(log->events, capacity * sizeof(*log->events));
	memset(log->events + log->event_capacity, 0,
	       added * sizeof(*log->events));
	log->event_capacity = capacity;
    }
    onibi_exec_charge_work(ctx, 1);
    log->events[id] = *event;
}

static const OnibiDynamicAbsenceCaptureWrite *
onibi_dynamic_absence_capture_write_event_find(
    const OnibiDynamicAbsenceCaptureWriteLog *log,
    const OnibiSemanticArena *arena, OnibiTagEventId tag_id,
    uint64_t logical_id, OnibiExecCtx *ctx)
{
    for (const OnibiDynamicAbsenceCaptureWriteLog *owner = log; owner != NULL;
	 owner = owner->registry_parent) {
	onibi_exec_charge_work(ctx, 1);
	if ((size_t)tag_id < owner->event_capacity) {
	    const OnibiDynamicAbsenceCaptureWrite *event =
		&owner->events[tag_id];
	    if (event->valid && event->tag_id == tag_id &&
		event->logical_id == logical_id && tag_id < arena->tag_count &&
		arena->tags[tag_id].logical_id == logical_id)
		return event;
	}
    }
    return NULL;
}

static int
onibi_dynamic_absence_capture_write_identity_equal(
    const OnibiDynamicAbsenceCaptureWriteIdentity *identity,
    const OnibiDynamicAbsenceCaptureWrite *event)
{
    if (identity->kind != event->kind || identity->slot != event->slot ||
	identity->flags != event->flags ||
	identity->position != event->position)
	return 0;
    if (event->kind == ONIBI_ABSENCE_CAPTURE_WRITE_ACTION)
	return identity->action_index == event->action_index;
    return identity->logical_id == event->logical_id;
}

static int
onibi_dynamic_absence_capture_write_identity_equal_identity(
    const OnibiDynamicAbsenceCaptureWriteIdentity *left,
    const OnibiDynamicAbsenceCaptureWriteIdentity *right)
{
    if (left->kind != right->kind || left->slot != right->slot ||
	left->flags != right->flags || left->position != right->position)
	return 0;
    if (left->kind == ONIBI_ABSENCE_CAPTURE_WRITE_ACTION)
	return left->action_index == right->action_index;
    return left->logical_id == right->logical_id;
}

static void
onibi_dynamic_absence_capture_write_clone(
    OnibiDynamicAbsenceCaptureWriteLog *log, OnibiSemanticArena *arena,
    OnibiTagEventId source, OnibiTagEventId destination, OnibiExecCtx *ctx)
{
    if (log == NULL) return;
    if (source >= arena->tag_count || destination >= arena->tag_count)
	rb_raise(eRegexpError, "absence capture clone is invalid");
    const OnibiSemanticTagEvent *source_tag = &arena->tags[source];
    const OnibiSemanticTagEvent *destination_tag = &arena->tags[destination];
    const OnibiDynamicAbsenceCaptureWrite *source_event =
	onibi_dynamic_absence_capture_write_event_find(
	    log, arena, source, source_tag->logical_id, ctx);
    if (source_event == NULL) return;
    OnibiDynamicAbsenceCaptureWrite clone = *source_event;
    clone.tag_id = destination;
    clone.logical_id = destination_tag->logical_id;
    clone.slot = destination_tag->slot;
    clone.position = destination_tag->position;
    clone.valid = 1;
    onibi_dynamic_absence_capture_write_event_store(log, arena, &clone, ctx);
}

static void
onibi_dynamic_absence_capture_write_publish(
    OnibiDynamicAbsenceCaptureWriteLog *log, OnibiSemanticArena *arena,
    OnibiTagEventId tag_id, uint16_t slot, OnibiBytePos position,
    OnibiExecCtx *ctx)
{
    if (log == NULL) return;
    if (tag_id >= arena->tag_count || arena->tags[tag_id].slot != slot ||
	arena->tags[tag_id].position != position)
	rb_raise(eRegexpError, "absence capture publication is invalid");
    OnibiDynamicAbsenceCaptureWrite event = {
	.tag_id = tag_id,
	.logical_id = arena->tags[tag_id].logical_id,
	.source_state = UINT32_MAX,
	.edge_index = UINT32_MAX,
	.destination = UINT32_MAX,
	.action_index = UINT32_MAX,
	.slot = slot,
	.flags = 0,
	.kind = ONIBI_ABSENCE_CAPTURE_WRITE_PUBLISHED,
	.valid = 1,
	.position = position};
    onibi_dynamic_absence_capture_write_event_store(log, arena, &event, ctx);
}

static void
onibi_dynamic_absence_capture_write_journal_reserve(
    OnibiDynamicAbsenceCaptureWriteLog *log, size_t required, OnibiExecCtx *ctx)
{
    if (required <= log->journal_capacity) return;
    size_t capacity = log->journal_capacity == 0 ? 16U : log->journal_capacity;
    while (capacity < required) {
	if (capacity > SIZE_MAX / 2U) rb_memerror();
	capacity *= 2U;
    }
    if (capacity > SIZE_MAX / sizeof(*log->journal)) rb_memerror();
    onibi_exec_charge_work(ctx, capacity - log->journal_capacity);
    log->journal =
	ruby_xrealloc(log->journal, capacity * sizeof(*log->journal));
    log->journal_capacity = capacity;
}

static void
onibi_dynamic_absence_capture_write_log_reset(
    OnibiDynamicAbsenceCaptureWriteLog *log, OnibiExecCtx *ctx)
{
    (void)ctx;
    log->path_count = 0;
    log->output_journal_count = 0;
    log->previous_path_count = 0;
    log->failure_path_count = 0;
    log->failure_prefix_count = 0;
}

static int
onibi_dynamic_absence_capture_write_path(
    OnibiSemanticArena *arena, OnibiDynamicAbsenceCaptureWriteLog *log,
    const OnibiSemanticState *failed, OnibiExecCtx *ctx)
{
    size_t count = 0;
    size_t traversed = 0;
    int found_base = log->base_history_identity == 0;
    for (OnibiTagEventId id = failed->tag_history; id != UINT32_MAX;
	 id = arena->tags[id].parent) {
	if (id >= arena->tag_count || traversed >= arena->tag_count)
	    rb_raise(eRegexpError, "absence capture history is invalid");
	onibi_exec_charge_work(ctx, 1);
	traversed++;
	if (log->base_history_identity != 0 &&
	    arena->tags[id].logical_id == log->base_history_identity) {
	    found_base = 1;
	    break;
	}
	if (count == log->path_capacity) {
	    size_t capacity =
		log->path_capacity == 0 ? 16U : log->path_capacity;
	    if (capacity > SIZE_MAX / 2U ||
		capacity * 2U > SIZE_MAX / sizeof(*log->path))
		rb_memerror();
	    capacity *= 2U;
	    onibi_exec_charge_work(ctx, capacity - log->path_capacity);
	    log->path = ruby_xrealloc(log->path, capacity * sizeof(*log->path));
	    log->path_capacity = capacity;
	}
	log->path[count++] = id;
    }
    if (!found_base)
	rb_raise(eRegexpError, "absence capture base is missing from history");

    size_t common = 0;
    while (common < log->previous_path_count && common < count) {
	onibi_exec_charge_work(ctx, 1);
	OnibiTagEventId current_id = log->path[count - common - 1U];
	const OnibiDynamicAbsenceCaptureWrite *event =
	    onibi_dynamic_absence_capture_write_event_find(
		log, arena, current_id, arena->tags[current_id].logical_id,
		ctx);
	if (event == NULL)
	    rb_raise(eRegexpError,
		     "absence capture write provenance is missing");
	if (!onibi_dynamic_absence_capture_write_identity_equal(
		log->previous_path + common, event))
	    break;
	common++;
    }
    for (size_t i = count - common; i > 0; i--) {
	OnibiTagEventId id = log->path[i - 1U];
	uint64_t logical_id = arena->tags[id].logical_id;
	const OnibiDynamicAbsenceCaptureWrite *event =
	    onibi_dynamic_absence_capture_write_event_find(log, arena, id,
							   logical_id, ctx);
	if (event == NULL)
	    rb_raise(eRegexpError,
		     "absence capture write provenance is missing");
	if (log->journal_count == SIZE_MAX) rb_memerror();
	onibi_dynamic_absence_capture_write_journal_reserve(
	    log, log->journal_count + 1U, ctx);
	onibi_exec_charge_work(ctx, 1);
	log->journal[log->journal_count++] = *event;
    }
    if (count > log->previous_path_capacity) {
	if (count > SIZE_MAX / sizeof(*log->previous_path)) rb_memerror();
	onibi_exec_charge_work(ctx, count - log->previous_path_capacity);
	log->previous_path = ruby_xrealloc(log->previous_path,
					   count * sizeof(*log->previous_path));
	log->previous_path_capacity = count;
    }
    for (size_t i = 0; i < count; i++) {
	onibi_exec_charge_work(ctx, 1);
	OnibiTagEventId id = log->path[count - i - 1U];
	const OnibiDynamicAbsenceCaptureWrite *event =
	    onibi_dynamic_absence_capture_write_event_find(
		log, arena, id, arena->tags[id].logical_id, ctx);
	if (event == NULL)
	    rb_raise(eRegexpError,
		     "absence capture write provenance is missing");
	log->previous_path[i] = (OnibiDynamicAbsenceCaptureWriteIdentity){
	    event->logical_id, event->action_index, event->slot,
	    event->flags,      event->kind,	    event->position};
    }
    log->previous_path_count = count;
    return 1;
}

static uint32_t
onibi_dynamic_absence_capture_failure_prefix_capture(
    OnibiSemanticArena *arena, OnibiDynamicAbsenceCaptureWriteLog *log,
    const OnibiSemanticState *state, OnibiExecCtx *ctx)
{
    size_t count = 0, traversed = 0;
    int found_base = log->base_history_identity == 0;
    for (OnibiTagEventId id = state->tag_history; id != UINT32_MAX;
	 id = arena->tags[id].parent) {
	if (id >= arena->tag_count || traversed++ >= arena->tag_count)
	    rb_raise(eRegexpError, "absence failure history is invalid");
	onibi_exec_charge_work(ctx, 1);
	if (log->base_history_identity != 0 &&
	    arena->tags[id].logical_id == log->base_history_identity) {
	    found_base = 1;
	    break;
	}
	if (count == log->path_capacity) {
	    size_t capacity =
		log->path_capacity == 0 ? 16U : log->path_capacity;
	    if (capacity > SIZE_MAX / 2U ||
		capacity * 2U > SIZE_MAX / sizeof(*log->path))
		rb_memerror();
	    capacity *= 2U;
	    onibi_exec_charge_work(ctx, capacity - log->path_capacity);
	    log->path = ruby_xrealloc(log->path, capacity * sizeof(*log->path));
	    log->path_capacity = capacity;
	}
	log->path[count++] = id;
    }
    if (!found_base) rb_raise(eRegexpError, "absence failure base is missing");
    if (count == 0) return UINT32_MAX;
    if (log->failure_prefix_count >= UINT32_MAX ||
	log->failure_prefix_count == SIZE_MAX)
	rb_memerror();
    if (log->failure_prefix_count == log->failure_prefix_capacity) {
	size_t capacity = log->failure_prefix_capacity == 0
			      ? 8U
			      : log->failure_prefix_capacity;
	while (capacity <= log->failure_prefix_count) {
	    if (capacity > SIZE_MAX / 2U) rb_memerror();
	    capacity *= 2U;
	}
	if (capacity > SIZE_MAX / sizeof(*log->failure_prefixes)) rb_memerror();
	onibi_exec_charge_work(ctx, capacity - log->failure_prefix_capacity);
	log->failure_prefixes = ruby_xrealloc(
	    log->failure_prefixes, capacity * sizeof(*log->failure_prefixes));
	log->failure_prefix_capacity = capacity;
    }
    if (count > SIZE_MAX - log->failure_path_count) rb_memerror();
    size_t required = log->failure_path_count + count;
    if (required > log->failure_path_capacity) {
	size_t capacity =
	    log->failure_path_capacity == 0 ? 16U : log->failure_path_capacity;
	while (capacity < required) {
	    if (capacity > SIZE_MAX / 2U) rb_memerror();
	    capacity *= 2U;
	}
	if (capacity > SIZE_MAX / sizeof(*log->failure_paths)) rb_memerror();
	onibi_exec_charge_work(ctx, capacity - log->failure_path_capacity);
	log->failure_paths = ruby_xrealloc(
	    log->failure_paths, capacity * sizeof(*log->failure_paths));
	log->failure_path_capacity = capacity;
    }
    size_t prefix_id = log->failure_prefix_count;
    size_t path_begin = log->failure_path_count;
    for (size_t i = count; i > 0; i--) {
	OnibiTagEventId id = log->path[i - 1U];
	const OnibiSemanticTagEvent *tag = &arena->tags[id];
	const OnibiDynamicAbsenceCaptureWrite *event =
	    onibi_dynamic_absence_capture_write_event_find(
		log, arena, id, tag->logical_id, ctx);
	if (event == NULL)
	    rb_raise(eRegexpError, "absence failure provenance is missing");
	onibi_exec_charge_work(ctx, 1);
	log->failure_paths[log->failure_path_count++] =
	    (OnibiDynamicAbsenceCaptureWriteIdentity){
		event->logical_id, event->action_index, event->slot,
		event->flags,	   event->kind,		event->position};
    }
    log->failure_prefixes[prefix_id] =
	(OnibiDynamicAbsenceFailurePrefix){path_begin, count};
    log->failure_prefix_count++;
    return (uint32_t)prefix_id;
}

static void
onibi_dynamic_absence_output_journal_append_batch(
    OnibiDynamicAbsenceCaptureWriteLog *log, OnibiSemanticArena *arena,
    uint32_t reference, OnibiExecCtx *ctx)
{
    if (reference == 0) return;
    OnibiDynamicOutputBatch *batch =
	onibi_dynamic_output_batch_get(arena, reference);
    if (batch->count > SIZE_MAX - log->output_journal_count) rb_memerror();
    size_t required = log->output_journal_count + batch->count;
    if (required > log->output_journal_capacity) {
	size_t capacity = log->output_journal_capacity == 0
			      ? 16U
			      : log->output_journal_capacity;
	while (capacity < required) {
	    if (capacity > SIZE_MAX / 2U) rb_memerror();
	    capacity *= 2U;
	}
	if (capacity > SIZE_MAX / sizeof(*log->output_journal)) rb_memerror();
	onibi_exec_charge_work(ctx, capacity - log->output_journal_capacity);
	log->output_journal = ruby_xrealloc(
	    log->output_journal, capacity * sizeof(*log->output_journal));
	log->output_journal_capacity = capacity;
    }
    for (size_t i = 0; i < batch->count; i++) {
	onibi_exec_charge_work(ctx, 1);
	log->output_journal[log->output_journal_count++] = batch->writes[i];
    }
}

static void
onibi_dynamic_absence_output_journal_append_to_batch(
    OnibiDynamicAbsenceCaptureWriteLog *log, OnibiSemanticArena *arena,
    uint32_t output_batch, OnibiExecCtx *ctx)
{
    if (output_batch == 0) return;
    for (size_t i = 0; i < log->output_journal_count; i++)
	onibi_dynamic_output_batch_append(arena, output_batch,
					  log->output_journal[i], ctx);
}

static void
onibi_dynamic_absence_output_journal_replay(
    OnibiDynamicAbsenceCaptureWriteLog *log, OnibiDynamicOutputState *state,
    OnibiExecCtx *ctx)
{
    if (state == NULL) return;
    for (size_t i = 0; i < log->output_journal_count; i++) {
	onibi_dynamic_output_apply_write(state, log->output_journal[i], ctx);
	onibi_exec_charge_work(ctx, 1);
    }
}

static void
onibi_dynamic_absence_capture_failure_prefix_publish(
    OnibiSemanticArena *arena, OnibiDynamicAbsenceCaptureWriteLog *log,
    uint32_t prefix_id, OnibiExecCtx *ctx)
{
    if (prefix_id >= log->failure_prefix_count)
	rb_raise(eRegexpError, "absence failure prefix is invalid");
    OnibiDynamicAbsenceFailurePrefix prefix = log->failure_prefixes[prefix_id];
    if (prefix.path_begin > log->failure_path_count ||
	prefix.path_count > log->failure_path_count - prefix.path_begin)
	rb_raise(eRegexpError, "absence failure path is invalid");
    onibi_dynamic_absence_output_journal_append_batch(log, arena,
						      prefix.output_batch, ctx);
    const OnibiDynamicAbsenceCaptureWriteIdentity *path =
	log->failure_paths + prefix.path_begin;
    size_t common = 0;
    while (common < log->previous_path_count && common < prefix.path_count) {
	onibi_exec_charge_work(ctx, 1);
	if (!onibi_dynamic_absence_capture_write_identity_equal_identity(
		log->previous_path + common, path + common))
	    break;
	common++;
    }
    for (size_t i = common; i < prefix.path_count; i++) {
	const OnibiDynamicAbsenceCaptureWriteIdentity *identity = &path[i];
	if (log->journal_count == SIZE_MAX) rb_memerror();
	onibi_dynamic_absence_capture_write_journal_reserve(
	    log, log->journal_count + 1U, ctx);
	onibi_exec_charge_work(ctx, 1);
	log->journal[log->journal_count++] = (OnibiDynamicAbsenceCaptureWrite){
	    .tag_id = UINT32_MAX,
	    .logical_id = identity->logical_id,
	    .source_state = UINT32_MAX,
	    .edge_index = UINT32_MAX,
	    .destination = UINT32_MAX,
	    .action_index = identity->action_index,
	    .slot = identity->slot,
	    .flags = identity->flags,
	    .kind = identity->kind,
	    .valid = 1,
	    .position = identity->position};
    }
    for (size_t i = 0; i < prefix.path_count; i++) {
	uint32_t capture = path[i].slot / 2U;
	if (capture >= log->capture_count ||
	    log->pending_failure_captures == NULL)
	    rb_raise(eRegexpError, "absence failure capture slot is invalid");
	onibi_exec_charge_work(ctx, 1);
	log->pending_failure_captures[capture] = 1;
    }
    if (prefix.path_count > log->previous_path_capacity) {
	if (prefix.path_count > SIZE_MAX / sizeof(*log->previous_path))
	    rb_memerror();
	onibi_exec_charge_work(ctx,
			       prefix.path_count - log->previous_path_capacity);
	log->previous_path =
	    ruby_xrealloc(log->previous_path,
			  prefix.path_count * sizeof(*log->previous_path));
	log->previous_path_capacity = prefix.path_count;
    }
    for (size_t i = 0; i < prefix.path_count; i++) {
	onibi_exec_charge_work(ctx, 1);
	log->previous_path[i] = path[i];
    }
    log->previous_path_count = prefix.path_count;
}

static void
onibi_dynamic_absence_capture_failure_prefix_merge_pending(
    OnibiSemanticArena *arena, OnibiDynamicAbsenceCaptureWriteLog *log,
    const OnibiSemanticState *previous, OnibiSemanticState *current,
    const unsigned char *pushed_captures, OnibiExecCtx *ctx)
{
    uint32_t slots = current->condition_captures.slot_count;
    if (previous->condition_captures.slot_count != slots ||
	(uint64_t)log->capture_count * 2U > slots)
	rb_raise(eRegexpError, "absence pending capture state is invalid");
    for (uint32_t capture = 0; capture < log->capture_count; capture++) {
	onibi_exec_charge_work(ctx, 1);
	int pending = log->pending_failure_captures[capture] != 0;
	if (!pending) continue;
	log->pending_failure_captures[capture] = 0;
	if (pushed_captures != NULL && pushed_captures[capture]) continue;
	uint32_t begin_slot = capture * 2U;
	uint32_t end_slot = begin_slot + 1U;
	OnibiBytePos current_begin = onibi_semantic_position_read(
	    arena, current->condition_captures.root, begin_slot, -1);
	OnibiBytePos current_end = onibi_semantic_position_read(
	    arena, current->condition_captures.root, end_slot, -1);
	if (current_begin >= 0 || current_end >= 0) continue;
	if (arena->active_output_state != NULL) {
	    OnibiDynamicOutputState *output = arena->active_output_state;
	    if (end_slot >= output->slot_count)
		rb_raise(eRegexpError,
			 "absence pending output slot is invalid");
	    if (output->slots[begin_slot] >= 0 || output->slots[end_slot] >= 0)
		continue;
	}
	OnibiBytePos previous_begin = onibi_semantic_position_read(
	    arena, previous->condition_captures.root, begin_slot, -1);
	OnibiBytePos previous_end = onibi_semantic_position_read(
	    arena, previous->condition_captures.root, end_slot, -1);
	if (previous_begin < 0 || previous_end < previous_begin) continue;
	onibi_dynamic_output_publish_slot(
	    arena, arena->active_output_state, arena->active_output_batch,
	    (uint16_t)begin_slot, previous_begin, ctx);
	onibi_dynamic_output_publish_slot(
	    arena, arena->active_output_state, arena->active_output_batch,
	    (uint16_t)end_slot, previous_end, ctx);
	onibi_exec_charge_work(ctx, 1);
	current->tag_history = onibi_semantic_tag_append(
	    arena, current->tag_history, begin_slot, previous_begin);
	onibi_dynamic_absence_capture_write_publish(
	    log, arena, current->tag_history, (uint16_t)begin_slot,
	    previous_begin, ctx);
	onibi_exec_charge_work(ctx, 1);
	current->tag_history = onibi_semantic_tag_append(
	    arena, current->tag_history, end_slot, previous_end);
	onibi_dynamic_absence_capture_write_publish(
	    log, arena, current->tag_history, (uint16_t)end_slot, previous_end,
	    ctx);
	onibi_semantic_condition_capture_write(
	    arena, &current->condition_captures, begin_slot, previous_begin);
	onibi_semantic_condition_capture_write(
	    arena, &current->condition_captures, end_slot, previous_end);
    }
}

static void
onibi_dynamic_absence_capture_failure_prefix_queue(
    OnibiSemanticArena *arena, OnibiDynamicAbsenceCaptureWriteLog *log,
    const OnibiSemanticState *state, OnibiBytePos position,
    OnibiBytePos previous_position, const OnibiDynamicOutputState *output_state,
    OnibiExecCtx *ctx)
{
    uint32_t prefix_id = onibi_dynamic_absence_capture_failure_prefix_capture(
	arena, log, state, ctx);
    if (prefix_id == UINT32_MAX) return;
    uint32_t output_batch =
	output_state != NULL && output_state->transcript_count != 0
	    ? onibi_dynamic_output_batch_from_state(arena, output_state, ctx)
	    : 0;
    log->failure_prefixes[prefix_id].output_batch = output_batch;
    OnibiDynamicFrame continuation = {0};
    continuation.state = prefix_id;
    continuation.position = position;
    continuation.cycle_root = ONIBI_DYNAMIC_FAILURE_FRAME_MARKER;
    continuation.previous_position = previous_position;
    continuation.output_batch = output_batch;
    onibi_dynamic_stack_push(arena, continuation);
}

static void
onibi_dynamic_absence_capture_write_relation_suffixes_prepare(
    const OnibiRSeqView *view, OnibiDynamicAbsenceCaptureWriteLog *log,
    OnibiExecCtx *ctx)
{
    if (log->relation_suffix_ready) return;
    size_t count = view->header->absence_capture_relation_count;
    if (count > SIZE_MAX / sizeof(*log->relation_suffix_heads)) rb_memerror();
    log->relation_count = count;
    if (count != 0) {
	onibi_exec_charge_work(ctx, count);
	log->relation_suffix_heads =
	    ruby_xmalloc(count * sizeof(*log->relation_suffix_heads));
	for (size_t i = 0; i < count; i++) {
	    onibi_exec_charge_work(ctx, 1);
	    log->relation_suffix_heads[i] = UINT32_MAX;
	}
    }
    for (uint32_t edge_index = 0; edge_index < view->header->edge_count;
	 edge_index++) {
	const OnibiREdge *edge = &view->edges[edge_index];
	onibi_exec_charge_work(ctx, 1);
	if (edge->action_offset == 0) continue;
	if (edge->action_offset % sizeof(OnibiRAction) != 0)
	    rb_raise(eRegexpError, "absence relation action offset is invalid");
	uint32_t action_index =
	    edge->action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
	for (; action_index < view->header->action_count; action_index++) {
	    const OnibiRAction *action = &view->actions[action_index];
	    onibi_exec_charge_work(ctx, 1);
	    if (action->op == ONIBI_RA_END) break;
	    if (action->op != ONIBI_RA_CAPTURE_RELATION ||
		action->flags != ONIBI_CAPTURE_RELATION_ROLE_SUFFIX)
		continue;
	    if (action->arg32 == 0 || action->arg32 > count ||
		edge->destination >= view->header->state_count)
		rb_raise(eRegexpError, "absence suffix relation is invalid");
	    size_t relation_index = action->arg32 - 1U;
	    const OnibiAbsenceCaptureRelation *relation =
		&view->absence_capture_relations[relation_index];
	    if (relation->target_close_slot != action->arg16)
		rb_raise(eRegexpError,
			 "absence suffix relation slot is invalid");
	    if (log->relation_suffix_count == SIZE_MAX ||
		log->relation_suffix_count >= UINT32_MAX)
		rb_memerror();
	    size_t required = log->relation_suffix_count + 1U;
	    if (required > log->relation_suffix_capacity) {
		size_t capacity = log->relation_suffix_capacity == 0
				      ? 16U
				      : log->relation_suffix_capacity;
		while (capacity < required) {
		    if (capacity > SIZE_MAX / 2U) rb_memerror();
		    capacity *= 2U;
		}
		if (capacity > SIZE_MAX / sizeof(*log->relation_suffixes) ||
		    capacity > UINT32_MAX)
		    rb_memerror();
		onibi_exec_charge_work(ctx, capacity -
						log->relation_suffix_capacity);
		log->relation_suffixes =
		    ruby_xrealloc(log->relation_suffixes,
				  capacity * sizeof(*log->relation_suffixes));
		log->relation_suffix_capacity = capacity;
	    }
	    uint32_t suffix_index = (uint32_t)log->relation_suffix_count++;
	    log->relation_suffixes[suffix_index].destination =
		edge->destination;
	    log->relation_suffixes[suffix_index].next =
		log->relation_suffix_heads[relation_index];
	    log->relation_suffix_heads[relation_index] = suffix_index;
	}
    }
    for (size_t i = 0; i < count; i++) {
	onibi_exec_charge_work(ctx, 1);
	if (log->relation_suffix_heads[i] == UINT32_MAX)
	    rb_raise(eRegexpError, "absence suffix relation is missing");
    }
    log->relation_suffix_ready = 1;
}

static int
onibi_dynamic_absence_capture_write_relation_suffix_matches(
    const OnibiDynamicAbsenceCaptureWriteLog *log, uint32_t relation_index,
    uint32_t failed_state_id, OnibiExecCtx *ctx)
{
    if (relation_index >= log->relation_count || !log->relation_suffix_ready)
	return 0;
    uint32_t head = log->relation_suffix_heads[relation_index];
    if (head == UINT32_MAX || head >= log->relation_suffix_count) return 0;
    uint32_t destination = log->relation_suffixes[head].destination;
    size_t traversed = 0;
    for (uint32_t suffix_index = head; suffix_index != UINT32_MAX;
	 suffix_index = log->relation_suffixes[suffix_index].next) {
	if (suffix_index >= log->relation_suffix_count)
	    rb_raise(eRegexpError, "absence suffix relation link is invalid");
	if (traversed++ >= log->relation_suffix_count)
	    rb_raise(eRegexpError, "absence suffix relation cycle is invalid");
	onibi_exec_charge_work(ctx, 1);
	if (log->relation_suffixes[suffix_index].destination != destination)
	    return 0;
    }
    return destination == failed_state_id;
}

typedef struct {
    const OnibiRSeqView *view;
    OnibiSemanticArena *arena;
    OnibiSemanticState *target;
    const OnibiSemanticState *before;
    OnibiTagEventId failed_history;
    OnibiDynamicAbsenceCaptureWriteLog *log;
    const unsigned char *pushed_captures;
    uint32_t capture_count;
    size_t journal_begin;
    size_t journal_end;
    uint32_t failed_state_id;
    OnibiBytePos failed_position;
    OnibiBytePos active_bound;
    OnibiExecCtx *ctx;
    unsigned char *clear;
    int changed;
} OnibiDynamicAbsenceCaptureJournalApply;

static int
onibi_dynamic_absence_capture_write_journal_has_tag(
    const OnibiDynamicAbsenceCaptureJournalApply *apply, OnibiTagEventId tag_id)
{
    for (size_t i = apply->journal_begin; i < apply->journal_end; i++) {
	onibi_exec_charge_work(apply->ctx, 1);
	if (apply->log->journal[i].tag_id == tag_id) return 1;
    }
    return 0;
}

static int
onibi_dynamic_absence_capture_write_history_has_tag(
    const OnibiDynamicAbsenceCaptureJournalApply *apply, OnibiTagEventId tag_id)
{
    size_t traversed = 0;
    for (OnibiTagEventId id = apply->failed_history; id != UINT32_MAX;
	 id = apply->arena->tags[id].parent) {
	if (id >= apply->arena->tag_count ||
	    traversed++ >= apply->arena->tag_count)
	    rb_raise(eRegexpError, "absence capture history is invalid");
	onibi_exec_charge_work(apply->ctx, 1);
	if (id == tag_id) return 1;
    }
    return 0;
}

static int
onibi_dynamic_absence_capture_relation_suffix_consumes(
    OnibiDynamicAbsenceCaptureJournalApply *apply)
{
    if (apply->failed_state_id >= apply->view->header->state_count ||
	apply->log->subject == Qnil)
	rb_raise(eRegexpError, "absence suffix consumer is invalid");
    const OnibiRState *state = &apply->view->states[apply->failed_state_id];
    onibi_exec_charge_work(apply->ctx, 1);
    switch (state->op) {
    case ONIBI_RS_CHAR:
    case ONIBI_RS_CLASS:
    case ONIBI_RS_ANY: {
	rb_encoding *encoding = rb_enc_get(apply->log->subject);
	OnibiEncodingMode mode =
	    onibi_encoding_mode_for(apply->log->subject, encoding);
	OnibiBytePos next_position = apply->active_bound;
	return onibi_rseq_consume_character(
	    apply->view, state, apply->log->subject, apply->active_bound,
	    encoding, mode, &next_position, apply->log->class_stack,
	    apply->log->class_stack_capacity, apply->ctx);
    }
    case ONIBI_RS_GRAPHEME:
	return onibi_grapheme_width(apply->log->subject, apply->active_bound) >
	       0;
    default: rb_raise(eRegexpError, "unsupported absence suffix consumer");
    }
}

static int
onibi_dynamic_absence_capture_write_pair_before(
    OnibiDynamicAbsenceCaptureJournalApply *apply, OnibiTagEventId history_head,
    OnibiTagEventId anchor_id, int include_anchor, uint32_t capture,
    OnibiTagEventId *open_id, OnibiTagEventId *close_id)
{
    OnibiSemanticArena *arena = apply->arena;
    if (capture > (UINT32_MAX - 1U) / 2U || anchor_id >= arena->tag_count)
	return 0;
    OnibiTagEventId id = history_head;
    size_t traversed = 0;
    while (id != UINT32_MAX && id != anchor_id) {
	if (id >= arena->tag_count || traversed++ >= arena->tag_count)
	    rb_raise(eRegexpError, "absence capture anchor is invalid");
	onibi_exec_charge_work(apply->ctx, 1);
	id = arena->tags[id].parent;
    }
    if (id != anchor_id) return 0;
    uint32_t start_slot = capture * 2U;
    uint32_t end_slot = start_slot + 1U;
    if (arena->tags[id].slot != end_slot) return 0;
    *close_id = id;
    id = include_anchor ? id : arena->tags[id].parent;
    traversed = 0;
    while (id != UINT32_MAX) {
	if (id >= arena->tag_count || traversed++ >= arena->tag_count)
	    rb_raise(eRegexpError, "absence capture pair history is invalid");
	onibi_exec_charge_work(apply->ctx, 1);
	if (arena->tags[id].slot == start_slot) {
	    *open_id = id;
	    return 1;
	}
	id = arena->tags[id].parent;
    }
    return 0;
}

static int
onibi_dynamic_absence_capture_write_pushed_target_apply(
    OnibiDynamicAbsenceCaptureJournalApply *apply,
    const OnibiDynamicAbsenceCaptureWrite *write)
{
    if (write->kind != ONIBI_ABSENCE_CAPTURE_WRITE_ACTION ||
	write->action_index >= apply->view->header->action_count ||
	(write->flags & ONIBI_RA_CAPTURE_CLOSE) == 0 ||
	(write->slot & 1U) == 0 || write->position != apply->active_bound ||
	apply->failed_position != apply->active_bound ||
	apply->failed_state_id >= apply->view->header->state_count ||
	!apply->log->relation_suffix_ready)
	return 0;
    const OnibiRAction *close = &apply->view->actions[write->action_index];
    if (close->op != ONIBI_RA_CAPTURE ||
	close->flags != ONIBI_RA_CAPTURE_CLOSE || close->arg16 != write->slot)
	rb_raise(eRegexpError, "absence capture close provenance is invalid");

    for (uint32_t i = write->action_index + 1U;
	 i < apply->view->header->action_count; i++) {
	const OnibiRAction *marker = &apply->view->actions[i];
	if (marker->op != ONIBI_RA_CAPTURE_RELATION) break;
	onibi_exec_charge_work(apply->ctx, 1);
	if (marker->flags != ONIBI_CAPTURE_RELATION_ROLE_CLOSE ||
	    marker->arg16 != write->slot)
	    continue;
	if (marker->arg32 == 0 || marker->arg32 > apply->log->relation_count)
	    rb_raise(eRegexpError, "absence capture close relation is invalid");
	uint32_t relation_index = marker->arg32 - 1U;
	const OnibiAbsenceCaptureRelation *relation =
	    &apply->view->absence_capture_relations[relation_index];
	if (relation->subprogram_id != apply->log->owner_subprogram_id ||
	    relation->target_close_slot != write->slot ||
	    relation->target_start_kind != ONIBI_RELATION_TARGET_START_PUSHED)
	    continue;
	if (!onibi_dynamic_absence_capture_write_relation_suffix_matches(
		apply->log, relation_index, apply->failed_state_id, apply->ctx))
	    continue;
	uint32_t target_capture = relation->target_close_slot / 2U;
	uint32_t witness_capture = relation->pushed_witness_close_slot / 2U;
	if (target_capture >= apply->capture_count ||
	    witness_capture >= apply->capture_count ||
	    target_capture == witness_capture ||
	    apply->pushed_captures == NULL ||
	    !apply->pushed_captures[target_capture])
	    continue;

	OnibiTagEventId target_open_id = UINT32_MAX;
	OnibiTagEventId target_close_id = UINT32_MAX;
	if (!onibi_dynamic_absence_capture_write_pair_before(
		apply, apply->failed_history, write->tag_id, 1, target_capture,
		&target_open_id, &target_close_id) ||
	    target_close_id != write->tag_id ||
	    !onibi_dynamic_absence_capture_write_journal_has_tag(
		apply, target_open_id))
	    continue;
	const OnibiDynamicAbsenceCaptureWrite *target_open_write =
	    onibi_dynamic_absence_capture_write_event_find(
		apply->log, apply->arena, target_open_id,
		apply->arena->tags[target_open_id].logical_id, apply->ctx);
	if (target_open_write == NULL ||
	    target_open_write->kind != ONIBI_ABSENCE_CAPTURE_WRITE_ACTION ||
	    (target_open_write->flags & ONIBI_RA_CAPTURE_OPEN_START_PUSH) == 0)
	    continue;

	OnibiTagEventId witness_open_id = UINT32_MAX;
	OnibiTagEventId witness_close_id = UINT32_MAX;
	if (!onibi_dynamic_absence_capture_write_pair_before(
		apply, apply->failed_history, write->tag_id, 0, witness_capture,
		&witness_open_id, &witness_close_id) ||
	    !onibi_dynamic_absence_capture_write_journal_has_tag(
		apply, witness_open_id) ||
	    !onibi_dynamic_absence_capture_write_journal_has_tag(
		apply, witness_close_id))
	    continue;
	const OnibiDynamicAbsenceCaptureWrite *witness_open_write =
	    onibi_dynamic_absence_capture_write_event_find(
		apply->log, apply->arena, witness_open_id,
		apply->arena->tags[witness_open_id].logical_id, apply->ctx);
	const OnibiDynamicAbsenceCaptureWrite *witness_close_write =
	    onibi_dynamic_absence_capture_write_event_find(
		apply->log, apply->arena, witness_close_id,
		apply->arena->tags[witness_close_id].logical_id, apply->ctx);
	if (witness_open_write == NULL || witness_close_write == NULL ||
	    witness_open_write->kind != ONIBI_ABSENCE_CAPTURE_WRITE_ACTION ||
	    witness_close_write->kind != ONIBI_ABSENCE_CAPTURE_WRITE_ACTION ||
	    (witness_open_write->flags & ONIBI_RA_CAPTURE_OPEN_START_PUSH) ==
		0 ||
	    (witness_close_write->flags & ONIBI_RA_CAPTURE_CLOSE) == 0 ||
	    witness_close_write->slot != relation->pushed_witness_close_slot)
	    continue;

	memset(apply->clear, 0, apply->target->semantic_captures.slot_count);
	apply->clear[relation->target_close_slot - 1U] = 1;
	apply->clear[relation->target_close_slot] = 1;
	onibi_dynamic_absence_filter_capture_slots(
	    apply->arena, apply->target, apply->clear,
	    apply->target->semantic_captures.slot_count, 0, 0, apply->log,
	    apply->ctx, NULL, NULL);
	OnibiSemanticTagEvent open = apply->arena->tags[target_open_id];
	OnibiSemanticTagEvent close_event = apply->arena->tags[target_close_id];
	onibi_exec_charge_work(apply->ctx, 1);
	OnibiTagEventId restored_open = onibi_semantic_tag_clone(
	    apply->arena, apply->target->tag_history, &open);
	apply->target->tag_history = restored_open;
	onibi_dynamic_absence_capture_write_clone(apply->log, apply->arena,
						  target_open_id, restored_open,
						  apply->ctx);
	onibi_exec_charge_work(apply->ctx, 1);
	OnibiTagEventId restored_close = onibi_semantic_tag_clone(
	    apply->arena, apply->target->tag_history, &close_event);
	apply->target->tag_history = restored_close;
	onibi_dynamic_absence_capture_write_clone(apply->log, apply->arena,
						  target_close_id,
						  restored_close, apply->ctx);
	onibi_semantic_condition_capture_write(
	    apply->arena, &apply->target->condition_captures,
	    relation->target_close_slot - 1U, open.position);
	onibi_semantic_condition_capture_write(
	    apply->arena, &apply->target->condition_captures,
	    relation->target_close_slot, close_event.position);
	apply->changed = 1;
	return 1;
    }
    return 0;
}

static int
onibi_dynamic_absence_capture_write_close_deferred(
    OnibiDynamicAbsenceCaptureJournalApply *apply,
    const OnibiDynamicAbsenceCaptureWrite *write)
{
    if (write->kind != ONIBI_ABSENCE_CAPTURE_WRITE_ACTION ||
	write->action_index >= apply->view->header->action_count ||
	(write->flags & ONIBI_RA_CAPTURE_CLOSE) == 0 ||
	(write->slot & 1U) == 0 || write->position != apply->active_bound ||
	apply->failed_position != apply->active_bound ||
	apply->failed_state_id >= apply->view->header->state_count ||
	!apply->log->relation_suffix_ready ||
	!onibi_dynamic_absence_capture_write_history_has_tag(apply,
							     write->tag_id))
	return 0;
    const OnibiRAction *close = &apply->view->actions[write->action_index];
    if (close->op != ONIBI_RA_CAPTURE ||
	close->flags != ONIBI_RA_CAPTURE_CLOSE || close->arg16 != write->slot)
	rb_raise(eRegexpError, "absence capture close provenance is invalid");

    for (uint32_t i = write->action_index + 1U;
	 i < apply->view->header->action_count; i++) {
	const OnibiRAction *marker = &apply->view->actions[i];
	if (marker->op != ONIBI_RA_CAPTURE_RELATION) break;
	onibi_exec_charge_work(apply->ctx, 1);
	if (marker->flags != ONIBI_CAPTURE_RELATION_ROLE_CLOSE ||
	    marker->arg16 != write->slot)
	    continue;
	if (marker->arg32 == 0 || marker->arg32 > apply->log->relation_count)
	    rb_raise(eRegexpError, "absence capture close relation is invalid");
	uint32_t relation_index = marker->arg32 - 1U;
	const OnibiAbsenceCaptureRelation *relation =
	    &apply->view->absence_capture_relations[relation_index];
	if (relation->subprogram_id != apply->log->owner_subprogram_id ||
	    relation->target_close_slot != write->slot)
	    continue;
	if (onibi_dynamic_absence_capture_write_relation_suffix_matches(
		apply->log, relation_index, apply->failed_state_id,
		apply->ctx) &&
	    !onibi_dynamic_absence_capture_relation_suffix_consumes(apply))
	    return 1;
    }
    return 0;
}

static VALUE
onibi_dynamic_absence_capture_journal_apply_body(VALUE opaque)
{
    OnibiDynamicAbsenceCaptureJournalApply *apply =
	(OnibiDynamicAbsenceCaptureJournalApply *)(uintptr_t)opaque;
    OnibiSemanticArena *arena = apply->arena;
    OnibiSemanticState *target = apply->target;
    uint32_t slots = target->semantic_captures.slot_count;
    if (target->condition_captures.slot_count != slots ||
	apply->before->semantic_captures.slot_count != slots ||
	apply->before->condition_captures.slot_count != slots ||
	(uint64_t)apply->capture_count * 2U > slots ||
	apply->journal_begin > apply->journal_end ||
	apply->journal_end > apply->log->journal_count)
	rb_raise(eRegexpError, "absence capture journal range is invalid");

    if (apply->ctx) apply->ctx->current_position = apply->failed_position;
    target->semantic_captures = apply->before->semantic_captures;
    target->condition_captures = apply->before->condition_captures;
    target->tag_history = apply->before->tag_history;
    target->reported_start = apply->before->reported_start;
    apply->changed =
	target->capture_event_history != apply->before->capture_event_history ||
	target->capture_event_dependency !=
	    apply->before->capture_event_dependency;
    if (slots == 0) return apply->changed ? Qtrue : Qfalse;
    apply->clear = ruby_xcalloc(slots, 1);

    for (size_t i = apply->journal_begin; i < apply->journal_end; i++) {
	onibi_exec_charge_work(apply->ctx, 1);
	const OnibiDynamicAbsenceCaptureWrite *write = &apply->log->journal[i];
	if (!write->valid || write->slot >= slots || write->position < 0)
	    rb_raise(eRegexpError, "absence capture journal entry is invalid");
	if (onibi_dynamic_absence_capture_write_pushed_target_apply(apply,
								    write))
	    continue;
	if (onibi_dynamic_absence_capture_write_close_deferred(apply, write))
	    continue;
	uint32_t capture = write->slot / 2U;
	if (capture >= apply->capture_count ||
	    (apply->pushed_captures != NULL && apply->pushed_captures[capture]))
	    continue;

	if ((write->slot & 1U) == 0) {
	    if (write->kind == ONIBI_ABSENCE_CAPTURE_WRITE_ACTION &&
		(write->flags & ONIBI_RA_CAPTURE_OPEN_START_PUSH) != 0)
		continue;
	    onibi_dynamic_output_publish_slot(
		arena, arena->active_output_state, arena->active_output_batch,
		write->slot, write->position, apply->ctx);
	    memset(apply->clear, 0, slots);
	    apply->clear[write->slot] = 1;
	    apply->clear[write->slot + 1U] = 1;
	    onibi_dynamic_absence_filter_capture_slots(
		arena, target, apply->clear, slots, 0, 0, apply->log,
		apply->ctx, NULL, NULL);
	    onibi_semantic_condition_capture_write(
		arena, &target->condition_captures, write->slot,
		write->position);
	    onibi_semantic_condition_capture_write(
		arena, &target->condition_captures, write->slot + 1U, -1);
	    apply->changed = 1;
	    continue;
	}
	OnibiBytePos capture_start = onibi_semantic_position_read(
	    arena, target->condition_captures.root, write->slot - 1U, -1);
	memset(apply->clear, 0, slots);
	apply->clear[write->slot - 1U] = 1;
	apply->clear[write->slot] = 1;
	onibi_dynamic_absence_filter_capture_slots(arena, target, apply->clear,
						   slots, 0, 0, apply->log,
						   apply->ctx, NULL, NULL);
	if (capture_start >= 0) {
	    /* A close event updates only its own output slot. The direct start
	     * can survive a semantic rollback that changed condition_captures.
	     */
	    onibi_dynamic_output_publish_slot(
		arena, arena->active_output_state, arena->active_output_batch,
		write->slot, write->position, apply->ctx);
	    target->tag_history = onibi_semantic_tag_append(
		arena, target->tag_history, write->slot - 1U, capture_start);
	    onibi_dynamic_absence_capture_write_publish(
		apply->log, arena, target->tag_history,
		(uint16_t)(write->slot - 1U), capture_start, apply->ctx);
	    target->tag_history = onibi_semantic_tag_append(
		arena, target->tag_history, write->slot, write->position);
	    onibi_dynamic_absence_capture_write_publish(
		apply->log, arena, target->tag_history, write->slot,
		write->position, apply->ctx);
	}
	onibi_semantic_condition_capture_write(
	    arena, &target->condition_captures, write->slot, write->position);
	apply->changed = 1;
    }
    return apply->changed ? Qtrue : Qfalse;
}

static VALUE
onibi_dynamic_absence_capture_journal_apply_ensure(VALUE opaque)
{
    OnibiDynamicAbsenceCaptureJournalApply *apply =
	(OnibiDynamicAbsenceCaptureJournalApply *)(uintptr_t)opaque;
    ruby_xfree(apply->clear);
    apply->clear = NULL;
    return Qnil;
}

static int
onibi_dynamic_absence_capture_journal_apply(
    const OnibiRSeqView *view, OnibiSemanticArena *arena,
    OnibiSemanticState *target, const OnibiSemanticState *before,
    OnibiDynamicAbsenceCaptureWriteLog *log,
    const unsigned char *pushed_captures, uint32_t capture_count,
    size_t journal_begin, size_t journal_end, uint32_t failed_state_id,
    OnibiBytePos failed_position, OnibiBytePos active_bound, OnibiExecCtx *ctx)
{
    OnibiDynamicAbsenceCaptureJournalApply apply = {
	.view = view,
	.arena = arena,
	.target = target,
	.before = before,
	.failed_history = target->tag_history,
	.log = log,
	.pushed_captures = pushed_captures,
	.capture_count = capture_count,
	.journal_begin = journal_begin,
	.journal_end = journal_end,
	.failed_state_id = failed_state_id,
	.failed_position = failed_position,
	.active_bound = active_bound,
	.ctx = ctx,
	.clear = NULL,
	.changed = 0};
    return RTEST(rb_ensure(onibi_dynamic_absence_capture_journal_apply_body,
			   (VALUE)(uintptr_t)&apply,
			   onibi_dynamic_absence_capture_journal_apply_ensure,
			   (VALUE)(uintptr_t)&apply));
}

static int
onibi_dynamic_absence_capture_journal_publish(
    const OnibiRSeqView *view, OnibiSemanticArena *arena,
    OnibiSemanticState *target, const OnibiSemanticState *before,
    const OnibiSemanticState *failed, OnibiDynamicAbsenceCaptureWriteLog *log,
    const unsigned char *pushed_captures, uint32_t capture_count,
    size_t journal_begin, size_t journal_end, uint32_t failed_state_id,
    OnibiBytePos failed_position, OnibiBytePos active_bound, OnibiExecCtx *ctx)
{
    OnibiSemanticState published = *failed;
    onibi_dynamic_absence_filter_capture_events(arena, &published,
						before->capture_event_history,
						pushed_captures, capture_count);

    if (!onibi_dynamic_absence_capture_journal_apply(
	    view, arena, &published, before, log, pushed_captures,
	    capture_count, journal_begin, journal_end, failed_state_id,
	    failed_position, active_bound, ctx))
	return 0;
    *target = published;
    return 1;
}

static int
onibi_dynamic_absence_capture_journal_publish_to_batch(
    const OnibiRSeqView *view, OnibiSemanticArena *arena,
    OnibiSemanticState *target, const OnibiSemanticState *before,
    const OnibiSemanticState *failed, OnibiDynamicAbsenceCaptureWriteLog *log,
    const unsigned char *pushed_captures, uint32_t capture_count,
    size_t journal_begin, size_t journal_end, uint32_t failed_state_id,
    OnibiBytePos failed_position, OnibiBytePos active_bound,
    uint32_t output_batch, OnibiExecCtx *ctx)
{
    uint32_t saved_batch = arena->active_output_batch;
    arena->active_output_batch = output_batch;
    int result = onibi_dynamic_absence_capture_journal_publish(
	view, arena, target, before, failed, log, pushed_captures,
	capture_count, journal_begin, journal_end, failed_state_id,
	failed_position, active_bound, ctx);
    arena->active_output_batch = saved_batch;
    return result;
}

static void
onibi_dynamic_absence_capture_write_record(
    OnibiDynamicAbsenceCaptureWriteLog *log, OnibiSemanticArena *arena,
    OnibiTagEventId tag_id, uint32_t source_state, uint32_t edge_index,
    uint32_t destination, uint32_t action_index, uint16_t slot, uint8_t flags,
    OnibiBytePos position, OnibiExecCtx *ctx)
{
    if (log == NULL) return;
    if (tag_id >= arena->tag_count || arena->tags[tag_id].slot != slot ||
	arena->tags[tag_id].position != position)
	rb_raise(eRegexpError, "absence capture action is invalid");
    OnibiDynamicAbsenceCaptureWrite event = {
	.tag_id = tag_id,
	.logical_id = arena->tags[tag_id].logical_id,
	.source_state = source_state,
	.edge_index = edge_index,
	.destination = destination,
	.action_index = action_index,
	.slot = slot,
	.flags = flags,
	.kind = ONIBI_ABSENCE_CAPTURE_WRITE_ACTION,
	.valid = 1,
	.position = position};
    onibi_dynamic_absence_capture_write_event_store(log, arena, &event, ctx);
}

static void
onibi_dynamic_absence_capture_write_transfer_history(
    OnibiDynamicAbsenceCaptureWriteLog *parent,
    OnibiDynamicAbsenceCaptureWriteLog *child, OnibiSemanticArena *arena,
    OnibiTagEventId history, OnibiExecCtx *ctx)
{
    if (parent == NULL) return;
    child->path_count = 0;
    size_t traversed = 0;
    int found_base = child->base_history_identity == 0;
    for (OnibiTagEventId id = history; id != UINT32_MAX;
	 id = arena->tags[id].parent) {
	if (id >= arena->tag_count || traversed >= arena->tag_count)
	    rb_raise(eRegexpError, "absence published history is invalid");
	onibi_exec_charge_work(ctx, 1);
	traversed++;
	if (child->base_history_identity != 0 &&
	    arena->tags[id].logical_id == child->base_history_identity) {
	    found_base = 1;
	    break;
	}
	if (child->path_count == child->path_capacity) {
	    size_t capacity =
		child->path_capacity == 0 ? 16U : child->path_capacity;
	    if (capacity > SIZE_MAX / 2U ||
		capacity * 2U > SIZE_MAX / sizeof(*child->path))
		rb_memerror();
	    capacity *= 2U;
	    onibi_exec_charge_work(ctx, capacity - child->path_capacity);
	    child->path =
		ruby_xrealloc(child->path, capacity * sizeof(*child->path));
	    child->path_capacity = capacity;
	}
	child->path[child->path_count++] = id;
    }
    if (!found_base)
	rb_raise(eRegexpError, "absence published base is missing");
    for (size_t i = child->path_count; i > 0; i--) {
	OnibiTagEventId id = child->path[i - 1U];
	const OnibiSemanticTagEvent *tag = &arena->tags[id];
	if (onibi_dynamic_absence_capture_write_event_find(
		child, arena, id, tag->logical_id, ctx) == NULL)
	    rb_raise(eRegexpError,
		     "absence published capture provenance is missing");
	onibi_dynamic_absence_capture_write_publish(
	    parent, arena, id, tag->slot, tag->position, ctx);
    }
}

static OnibiActionResult
onibi_apply_action_program(const OnibiRSeqView *view, const OnibiREdge *edge,
			   VALUE str, OnibiBytePos pos,
			   OnibiBytePos search_origin, rb_encoding *encoding,
			   OnibiEncodingMode mode, OnibiSemanticArena *arena,
			   const OnibiSemanticState *predecessor,
			   OnibiSemanticState *successor, OnibiExecCtx *ctx,
			   uint32_t source_state, uint32_t edge_index,
			   OnibiDynamicAbsenceCaptureWriteLog *capture_writes,
			   int capture_failure_owner)
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
	if (action->op == ONIBI_RA_CAPTURE_RELATION) continue;
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
	    if (arena->active_output_batch != 0)
		onibi_dynamic_output_batch_append(
		    arena, arena->active_output_batch,
		    (OnibiDynamicOutputWrite){.slot = action->arg16,
					      .flags = action->flags,
					      .kind =
						  ONIBI_DYNAMIC_OUTPUT_ACTION,
					      .position = pos,
					      .previous_begin = -1,
					      .previous_end = -1,
					      .source_state = source_state,
					      .edge_index = edge_index,
					      .destination = edge->destination,
					      .action_index = index,
					      .capture_order = working.order},
		    ctx);
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
	    if ((action->flags & ONIBI_RA_CAPTURE_OPEN_UNSCOPED) != 0) {
		working.capture_event_history =
		    onibi_semantic_capture_event_append(
			arena, working.capture_event_history, working.order,
			action->arg16, pos);
	    }
	    working.tag_history = onibi_semantic_tag_append(
		arena, working.tag_history, action->arg16, pos);
	    onibi_dynamic_absence_capture_write_record(
		capture_writes, arena, working.tag_history, source_state,
		edge_index, edge->destination, index, action->arg16,
		action->flags, pos, ctx);
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
	    if (ctx == NULL) goto fail;
	    OnibiActionResult assertion_result =
		ctx->program != NULL &&
			ctx->program->exec_kind == ONIBI_EXEC_DYNAMIC
		    ? onibi_dynamic_assert_subprogram(
			  ctx, action, pos, &working, &assertion_state,
			  capture_writes, capture_failure_owner)
		    : onibi_tagged_assert_subprogram(ctx, action, pos, &working,
						     &assertion_state);
	    if (assertion_result == ONIBI_ACTION_FAIL) goto fail;
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

static OnibiActionResult
onibi_dynamic_apply_action_program(
    const OnibiRSeqView *view, const OnibiREdge *edge, VALUE str,
    OnibiBytePos position, OnibiBytePos search_origin, rb_encoding *encoding,
    OnibiEncodingMode mode, OnibiSemanticArena *arena,
    const OnibiSemanticState *predecessor, OnibiSemanticState *successor,
    OnibiExecCtx *ctx, uint32_t source_state, uint32_t edge_index,
    OnibiDynamicAbsenceCaptureWriteLog *capture_writes,
    int capture_failure_owner, uint32_t prefix_batch, uint32_t *output_batch)
{
    *output_batch = 0;
    if (arena->active_output_state == NULL)
	return onibi_apply_action_program(
	    view, edge, str, position, search_origin, encoding, mode, arena,
	    predecessor, successor, ctx, source_state, edge_index,
	    capture_writes, capture_failure_owner);

    uint32_t reference = onibi_dynamic_output_batch_new(arena, ctx);
    onibi_dynamic_output_batch_copy(arena, reference, prefix_batch, ctx);
    uint32_t saved_batch = arena->active_output_batch;
    arena->active_output_batch = reference;
    OnibiActionResult result = onibi_apply_action_program(
	view, edge, str, position, search_origin, encoding, mode, arena,
	predecessor, successor, ctx, source_state, edge_index, capture_writes,
	capture_failure_owner);
    arena->active_output_batch = saved_batch;
    OnibiDynamicOutputBatch *batch =
	onibi_dynamic_output_batch_get(arena, reference);
    if (batch->count != 0) *output_batch = reference;
    return result;
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
	    arena, &predecessor, &successor, &ctx, UINT32_MAX, UINT32_MAX, NULL,
	    0);
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
	    &predecessor, &successor, NULL, UINT32_MAX, UINT32_MAX, NULL, 0);
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
	    if (!onibi_dynamic_key_seen(&arena, 7, 11, 11, &semantic))
		inserted++;
	    onibi_dynamic_stack_push(
		&arena, (OnibiDynamicFrame){7, 11, semantic, UINT32_MAX, 11});
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
	int duplicate_seen = onibi_dynamic_key_seen(&arena, 7, 11, 11, &last);
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
	    &arena, &predecessor, &first, NULL, UINT32_MAX, UINT32_MAX, NULL,
	    0);
	OnibiActionResult second_status = onibi_apply_action_program(
	    &view, &edges[1], subject, 2, 0, encoding, ONIBI_ENC_ASCII_7BIT,
	    &arena, &predecessor, &second, NULL, UINT32_MAX, UINT32_MAX, NULL,
	    0);
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
	    &arena, &predecessor, &failed, NULL, UINT32_MAX, UINT32_MAX, NULL,
	    0);
	OnibiSemanticState repeated = first;
	OnibiActionResult repeated_status = onibi_apply_action_program(
	    &view, &edges[3], subject, 2, 0, encoding, ONIBI_ENC_ASCII_7BIT,
	    &arena, &first, &repeated, NULL, UINT32_MAX, UINT32_MAX, NULL, 0);

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
	    &first, &failed, NULL, UINT32_MAX, UINT32_MAX, NULL, 0);
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
				      &raw_match, 4, 0, NULL);
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
	onibi_tagged_materialize_tags(&arena, &accepted, &raw_match, 2, 0,
				      NULL);
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
	int merged_materialized = onibi_tagged_materialize_tags(
	    &arena, &merged, &merged_match, 2, 0, NULL);
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
    OnibiBytePos initial_previous_position, OnibiBytePos active_bound,
    OnibiBytePos search_origin, uint32_t entry_edge_base,
    uint32_t entry_edge_count, uint32_t local_subprogram_id,
    OnibiBytePos required_end, int force_exhaustion,
    const OnibiSemanticState *initial_state, OnibiSemanticState *failed_state,
    OnibiBytePos *failed_position, int reset_arena, OnibiBytePos *matched_end,
    OnibiSemanticState *accepted_state, OnibiSemanticArena *semantic_arena,
    unsigned char *class_stack, size_t class_stack_capacity, OnibiExecCtx *ctx,
    OnibiBytePos *matched_previous_position,
    OnibiDynamicAbsenceCaptureWriteLog *capture_writes,
    uint32_t *failed_state_id)
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
    int capture_failure_owner =
	capture_writes != NULL && local_subprogram_id != UINT32_MAX &&
	local_subprogram_id == capture_writes->owner_subprogram_id &&
	local_subprogram_id < header->subprogram_count &&
	view->subprograms[local_subprogram_id].kind == ONIBI_SUBPROGRAM_ABSENCE;
    if (header->capture_count > UINT32_MAX / 2U) return -1;
    if (start < 0 || start > active_bound || active_bound < 0 ||
	active_bound > RSTRING_LEN(str) || initial_previous_position < 0 ||
	initial_previous_position > start ||
	!onibi_character_boundary(str, start) ||
	!onibi_character_boundary(str, initial_previous_position) ||
	!onibi_character_boundary(str, active_bound))
	return -1;
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
    size_t saved_absence_endpoint_count = arena->absence_endpoint_count;
    OnibiDynamicOutputState *saved_output_state = arena->active_output_state;
    uint32_t saved_output_batch = arena->active_output_batch;
    OnibiBytePos saved_active_bound = ctx ? ctx->active_bound : -1;
    OnibiBytePos saved_previous_position =
	ctx ? ctx->current_previous_position : -1;
    if (reset_arena) {
	onibi_semantic_arena_reset(arena);
	frame_base = 0;
	initial_state = NULL;
	if (ctx != NULL && ctx->program != NULL &&
	    ctx->program->exec_kind == ONIBI_EXEC_DYNAMIC) {
	    onibi_dynamic_output_state_reset(&arena->output_root,
					     header->capture_count * 2U, ctx);
	    arena->active_output_state = &arena->output_root;
	}
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
    if (ctx) {
	ctx->active_bound = active_bound;
	ctx->current_previous_position = initial_previous_position;
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
	arena->absence_endpoint_count =                                        \
	    reset_arena ? 0 : saved_absence_endpoint_count;                    \
	if (ctx) {                                                             \
	    ctx->active_bound = saved_active_bound;                            \
	    ctx->current_previous_position = saved_previous_position;          \
	}                                                                      \
	arena->active_output_state = saved_output_state;                       \
	arena->active_output_batch = saved_output_batch;                       \
	return (value);                                                        \
    } while (0)

    if (entry_edge_base == UINT32_MAX) {
	if (header->subprogram_count == 0 ||
	    view->subprograms[0].entry >= header->state_count)
	    ONIBI_DYNAMIC_RUN_RETURN(-1);
	onibi_dynamic_stack_push(
	    arena,
	    (OnibiDynamicFrame){view->subprograms[0].entry, start, initial,
				UINT32_MAX, initial_previous_position});
    }
    for (uint32_t i = entry_edge_count; i > 0; i--) {
	const OnibiREdge *edge = &edges[entry_edge_base + (i - 1U)];
	uint32_t edge_index = entry_edge_base + (i - 1U);
	OnibiSemanticState branch;
	uint32_t output_batch = 0;
	if (onibi_dynamic_apply_action_program(
		view, edge, str, start, search_origin, encoding, encoding_mode,
		arena, &initial, &branch, ctx, UINT32_MAX, edge_index,
		capture_writes, capture_failure_owner, 0,
		&output_batch) == ONIBI_ACTION_FAIL) {
	    onibi_dynamic_output_queue_only(arena, output_batch, ctx);
	    continue;
	}
	if (edge->destination == ONIBI_ACCEPT_STATE &&
	    (required_end < 0 || start == required_end)) {
	    OnibiDynamicFrame frame = {ONIBI_ACCEPT_STATE, start, branch,
				       UINT32_MAX, initial_previous_position};
	    frame.output_batch = output_batch;
	    onibi_dynamic_stack_push(arena, frame);
	    continue;
	}
	if (edge->destination < header->state_count) {
	    OnibiDynamicFrame frame = {edge->destination, start, branch,
				       UINT32_MAX, initial_previous_position};
	    frame.output_batch = output_batch;
	    onibi_dynamic_stack_push(arena, frame);
	}
	else
	    onibi_dynamic_output_queue_only(arena, output_batch, ctx);
    }

    while (arena->frame_count > frame_base) {
	OnibiDynamicFrame frame = arena->frames[--arena->frame_count];
	if (ctx) {
	    ctx->current_position = frame.position;
	    ctx->current_previous_position = frame.previous_position;
	}
	onibi_exec_charge_work(ctx, 1);
	if (arena->active_output_state != NULL) {
	    onibi_dynamic_output_restore_to(arena->active_output_state,
					    frame.output_mark, ctx);
	}
	if (frame.output_only) {
	    if (arena->active_output_state != NULL) {
		onibi_dynamic_output_apply_batch(
		    arena->active_output_state, arena, frame.output_batch, ctx);
		onibi_dynamic_output_restore_to(arena->active_output_state,
						frame.output_mark, ctx);
	    }
	    continue;
	}
	if (frame.cycle_root == ONIBI_DYNAMIC_FAILURE_FRAME_MARKER) {
	    if (arena->active_output_state != NULL) {
		onibi_dynamic_output_apply_batch(
		    arena->active_output_state, arena, frame.output_batch, ctx);
	    }
	    if (!capture_failure_owner || capture_writes == NULL)
		ONIBI_DYNAMIC_RUN_RETURN(-1);
	    onibi_dynamic_absence_capture_failure_prefix_publish(
		arena, capture_writes, frame.state, ctx);
	    continue;
	}
	if (frame.state == ONIBI_ACCEPT_STATE) {
	    if (arena->active_output_state != NULL)
		onibi_dynamic_output_apply_batch(
		    arena->active_output_state, arena, frame.output_batch, ctx);
	    if (force_exhaustion && required_end >= 0 &&
		frame.position == required_end)
		continue;
	    if (required_end < 0 || frame.position == required_end) {
		*matched_end = frame.position;
		if (matched_previous_position)
		    *matched_previous_position = frame.previous_position;
		*accepted_state = frame.semantic;
		if (local_subprogram_id != UINT32_MAX)
		    onibi_semantic_local_slots_restore(
			arena, local_subprogram_id, accepted_state,
			caller_state.counters, caller_state.progress);
		ONIBI_DYNAMIC_RUN_RETURN(1);
	    }
	    continue;
	}
	if (capture_writes != NULL && local_subprogram_id != UINT32_MAX &&
	    local_subprogram_id < header->subprogram_count &&
	    view->subprograms[local_subprogram_id].kind ==
		ONIBI_SUBPROGRAM_ABSENCE &&
	    frame.semantic.calls.depth == caller_state.calls.depth &&
	    frame.position >= 0 && frame.position <= active_bound &&
	    frame.state < header->state_count) {
	    if (!onibi_dynamic_absence_capture_write_path(arena, capture_writes,
							  &frame.semantic, ctx))
		ONIBI_DYNAMIC_RUN_RETURN(-1);
	}
	if (!force_exhaustion && failed_state && failed_position &&
	    frame.position >= *failed_position) {
	    *failed_state = frame.semantic;
	    if (local_subprogram_id != UINT32_MAX)
		onibi_semantic_local_slots_restore(
		    arena, local_subprogram_id, failed_state,
		    caller_state.counters, caller_state.progress);
	    *failed_position = frame.position;
	    if (failed_state_id != NULL) *failed_state_id = frame.state;
	}
	if (frame.position < 0 || frame.position > active_bound ||
	    frame.state >= header->state_count)
	    continue;
	const OnibiRState *state = &states[frame.state];
#define ONIBI_RECORD_FAILURE()                                                 \
    do {                                                                       \
	if (failed_state && failed_position &&                                 \
	    frame.position >= *failed_position) {                              \
	    *failed_state = frame.semantic;                                    \
	    *failed_position = frame.position;                                 \
	    if (failed_state_id != NULL) *failed_state_id = frame.state;       \
	}                                                                      \
    } while (0)
	uint32_t cycle_root = frame.cycle_root;
	OnibiDynamicThreadKey cycle_key = {frame.state, frame.position,
					   frame.semantic, 0};
	cycle_key.previous_position = frame.previous_position;
	cycle_key.hash = onibi_dynamic_thread_key_hash(arena, &cycle_key);
	if (onibi_dynamic_cycle_seen(arena, &cycle_key, frame.cycle_root,
				     &cycle_root))
	    continue;
	if (onibi_dynamic_key_seen(arena, frame.state, frame.position,
				   frame.previous_position, &frame.semantic))
	    continue;
	if (arena->active_output_state != NULL)
	    onibi_dynamic_output_apply_batch(arena->active_output_state, arena,
					     frame.output_batch, ctx);
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
		    if (matched_previous_position)
			*matched_previous_position = frame.previous_position;
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
	    onibi_dynamic_output_restore_active_captures(
		arena, arena->active_output_state, arena->active_output_batch,
		&call->caller_captures, call->caller_tag_history, ctx);
	    onibi_semantic_restore_active_conditions(
		arena, &returned, &call->caller_condition_captures,
		call->caller_tag_history);
	    onibi_semantic_restore_active_capture_tags(arena, &returned,
						       call->caller_tag_history,
						       capture_writes, ctx);
	    OnibiSemanticState branch;
	    const OnibiREdge *edge = &edges[edge_index];
	    uint32_t output_batch = 0;
	    if (onibi_dynamic_apply_action_program(
		    view, edge, str, frame.position, search_origin, encoding,
		    encoding_mode, arena, &returned, &branch, ctx, UINT32_MAX,
		    edge_index, capture_writes, capture_failure_owner, 0,
		    &output_batch) == ONIBI_ACTION_FAIL) {
		onibi_dynamic_output_queue_only(arena, output_batch, ctx);
		continue;
	    }
	    if (edge->destination == ONIBI_ACCEPT_STATE &&
		(required_end < 0 || frame.position == required_end)) {
		size_t child_frame_base = arena->frame_count;
		OnibiDynamicFrame next = {ONIBI_ACCEPT_STATE, frame.position,
					  branch, cycle_root,
					  frame.previous_position};
		next.output_batch = output_batch;
		onibi_dynamic_stack_push(arena, next);
		onibi_dynamic_cycle_prune_redundant(arena, child_frame_base);
		continue;
	    }
	    if (edge->destination < header->state_count) {
		size_t child_frame_base = arena->frame_count;
		OnibiDynamicFrame next = {edge->destination, frame.position,
					  branch, cycle_root,
					  frame.previous_position};
		next.output_batch = output_batch;
		onibi_dynamic_stack_push(arena, next);
		onibi_dynamic_cycle_prune_redundant(arena, child_frame_base);
	    }
	    else
		onibi_dynamic_output_queue_only(arena, output_batch, ctx);
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
		    uint32_t output_batch = 0;
		    if (onibi_dynamic_apply_action_program(
			    view, entry, str, frame.position, search_origin,
			    encoding, encoding_mode, arena, &branch, &branch,
			    ctx, UINT32_MAX,
			    subprogram->entry_edge_base + (s - 1U),
			    capture_writes, capture_failure_owner, 0,
			    &output_batch) == ONIBI_ACTION_FAIL) {
			onibi_dynamic_output_queue_only(arena, output_batch,
							ctx);
			continue;
		    }
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
		    if (entry->destination < header->state_count) {
			OnibiDynamicFrame next = {
			    entry->destination, frame.position, branch,
			    cycle_root, frame.previous_position};
			next.output_batch = output_batch;
			onibi_dynamic_stack_push(arena, next);
		    }
		    else
			onibi_dynamic_output_queue_only(arena, output_batch,
							ctx);
		}
	    }
	    onibi_dynamic_cycle_prune_redundant(arena, child_frame_base);
	    continue;
	}
	OnibiSemanticState transition_semantic = frame.semantic;
	OnibiBytePos atomic_previous_position = frame.previous_position;
	if (state->op == ONIBI_RS_ABSENT) {
	    size_t endpoint_base = arena->absence_endpoint_count;
	    size_t endpoint_count = 0;
	    int absence_status = onibi_dynamic_absence_consume(
		rseq, view, str, frame.position, frame.previous_position,
		active_bound, search_origin, state->payload, &frame.semantic,
		arena, class_stack, class_stack_capacity, ctx, &endpoint_base,
		&endpoint_count, capture_writes, capture_failure_owner);
	    if (absence_status < 0) ONIBI_DYNAMIC_RUN_RETURN(-1);
	    if (absence_status == 0) continue;
	    if (endpoint_base !=
		    arena->absence_endpoint_count - endpoint_count ||
		endpoint_base + endpoint_count > arena->absence_endpoint_count)
		ONIBI_DYNAMIC_RUN_RETURN(-1);
	    size_t child_frame_base = arena->frame_count;
	    for (size_t endpoint_index = endpoint_base;
		 endpoint_index < endpoint_base + endpoint_count;
		 endpoint_index++) {
		OnibiDynamicAbsenceEndpoint endpoint =
		    arena->absence_endpoints[endpoint_index];
		OnibiBytePos candidate = endpoint.position;
		if (ctx) {
		    ctx->current_position = candidate;
		    ctx->current_previous_position = endpoint.previous_position;
		}
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
			    : &endpoint.semantic;
		    if (ctx)
			ctx->current_previous_position =
			    endpoint.previous_position;
		    uint32_t output_batch = 0;
		    if (onibi_dynamic_apply_action_program(
			    view, edge, str, candidate, search_origin, encoding,
			    encoding_mode, arena, edge_input, &branch, ctx,
			    frame.state, state->edge_base + (e - 1U),
			    capture_writes, capture_failure_owner,
			    endpoint.output_batch,
			    &output_batch) == ONIBI_ACTION_FAIL) {
			onibi_dynamic_output_queue_only(arena, output_batch,
							ctx);
			continue;
		    }
		    if (edge->destination == ONIBI_ACCEPT_STATE) {
			OnibiDynamicFrame next = {
			    ONIBI_ACCEPT_STATE, candidate, branch,
			    candidate == frame.position ? cycle_root
							: UINT32_MAX,
			    endpoint.previous_position};
			next.output_batch = output_batch;
			onibi_dynamic_stack_push(arena, next);
			continue;
		    }
		    if (edge->destination < header->state_count) {
			OnibiDynamicFrame next = {
			    edge->destination, candidate, branch,
			    candidate == frame.position ? cycle_root
							: UINT32_MAX,
			    endpoint.previous_position};
			next.output_batch = output_batch;
			onibi_dynamic_stack_push(arena, next);
		    }
		    else
			onibi_dynamic_output_queue_only(arena, output_batch,
							ctx);
		}
	    }
	    arena->absence_endpoint_count = endpoint_base;
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
	    OnibiDynamicOutputState *atomic_output = NULL;
	    OnibiDynamicOutputState *saved_output_state =
		arena->active_output_state;
	    uint32_t saved_output_batch = arena->active_output_batch;
	    if (saved_output_state != NULL) {
		atomic_output = onibi_dynamic_output_scope_new(
		    arena, saved_output_state, 1, ctx);
		arena->active_output_state = atomic_output;
		arena->active_output_batch = 0;
	    }
	    int atomic_status = onibi_rseq_dynamic_run(
		rseq, view, str, frame.position, frame.previous_position,
		active_bound, search_origin, subprogram->entry_edge_base,
		subprogram->entry_edge_count, state->payload, -1, 0,
		&frame.semantic, NULL, NULL, 0, &atomic_end, &atomic_result,
		arena, class_stack, class_stack_capacity, ctx,
		&atomic_previous_position, capture_writes, NULL);
	    arena->active_output_state = saved_output_state;
	    arena->active_output_batch = saved_output_batch;
	    if (atomic_status < 0) {
		onibi_dynamic_output_scope_release(arena, atomic_output);
		ONIBI_DYNAMIC_RUN_RETURN(-1);
	    }
	    if (atomic_status == 0) {
		onibi_semantic_checkpoint_restore(arena, &checkpoint);
		onibi_dynamic_output_scope_release(arena, atomic_output);
		continue;
	    }
	    if (atomic_output != NULL)
		onibi_dynamic_output_replay_transcript(saved_output_state,
						       atomic_output, ctx);
	    onibi_dynamic_output_scope_release(arena, atomic_output);
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
	if (next_position < frame.position || next_position > active_bound)
	    hit = 0;
	if (!hit) {
	    ONIBI_RECORD_FAILURE();
	    continue;
	}
	OnibiBytePos next_previous_position = frame.previous_position;
	if (next_position != frame.position) {
	    next_previous_position = onibi_dynamic_previous_position(
		str, next_position, encoding, encoding_mode);
	    if (next_previous_position < 0) ONIBI_DYNAMIC_RUN_RETURN(-1);
	}
	if (state->op == ONIBI_RS_ATOMIC)
	    next_previous_position = atomic_previous_position;
	uint32_t child_cycle_root =
	    next_position == frame.position ? cycle_root : UINT32_MAX;
	size_t child_frame_base = arena->frame_count;
	for (uint32_t pass = 0; pass < state->edge_count; pass++) {
	    uint32_t e = state->edge_count - pass;
	    const OnibiREdge *edge = &edges[state->edge_base + (e - 1U)];
	    uint32_t edge_index = state->edge_base + (e - 1U);
	    OnibiSemanticState branch;
	    uint32_t output_batch = 0;
	    if (ctx) ctx->current_previous_position = next_previous_position;
	    if (onibi_dynamic_apply_action_program(
		    view, edge, str, next_position, search_origin, encoding,
		    encoding_mode, arena, &transition_semantic, &branch, ctx,
		    frame.state, edge_index, capture_writes,
		    capture_failure_owner, 0,
		    &output_batch) == ONIBI_ACTION_FAIL) {
		onibi_dynamic_output_queue_only(arena, output_batch, ctx);
		continue;
	    }
	    if (edge->destination == ONIBI_ACCEPT_STATE) {
		if (required_end < 0 || next_position == required_end) {
		    OnibiDynamicFrame next = {ONIBI_ACCEPT_STATE, next_position,
					      branch, child_cycle_root,
					      next_previous_position};
		    next.output_batch = output_batch;
		    onibi_dynamic_stack_push(arena, next);
		    continue;
		}
	    }
	    if (edge->destination < header->state_count) {
		OnibiDynamicFrame next = {edge->destination, next_position,
					  branch, child_cycle_root,
					  next_previous_position};
		next.output_batch = output_batch;
		onibi_dynamic_stack_push(arena, next);
	    }
	    else
		onibi_dynamic_output_queue_only(arena, output_batch, ctx);
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
    rb_encoding *encoding = rb_enc_get(str);
    OnibiEncodingMode encoding_mode = onibi_encoding_mode_for(str, encoding);
    OnibiBytePos matched_previous_position =
	onibi_dynamic_previous_position(str, start, encoding, encoding_mode);
    if (matched_previous_position < 0) return -1;
    return onibi_rseq_dynamic_run(
	rseq, view, str, start, matched_previous_position, RSTRING_LEN(str),
	search_origin, edge_base, edge_count, UINT32_MAX, -1, 0, NULL, NULL,
	NULL, 1, matched_end, accepted_state, semantic_arena, class_stack,
	class_stack_capacity, ctx, &matched_previous_position, NULL, NULL);
}

/* Keep one saved continuation for each endpoint that the absence scan can
 * restore. Each nested scan has its own end bound and previous cursor. */
static int
onibi_dynamic_absence_consume_run(
    VALUE rseq, const OnibiRSeqView *view, VALUE str, OnibiBytePos position,
    OnibiBytePos previous_position, OnibiBytePos active_bound,
    OnibiBytePos search_origin, uint32_t subprogram_id,
    const OnibiSemanticState *input, OnibiSemanticArena *arena,
    unsigned char *class_stack, size_t class_stack_capacity, OnibiExecCtx *ctx,
    size_t *endpoint_base, size_t *endpoint_count,
    const unsigned char *pushed_captures,
    OnibiDynamicAbsenceCaptureWriteLog *capture_writes,
    OnibiDynamicOutputState *scan_output)
{
    if (view->header->subprogram_count == 0) return -1;
    if (subprogram_id == 0 || subprogram_id >= view->header->subprogram_count)
	return -1;
    if (position < 0 || position > active_bound || active_bound < 0 ||
	active_bound > RSTRING_LEN(str) || previous_position < 0 ||
	previous_position > position ||
	!onibi_character_boundary(str, position) ||
	!onibi_character_boundary(str, previous_position) ||
	!onibi_character_boundary(str, active_bound))
	return -1;

    const OnibiSubprogramDesc *subprogram = &view->subprograms[subprogram_id];
    size_t base = arena->absence_endpoint_count;
    OnibiBytePos absent_start = position;
    OnibiBytePos outer_end = active_bound;
    OnibiBytePos aend = outer_end;
    OnibiBytePos probe = position;
    OnibiBytePos sprev = previous_position;
    OnibiSemanticState scan_state = *input;
    int saw_positive = 0;
    rb_encoding *encoding = rb_enc_get(str);
    OnibiEncodingMode encoding_mode = onibi_encoding_mode_for(str, encoding);

    if (scan_output != NULL &&
	scan_output->slot_count != view->header->capture_count * 2U)
	rb_raise(eRegexpError, "absence scan output slot counts do not match");

    if (capture_writes == NULL) return -1;
    capture_writes->owner_subprogram_id = subprogram_id;
    capture_writes->subject = str;
    capture_writes->class_stack = class_stack;
    capture_writes->class_stack_capacity = class_stack_capacity;
    if (input->tag_history != UINT32_MAX) {
	if (input->tag_history >= arena->tag_count) return -1;
	capture_writes->base_history_identity =
	    arena->tags[input->tag_history].logical_id;
    }
    else
	capture_writes->base_history_identity = 0;
    onibi_dynamic_absence_capture_write_relation_suffixes_prepare(
	view, capture_writes, ctx);

    while (probe <= outer_end) {
	if (ctx) {
	    ctx->current_position = probe;
	    ctx->current_previous_position = sprev;
	}
	onibi_exec_charge_work(ctx, 1);

	/* These guards match OP_ABSENT's local end checks. */
	if (absent_start > aend && probe > absent_start) break;
	if (probe >= aend && probe > absent_start) {
	    if (probe > aend) break;
	    uint32_t output_batch = scan_output == NULL
					? 0
					: onibi_dynamic_output_batch_from_state(
					      arena, scan_output, ctx);
	    onibi_dynamic_absence_endpoint_push(arena, probe, sprev,
						&scan_state, output_batch);
	    break;
	}
	int at_outer_end = probe == outer_end;
	if (at_outer_end) {
	    uint32_t output_batch = scan_output == NULL
					? 0
					: onibi_dynamic_output_batch_from_state(
					      arena, scan_output, ctx);
	    onibi_dynamic_absence_endpoint_push(arena, probe, sprev,
						&scan_state, output_batch);
	}
	if (!onibi_character_boundary(str, probe)) {
	    arena->absence_endpoint_count = base;
	    return -1;
	}

	/* MRI saves this endpoint before it runs the forbidden subprogram. */
	size_t endpoint_index = arena->absence_endpoint_count;
	uint32_t output_batch = scan_output == NULL
				    ? 0
				    : onibi_dynamic_output_batch_from_state(
					  arena, scan_output, ctx);
	onibi_dynamic_absence_endpoint_push(arena, probe, sprev, &scan_state,
					    output_batch);
	OnibiSemanticState trial_snapshot = scan_state;
	OnibiSemanticState body_result;
	OnibiSemanticState failed_result = *input;
	OnibiBytePos body_end = probe;
	OnibiBytePos body_previous_position = sprev;
	OnibiBytePos failed_end = probe;
	uint32_t failed_state_id = UINT32_MAX;
	onibi_dynamic_absence_capture_write_log_reset(capture_writes, ctx);
	size_t journal_begin = capture_writes->journal_count;
	OnibiDynamicOutputState *probe_output =
	    scan_output == NULL
		? NULL
		: onibi_dynamic_output_scope_new(arena, scan_output, 1, ctx);
	OnibiDynamicOutputState *saved_output_state =
	    arena->active_output_state;
	uint32_t saved_output_batch = arena->active_output_batch;
	if (probe_output != NULL) {
	    arena->active_output_state = probe_output;
	    arena->active_output_batch = 0;
	}
	int result = onibi_rseq_dynamic_run(
	    rseq, view, str, probe, sprev, aend, search_origin,
	    subprogram->entry_edge_base, subprogram->entry_edge_count,
	    subprogram_id, -1, 0, input, &failed_result, &failed_end, 0,
	    &body_end, &body_result, arena, class_stack, class_stack_capacity,
	    ctx, &body_previous_position, capture_writes, &failed_state_id);
	arena->active_output_state = saved_output_state;
	arena->active_output_batch = saved_output_batch;
	if (result < 0) {
	    capture_writes->journal_count = journal_begin;
	    arena->absence_endpoint_count = base;
	    onibi_dynamic_output_scope_release(arena, probe_output);
	    return -1;
	}
	if (result > 0) {
	    capture_writes->journal_count = journal_begin;
	    if (body_end == probe && probe == absent_start) {
		if (at_outer_end) {
		    onibi_dynamic_output_scope_release(arena, probe_output);
		    break;
		}
		if (capture_writes->registry_parent != NULL &&
		    capture_writes->registry_parent_failure_owner) {
		    onibi_dynamic_absence_capture_write_transfer_history(
			capture_writes->registry_parent, capture_writes, arena,
			body_result.tag_history, ctx);
		    onibi_dynamic_absence_capture_failure_prefix_queue(
			arena, capture_writes->registry_parent, &body_result,
			probe, sprev, probe_output, ctx);
		}
		onibi_dynamic_output_scope_release(arena, probe_output);
		arena->absence_endpoint_count = base;
		return 0;
	    }
	    OnibiSemanticState terminal_state = *input;
	    OnibiBytePos terminal_position = probe;
	    OnibiBytePos forced_end = body_end;
	    OnibiBytePos forced_previous_position = sprev;
	    OnibiSemanticState forced_accept;
	    saved_output_state = arena->active_output_state;
	    saved_output_batch = arena->active_output_batch;
	    arena->active_output_state = NULL;
	    arena->active_output_batch = 0;
	    int forced_status = onibi_rseq_dynamic_run(
		rseq, view, str, probe, sprev, aend, search_origin,
		subprogram->entry_edge_base, subprogram->entry_edge_count,
		subprogram_id, body_end, 0, input, &terminal_state,
		&terminal_position, 0, &forced_end, &forced_accept, arena,
		class_stack, class_stack_capacity, ctx,
		&forced_previous_position, NULL, NULL);
	    arena->active_output_state = saved_output_state;
	    arena->active_output_batch = saved_output_batch;
	    if (forced_status < 0) {
		arena->absence_endpoint_count = base;
		onibi_dynamic_output_scope_release(arena, probe_output);
		return -1;
	    }
	    if (forced_status > 0) terminal_state = forced_accept;
	    onibi_dynamic_absence_filter_captures(
		arena, &body_result, &terminal_state,
		onibi_dynamic_absence_has_active_nullable_repeat(view, arena,
								 &body_result),
		capture_writes, probe_output, pushed_captures, ctx);
	    onibi_dynamic_absence_filter_capture_events(
		arena, &body_result, trial_snapshot.capture_event_history,
		pushed_captures, view->header->capture_count);
	    onibi_dynamic_absence_restore_pushed_tags(
		arena, &body_result, &trial_snapshot, pushed_captures,
		view->header->capture_count, capture_writes, ctx);
	    onibi_dynamic_absence_restore_pushed_capture_files(
		arena, &body_result, &trial_snapshot, pushed_captures,
		view->header->capture_count, 0);
	    saved_output_state = arena->active_output_state;
	    saved_output_batch = arena->active_output_batch;
	    arena->active_output_state = probe_output;
	    arena->active_output_batch = 0;
	    onibi_dynamic_absence_capture_failure_prefix_merge_pending(
		arena, capture_writes, &scan_state, &body_result,
		pushed_captures, ctx);
	    arena->active_output_state = saved_output_state;
	    arena->active_output_batch = saved_output_batch;
	    if (probe_output != NULL) {
		for (size_t i = base; i <= endpoint_index; i++) {
		    onibi_dynamic_output_batch_append_transcript(
			arena, arena->absence_endpoints[i].output_batch,
			probe_output, ctx);
		}
		onibi_dynamic_output_replay_transcript(scan_output,
						       probe_output, ctx);
	    }
	    /* The last positive probe sets output captures for all earlier
	     * continuations. Keep each endpoint's pre-body registers for
	     * backreferences. */
	    for (size_t i = base; i <= endpoint_index; i++) {
		if (ctx != NULL) {
		    ctx->current_position =
			arena->absence_endpoints[i].position;
		    ctx->current_previous_position =
			arena->absence_endpoints[i].previous_position;
		}
		onibi_exec_charge_work(ctx, 1);
		onibi_dynamic_absence_endpoint_publish_body_captures(
		    &arena->absence_endpoints[i], &body_result);
	    }
	    OnibiBytePos scan_reported_start = scan_state.reported_start;
	    scan_state.condition_captures = body_result.condition_captures;
	    scan_state.tag_history = body_result.tag_history;
	    scan_state.capture_event_history =
		body_result.capture_event_history;
	    scan_state.capture_event_dependency =
		body_result.capture_event_dependency;
	    scan_state.order = body_result.order;
	    scan_state.reported_start = scan_reported_start;
	    saw_positive = 1;
	    onibi_dynamic_output_scope_release(arena, probe_output);
	    if (body_end == probe) {
		if (probe < aend) aend = probe;
	    }
	    else if (body_previous_position < aend)
		aend = body_previous_position;
	}
	else {
	    int output_selected = 0;
	    size_t journal_end = capture_writes->journal_count;
	    if (journal_end < journal_begin)
		rb_raise(eRegexpError,
			 "absence capture journal order is invalid");
	    if (failed_end != aend && saw_positive) {
		OnibiSemanticState before =
		    arena->absence_endpoints[endpoint_index].semantic;
		(void)onibi_dynamic_absence_capture_journal_publish_to_batch(
		    view, arena,
		    &arena->absence_endpoints[endpoint_index].semantic, &before,
		    &failed_result, capture_writes, pushed_captures,
		    view->header->capture_count, journal_begin, journal_end,
		    failed_state_id, failed_end, aend,
		    arena->absence_endpoints[endpoint_index].output_batch, ctx);
		onibi_dynamic_absence_output_journal_append_to_batch(
		    capture_writes, arena,
		    arena->absence_endpoints[endpoint_index].output_batch, ctx);
		before = scan_state;
		(void)onibi_dynamic_absence_capture_journal_publish(
		    view, arena, &scan_state, &before, &failed_result,
		    capture_writes, pushed_captures,
		    view->header->capture_count, journal_begin, journal_end,
		    failed_state_id, failed_end, aend, ctx);
		output_selected = 1;
	    }
	    else if (failed_end == aend) {
		if (!saw_positive) {
		    if (!at_outer_end) {
			for (size_t i = base; i < arena->absence_endpoint_count;
			     i++) {
			    OnibiSemanticState before =
				arena->absence_endpoints[i].semantic;
			    (void)
				onibi_dynamic_absence_capture_journal_publish_to_batch(
				    view, arena,
				    &arena->absence_endpoints[i].semantic,
				    &before, &failed_result, capture_writes,
				    pushed_captures,
				    view->header->capture_count, journal_begin,
				    journal_end, failed_state_id, failed_end,
				    aend,
				    arena->absence_endpoints[i].output_batch,
				    ctx);
			    onibi_dynamic_absence_output_journal_append_to_batch(
				capture_writes, arena,
				arena->absence_endpoints[i].output_batch, ctx);
			}
			OnibiSemanticState before = scan_state;
			(void)onibi_dynamic_absence_capture_journal_publish(
			    view, arena, &scan_state, &before, &failed_result,
			    capture_writes, pushed_captures,
			    view->header->capture_count, journal_begin,
			    journal_end, failed_state_id, failed_end, aend,
			    ctx);
			output_selected = 1;
		    }
		}
		else {
		    OnibiSemanticState before =
			arena->absence_endpoints[endpoint_index].semantic;
		    (void)
			onibi_dynamic_absence_capture_journal_publish_to_batch(
			    view, arena,
			    &arena->absence_endpoints[endpoint_index].semantic,
			    &before, &failed_result, capture_writes,
			    pushed_captures, view->header->capture_count,
			    journal_begin, journal_end, failed_state_id,
			    failed_end, aend,
			    arena->absence_endpoints[endpoint_index]
				.output_batch,
			    ctx);
		    onibi_dynamic_absence_output_journal_append_to_batch(
			capture_writes, arena,
			arena->absence_endpoints[endpoint_index].output_batch,
			ctx);
		    before = scan_state;
		    (void)onibi_dynamic_absence_capture_journal_publish(
			view, arena, &scan_state, &before, &failed_result,
			capture_writes, pushed_captures,
			view->header->capture_count, journal_begin, journal_end,
			failed_state_id, failed_end, aend, ctx);
		    output_selected = 1;
		}
	    }
	    else if (!saw_positive) {
		OnibiSemanticState before = scan_state;
		(void)onibi_dynamic_absence_capture_journal_publish(
		    view, arena, &scan_state, &before, &failed_result,
		    capture_writes, pushed_captures,
		    view->header->capture_count, journal_begin, journal_end,
		    failed_state_id, failed_end, aend, ctx);
		output_selected = 1;
	    }
	    if (output_selected)
		onibi_dynamic_absence_output_journal_replay(capture_writes,
							    scan_output, ctx);
	    onibi_dynamic_output_scope_release(arena, probe_output);
	}

	if (probe >= outer_end) break;
	OnigCodePoint codepoint;
	long width = 0;
	if (!onibi_rseq_decode_character(str, probe, encoding, encoding_mode,
					 &codepoint, &width) ||
	    width <= 0 || probe + width > outer_end) {
	    arena->absence_endpoint_count = base;
	    return -1;
	}
	sprev = probe;
	probe += width;
    }

    size_t write = base;
    size_t end = arena->absence_endpoint_count;
    for (size_t i = base; i < end; i++) {
	OnibiDynamicAbsenceEndpoint endpoint = arena->absence_endpoints[i];
	if (endpoint.position != absent_start && endpoint.position > aend)
	    continue;
	arena->absence_endpoints[write++] = endpoint;
    }
    arena->absence_endpoint_count = write;
    *endpoint_base = base;
    *endpoint_count = write - base;
    if (capture_writes->registry_parent != NULL) {
	for (size_t i = base; i < write; i++)
	    onibi_dynamic_absence_capture_write_transfer_history(
		capture_writes->registry_parent, capture_writes, arena,
		arena->absence_endpoints[i].semantic.tag_history, ctx);
    }
    return *endpoint_count > 0 ? 1 : 0;
}

static VALUE
onibi_dynamic_absence_consume_body(VALUE opaque)
{
    OnibiDynamicAbsenceCall *call =
	(OnibiDynamicAbsenceCall *)(uintptr_t)opaque;
    call->capture_writes.capture_count = call->view->header->capture_count;
    if (call->capture_writes.capture_count != 0) {
	onibi_exec_charge_work(call->ctx, call->capture_writes.capture_count);
	call->capture_writes.pending_failure_captures =
	    ruby_xcalloc(call->capture_writes.capture_count, 1);
    }
    call->saved_output_state = call->arena->active_output_state;
    call->saved_output_batch = call->arena->active_output_batch;
    if (call->saved_output_state != NULL) {
	call->scan_output = onibi_dynamic_output_scope_new(
	    call->arena, call->saved_output_state, 1, call->ctx);
	call->arena->active_output_state = call->scan_output;
	call->arena->active_output_batch = 0;
    }
    call->result = onibi_dynamic_absence_consume_run(
	call->rseq, call->view, call->str, call->position,
	call->previous_position, call->active_bound, call->search_origin,
	call->subprogram_id, call->input, call->arena, call->class_stack,
	call->class_stack_capacity, call->ctx, call->endpoint_base,
	call->endpoint_count, call->pushed_captures, &call->capture_writes,
	call->scan_output);
    call->arena->active_output_state = call->saved_output_state;
    call->arena->active_output_batch = call->saved_output_batch;
    if (call->result == 0 && call->scan_output != NULL &&
	call->saved_output_state != NULL) {
	if (call->saved_output_batch != 0)
	    onibi_dynamic_output_batch_append_transcript(
		call->arena, call->saved_output_batch, call->scan_output,
		call->ctx);
	else
	    onibi_dynamic_output_replay_transcript(
		call->saved_output_state, call->scan_output, call->ctx);
    }
    return Qnil;
}

static VALUE
onibi_dynamic_absence_consume_ensure(VALUE opaque)
{
    OnibiDynamicAbsenceCall *call =
	(OnibiDynamicAbsenceCall *)(uintptr_t)opaque;
    call->arena->active_output_state = call->saved_output_state;
    call->arena->active_output_batch = call->saved_output_batch;
    onibi_dynamic_output_scope_release(call->arena, call->scan_output);
    call->scan_output = NULL;
    ruby_xfree(call->pushed_captures);
    ruby_xfree(call->capture_writes.events);
    ruby_xfree(call->capture_writes.journal);
    ruby_xfree(call->capture_writes.output_journal);
    ruby_xfree(call->capture_writes.path);
    ruby_xfree(call->capture_writes.previous_path);
    ruby_xfree(call->capture_writes.failure_paths);
    ruby_xfree(call->capture_writes.failure_prefixes);
    ruby_xfree(call->capture_writes.pending_failure_captures);
    ruby_xfree(call->capture_writes.relation_suffix_heads);
    ruby_xfree(call->capture_writes.relation_suffixes);
    call->pushed_captures = NULL;
    call->capture_writes.events = NULL;
    call->capture_writes.journal = NULL;
    call->capture_writes.output_journal = NULL;
    call->capture_writes.path = NULL;
    call->capture_writes.previous_path = NULL;
    call->capture_writes.failure_paths = NULL;
    call->capture_writes.failure_prefixes = NULL;
    call->capture_writes.pending_failure_captures = NULL;
    call->capture_writes.relation_suffix_heads = NULL;
    call->capture_writes.relation_suffixes = NULL;
    return Qnil;
}

static int
onibi_dynamic_absence_consume(
    VALUE rseq, const OnibiRSeqView *view, VALUE str, OnibiBytePos position,
    OnibiBytePos previous_position, OnibiBytePos active_bound,
    OnibiBytePos search_origin, uint32_t subprogram_id,
    const OnibiSemanticState *input, OnibiSemanticArena *arena,
    unsigned char *class_stack, size_t class_stack_capacity, OnibiExecCtx *ctx,
    size_t *endpoint_base, size_t *endpoint_count,
    OnibiDynamicAbsenceCaptureWriteLog *parent_capture_writes,
    int parent_capture_failure_owner)
{
    OnibiDynamicAbsenceCall call;
    memset(&call, 0, sizeof(call));
    call.rseq = rseq;
    call.view = view;
    call.str = str;
    call.position = position;
    call.previous_position = previous_position;
    call.active_bound = active_bound;
    call.search_origin = search_origin;
    call.subprogram_id = subprogram_id;
    call.input = input;
    call.arena = arena;
    call.class_stack = class_stack;
    call.class_stack_capacity = class_stack_capacity;
    call.ctx = ctx;
    call.endpoint_base = endpoint_base;
    call.endpoint_count = endpoint_count;
    call.capture_writes.registry_parent = parent_capture_writes;
    call.capture_writes.registry_parent_failure_owner =
	parent_capture_failure_owner;
    call.result = -1;

    uint32_t capture_count = view->header->capture_count;
    if ((view->header->features & ONIBI_RSEQ_FEATURE_CAPTURE_ROLLBACK) != 0 &&
	capture_count != 0) {
	call.pushed_captures = ruby_xcalloc(capture_count, 1);
	for (uint32_t i = 0; i < view->header->action_count; i++) {
	    const OnibiRAction *action = &view->actions[i];
	    if (action->op != ONIBI_RA_CAPTURE ||
		(action->flags & ONIBI_RA_CAPTURE_OPEN_START_PUSH) == 0 ||
		(action->arg16 & 1U) != 0)
		continue;
	    uint32_t capture = action->arg16 / 2U;
	    if (capture < capture_count) call.pushed_captures[capture] = 1;
	}
    }
    rb_ensure(onibi_dynamic_absence_consume_body, (VALUE)(uintptr_t)&call,
	      onibi_dynamic_absence_consume_ensure, (VALUE)(uintptr_t)&call);
    return call.result;
}

static OnibiActionResult
onibi_dynamic_assert_subprogram(
    OnibiExecCtx *ctx, const OnibiRAction *action, OnibiBytePos position,
    const OnibiSemanticState *predecessor, OnibiSemanticState *successor,
    OnibiDynamicAbsenceCaptureWriteLog *capture_writes,
    int capture_failure_owner)
{
    if (action->arg32 == 0 ||
	action->arg32 >= ctx->view->header->subprogram_count)
	return ONIBI_ACTION_FAIL;
    const OnibiSubprogramDesc *subprogram =
	&ctx->view->subprograms[action->arg32];
    int positive = action->flags == 1 || action->flags == 5;
    int lookbehind = action->arg16 == ONIBI_RAP_LOOKBEHIND;
    OnibiSemanticArena *arena = &ctx->semantic_arena;
    OnibiDynamicOutputState *parent_output = arena->active_output_state;
    uint32_t parent_batch = arena->active_output_batch;
    OnibiDynamicOutputState *assertion_output = NULL;

    if (parent_output != NULL) {
	assertion_output =
	    onibi_dynamic_output_scope_new(arena, parent_output, 1, ctx);
	if (assertion_output->slot_count != parent_output->slot_count)
	    rb_raise(eRegexpError,
		     "dynamic assertion output slot counts do not match");
    }
    OnibiSemanticCheckpoint checkpoint = onibi_semantic_checkpoint_save(arena);
    uint32_t trial_count = lookbehind ? subprogram->width_count : 1U;
    for (uint32_t i = 0; i < trial_count; i++) {
	OnibiBytePos trial_start = position;
	OnibiBytePos trial_previous = ctx->current_previous_position;
	OnibiBytePos required_end = -1;
	if (lookbehind) {
	    uint32_t width =
		ctx->view->lookbehind_widths[subprogram->width_base + i];
	    if (!onibi_tagged_lookbehind_start(ctx, position, width,
					       &trial_start))
		continue;
	    trial_previous = onibi_dynamic_previous_position(
		ctx->subject, trial_start, ctx->encoding, ctx->encoding_mode);
	    if (trial_previous < 0) continue;
	    required_end = position;
	}
	OnibiSemanticState assertion_result;
	OnibiBytePos assertion_end = trial_start;
	OnibiBytePos assertion_previous = trial_previous;
	OnibiDynamicOutputState *saved_output = arena->active_output_state;
	uint32_t saved_batch = arena->active_output_batch;
	if (assertion_output != NULL) {
	    onibi_dynamic_output_copy_registers(assertion_output, parent_output,
						ctx);
	    arena->active_output_state = assertion_output;
	    onibi_dynamic_output_apply_batch(assertion_output, arena,
					     parent_batch, ctx);
	    assertion_output->transcript_count = 0;
	    arena->active_output_batch = 0;
	}
	int result = onibi_rseq_dynamic_run(
	    ctx->rseq, ctx->view, ctx->subject, trial_start, trial_previous,
	    ctx->active_bound, ctx->search_origin, subprogram->entry_edge_base,
	    subprogram->entry_edge_count, action->arg32, required_end, 0,
	    predecessor, NULL, NULL, 0, &assertion_end, &assertion_result,
	    arena, ctx->class_stack, ctx->class_stack_capacity, ctx,
	    &assertion_previous, capture_writes, NULL);
	arena->active_output_state = saved_output;
	arena->active_output_batch = saved_batch;
	if (result < 0) {
	    onibi_semantic_checkpoint_restore(arena, &checkpoint);
	    onibi_dynamic_output_scope_release(arena, assertion_output);
	    return ONIBI_ACTION_FAIL;
	}
	if (result > 0) {
	    if (!positive) {
		onibi_semantic_checkpoint_restore(arena, &checkpoint);
		onibi_dynamic_output_scope_release(arena, assertion_output);
		if (capture_failure_owner && capture_writes != NULL)
		    onibi_dynamic_absence_capture_failure_prefix_queue(
			arena, capture_writes, predecessor, position,
			ctx->current_previous_position, NULL, ctx);
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
		if (assertion_output != NULL) {
		    if (parent_batch != 0)
			onibi_dynamic_output_batch_append_transcript(
			    arena, parent_batch, assertion_output, ctx);
		    else
			onibi_dynamic_output_replay_transcript(
			    parent_output, assertion_output, ctx);
		}
	    }
	    onibi_dynamic_output_scope_release(arena, assertion_output);
	    return ONIBI_ACTION_SUCCESS;
	}
	onibi_semantic_checkpoint_restore(arena, &checkpoint);
    }
    onibi_dynamic_output_scope_release(arena, assertion_output);
    if (positive) {
	if (capture_failure_owner && capture_writes != NULL)
	    onibi_dynamic_absence_capture_failure_prefix_queue(
		arena, capture_writes, predecessor, position,
		ctx->current_previous_position, NULL, ctx);
	return ONIBI_ACTION_FAIL;
    }
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
	if (action->op == ONIBI_RA_CAPTURE_RELATION) continue;
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
			      OnibiRawMatch *raw_match, uint32_t capture_slots,
			      int require_complete_pairs, OnibiExecCtx *ctx)
{
    if (capture_slots > SIZE_MAX / sizeof(uint32_t)) return 0;
    if (require_complete_pairs && ctx != NULL && raw_match->num_regs > 1U) {
	ctx->current_position = ctx->matched_end;
	onibi_exec_charge_work(ctx, raw_match->num_regs - 1U);
    }
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

    if (require_complete_pairs) {
	for (uint32_t reg = 1; reg < raw_match->num_regs; reg++) {
	    if (raw_match->beg[reg] < 0 || raw_match->end[reg] < 0) {
		raw_match->beg[reg] = -1;
		raw_match->end[reg] = -1;
	    }
	}
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
				       accepted, ctx, UINT32_MAX, UINT32_MAX,
				       NULL, 0) == ONIBI_ACTION_SUCCESS) {
	    return 1;
	}
    }
    if (state->edge_count != 0) return 0;
    *accepted = *predecessor;
    return 1;
}

static int
onibi_dynamic_output_materialize(OnibiExecCtx *ctx)
{
    OnibiDynamicOutputState *output = &ctx->semantic_arena.output_root;
    OnibiRawMatch *raw_match = ctx->raw_match;
    uint32_t capture_count = ctx->program->capture_count;
    if (output->slot_count != capture_count * 2U ||
	raw_match->num_regs != capture_count + 1U)
	return 0;
    OnibiBytePos length = RSTRING_LEN(ctx->subject);
    for (uint32_t capture = 0; capture < capture_count; capture++) {
	uint32_t begin_slot = capture * 2U;
	OnibiBytePos begin = output->slots[begin_slot];
	OnibiBytePos end = output->slots[begin_slot + 1U];
	if (begin == -1 || end == -1) {
	    if (begin < -1 || end < -1) return 0;
	    begin = end = -1;
	}
	else if (begin < 0 || end < 0 || begin > length || end > length ||
		 !onibi_character_boundary(ctx->subject, begin) ||
		 !onibi_character_boundary(ctx->subject, end))
	    return 0;
	ctx->current_position = ctx->matched_end;
	onibi_exec_charge_work(ctx, 1);
	raw_match->beg[capture + 1U] = begin;
	raw_match->end[capture + 1U] = end;
    }
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
	if (onibi_apply_action_program(
		view, edge, str, start, ctx->search_origin, ctx->encoding,
		ctx->encoding_mode, arena, &predecessor, &branch, ctx,
		UINT32_MAX, UINT32_MAX, NULL, 0) == ONIBI_ACTION_FAIL)
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
			&branch, ctx, UINT32_MAX, UINT32_MAX, NULL,
			0) == ONIBI_ACTION_FAIL)
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
	    !onibi_dynamic_output_materialize(ctx)) {
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
	    !onibi_tagged_materialize_tags(
		&ctx->semantic_arena, &accepted, ctx->raw_match,
		ctx->program->capture_count * 2U, 1, ctx)) {
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
