static void
onibi_exec_ctx_release(OnibiExecCtx *ctx)
{
    ruby_xfree(ctx->tags.data);
    ctx->tags.data = NULL;
    ctx->tags.count = 0;
    ctx->tags.capacity = 0;
    ruby_xfree(ctx->class_stack);
    ctx->class_stack = NULL;
    ctx->class_stack_capacity = 0;
}

static OnibiExecStatus
onibi_vm_search_body(VALUE self, VALUE str, long search_origin,
		     long *match_start, long *match_end)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(str);
    OnibiExecCtx exec_ctx;
    memset(&exec_ctx, 0, sizeof(exec_ctx));
    exec_ctx.regexp = self;
    exec_ctx.subject = str;
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

    if (!(obj->options & ONIBI_OPT_NOENCODING) && !NIL_P(obj->rseq) &&
	obj->rseq_view_valid && onibi_vm_input_eligible(obj, str) &&
	(rb_enc_str_asciionly_p(str) || onibi_valid_encoding(str))) {
	/* The immutable RSeq was validated and its physical execution view was
	   built during initialize.  Do not rescan the program on each match. */
	exec_ctx.encoding = rb_enc_get(str);
	exec_ctx.encoding_mode =
	    onibi_encoding_mode_for(str, exec_ctx.encoding);
	exec_ctx.class_stack_capacity = obj->rseq_view.class_stack_capacity;
	if (exec_ctx.class_stack_capacity != 0)
	    exec_ctx.class_stack = ruby_xmalloc(exec_ctx.class_stack_capacity);
	for (long start = search_origin; start <= RSTRING_LEN(str); start++) {
	    exec_ctx.attempt_start = start;
	    exec_ctx.reported_start = start;
	    exec_ctx.current_position = start;
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
	    rb_thread_check_ints();
	    onibi_check_deadline();
	    OnibiExecStatus result = onibi_execute(&exec_ctx);
	    if (result == ONIBI_EXEC_STATUS_MATCH) {
		if (match_start) *match_start = exec_ctx.reported_start;
		if (match_end) *match_end = exec_ctx.matched_end;
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
	    if (result == ONIBI_EXEC_STATUS_FALLBACK) {
		onibi_exec_ctx_release(&exec_ctx);
		onibi_deadline_ns = 0;
		onibi_active_exec_ctx = NULL;
		return ONIBI_EXEC_STATUS_FALLBACK;
	    }
	}
	onibi_exec_ctx_release(&exec_ctx);
	onibi_deadline_ns = 0;
	onibi_active_exec_ctx = NULL;
	return ONIBI_EXEC_STATUS_NO_MATCH;
    }

    onibi_exec_ctx_release(&exec_ctx);
    onibi_deadline_ns = 0;
    onibi_active_exec_ctx = NULL;
    /* No RSeq program is available for this input or feature set. */
    return ONIBI_EXEC_STATUS_FALLBACK;
}

typedef struct {
    VALUE self, subject;
    long origin;
    long *match_start, *match_end;
    OnibiExecCtx *previous_ctx;
    uint64_t previous_deadline;
} OnibiSearchEnsure;

static VALUE
onibi_vm_search_ensure_call(VALUE opaque)
{
    OnibiSearchEnsure *call = (OnibiSearchEnsure *)(uintptr_t)opaque;
    return INT2NUM(onibi_vm_search_body(call->self, call->subject, call->origin,
					call->match_start, call->match_end));
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
onibi_vm_search(VALUE self, VALUE str, long search_origin, long *match_start,
		long *match_end)
{
    OnibiSearchEnsure call = {self,
			      str,
			      search_origin,
			      match_start,
			      match_end,
			      onibi_active_exec_ctx,
			      onibi_deadline_ns};
    VALUE result =
	rb_ensure(onibi_vm_search_ensure_call, (VALUE)(uintptr_t)&call,
		  onibi_vm_search_ensure_cleanup, (VALUE)(uintptr_t)&call);
    return NUM2INT(result);
}

static VALUE
onibi_scan(VALUE self, VALUE str)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(str);
    VALUE result = rb_ary_new();
    uint32_t capture_count = (!NIL_P(obj->rseq) && obj->rseq_view_valid)
				 ? obj->rseq_view.header->capture_count
				 : 0;
    VALUE plain_subject = capture_count > 0 ? rb_str_dup(str) : str;
    long origin = 0;
    for (;;) {
	long start = 0, end = 0;
	OnibiExecStatus status =
	    onibi_vm_search(self, str, origin, &start, &end);
	if (status == ONIBI_EXEC_STATUS_INTERNAL_ERROR)
	    rb_raise(eRegexpError, "Onibi execution failed");
	if (status == ONIBI_EXEC_STATUS_FALLBACK) {
	    onibi_regexp_t *obj;
	    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
	    VALUE plain = rb_str_dup(str);
	    return rb_funcall(plain, id_scan, 1, obj->regexp);
	}
	if (status == ONIBI_EXEC_STATUS_NO_MATCH) break;
	if (capture_count == 0) {
	    rb_ary_push(result, rb_str_substr(str, start, end - start));
	}
	else {
	    /* VM selects the candidate.  MRI only materializes its capture
	     * values until direct RMatch construction is available. */
	    VALUE match = rb_funcall(obj->regexp, id_match, 2, plain_subject,
				     LONG2NUM(start));
	    VALUE captures = rb_ary_new_capa(capture_count);
	    for (uint32_t i = 0; i < capture_count; i++)
		rb_ary_push(captures,
			    rb_funcall(match, id_aref, 1, UINT2NUM(i + 1U)));
	    rb_ary_push(result, capture_count == 1 ? rb_ary_entry(captures, 0)
						   : captures);
	}
	if (end > start)
	    origin = end;
	else {
	    if (origin >= RSTRING_LEN(str)) break;
	    origin += rb_enc_mbclen(RSTRING_PTR(str) + origin,
				    RSTRING_PTR(str) + RSTRING_LEN(str),
				    rb_enc_get(str));
	}
    }
    return result;
}
static VALUE
onibi_case_equal(VALUE self, VALUE other)
{
    if (!RB_TYPE_P(other, T_STRING)) return Qfalse;
    long start = 0, end = 0;
    OnibiExecStatus status = onibi_vm_search(self, other, 0, &start, &end);
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
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    rb_funcall(obj->regexp, id_match, 1, other);
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
onibi_tilde(VALUE self)
{
    VALUE input = rb_gv_get("$_");
    if (!RB_TYPE_P(input, T_STRING)) return Qnil;
    long start = 0, end = 0;
    OnibiExecStatus status = onibi_vm_search(self, input, 0, &start, &end);
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
	return NIL_P(match) ? Qnil
			    : rb_funcall(match, id_bytebegin, 1, INT2NUM(0));
    }
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    rb_funcall(obj->regexp, id_match, 1, input);
    return LONG2NUM(start);
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
    if (!rb_block_given_p() && RB_TYPE_P(replacement, T_STRING) &&
	memchr(RSTRING_PTR(replacement), '\\', RSTRING_LEN(replacement)) !=
	    NULL) {
	/* MRI expands numbered and named replacement references.  Keep this
	 * compatibility boundary explicit until Onibi owns MatchData. */
	VALUE plain = rb_str_dup(str);
	return rb_funcall(plain, id_gsub, 2, obj->regexp, replacement);
    }
    VALUE result = rb_str_buf_new(RSTRING_LEN(str));
    rb_enc_associate(result, rb_enc_get(str));
    long origin = 0, copied = 0;
    for (;;) {
	long start = 0, end = 0;
	OnibiExecStatus status =
	    onibi_vm_search(self, str, origin, &start, &end);
	if (status == ONIBI_EXEC_STATUS_INTERNAL_ERROR)
	    rb_raise(eRegexpError, "Onibi execution failed");
	if (status == ONIBI_EXEC_STATUS_FALLBACK) {
	    onibi_regexp_t *obj;
	    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
	    VALUE plain = rb_str_dup(str);
	    if (rb_block_given_p())
		return rb_block_call(plain, id_gsub, 1, &obj->regexp,
				     rb_yield_block, Qnil);
	    return rb_funcall(plain, id_gsub, 2, obj->regexp, replacement);
	}
	if (status == ONIBI_EXEC_STATUS_NO_MATCH) break;
	rb_str_buf_cat(result, RSTRING_PTR(str) + copied, start - copied);
	VALUE replacement_value =
	    rb_block_given_p()
		? rb_yield(rb_str_substr(str, start, end - start))
		: replacement;
	StringValue(replacement_value);
	rb_str_buf_cat(result, RSTRING_PTR(replacement_value),
		       RSTRING_LEN(replacement_value));
	copied = end;
	if (end > start)
	    origin = end;
	else {
	    if (origin >= RSTRING_LEN(str)) break;
	    origin += rb_enc_mbclen(RSTRING_PTR(str) + origin,
				    RSTRING_PTR(str) + RSTRING_LEN(str),
				    rb_enc_get(str));
	}
    }
    rb_str_buf_cat(result, RSTRING_PTR(str) + copied,
		   RSTRING_LEN(str) - copied);
    return result;
}

void
