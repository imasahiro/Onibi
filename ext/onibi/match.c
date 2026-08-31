static int
onibi_vm_search(VALUE self, VALUE str, long search_origin, long *match_start,
		long *match_end)
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
    int str_encoding_index = rb_enc_get_index(str);
    onibi_set_deadline(obj->timeout_seconds);
    exec_ctx.timeout_deadline = onibi_deadline_ns;
    onibi_active_exec_ctx = &exec_ctx;
    if (search_origin < 0) search_origin = 0;
    if (search_origin > RSTRING_LEN(str)) {
	onibi_deadline_ns = 0;
	onibi_active_exec_ctx = NULL;
	return 0;
    }

    if (!(obj->options & ONIBI_OPT_NOENCODING) &&
	(!onibi_regexp_fixed_p(obj) || onibi_encoded_literal_program_p(obj)) &&
	!NIL_P(obj->rseq) && obj->rseq_view_valid &&
	onibi_vm_input_eligible(obj, str) &&
	(!ONIBI_FEATURE_P(obj, ONIBI_FEATURE_ASCII_PROPERTY) ||
	 rb_enc_str_asciionly_p(str) ||
	 (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_UNICODE_PROPERTY) &&
	  (str_encoding_index == rb_utf8_encindex() ||
	   str_encoding_index == obj->source_encoding_index))) &&
	(rb_enc_str_asciionly_p(str) || onibi_valid_encoding(str))) {
	/* The immutable RSeq was validated and its physical execution view was
	   built during initialize.  Do not rescan the program on each match. */
	for (long start = search_origin; start <= RSTRING_LEN(str); start++) {
	    exec_ctx.attempt_start = start;
	    exec_ctx.current_position = start;
	    exec_ctx.program = obj->rseq_view.header;
	    exec_ctx.rseq = obj->rseq;
	    exec_ctx.view = &obj->rseq_view;
	    if (!onibi_character_boundary(str, start)) continue;
	    if ((exec_ctx.program->features &
		 ONIBI_RSEQ_FEATURE_FIRST_BITMAP) != 0 &&
		start < RSTRING_LEN(str) &&
		(exec_ctx.program
		     ->first_bitmap[(unsigned char)RSTRING_PTR(str)[start] >>
				    3] &
		 (1U << ((unsigned char)RSTRING_PTR(str)[start] & 7))) == 0)
		continue;
	    if (exec_ctx.program->prefix_length > 0 &&
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
		onibi_deadline_ns = 0;
		onibi_active_exec_ctx = NULL;
		return 1;
	    }
	    if (result == ONIBI_EXEC_STATUS_INTERNAL_ERROR) {
		onibi_deadline_ns = 0;
		onibi_active_exec_ctx = NULL;
		return 0;
	    }
	    if (result == ONIBI_EXEC_STATUS_FALLBACK) {
		onibi_deadline_ns = 0;
		onibi_active_exec_ctx = NULL;
		return -1;
	    }
	}
	onibi_deadline_ns = 0;
	onibi_active_exec_ctx = NULL;
	return 0;
    }
    onibi_deadline_ns = 0;
    onibi_active_exec_ctx = NULL;
    /* No RSeq program is available for this input or feature set. */
    return -1;
}

static VALUE
onibi_scan(VALUE self, VALUE str)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(str);
    VALUE result = rb_ary_new();
    long origin = 0;
    for (;;) {
	long start = 0, end = 0;
	if (!onibi_vm_search(self, str, origin, &start, &end)) break;
	rb_ary_push(result, rb_str_substr(str, start, end - start));
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
    if (!onibi_vm_search(self, other, 0, &start, &end)) {
	rb_backref_set(Qnil);
	return Qfalse;
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
    if (!onibi_vm_search(self, input, 0, &start, &end)) {
	rb_backref_set(Qnil);
	return Qnil;
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
    VALUE result = rb_str_buf_new(RSTRING_LEN(str));
    rb_enc_associate(result, rb_enc_get(str));
    long origin = 0, copied = 0;
    for (;;) {
	long start = 0, end = 0;
	if (!onibi_vm_search(self, str, origin, &start, &end)) break;
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
