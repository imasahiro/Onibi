static VALUE
onibi_vm_regular_fast(VALUE rseq, const OnibiRSeqView *view, VALUE str,
		      long search_origin)
{
    for (long start = search_origin; start <= RSTRING_LEN(str); start++) {
	if (!onibi_character_boundary(str, start)) continue;
	rb_thread_check_ints();
	onibi_check_deadline();
	long end = 0;
	int simple = onibi_rseq_simple_match(rseq, view, str, start,
					     search_origin, &end);
	if (simple > 0) return Qtrue;
	if (simple < 0) return Qundef;
    }
    return Qfalse;
}

static VALUE
onibi_vm_tagged_ordered(VALUE rseq, const OnibiRSeqView *view, VALUE str,
			long search_origin, int need_captures)
{
    (void)need_captures;
    for (long start = search_origin; start <= RSTRING_LEN(str); start++) {
	if (!onibi_character_boundary(str, start)) continue;
	rb_thread_check_ints();
	onibi_check_deadline();
	long end = 0;
	int simple = onibi_rseq_simple_match(rseq, view, str, start,
					     search_origin, &end);
	if (simple > 0) return Qtrue;
	if (simple == 0) continue;
	if (simple < 0) return Qundef;
    }
    return Qfalse;
}

static VALUE
onibi_vm_dynamic(VALUE rseq, const OnibiRSeqView *view, VALUE str,
		 long search_origin)
{
    for (long start = search_origin; start <= RSTRING_LEN(str); start++) {
	if (!onibi_character_boundary(str, start)) continue;
	rb_thread_check_ints();
	onibi_check_deadline();
	long end = 0;
	int native = onibi_rseq_simple_match(rseq, view, str, start,
					     search_origin, &end);
	if (native > 0) return Qtrue;
	if (native < 0) return Qundef;
    }
    return Qfalse;
}

static VALUE
onibi_vm_match_p(VALUE self, VALUE str)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(str);
    int str_encoding_index = rb_enc_get_index(str);
    onibi_set_deadline(obj->timeout_seconds);
    if (!NIL_P(obj->rseq_blob))
	obj->rseq_view_valid =
	    onibi_rseq_view_init(obj->rseq_blob, &obj->rseq_view) ? 1 : 0;
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
	VALUE result =
	    obj->execution_kind == ONIBI_EXEC_REGULAR
		? onibi_vm_regular_fast(obj->rseq, &obj->rseq_view, str, 0)
		: (obj->execution_kind == ONIBI_EXEC_TAGGED
		       ? onibi_vm_tagged_ordered(
			     obj->rseq, &obj->rseq_view, str, 0,
			     ONIBI_FEATURE_P(obj, ONIBI_FEATURE_CONDITIONAL) ||
				 ONIBI_FEATURE_P(obj, ONIBI_FEATURE_BACKREF) ||
				 ONIBI_FEATURE_P(obj, ONIBI_FEATURE_SUBROUTINE))
		       : onibi_vm_dynamic(obj->rseq, &obj->rseq_view, str, 0));
	onibi_deadline_ns = 0;
	if (result == Qundef)
	    return rb_funcall(obj->regexp, id_match_p, 1, str);
	return result;
    }
    onibi_deadline_ns = 0;
    return rb_funcall(obj->regexp, id_match_p, 1, str);
}

static VALUE
onibi_scan(VALUE self, VALUE str)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return rb_funcall(str, id_scan, 1, obj->regexp);
}
static VALUE
onibi_case_equal(VALUE self, VALUE other)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return rb_funcall(obj->regexp, id_case_equal, 1, other);
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
