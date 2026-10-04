#include "onibi_encoding_internal.h"
#include "onibi_exec_internal.h"
#include "onibi_ruby_api_internal.h"

#include <limits.h>

typedef struct {
    OnibiBytePos *ranges;
    size_t bytes;
} OnibiCaptureRangeOwner;

static void
onibi_capture_range_owner_release(OnibiCaptureRangeOwner *owner)
{
    if (owner == NULL) return;
    OnibiBytePos *ranges = owner->ranges;
    owner->ranges = NULL;
    owner->bytes = 0;
    if (ranges != NULL) ruby_xfree(ranges);
}

static void
onibi_capture_range_owner_free(void *opaque)
{
    OnibiCaptureRangeOwner *owner = (OnibiCaptureRangeOwner *)opaque;
    if (owner == NULL) return;
    onibi_capture_range_owner_release(owner);
    ruby_xfree(owner);
}

static size_t
onibi_capture_range_owner_size(const void *opaque)
{
    const OnibiCaptureRangeOwner *owner =
	(const OnibiCaptureRangeOwner *)opaque;
    if (owner == NULL) return 0;
    if (owner->bytes > SIZE_MAX - sizeof(*owner)) return SIZE_MAX;
    return sizeof(*owner) + owner->bytes;
}

static const rb_data_type_t onibi_capture_range_owner_type = {
    .wrap_struct_name = "OnibiCaptureRangeOwner",
    .function =
	{
	    .dfree = onibi_capture_range_owner_free,
	    .dsize = onibi_capture_range_owner_size,
	},
};

static VALUE
onibi_capture_range_owner_new(size_t bytes, OnibiBytePos **ranges_out)
{
    VALUE value =
	rb_data_typed_object_zalloc(rb_cObject, sizeof(OnibiCaptureRangeOwner),
				    &onibi_capture_range_owner_type);
    OnibiCaptureRangeOwner *owner = RTYPEDDATA_DATA(value);
    owner->ranges = ruby_xmalloc(bytes);
    owner->bytes = bytes;
    *ranges_out = owner->ranges;
    RB_GC_GUARD(value);
    return value;
}

static void
onibi_capture_range_owner_release_value(VALUE value)
{
    OnibiCaptureRangeOwner *owner = RTYPEDDATA_DATA(value);
    onibi_capture_range_owner_release(owner);
}

/* The search loop receives byte offsets, but a multibyte subject has only
 * character boundaries as valid candidate starts.  The input eligibility
 * gate rejects broken multibyte strings before this helper runs. */
static int
onibi_search_candidate_origin(VALUE str, OnibiBytePos *origin,
			      rb_encoding *encoding,
			      OnibiEncodingMode encoding_mode)
{
    OnibiBytePos length = RSTRING_LEN(str);
    if (*origin > length) return 0;
    if (*origin == length || encoding_mode == ONIBI_ENC_ASCII_7BIT ||
	encoding_mode == ONIBI_ENC_SINGLE_BYTE ||
	onibi_character_boundary(str, *origin))
	return 1;

    const char *begin = RSTRING_PTR(str);
    const char *current = begin + *origin;
    const char *end = begin + length;
    const char *next = rb_enc_right_char_head(begin, current, end, encoding);
    if (next > current && next <= end) {
	*origin = (OnibiBytePos)(next - begin);
	return 1;
    }

    /* This is unreachable after onibi_vm_input_eligible accepted the input.
     * Do not enter an interior byte if an encoding callback violates that
     * contract. */
    return 0;
}

static int
onibi_search_candidate_next(VALUE str, OnibiBytePos *start,
			    rb_encoding *encoding,
			    OnibiEncodingMode encoding_mode)
{
    OnibiBytePos length = RSTRING_LEN(str);
    if (*start >= length) return 0;
    if (encoding_mode == ONIBI_ENC_ASCII_7BIT ||
	encoding_mode == ONIBI_ENC_SINGLE_BYTE) {
	*start += 1;
	return 1;
    }

    OnigCodePoint codepoint;
    long width;
    if (onibi_rseq_decode_character(str, *start, encoding, encoding_mode,
				    &codepoint, &width) &&
	width > 0) {
	*start += width;
	return 1;
    }

    /* Broken input is rejected before native execution.  Skip the rest if an
     * encoding callback still fails, so this loop never visits an interior
     * byte in a character encoding. */
    return 0;
}

/* With fixed byte distances 1/1, a MAP hit can admit only the candidate
 * immediately before it.  Visit those candidates in the normal forward
 * character order.  This is the same inclusive [low, high] interval that
 * MRI forms after its character-head adjustment of low. */
static int
onibi_search_class_tail_map_candidate(VALUE str, const OnibiRSeqHeader *header,
				      OnibiBytePos candidate,
				      rb_encoding *encoding)
{
    uint64_t length = (uint64_t)RSTRING_LEN(str);
    if (candidate < 0 || (uint64_t)candidate > length) return 0;
    uint64_t candidate_offset = (uint64_t)candidate;
    uint64_t dmin = header->class_tail_map_dmin_bytes;
    uint64_t dmax = header->class_tail_map_dmax_bytes;
    if (dmin > length - candidate_offset) return 0;

    uint64_t hit = candidate_offset + dmin;
    uint64_t hit_limit = length;
    if ((header->class_tail_map_flags &
	 ONIBI_RSEQ_CLASS_TAIL_MAP_FLAG_ANCHORED) != 0) {
	if (candidate_offset != 0) return 0;
	/* MRI scans one candidate byte plus dmax bytes for an anchored MAP. */
	uint64_t anchored_limit = dmax + 1U;
	if (anchored_limit < hit_limit) hit_limit = anchored_limit;
    }

    /* MAP search treats its upper hit bound as exclusive. */
    if (hit >= hit_limit || hit >= length ||
	!onibi_character_boundary(str, (OnibiBytePos)hit))
	return 0;
    const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(str);
    if (bytes[hit] != header->class_tail_map_byte) return 0;

    /* Rebuild the byte candidate interval.  MRI leaves high raw and moves
     * only low to the next character head.  Saturate before subtraction. */
    uint64_t low = hit < dmax ? 0 : hit - dmax;
    uint64_t high = hit < dmin ? 0 : hit - dmin;
    if (!onibi_character_boundary(str, (OnibiBytePos)low)) {
	const char *begin = RSTRING_PTR(str);
	const char *end = begin + (size_t)length;
	const char *adjusted =
	    rb_enc_right_char_head(begin, begin + (size_t)low, end, encoding);
	if (adjusted < begin || adjusted > end) return 0;
	low = (uint64_t)(adjusted - begin);
    }
    return candidate_offset >= low && candidate_offset <= high;
}

static void
onibi_frontier_release(OnibiFrontier *frontier)
{
    ruby_xfree(frontier->states);
    ruby_xfree(frontier->semantics);
    ruby_xfree(frontier->failure_owners);
    ruby_xfree(frontier->hashes);
    ruby_xfree(frontier->key_buckets);
    ruby_xfree(frontier->membership);
    ruby_xfree(frontier->histories);
    memset(frontier, 0, sizeof(*frontier));
}

static void
onibi_exec_ctx_release(OnibiExecCtx *ctx)
{
    onibi_frontier_release(&ctx->current);
    onibi_frontier_release(&ctx->next);
    for (size_t i = 0; i < ctx->assertion_frontier_count; i++)
	onibi_frontier_release(&ctx->assertion_frontiers[i]);
    ruby_xfree(ctx->assertion_frontiers);
    ctx->assertion_frontiers = NULL;
    ctx->assertion_frontier_count = 0;
    ctx->assertion_frontier_capacity = 0;
    ctx->assertion_depth = 0;
    ruby_xfree(ctx->tags.data);
    ctx->tags.data = NULL;
    ctx->tags.count = 0;
    ctx->tags.capacity = 0;
    onibi_semantic_arena_release(&ctx->semantic_arena);
    ruby_xfree(ctx->class_stack);
    ctx->class_stack = NULL;
    ctx->class_stack_capacity = 0;
}

static VALUE
onibi_byte_slice(VALUE str, OnibiBytePos start, OnibiBytePos end)
{
    if (start < 0 || end < start || end > RSTRING_LEN(str))
	rb_raise(eRegexpError, "Onibi returned an invalid byte range");
    return rb_str_subseq(str, start, end - start);
}

static uint32_t
onibi_public_capture_count(const onibi_regexp_t *obj)
{
    if (obj == NULL || NIL_P(obj->rseq) || !obj->rseq_view_valid ||
	obj->rseq_view.header == NULL)
	return 0;
    return obj->rseq_view.header->capture_count;
}

static OnibiExecStatus
onibi_vm_search_body(VALUE self, VALUE str, OnibiBytePos search_origin,
		     OnibiRawMatch *raw_match, OnibiBytePos *attempt_start_out)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(str);
    OnibiExecCtx exec_ctx;
    memset(&exec_ctx, 0, sizeof(exec_ctx));
    exec_ctx.regexp = self;
    exec_ctx.subject = str;
    exec_ctx.raw_match = raw_match;
    if (!onibi_raw_match_reset(raw_match)) {
	onibi_diagnostics.executor_error_kind = ONIBI_EXECUTOR_ERROR_CONTRACT;
	return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
    }
    exec_ctx.search_origin = search_origin < 0 ? 0 : search_origin;
    exec_ctx.reported_start = exec_ctx.search_origin;
    onibi_set_deadline(obj->timeout_seconds);
    exec_ctx.timeout_deadline = onibi_deadline_ns;
    onibi_active_exec_ctx = &exec_ctx;
    if (search_origin < 0) search_origin = 0;
    if (search_origin > RSTRING_LEN(str)) {
	onibi_exec_ctx_release(&exec_ctx);
	onibi_deadline_ns = 0;
	onibi_active_exec_ctx = NULL;
	return ONIBI_EXEC_STATUS_NO_MATCH;
    }

    if (!(obj->options & ONIBI_OPT_NOENCODING) && !NIL_P(obj->rseq))
	(void)rb_reg_prepare_re(obj->regexp, str);

    /* Select MRI only before the first executor call. */
    if (NIL_P(obj->rseq)) {
	if ((obj->options & ONIBI_OPT_NOENCODING) != 0)
	    onibi_diagnostics.runtime_fallback_reason =
		ONIBI_RUNTIME_FALLBACK_NOENCODING;
	onibi_diagnostics.fallback++;
	onibi_exec_ctx_release(&exec_ctx);
	onibi_deadline_ns = 0;
	onibi_active_exec_ctx = NULL;
	return ONIBI_EXEC_STATUS_FALLBACK;
    }
    if (!obj->rseq_view_valid || obj->rseq_view.header == NULL) {
	onibi_diagnostics.executor_error_kind =
	    ONIBI_EXECUTOR_ERROR_MALFORMED_PROGRAM;
	onibi_exec_ctx_release(&exec_ctx);
	onibi_deadline_ns = 0;
	onibi_active_exec_ctx = NULL;
	return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
    }
    OnibiRuntimeFallbackReason input_reason = onibi_vm_input_eligible(obj, str);
    if ((obj->options & ONIBI_OPT_NOENCODING) != 0 ||
	input_reason != ONIBI_RUNTIME_FALLBACK_NONE ||
	(!rb_enc_str_asciionly_p(str) && !onibi_valid_encoding(str))) {
	/* Input eligibility is the only runtime fallback decision. */
	onibi_diagnostics.runtime_fallback_reason =
	    input_reason != ONIBI_RUNTIME_FALLBACK_NONE
		? input_reason
		: ONIBI_RUNTIME_FALLBACK_INPUT_INELIGIBLE;
	onibi_diagnostics.fallback++;
	onibi_exec_ctx_release(&exec_ctx);
	onibi_deadline_ns = 0;
	onibi_active_exec_ctx = NULL;
	return ONIBI_EXEC_STATUS_FALLBACK;
    }

    {
	/* The immutable RSeq was validated and its physical execution view was
	   built during initialize.  Do not rescan the program on each match. */
	exec_ctx.encoding = rb_enc_get(str);
	exec_ctx.encoding_mode =
	    onibi_encoding_mode_for(str, exec_ctx.encoding);
	exec_ctx.class_stack_capacity = obj->rseq_view.class_stack_capacity;
	if (exec_ctx.class_stack_capacity != 0)
	    exec_ctx.class_stack = ruby_xmalloc(exec_ctx.class_stack_capacity);
	if (obj->rseq_view.header->exec_kind != ONIBI_EXEC_REGULAR)
	    onibi_semantic_live_captures_prepare(&exec_ctx.semantic_arena,
						 &obj->rseq_view);
	OnibiBytePos start = search_origin;
	OnibiBytePos maximum_start = RSTRING_LEN(str);
	uint64_t subject_length = (uint64_t)RSTRING_LEN(str);
	if ((obj->rseq_view.header->features &
	     ONIBI_RSEQ_FEATURE_END_SEARCH_BOUND) != 0) {
	    uint64_t bound = obj->rseq_view.header->end_search_bound_bytes;
	    uint64_t minimum_start =
		subject_length > bound ? subject_length - bound : 0;
	    if (minimum_start > (uint64_t)start)
		start = (OnibiBytePos)minimum_start;
	}
	if ((obj->rseq_view.header->features &
	     ONIBI_RSEQ_FEATURE_SEARCH_ORIGIN_BOUND) != 0) {
	    uint64_t origin = (uint64_t)search_origin;
	    uint64_t delta =
		obj->rseq_view.header->search_origin_bound_delta_bytes;
	    uint64_t remaining = subject_length - origin;
	    if (delta > remaining) delta = remaining;
	    maximum_start = (OnibiBytePos)(origin + delta);
	}
	int has_end_search_fold_direct_capture =
	    (obj->rseq_view.header->features &
	     ONIBI_RSEQ_FEATURE_END_SEARCH_FOLD_DIRECT_CAPTURE) != 0;
	uint64_t direct_fold_range = 0;
	if (has_end_search_fold_direct_capture) {
	    uint64_t dmax = obj->rseq_view.header->end_search_fold_dmax_bytes;
	    uint64_t dmin = obj->rseq_view.header->end_search_fold_dmin_bytes;
	    uint64_t minimum_start =
		subject_length > dmax ? subject_length - dmax : 0;
	    if (minimum_start > (uint64_t)start)
		start = (OnibiBytePos)minimum_start;
	    if (subject_length >= dmin)
		direct_fold_range = subject_length - dmin + 1U;
	}
	int candidate_valid = onibi_search_candidate_origin(
	    str, &start, exec_ctx.encoding, exec_ctx.encoding_mode);
	if (has_end_search_fold_direct_capture) {
	    uint64_t dmin = obj->rseq_view.header->end_search_fold_dmin_bytes;
	    uint64_t adjusted_start = (uint64_t)start;
	    if (subject_length < dmin || adjusted_start > direct_fold_range)
		candidate_valid = 0;
	    else if (adjusted_start == direct_fold_range)
		maximum_start = (OnigPosition)direct_fold_range;
	    else
		maximum_start = (OnigPosition)(direct_fold_range - 1U);
	}
	else if ((obj->rseq_view.header->features &
		  ONIBI_RSEQ_FEATURE_END_SEARCH_MINIMUM) != 0) {
	    uint64_t minimum_distance =
		obj->rseq_view.header->end_search_minimum_bytes;
	    uint64_t origin = (uint64_t)search_origin;
	    if (subject_length < minimum_distance) {
		candidate_valid = 0;
	    }
	    else {
		uint64_t range = subject_length - minimum_distance + 1U;
		if (origin > range)
		    candidate_valid = 0;
		else if (origin == range)
		    maximum_start = (OnibiBytePos)range;
		else
		    maximum_start = (OnibiBytePos)(range - 1U);
	    }
	}
	int use_class_tail_map = (obj->rseq_view.header->features &
				  ONIBI_RSEQ_FEATURE_CLASS_TAIL_MAP) != 0 &&
				 exec_ctx.encoding == rb_utf8_encoding();
	for (; candidate_valid && start <= maximum_start;
	     candidate_valid = onibi_search_candidate_next(
		 str, &start, exec_ctx.encoding, exec_ctx.encoding_mode)) {
	    exec_ctx.attempt_start = start;
	    exec_ctx.reported_start = start;
	    exec_ctx.current_position = start;
	    exec_ctx.work_before_poll = ONIBI_POLL_WORK;
	    exec_ctx.program = obj->rseq_view.header;
	    exec_ctx.rseq = obj->rseq;
	    exec_ctx.view = &obj->rseq_view;
	    if (!onibi_character_boundary(str, start)) continue;
	    if (use_class_tail_map &&
		!onibi_search_class_tail_map_candidate(
		    str, obj->rseq_view.header, start, exec_ctx.encoding))
		continue;
	    if (obj->rseq_view.regular_capable &&
		(exec_ctx.program->features &
		 ONIBI_RSEQ_FEATURE_FIRST_BITMAP) != 0 &&
		start < RSTRING_LEN(str) &&
		(exec_ctx.program
		     ->first_bitmap[(unsigned char)RSTRING_PTR(str)[start] >>
				    3] &
		 (1U << ((unsigned char)RSTRING_PTR(str)[start] & 7))) == 0)
		continue;
	    if (obj->rseq_view.regular_capable &&
		exec_ctx.program->prefix_length > 0 &&
		(start + exec_ctx.program->prefix_length > RSTRING_LEN(str) ||
		 memcmp(RSTRING_PTR(str) + start, exec_ctx.program->prefix,
			exec_ctx.program->prefix_length) != 0))
		continue;
	    if (obj->rseq_view.header->exec_kind == ONIBI_EXEC_REGULAR)
		onibi_diagnostics.regular_candidate_starts++;
	    rb_thread_check_ints();
	    onibi_check_deadline();
	    OnibiExecStatus result = onibi_execute(&exec_ctx);
	    if (result == ONIBI_EXEC_STATUS_MATCH) {
		if (attempt_start_out != NULL) *attempt_start_out = start;
		onibi_exec_ctx_release(&exec_ctx);
		onibi_deadline_ns = 0;
		onibi_active_exec_ctx = NULL;
		return ONIBI_EXEC_STATUS_MATCH;
	    }
	    if (result == ONIBI_EXEC_STATUS_INTERNAL_ERROR) {
		onibi_exec_ctx_release(&exec_ctx);
		onibi_deadline_ns = 0;
		onibi_active_exec_ctx = NULL;
		return ONIBI_EXEC_STATUS_INTERNAL_ERROR;
	    }
	}
	onibi_exec_ctx_release(&exec_ctx);
	onibi_deadline_ns = 0;
	onibi_active_exec_ctx = NULL;
	return ONIBI_EXEC_STATUS_NO_MATCH;
    }
}

typedef struct {
    VALUE self, subject;
    OnibiBytePos origin;
    OnibiRawMatch *raw_match;
    OnibiBytePos *attempt_start_out;
    OnibiExecCtx *previous_ctx;
    uint64_t previous_deadline;
} OnibiSearchEnsure;

static VALUE
onibi_vm_search_ensure_call(VALUE opaque)
{
    OnibiSearchEnsure *call = (OnibiSearchEnsure *)(uintptr_t)opaque;
    return INT2NUM(onibi_vm_search_body(call->self, call->subject, call->origin,
					call->raw_match,
					call->attempt_start_out));
}

static VALUE
onibi_vm_search_ensure_cleanup(VALUE opaque)
{
    OnibiSearchEnsure *call = (OnibiSearchEnsure *)(uintptr_t)opaque;
    if (onibi_active_exec_ctx && onibi_active_exec_ctx != call->previous_ctx)
	onibi_exec_ctx_release(onibi_active_exec_ctx);
    onibi_active_exec_ctx = call->previous_ctx;
    onibi_deadline_ns = call->previous_deadline;
    return Qnil;
}

static OnibiExecStatus
onibi_vm_search_with_attempt_start(VALUE self, VALUE str,
				   OnibiBytePos search_origin,
				   OnibiRawMatch *raw_match,
				   OnibiBytePos *attempt_start_out)
{
    if (attempt_start_out != NULL) *attempt_start_out = -1;
    OnibiSearchEnsure call = {
	.self = self,
	.subject = str,
	.origin = search_origin,
	.raw_match = raw_match,
	.attempt_start_out = attempt_start_out,
	.previous_ctx = onibi_active_exec_ctx,
	.previous_deadline = onibi_deadline_ns,
    };
    VALUE result =
	rb_ensure(onibi_vm_search_ensure_call, (VALUE)(uintptr_t)&call,
		  onibi_vm_search_ensure_cleanup, (VALUE)(uintptr_t)&call);
    return NUM2INT(result);
}

static OnibiExecStatus
onibi_vm_search(VALUE self, VALUE str, OnibiBytePos search_origin,
		OnibiRawMatch *raw_match)
{
    return onibi_vm_search_with_attempt_start(self, str, search_origin,
					      raw_match, NULL);
}

typedef struct {
    VALUE self;
    VALUE str;
    VALUE result;
    VALUE snapshot;
    int with_block;
    uint32_t capture_count;
    uint32_t num_regs;
    VALUE range_owner;
    OnibiBytePos *ranges;
    OnibiBytePos *beg;
    OnibiBytePos *end;
} OnibiScanCall;

static VALUE
onibi_scan_yield(OnibiScanCall *call, VALUE value)
{
    VALUE result = rb_yield(value);
    VALUE str = call->str;
    /* MRI permits same-length byte changes. Check length and encoding
     * before any raw range or character advance is used again. */
    if (RSTRING_LEN(str) != RSTRING_LEN(call->snapshot) ||
	rb_enc_get_index(str) != rb_enc_get_index(call->snapshot))
	rb_raise(rb_eRuntimeError, "string modified");
    return result;
}

static VALUE
onibi_scan_fallback_yield(RB_BLOCK_CALL_FUNC_ARGLIST(value, opaque))
{
    (void)argc;
    (void)argv;
    (void)blockarg;
    return onibi_scan_yield((OnibiScanCall *)(uintptr_t)opaque, value);
}

static VALUE
onibi_scan_body(VALUE opaque)
{
    OnibiScanCall *call = (OnibiScanCall *)(uintptr_t)opaque;
    VALUE str = call->str;
    OnibiBytePos *beg = call->beg;
    OnibiBytePos *end = call->end;
    OnibiBytePos origin = 0;
    if (call->with_block) call->snapshot = rb_str_new_frozen(str);

    for (;;) {
	OnibiRawMatch raw_match = {.begin_byte = -1,
				   .end_byte = -1,
				   .num_regs = call->num_regs,
				   .beg = call->beg,
				   .end = call->end};
	OnibiExecStatus status =
	    onibi_vm_search(call->self, str, origin, &raw_match);
	if (status == ONIBI_EXEC_STATUS_INTERNAL_ERROR)
	    rb_raise(eRegexpError, "Onibi execution failed");
	if (status == ONIBI_EXEC_STATUS_FALLBACK) {
	    onibi_regexp_t *obj;
	    TypedData_Get_Struct(call->self, onibi_regexp_t, &onibi_type, obj);
	    if (call->with_block)
		return rb_block_call(str, id_scan, 1, &obj->regexp,
				     onibi_scan_fallback_yield, opaque);
	    VALUE plain = rb_str_dup(call->str);
	    return rb_funcall(plain, id_scan, 1, obj->regexp);
	}
	if (status == ONIBI_EXEC_STATUS_NO_MATCH) break;
	VALUE value;
	if (call->capture_count == 0) {
	    value =
		onibi_byte_slice(str, raw_match.begin_byte, raw_match.end_byte);
	}
	else {
	    VALUE captures = rb_ary_new_capa(call->capture_count);
	    for (uint32_t i = 1; i <= call->capture_count; i++) {
		VALUE capture = (beg[i] < 0 || end[i] < 0)
				    ? Qnil
				    : onibi_byte_slice(str, beg[i], end[i]);
		rb_ary_push(captures, capture);
	    }
	    value = captures;
	}
	if (call->with_block)
	    onibi_scan_yield(call, value);
	else
	    rb_ary_push(call->result, value);
	if (raw_match.end_byte > raw_match.begin_byte)
	    origin = raw_match.end_byte;
	else {
	    if (raw_match.end_byte >= RSTRING_LEN(str)) break;
	    origin = raw_match.end_byte +
		     rb_enc_mbclen(RSTRING_PTR(str) + raw_match.end_byte,
				   RSTRING_PTR(str) + RSTRING_LEN(str),
				   rb_enc_get(str));
	}
    }
    return call->with_block ? str : call->result;
}

static VALUE
onibi_scan_ensure_cleanup(VALUE opaque)
{
    OnibiScanCall *call = (OnibiScanCall *)(uintptr_t)opaque;
    onibi_capture_range_owner_release_value(call->range_owner);
    call->ranges = NULL;
    call->beg = NULL;
    call->end = NULL;
    return Qnil;
}

static VALUE
onibi_scan(VALUE self, VALUE str)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(str);
    uint32_t capture_count = onibi_public_capture_count(obj);
    if (capture_count == UINT32_MAX)
	rb_raise(rb_eRangeError, "Onibi capture count is too large");
    uint32_t num_regs = capture_count + 1U;

    if ((size_t)num_regs > SIZE_MAX / sizeof(OnibiBytePos) / 2U)
	rb_raise(rb_eRangeError, "Onibi capture ranges are too large");
    size_t range_bytes = (size_t)num_regs * sizeof(OnibiBytePos) * 2U;

    OnibiScanCall call = {.self = self,
			  .str = str,
			  .result = Qnil,
			  .snapshot = Qnil,
			  .with_block = rb_block_given_p(),
			  .capture_count = capture_count,
			  .num_regs = num_regs,
			  .range_owner = Qnil,
			  .ranges = NULL,
			  .beg = NULL,
			  .end = NULL};
    if (!call.with_block) call.result = rb_ary_new();
    call.range_owner = onibi_capture_range_owner_new(range_bytes, &call.ranges);
    call.beg = call.ranges;
    call.end = call.ranges + num_regs;
    VALUE result =
	rb_ensure(onibi_scan_body, (VALUE)(uintptr_t)&call,
		  onibi_scan_ensure_cleanup, (VALUE)(uintptr_t)&call);
    RB_GC_GUARD(call.range_owner);
    return result;
}
static VALUE
onibi_case_equal(VALUE self, VALUE other)
{
    if (!RB_TYPE_P(other, T_STRING)) return Qfalse;
    OnibiRawMatch raw_match = {.begin_byte = -1, .end_byte = -1};
    OnibiExecStatus status = onibi_vm_search(self, other, 0, &raw_match);
    if (status == ONIBI_EXEC_STATUS_NO_MATCH) {
	rb_backref_set(Qnil);
	return Qfalse;
    }
    if (status == ONIBI_EXEC_STATUS_INTERNAL_ERROR)
	rb_raise(eRegexpError, "Onibi execution failed");
    if (status == ONIBI_EXEC_STATUS_FALLBACK) {
	onibi_regexp_t *obj;
	TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
	return RTEST(rb_funcall(obj->regexp, id_match, 1, other)) ? Qtrue
								  : Qfalse;
    }
    return Qtrue;
}
static VALUE
onibi_last_match(int argc, VALUE *argv, VALUE klass)
{
    (void)klass;
    VALUE match = rb_backref_get();
    if (argc == 0) return match;
    if (argc != 1)
	rb_raise(rb_eArgError,
		 "wrong number of arguments (given %d, expected 0..1)", argc);
    return NIL_P(match) ? Qnil : rb_funcallv(match, id_aref, 1, argv);
}
static VALUE
onibi_match_operator(VALUE self, VALUE input)
{
    if (NIL_P(input)) {
	rb_backref_set(Qnil);
	return Qnil;
    }
    if (SYMBOL_P(input)) input = rb_sym2str(input);
    StringValue(input);
    OnibiRawMatch raw_match = {.begin_byte = -1, .end_byte = -1};
    OnibiBytePos attempt_start = -1;
    OnibiExecStatus status = onibi_vm_search_with_attempt_start(
	self, input, 0, &raw_match, &attempt_start);
    if (status == ONIBI_EXEC_STATUS_NO_MATCH) {
	rb_backref_set(Qnil);
	return Qnil;
    }
    if (status == ONIBI_EXEC_STATUS_INTERNAL_ERROR)
	rb_raise(eRegexpError, "Onibi execution failed");
    if (status == ONIBI_EXEC_STATUS_FALLBACK) {
	onibi_regexp_t *obj;
	TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
	return rb_reg_match(obj->regexp, input);
    }
    if (attempt_start < 0 || attempt_start > RSTRING_LEN(input))
	rb_raise(eRegexpError, "Onibi match attempt start is unavailable");
    return LONG2NUM(onibi_ruby_character_position(input, attempt_start));
}
static VALUE
onibi_tilde(VALUE self)
{
    VALUE input = rb_gv_get("$_");
    if (!RB_TYPE_P(input, T_STRING)) return Qnil;
    OnibiRawMatch raw_match = {.begin_byte = -1, .end_byte = -1};
    OnibiBytePos attempt_start = -1;
    OnibiExecStatus status = onibi_vm_search_with_attempt_start(
	self, input, 0, &raw_match, &attempt_start);
    if (status == ONIBI_EXEC_STATUS_NO_MATCH) {
	rb_backref_set(Qnil);
	return Qnil;
    }
    if (status == ONIBI_EXEC_STATUS_INTERNAL_ERROR)
	rb_raise(eRegexpError, "Onibi execution failed");
    if (status == ONIBI_EXEC_STATUS_FALLBACK) {
	onibi_regexp_t *obj;
	TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
	VALUE match = rb_funcall(obj->regexp, id_match, 1, input);
	return NIL_P(match)
		   ? Qnil
		   : LONG2NUM(onibi_ruby_character_position(
			 input, NUM2LONG(rb_funcall(match, id_bytebegin, 1,
						    INT2NUM(0)))));
    }
    if (attempt_start < 0 || attempt_start > RSTRING_LEN(input))
	rb_raise(eRegexpError, "Onibi match attempt start is unavailable");
    return LONG2NUM(onibi_ruby_character_position(input, attempt_start));
}

typedef enum {
    ONIBI_GSUB_REPLACEMENT_STRING,
    ONIBI_GSUB_REPLACEMENT_HASH
} OnibiGsubReplacementKind;

/* This state stays in the active C frame across Ruby callbacks. */
typedef struct {
    VALUE self;
    VALUE str;
    VALUE replacement;
    VALUE result;
    VALUE hash;
    VALUE hash_key;
    VALUE hash_value;
    VALUE hash_string;
    OnibiBytePos origin;
    OnibiBytePos copied;
    uint32_t capture_count;
    uint32_t num_regs;
    VALUE range_owner;
    OnibiBytePos *ranges;
    OnibiBytePos *beg;
    OnibiBytePos *end;
    OnibiBytePos subject_length;
    OnibiGsubReplacementKind replacement_kind;
    int with_block;
} OnibiGsubCall;

static void
onibi_gsub_check_subject(OnibiGsubCall *call)
{
    /* MRI permits same-length byte and encoding changes during gsub.  A
     * length change invalidates the saved byte ranges and must stop before
     * the next native read. */
    if (RSTRING_LEN(call->str) != call->subject_length)
	rb_raise(rb_eRuntimeError, "string modified");
}

static long
onibi_gsub_length(OnibiBytePos length)
{
    if (length < 0 || (uintmax_t)length > (uintmax_t)LONG_MAX)
	rb_raise(rb_eRangeError, "Onibi replacement range is too large");
    return (long)length;
}

static void
onibi_gsub_append_bytes(VALUE target, const char *bytes, long length,
			rb_encoding *encoding)
{
    if (length < 0)
	rb_raise(rb_eRangeError, "Onibi replacement range is too large");
    if (length > 0) rb_enc_str_buf_cat(target, bytes, length, encoding);
}

static void
onibi_gsub_append_range(OnibiGsubCall *call, VALUE target, OnibiBytePos start,
			OnibiBytePos end)
{
    if (start < 0 || end < start || end > RSTRING_LEN(call->str))
	rb_raise(eRegexpError, "Onibi returned an invalid replacement range");

    onibi_gsub_append_bytes(target, RSTRING_PTR(call->str) + start,
			    onibi_gsub_length(end - start),
			    rb_enc_get(call->str));
}

static void
onibi_gsub_append_hash_replacement(OnibiGsubCall *call,
				   OnibiBytePos match_begin,
				   OnibiBytePos match_end)
{
    if (match_begin < 0 || match_end < match_begin ||
	match_end > RSTRING_LEN(call->str))
	rb_raise(eRegexpError, "Onibi returned an invalid replacement range");

    call->hash_key = Qnil;
    call->hash_value = Qnil;
    call->hash_string = Qnil;
    long key_length = onibi_gsub_length(match_end - match_begin);
    rb_encoding *key_encoding = rb_enc_get(call->str);
    call->hash_key = rb_enc_str_new(RSTRING_PTR(call->str) + match_begin,
				    key_length, key_encoding);
    call->hash_value = rb_hash_aref(call->hash, call->hash_key);
    RB_GC_GUARD(call->hash);
    RB_GC_GUARD(call->hash_key);

    call->hash_string = rb_obj_as_string(call->hash_value);
    RB_GC_GUARD(call->hash_value);

    onibi_gsub_check_subject(call);
    onibi_gsub_append_range(call, call->result, call->copied, match_begin);
    onibi_gsub_append_bytes(call->result, RSTRING_PTR(call->hash_string),
			    RSTRING_LEN(call->hash_string),
			    rb_enc_get(call->hash_string));
    RB_GC_GUARD(call->hash_string);
}

static int
onibi_gsub_next_replacement_char(VALUE replacement, long length, long offset,
				 rb_encoding *encoding, int *codepoint,
				 long *width)
{
    long remaining;
    const char *bytes;
    const char *cursor;
    const char *end;
    int precise;

    if (offset < 0 || offset >= length) return 0;
    remaining = length - offset;
    bytes = RSTRING_PTR(replacement);
    cursor = bytes + offset;
    end = bytes + length;
    precise = rb_enc_precise_mbclen(cursor, end, encoding);
    if (MBCLEN_CHARFOUND_P(precise)) {
	int found_width = MBCLEN_CHARFOUND_LEN(precise);
	if (found_width <= 0 || (long)found_width > remaining)
	    rb_raise(eRegexpError, "Onibi found an invalid replacement width");
	*width = found_width;
	*codepoint = rb_enc_ascget(cursor, end, NULL, encoding);
	return 1;
    }

    /* MRI keeps broken replacement bytes literal.  Use its boundary helper
     * to advance over one malformed character without decoding it. */
    int malformed_width = rb_enc_mbclen(cursor, end, encoding);
    if (malformed_width <= 0) malformed_width = 1;
    *width = (long)malformed_width > remaining ? remaining : malformed_width;
    *codepoint = -1;
    return 1;
}

static void
onibi_gsub_append_replacement_range(VALUE target, VALUE replacement, long start,
				    long end, rb_encoding *encoding)
{
    long length = RSTRING_LEN(replacement);
    if (start < 0 || end < start || end > length)
	rb_raise(eRegexpError, "Onibi returned an invalid replacement range");

    if (end > start)
	onibi_gsub_append_bytes(target, RSTRING_PTR(replacement) + start,
				end - start, encoding);
}

static int
onibi_gsub_named_capture(const onibi_regexp_t *obj, OnibiGsubCall *call,
			 VALUE target, VALUE replacement, long name_start,
			 long name_end, rb_encoding *replacement_encoding)
{
    long replacement_length = RSTRING_LEN(replacement);
    if (name_start < 0 || name_end < name_start ||
	name_end > replacement_length)
	rb_raise(eRegexpError, "Onibi returned an invalid capture name range");
    VALUE name_value =
	rb_enc_str_new(RSTRING_PTR(replacement) + name_start,
		       name_end - name_start, replacement_encoding);
    VALUE indexes = Qnil;
    for (long i = 0; i < RARRAY_LEN(obj->names); i++) {
	VALUE regexp_name = rb_ary_entry(obj->names, i);
	if (!RTEST(rb_str_equal(name_value, regexp_name))) continue;
	VALUE metadata_key =
	    rb_enc_str_new(RSTRING_PTR(regexp_name), RSTRING_LEN(regexp_name),
			   rb_ascii8bit_encoding());
	indexes = rb_hash_lookup(obj->named_captures, metadata_key);
	RB_GC_GUARD(metadata_key);
	RB_GC_GUARD(regexp_name);
	break;
    }
    if (NIL_P(indexes)) return 0;
    for (long i = RARRAY_LEN(indexes) - 1; i >= 0; i--) {
	long index = NUM2LONG(rb_ary_entry(indexes, i));
	if (index <= 0 || (uint32_t)index > call->capture_count) continue;
	if (call->beg[index] < 0 || call->end[index] < 0) continue;
	onibi_gsub_append_range(call, target, call->beg[index],
				call->end[index]);
	break;
    }
    return 1;
}

/* Expand the replacement forms that use only the native raw registers.  A
 * zero return means that MRI must handle the replacement grammar. */
static int
onibi_gsub_append_replacement(OnibiGsubCall *call, const onibi_regexp_t *obj,
			      VALUE *expanded, OnibiBytePos match_begin,
			      OnibiBytePos match_end)
{
    long length = RSTRING_LEN(call->replacement);
    long literal = 0;
    long cursor = 0;
    int named = RARRAY_LEN(obj->names) != 0;
    rb_encoding *replacement_encoding = rb_enc_get(call->replacement);
    VALUE output = Qnil;
    while (cursor < length) {
	long character_width;
	int character;
	if (!onibi_gsub_next_replacement_char(call->replacement, length, cursor,
					      replacement_encoding, &character,
					      &character_width))
	    break;
	if (character != '\\') {
	    cursor += character_width;
	    continue;
	}

	long slash_start = cursor;
	long escape_start = cursor + character_width;
	if (escape_start == length) {
	    cursor = escape_start;
	    continue;
	}
	if (NIL_P(output)) output = rb_str_buf_new(cursor - literal);
	onibi_gsub_append_replacement_range(output, call->replacement, literal,
					    cursor, replacement_encoding);

	long escape_width;
	int escape;
	if (!onibi_gsub_next_replacement_char(
		call->replacement, length, escape_start, replacement_encoding,
		&escape, &escape_width))
	    break;
	long after_escape = escape_start + escape_width;
	if (escape < 0) {
	    onibi_gsub_append_replacement_range(output, call->replacement,
						cursor, after_escape,
						replacement_encoding);
	    literal = after_escape;
	    cursor = after_escape;
	    continue;
	}
	literal = after_escape;
	cursor = after_escape;
	if (escape == '\\') {
	    onibi_gsub_append_replacement_range(output, call->replacement,
						escape_start, after_escape,
						replacement_encoding);
	    continue;
	}
	if (escape == '&' || escape == '0') {
	    onibi_gsub_append_range(call, output, match_begin, match_end);
	    continue;
	}
	if (escape == '`') {
	    onibi_gsub_append_range(call, output, 0, match_begin);
	    continue;
	}
	if (escape == '\'') {
	    onibi_gsub_append_range(call, output, match_end,
				    call->subject_length);
	    continue;
	}
	if (escape == '+') {
	    if (named) {
		for (long name_index = RARRAY_LEN(obj->names) - 1;
		     name_index >= 0; name_index--) {
		    VALUE name = rb_ary_entry(obj->names, name_index);
		    VALUE indexes = rb_hash_lookup(obj->named_captures, name);
		    for (long index = RARRAY_LEN(indexes) - 1; index >= 0;
			 index--) {
			long capture = NUM2LONG(rb_ary_entry(indexes, index));
			if (capture > 0 &&
			    (uint32_t)capture <= call->capture_count &&
			    call->beg[capture] >= 0 &&
			    call->end[capture] >= 0) {
			    onibi_gsub_append_range(call, output,
						    call->beg[capture],
						    call->end[capture]);
			    name_index = -1;
			    break;
			}
		    }
		}
	    }
	    else {
		for (uint32_t index = call->capture_count; index > 0; index--)
		    if (call->beg[index] >= 0 && call->end[index] >= 0) {
			onibi_gsub_append_range(call, output, call->beg[index],
						call->end[index]);
			break;
		    }
	    }
	    continue;
	}
	if (escape == 'k') {
	    long open_width;
	    int open;
	    if (after_escape >= length ||
		!onibi_gsub_next_replacement_char(
		    call->replacement, length, after_escape,
		    replacement_encoding, &open, &open_width) ||
		open != '<')
		return 0;
	    long name_start = after_escape + open_width;
	    long name_end = name_start;
	    long close_width = 0;
	    while (name_end < length) {
		int name_character;
		if (!onibi_gsub_next_replacement_char(
			call->replacement, length, name_end,
			replacement_encoding, &name_character, &close_width))
		    return 0;
		if (name_character == '>') break;
		name_end += close_width;
	    }
	    if (name_end == length ||
		!onibi_gsub_named_capture(obj, call, output, call->replacement,
					  name_start, name_end,
					  replacement_encoding))
		return 0;
	    cursor = name_end + close_width;
	    literal = cursor;
	    continue;
	}
	if (escape >= '1' && escape <= '9') {
	    long number = escape - '0';
	    if (!named && number <= call->capture_count &&
		call->beg[number] >= 0 && call->end[number] >= 0)
		onibi_gsub_append_range(call, output, call->beg[number],
					call->end[number]);
	    continue;
	}
	/* MRI preserves an unknown escape as its encoded two-character span. */
	onibi_gsub_append_replacement_range(output, call->replacement,
					    slash_start, after_escape,
					    replacement_encoding);
    }
    if (NIL_P(output)) {
	*expanded = call->replacement;
	return 1;
    }
    if (literal < length)
	onibi_gsub_append_replacement_range(output, call->replacement, literal,
					    length, replacement_encoding);
    *expanded = output;
    return 1;
}

static VALUE
onibi_gsub_body(VALUE opaque)
{
    OnibiGsubCall *call = (OnibiGsubCall *)(uintptr_t)opaque;
    onibi_regexp_t *obj;
    TypedData_Get_Struct(call->self, onibi_regexp_t, &onibi_type, obj);
    for (;;) {
	OnibiRawMatch raw_match = {.begin_byte = -1,
				   .end_byte = -1,
				   .num_regs = call->num_regs,
				   .beg = call->beg,
				   .end = call->end};
	OnibiExecStatus status =
	    onibi_vm_search(call->self, call->str, call->origin, &raw_match);
	if (status == ONIBI_EXEC_STATUS_INTERNAL_ERROR)
	    rb_raise(eRegexpError, "Onibi execution failed");
	if (status == ONIBI_EXEC_STATUS_FALLBACK) {
	    VALUE plain = rb_str_dup(call->str);
	    if (call->with_block)
		return rb_block_call(plain, id_gsub, 1, &obj->regexp,
				     rb_yield_block, Qnil);
	    return rb_funcall(plain, id_gsub, 2, obj->regexp,
			      call->replacement);
	}
	if (status == ONIBI_EXEC_STATUS_NO_MATCH) break;
	if (call->replacement_kind == ONIBI_GSUB_REPLACEMENT_HASH) {
	    onibi_gsub_append_hash_replacement(call, raw_match.begin_byte,
					       raw_match.end_byte);
	}
	else if (call->with_block) {
	    VALUE value = rb_yield(onibi_byte_slice(
		call->str, raw_match.begin_byte, raw_match.end_byte));
	    value = rb_obj_as_string(value);
	    onibi_gsub_check_subject(call);
	    onibi_gsub_append_range(call, call->result, call->copied,
				    raw_match.begin_byte);
	    onibi_gsub_append_bytes(call->result, RSTRING_PTR(value),
				    RSTRING_LEN(value), rb_enc_get(value));
	}
	else {
	    VALUE expanded = call->replacement;
	    if (!onibi_gsub_append_replacement(call, obj, &expanded,
					       raw_match.begin_byte,
					       raw_match.end_byte)) {
		VALUE plain = rb_str_dup(call->str);
		return rb_funcall(plain, id_gsub, 2, obj->regexp,
				  call->replacement);
	    }
	    onibi_gsub_append_range(call, call->result, call->copied,
				    raw_match.begin_byte);
	    onibi_gsub_append_bytes(call->result, RSTRING_PTR(expanded),
				    RSTRING_LEN(expanded),
				    rb_enc_get(expanded));
	}
	call->copied = raw_match.end_byte;
	if (raw_match.end_byte > raw_match.begin_byte)
	    call->origin = raw_match.end_byte;
	else {
	    if (raw_match.end_byte >= RSTRING_LEN(call->str)) break;
	    call->origin =
		raw_match.end_byte +
		rb_enc_mbclen(RSTRING_PTR(call->str) + raw_match.end_byte,
			      RSTRING_PTR(call->str) + RSTRING_LEN(call->str),
			      rb_enc_get(call->str));
	}
    }
    onibi_gsub_append_range(call, call->result, call->copied,
			    call->subject_length);
    return call->result;
}

static VALUE
onibi_gsub_ensure_cleanup(VALUE opaque)
{
    OnibiGsubCall *call = (OnibiGsubCall *)(uintptr_t)opaque;
    onibi_capture_range_owner_release_value(call->range_owner);
    call->ranges = NULL;
    call->beg = NULL;
    call->end = NULL;
    return Qnil;
}

static VALUE
onibi_gsub(int argc, VALUE *argv, VALUE self)
{
    VALUE str, replacement = Qnil;
    rb_scan_args(argc, argv, "11", &str, &replacement);
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    if (argc == 1) RETURN_ENUMERATOR(self, argc, argv);
    StringValue(str);
    int replacement_given = argc == 2;
    OnibiGsubReplacementKind replacement_kind = ONIBI_GSUB_REPLACEMENT_STRING;
    if (replacement_given) {
	VALUE hash =
	    rb_check_convert_type(replacement, T_HASH, "Hash", "to_hash");
	if (!NIL_P(hash)) {
	    replacement = hash;
	    replacement_kind = ONIBI_GSUB_REPLACEMENT_HASH;
	}
    }
    if (replacement_kind == ONIBI_GSUB_REPLACEMENT_STRING &&
	(replacement_given || !rb_block_given_p()))
	StringValue(replacement);
    uint32_t capture_count = onibi_public_capture_count(obj);
    if (capture_count == UINT32_MAX)
	rb_raise(rb_eRangeError, "Onibi capture count is too large");
    uint32_t num_regs = capture_count + 1U;
    if ((size_t)num_regs > SIZE_MAX / sizeof(OnibiBytePos) / 2U)
	rb_raise(rb_eRangeError, "Onibi capture ranges are too large");
    size_t range_bytes = (size_t)num_regs * sizeof(OnibiBytePos) * 2U;
    OnibiGsubCall call = {
	.self = self,
	.str = str,
	.replacement = replacement,
	.result = Qnil,
	.hash = replacement_kind == ONIBI_GSUB_REPLACEMENT_HASH ? replacement
								: Qnil,
	.hash_key = Qnil,
	.hash_value = Qnil,
	.hash_string = Qnil,
	.origin = 0,
	.copied = 0,
	.capture_count = capture_count,
	.num_regs = num_regs,
	.range_owner = Qnil,
	.ranges = NULL,
	.beg = NULL,
	.end = NULL,
	.subject_length = RSTRING_LEN(str),
	.replacement_kind = replacement_kind,
	.with_block = !replacement_given && rb_block_given_p()};
    call.result = rb_str_buf_new(RSTRING_LEN(str));
    rb_enc_associate(call.result, rb_enc_get(str));
    call.range_owner = onibi_capture_range_owner_new(range_bytes, &call.ranges);
    call.beg = call.ranges;
    call.end = call.ranges + num_regs;
    VALUE result =
	rb_ensure(onibi_gsub_body, (VALUE)(uintptr_t)&call,
		  onibi_gsub_ensure_cleanup, (VALUE)(uintptr_t)&call);
    RB_GC_GUARD(call.range_owner);
    return result;
}

void
