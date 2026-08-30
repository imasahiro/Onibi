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
		return -1;
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
    if (result >= 0) return result ? Qtrue : Qfalse;
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return rb_funcall(obj->regexp, id_match_p, 1, str);
}

static VALUE
onibi_scan(VALUE self, VALUE str)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(str);
    return rb_funcall(str, id_scan, 1, obj->regexp);
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
    return rb_funcallv(rb_cRegexp, id_last_match, argc, argv);
}
static VALUE
onibi_tilde(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return rb_funcall(obj->regexp, id_tilde, 0);
}
static VALUE
onibi_gsub_yield(VALUE value, VALUE data, int argc, const VALUE *argv,
		 VALUE blockarg)
{
    (void)data;
    (void)blockarg;
    return argc == 0 ? rb_yield(value) : rb_yield_values2(argc, argv);
}
static VALUE
onibi_gsub(int argc, VALUE *argv, VALUE self)
{
    VALUE str, replacement = Qnil;
    rb_scan_args(argc, argv, "11", &str, &replacement);
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(str);
    if (rb_block_given_p()) {
	VALUE regexp = obj->regexp;
	return rb_block_call(str, id_gsub, 1, &regexp, onibi_gsub_yield, Qnil);
    }
    return rb_funcall(str, id_gsub, 2, obj->regexp, replacement);
}

void
