static int
onibi_unicode_ctype_id(ID property)
{
    static ID ids[26];
    static int ready = 0;
    if (!ready) {
	const char *names[] = {"Alpha", "alpha", "Letter", "Digit",  "digit",
			       "Alnum", "alnum", "Lower",  "lower",  "Upper",
			       "upper", "Space", "space",  "Blank",  "blank",
			       "Word",	"word",	 "XDigit", "xdigit", "Cntrl",
			       "Print", "Graph", "Punct"};
	for (size_t i = 0; i < 23; i++)
	    ids[i] = rb_intern(names[i]);
	ready = 1;
    }
    if (property == ids[0] || property == ids[1] || property == ids[2])
	return ONIGENC_CTYPE_ALPHA;
    if (property == ids[3] || property == ids[4]) return ONIGENC_CTYPE_DIGIT;
    if (property == ids[5] || property == ids[6]) return ONIGENC_CTYPE_ALNUM;
    if (property == ids[7] || property == ids[8]) return ONIGENC_CTYPE_LOWER;
    if (property == ids[9] || property == ids[10]) return ONIGENC_CTYPE_UPPER;
    if (property == ids[11] || property == ids[12]) return ONIGENC_CTYPE_SPACE;
    if (property == ids[13] || property == ids[14]) return ONIGENC_CTYPE_BLANK;
    if (property == ids[15] || property == ids[16]) return ONIGENC_CTYPE_WORD;
    if (property == ids[17] || property == ids[18]) return ONIGENC_CTYPE_XDIGIT;
    if (property == ids[19]) return ONIGENC_CTYPE_CNTRL;
    if (property == ids[20]) return ONIGENC_CTYPE_PRINT;
    if (property == ids[21]) return ONIGENC_CTYPE_GRAPH;
    if (property == ids[22]) return ONIGENC_CTYPE_PUNCT;
    return -1;
}

/* Diagnostic compatibility adapter.  This Ruby Hash view is not consumed by
 * canonical GIR lowering; it exists only for verification/debug metadata. */
static VALUE
onibi_class_payload_with_ctypes(VALUE payload)
{
    VALUE copy = rb_hash_dup(payload);
    OnibiClassMatchMode match_mode =
	onibi_ast_kind(copy) == ONIBI_AST_CLASS_INTERSECTION
	    ? ONIBI_CLASS_MODE_INTERSECTION
	    : ONIBI_CLASS_MODE_NORMAL;
    rb_hash_aset(copy, ID2SYM(id_key_class_mode), INT2NUM(match_mode));
    int fold = RTEST(onibi_hash_value_id(copy, id_key_ignorecase));
    VALUE name_id = onibi_hash_value_id(copy, id_key_name_id);
    ID property = NIL_P(name_id) ? 0 : (ID)NUM2ULONG(name_id);
    int ctype = onibi_unicode_ctype_id(property);
    if (ctype >= 0) rb_hash_aset(copy, ID2SYM(id_key_ctype), INT2NUM(ctype));
    VALUE children = onibi_hash_value_id(copy, id_key_children);
    if (RB_TYPE_P(children, T_ARRAY)) {
	VALUE compiled = rb_ary_new_capa(RARRAY_LEN(children));
	for (long i = 0; i < RARRAY_LEN(children); i++) {
	    VALUE child = rb_ary_entry(children, i);
	    VALUE child_copy =
		RB_TYPE_P(child, T_HASH) ? rb_hash_dup(child) : child;
	    if (RB_TYPE_P(child_copy, T_HASH) &&
		(onibi_hash_value_id(child_copy, id_key_kind_code) ==
		     UINT2NUM(ONIBI_TOKEN_ESCAPE) ||
		 onibi_ast_kind(child_copy) == ONIBI_AST_ESCAPE)) {
		VALUE child_name_id =
		    onibi_hash_value_id(child_copy, id_key_name_id);
		ID property =
		    NIL_P(child_name_id) ? 0 : (ID)NUM2ULONG(child_name_id);
		int child_ctype = onibi_unicode_ctype_id(property);
		if (child_ctype >= 0)
		    rb_hash_aset(child_copy, ID2SYM(id_key_ctype),
				 INT2NUM(child_ctype));
	    }
	    if (fold && RB_TYPE_P(child_copy, T_HASH))
		rb_hash_aset(child_copy, ID2SYM(id_key_ignorecase), Qtrue);
	    rb_ary_push(compiled, child_copy);
	}
	rb_hash_aset(copy, ID2SYM(id_key_children), compiled);
    }
    VALUE operands = onibi_hash_value_id(copy, id_key_operands);
    if (RB_TYPE_P(operands, T_ARRAY)) {
	VALUE compiled_operands = rb_ary_new_capa(RARRAY_LEN(operands));
	for (long i = 0; i < RARRAY_LEN(operands); i++) {
	    VALUE operand =
		onibi_class_payload_with_ctypes(rb_ary_entry(operands, i));
	    if (fold) rb_hash_aset(operand, ID2SYM(id_key_ignorecase), Qtrue);
	    OnibiAstKind operand_type = onibi_ast_kind(operand);
	    if (operand_type == ONIBI_AST_CHARACTER_CLASS ||
		operand_type == ONIBI_AST_CLASS_INTERSECTION)
		rb_hash_aset(operand, ID2SYM(id_key_bitmap),
			     onibi_class_bitmap(operand, 0));
	    rb_ary_push(compiled_operands, operand);
	}
	rb_hash_aset(copy, ID2SYM(id_key_operands), compiled_operands);
    }
    return copy;
}

/* Internal test hook.  It reports the compiled contract and the executor
 * selected for one search.  The hook does not call MRI to obtain a result. */
typedef struct {
    VALUE self;
    VALUE subject;
    long *start;
    long *finish;
    long *previous_capture_result;
} OnibiDiagnosticSearch;

static VALUE
onibi_diagnostic_search_call(VALUE opaque)
{
    OnibiDiagnosticSearch *call =
	(OnibiDiagnosticSearch *)(uintptr_t)opaque;
    return INT2NUM(onibi_vm_search(call->self, call->subject, 0, call->start,
				   call->finish));
}

static VALUE
onibi_diagnostic_search_cleanup(VALUE opaque)
{
    OnibiDiagnosticSearch *call =
	(OnibiDiagnosticSearch *)(uintptr_t)opaque;
    onibi_regular_capture_result = call->previous_capture_result;
    return Qnil;
}

static int
onibi_diagnostic_search(VALUE self, VALUE subject, long *start, long *finish,
			long *capture_result)
{
    OnibiDiagnosticSearch call = {self, subject, start, finish,
				  onibi_regular_capture_result};
    onibi_regular_capture_result = capture_result;
    VALUE status = rb_ensure(onibi_diagnostic_search_call,
			     (VALUE)(uintptr_t)&call,
			     onibi_diagnostic_search_cleanup,
			     (VALUE)(uintptr_t)&call);
    return NUM2INT(status);
}

static VALUE
onibi_diagnostics_for(VALUE self, VALUE subject)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(subject);
    memset(&onibi_diagnostics, 0, sizeof(onibi_diagnostics));
    uint32_t capture_slots = !NIL_P(obj->rseq) ?
	obj->rseq_view.header->capture_count * 2U : 0;
    long *capture_result = capture_slots == 0 ? NULL : ALLOCA_N(long, capture_slots);
    if (capture_result)
	for (uint32_t i = 0; i < capture_slots; i++) capture_result[i] = -1;
    long start = 0, finish = 0;
	int status = NIL_P(obj->rseq)
			     ? ONIBI_EXEC_STATUS_FALLBACK
			     : onibi_diagnostic_search(self, subject, &start, &finish,
					       capture_result);
    VALUE result = rb_hash_new();
    rb_hash_aset(result, ID2SYM(rb_intern("rseq")),
		 NIL_P(obj->rseq) ? Qfalse : Qtrue);
    rb_hash_aset(result, ID2SYM(rb_intern("regular_capable")),
		 NIL_P(obj->rseq) ? Qfalse :
		 (obj->rseq_view.regular_capable ? Qtrue : Qfalse));
    rb_hash_aset(result, ID2SYM(rb_intern("exec_kind")),
		 UINT2NUM(NIL_P(obj->rseq) ? obj->execution_kind
					   : obj->rseq_view.header->exec_kind));
    if (!NIL_P(obj->rseq)) {
	rb_hash_aset(result, ID2SYM(rb_intern("capture_count")),
		     UINT2NUM(obj->rseq_view.header->capture_count));
	rb_hash_aset(result, ID2SYM(rb_intern("semantic_capture_count")),
			     UINT2NUM(obj->rseq_view.header->semantic_capture_count));
	rb_hash_aset(result, ID2SYM(rb_intern("start_edge_base")),
			     UINT2NUM(obj->rseq_view.header->start_edge_base));
	rb_hash_aset(result, ID2SYM(rb_intern("start_edge_count")),
			     UINT2NUM(obj->rseq_view.header->start_edge_count));
    }
    rb_hash_aset(result, ID2SYM(rb_intern("status")), INT2NUM(status));
    rb_hash_aset(result, ID2SYM(rb_intern("match_start")), LONG2NUM(start));
    rb_hash_aset(result, ID2SYM(rb_intern("match_end")), LONG2NUM(finish));
    VALUE captures = rb_ary_new_capa(NIL_P(obj->rseq)
					 ? 0
					 : obj->rseq_view.header->capture_count);
    for (uint32_t i = 0; i < capture_slots / 2U; i++) {
	if ((capture_result[2U * i] >= 0 && capture_result[2U * i + 1U] < 0) ||
	    (capture_result[2U * i] < 0 && capture_result[2U * i + 1U] >= 0))
	{
	    capture_result[2U * i] = -1;
	    capture_result[2U * i + 1U] = -1;
	}
	VALUE range = rb_ary_new_from_args(2, LONG2NUM(capture_result[2U * i]),
					   LONG2NUM(capture_result[2U * i + 1U]));
	rb_ary_push(captures, range);
    }
    rb_hash_aset(result, ID2SYM(rb_intern("captures")), captures);
    VALUE actions = rb_ary_new();
    if (!NIL_P(obj->rseq)) {
	for (uint32_t i = 0; i < obj->rseq_view.header->action_count; i++) {
	    const OnibiRAction *a = &obj->rseq_view.actions[i];
	    rb_ary_push(actions, rb_ary_new_from_args(3, INT2NUM(a->op),
							INT2NUM(a->flags),
							UINT2NUM(a->arg16)));
	}
    }
    rb_hash_aset(result, ID2SYM(rb_intern("actions")), actions);
    VALUE edges = rb_ary_new();
    if (!NIL_P(obj->rseq)) {
	for (uint32_t i = 0; i < obj->rseq_view.header->edge_count; i++) {
	    const OnibiREdge *e = &obj->rseq_view.edges[i];
	    rb_ary_push(edges, rb_ary_new_from_args(2, UINT2NUM(e->destination),
							UINT2NUM(e->action_offset)));
	}
    }
    rb_hash_aset(result, ID2SYM(rb_intern("edges")), edges);
    VALUE states = rb_ary_new();
    if (!NIL_P(obj->rseq)) {
	for (uint32_t i = 0; i < obj->rseq_view.header->state_count; i++) {
	    const OnibiRState *s = &obj->rseq_view.states[i];
	    rb_ary_push(states, rb_ary_new_from_args(3, INT2NUM(s->op),
							UINT2NUM(s->edge_base),
							UINT2NUM(s->edge_count)));
	}
    }
    rb_hash_aset(result, ID2SYM(rb_intern("states")), states);
    rb_hash_aset(result, ID2SYM(rb_intern("regular")),
		 ULONG2NUM(onibi_diagnostics.regular));
    rb_hash_aset(result, ID2SYM(rb_intern("tagged")),
		 ULONG2NUM(onibi_diagnostics.tagged));
    rb_hash_aset(result, ID2SYM(rb_intern("dynamic")),
		 ULONG2NUM(onibi_diagnostics.dynamic));
    rb_hash_aset(result, ID2SYM(rb_intern("dfs")),
		 ULONG2NUM(onibi_diagnostics.dfs));
    rb_hash_aset(result, ID2SYM(rb_intern("fallback")),
		 ULONG2NUM(onibi_diagnostics.fallback));
    rb_hash_aset(result, ID2SYM(rb_intern("tag_events")),
		 ULONG2NUM(onibi_diagnostics.tag_events));
    return result;
}

static VALUE
onibi_match_p_diagnostics(VALUE self, VALUE subject)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(subject);
    memset(&onibi_diagnostics, 0, sizeof(onibi_diagnostics));
    long start = 0, finish = 0;
	int status = NIL_P(obj->rseq)
			     ? ONIBI_EXEC_STATUS_FALLBACK
			     : onibi_diagnostic_search(self, subject, &start, &finish,
					       NULL);
    VALUE result = rb_hash_new();
    rb_hash_aset(result, ID2SYM(rb_intern("status")), INT2NUM(status));
    rb_hash_aset(result, ID2SYM(rb_intern("tag_events")),
			 ULONG2NUM(onibi_diagnostics.tag_events));
    return result;
}

static VALUE
onibi_internal_error_diagnostics(VALUE self, VALUE subject)
{
    onibi_inject_internal_error = 1;
    return onibi_diagnostics_for(self, subject);
}
/* Diagnostic and compatibility payload adapters.  Ruby Hash records created
 * here are never canonical compiler or runtime state. */
