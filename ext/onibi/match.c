static int
onibi_vm_search(VALUE self, VALUE str, long search_origin, long *match_start,
		long *match_end)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(str);
    int str_encoding_index = rb_enc_get_index(str);
    onibi_set_deadline(obj->timeout_seconds);
    if (search_origin < 0) search_origin = 0;
    if (search_origin > RSTRING_LEN(str)) {
	onibi_deadline_ns = 0;
	return 0;
    }
    if (!onibi_mri_compat_path_p(obj) && !(obj->options & 32) &&
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
	    if (!onibi_character_boundary(str, start)) continue;
	    rb_thread_check_ints();
	    onibi_check_deadline();
	    long end = 0;
	    int result = onibi_rseq_simple_match(
		obj->rseq, &obj->rseq_view, str, start, search_origin, &end);
	    if (result > 0) {
		if (match_start) *match_start = start;
		if (match_end) *match_end = end;
		onibi_deadline_ns = 0;
		return 1;
	    }
	    if (result < 0) {
		onibi_deadline_ns = 0;
		return 0;
	    }
	}
	onibi_deadline_ns = 0;
	return 0;
    }
    onibi_deadline_ns = 0;
    return -1;
}

static VALUE
onibi_vm_match_p(VALUE self, VALUE str)
{
    long start = 0, end = 0;
    int result = onibi_vm_search(self, str, 0, &start, &end);
    return result > 0 ? Qtrue : Qfalse;
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
    return onibi_vm_match_p(self, other);
}
static VALUE
onibi_last_match(int argc, VALUE *argv, VALUE klass)
{
    (void)argc;
    (void)argv;
    (void)klass;
    return Qnil;
}
static VALUE
onibi_tilde(VALUE self)
{
    VALUE input = rb_gv_get("$_");
    if (!RB_TYPE_P(input, T_STRING)) return Qnil;
    long start = 0, end = 0;
    return onibi_vm_search(self, input, 0, &start, &end) ? LONG2NUM(start)
							 : Qnil;
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
