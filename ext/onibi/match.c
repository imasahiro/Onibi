#include "onibi_encoding_internal.h"
#include "onibi_exec_internal.h"
#include "onibi_ruby_api_internal.h"

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
		     OnibiRawMatch *raw_match)
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
	int candidate_valid = onibi_search_candidate_origin(
	    str, &start, exec_ctx.encoding, exec_ctx.encoding_mode);
	for (; candidate_valid;
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
    OnibiExecCtx *previous_ctx;
    uint64_t previous_deadline;
} OnibiSearchEnsure;

static VALUE
onibi_vm_search_ensure_call(VALUE opaque)
{
    OnibiSearchEnsure *call = (OnibiSearchEnsure *)(uintptr_t)opaque;
    return INT2NUM(onibi_vm_search_body(call->self, call->subject, call->origin,
					call->raw_match));
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
onibi_vm_search(VALUE self, VALUE str, OnibiBytePos search_origin,
		OnibiRawMatch *raw_match)
{
    OnibiSearchEnsure call = {self,
			      str,
			      search_origin,
			      raw_match,
			      onibi_active_exec_ctx,
			      onibi_deadline_ns};
    VALUE result =
	rb_ensure(onibi_vm_search_ensure_call, (VALUE)(uintptr_t)&call,
		  onibi_vm_search_ensure_cleanup, (VALUE)(uintptr_t)&call);
    return NUM2INT(result);
}

typedef struct {
    VALUE self;
    VALUE str;
    VALUE result;
    VALUE snapshot;
    int with_block;
    uint32_t capture_count;
    uint32_t num_regs;
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
    ruby_xfree(call->ranges);
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
			  .result = rb_block_given_p() ? Qnil : rb_ary_new(),
			  .snapshot = Qnil,
			  .with_block = rb_block_given_p(),
			  .capture_count = capture_count,
			  .num_regs = num_regs,
			  .ranges = ruby_xmalloc(range_bytes),
			  .beg = NULL,
			  .end = NULL};
    call.beg = call.ranges;
    call.end = call.ranges + num_regs;
    return rb_ensure(onibi_scan_body, (VALUE)(uintptr_t)&call,
		     onibi_scan_ensure_cleanup, (VALUE)(uintptr_t)&call);
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
    OnibiExecStatus status = onibi_vm_search(self, input, 0, &raw_match);
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
    return LONG2NUM(onibi_ruby_character_position(input, raw_match.begin_byte));
}
static VALUE
onibi_tilde(VALUE self)
{
    VALUE input = rb_gv_get("$_");
    if (!RB_TYPE_P(input, T_STRING)) return Qnil;
    OnibiRawMatch raw_match = {.begin_byte = -1, .end_byte = -1};
    OnibiExecStatus status = onibi_vm_search(self, input, 0, &raw_match);
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
    return LONG2NUM(onibi_ruby_character_position(input, raw_match.begin_byte));
}

typedef struct {
    VALUE self;
    VALUE str;
    VALUE replacement;
    VALUE result;
    OnibiBytePos origin;
    OnibiBytePos copied;
    uint32_t capture_count;
    uint32_t num_regs;
    OnibiBytePos *ranges;
    OnibiBytePos *beg;
    OnibiBytePos *end;
    OnibiBytePos subject_length;
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

static void
onibi_gsub_append_range(OnibiGsubCall *call, OnibiBytePos start,
			OnibiBytePos end)
{
    if (start < 0 || end < start || end > RSTRING_LEN(call->str))
	rb_raise(eRegexpError, "Onibi returned an invalid replacement range");
    if (end > start)
	rb_str_buf_cat(call->result, RSTRING_PTR(call->str) + start,
		       end - start);
}

static int
onibi_gsub_named_capture(const onibi_regexp_t *obj, OnibiGsubCall *call,
			 const char *name, long name_length)
{
    VALUE name_value = rb_str_new(name, name_length);
    VALUE indexes = rb_hash_lookup(obj->named_captures, name_value);
    if (NIL_P(indexes)) return 0;
    for (long i = RARRAY_LEN(indexes) - 1; i >= 0; i--) {
	long index = NUM2LONG(rb_ary_entry(indexes, i));
	if (index <= 0 || (uint32_t)index > call->capture_count) continue;
	if (call->beg[index] < 0 || call->end[index] < 0) continue;
	onibi_gsub_append_range(call, call->beg[index], call->end[index]);
	break;
    }
    return 1;
}

/* Expand the replacement forms that use only the native raw registers.  A
 * zero return means that MRI must handle the replacement grammar. */
static int
onibi_gsub_append_replacement(OnibiGsubCall *call, const onibi_regexp_t *obj,
			      OnibiBytePos match_begin, OnibiBytePos match_end)
{
    const char *replacement = RSTRING_PTR(call->replacement);
    long length = RSTRING_LEN(call->replacement);
    long literal = 0;
    int named = RARRAY_LEN(obj->names) != 0;
    for (long i = 0; i < length; i++) {
	if (replacement[i] != '\\') continue;
	if (i > literal)
	    rb_str_buf_cat(call->result, replacement + literal, i - literal);
	if (++i == length) {
	    rb_str_buf_cat(call->result, "\\", 1);
	    literal = i;
	    break;
	}
	char escape = replacement[i];
	if (escape == '\\') {
	    rb_str_buf_cat(call->result, "\\", 1);
	    literal = i + 1;
	    continue;
	}
	if (escape == '&' || escape == '0') {
	    onibi_gsub_append_range(call, match_begin, match_end);
	    literal = i + 1;
	    continue;
	}
	if (escape == '`') {
	    onibi_gsub_append_range(call, 0, match_begin);
	    literal = i + 1;
	    continue;
	}
	if (escape == '\'') {
	    onibi_gsub_append_range(call, match_end, RSTRING_LEN(call->str));
	    literal = i + 1;
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
			    onibi_gsub_append_range(call, call->beg[capture],
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
			onibi_gsub_append_range(call, call->beg[index],
						call->end[index]);
			break;
		    }
	    }
	    literal = i + 1;
	    continue;
	}
	if (escape == 'k') {
	    if (i + 1 >= length || replacement[i + 1] != '<') return 0;
	    long name_start = i + 2;
	    long name_end = name_start;
	    while (name_end < length && replacement[name_end] != '>')
		name_end++;
	    if (name_end == length ||
		!onibi_gsub_named_capture(obj, call, replacement + name_start,
					  name_end - name_start))
		return 0;
	    literal = name_end + 1;
	    i = name_end;
	    continue;
	}
	if (escape >= '1' && escape <= '9') {
	    long number_start = i;
	    long number_end = i + 1;
	    while (number_end < length && replacement[number_end] >= '0' &&
		   replacement[number_end] <= '9')
		number_end++;
	    long number = 0;
	    long selected_end = number_start + 1;
	    for (long digit_end = number_start + 1; digit_end <= number_end;
		 digit_end++) {
		long digit = replacement[digit_end - 1] - '0';
		if (number > (LONG_MAX - digit) / 10) break;
		number = number * 10 + digit;
		if (number > 0 && number <= call->capture_count) {
		    selected_end = digit_end;
		    continue;
		}
		break;
	    }
	    if (named) selected_end = number_start + 1;
	    if (!named && (number == 0 || number > call->capture_count)) {
		number = replacement[number_start] - '0';
		selected_end = number_start + 1;
	    }
	    if (number > 0 && number <= call->capture_count && !named &&
		call->beg[number] >= 0 && call->end[number] >= 0)
		onibi_gsub_append_range(call, call->beg[number],
					call->end[number]);
	    literal = selected_end;
	    i = selected_end - 1;
	    continue;
	}
	/* MRI preserves an unrecognised escape as two literal bytes. */
	rb_str_buf_cat(call->result, replacement + i - 1, 2);
	literal = i + 1;
    }
    if (literal < length)
	rb_str_buf_cat(call->result, replacement + literal, length - literal);
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
	rb_str_buf_cat(call->result, RSTRING_PTR(call->str) + call->copied,
		       raw_match.begin_byte - call->copied);
	if (call->with_block) {
	    VALUE value = rb_yield(onibi_byte_slice(
		call->str, raw_match.begin_byte, raw_match.end_byte));
	    value = rb_obj_as_string(value);
	    onibi_gsub_check_subject(call);
	    rb_str_buf_cat(call->result, RSTRING_PTR(value),
			   RSTRING_LEN(value));
	}
	else if (!onibi_gsub_append_replacement(call, obj, raw_match.begin_byte,
						raw_match.end_byte)) {
	    VALUE plain = rb_str_dup(call->str);
	    return rb_funcall(plain, id_gsub, 2, obj->regexp,
			      call->replacement);
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
    rb_str_buf_cat(call->result, RSTRING_PTR(call->str) + call->copied,
		   RSTRING_LEN(call->str) - call->copied);
    return call->result;
}

static VALUE
onibi_gsub_ensure_cleanup(VALUE opaque)
{
    OnibiGsubCall *call = (OnibiGsubCall *)(uintptr_t)opaque;
    ruby_xfree(call->ranges);
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
    StringValue(str);
    if (!rb_block_given_p()) StringValue(replacement);
    uint32_t capture_count = onibi_public_capture_count(obj);
    if (capture_count == UINT32_MAX)
	rb_raise(rb_eRangeError, "Onibi capture count is too large");
    uint32_t num_regs = capture_count + 1U;
    if ((size_t)num_regs > SIZE_MAX / sizeof(OnibiBytePos) / 2U)
	rb_raise(rb_eRangeError, "Onibi capture ranges are too large");
    OnibiGsubCall call = {
	.self = self,
	.str = str,
	.replacement = replacement,
	.result = rb_str_buf_new(RSTRING_LEN(str)),
	.origin = 0,
	.copied = 0,
	.capture_count = capture_count,
	.num_regs = num_regs,
	.ranges = ruby_xmalloc((size_t)num_regs * sizeof(OnibiBytePos) * 2U),
	.beg = NULL,
	.end = NULL,
	.subject_length = RSTRING_LEN(str),
	.with_block = rb_block_given_p()};
    rb_enc_associate(call.result, rb_enc_get(str));
    call.beg = call.ranges;
    call.end = call.ranges + num_regs;
    return rb_ensure(onibi_gsub_body, (VALUE)(uintptr_t)&call,
		     onibi_gsub_ensure_cleanup, (VALUE)(uintptr_t)&call);
}

void
