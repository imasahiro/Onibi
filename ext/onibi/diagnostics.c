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
    OnibiDiagnosticSearch *call = (OnibiDiagnosticSearch *)(uintptr_t)opaque;
    return INT2NUM(onibi_vm_search(call->self, call->subject, 0, call->start,
				   call->finish));
}

static VALUE
onibi_diagnostic_search_cleanup(VALUE opaque)
{
    OnibiDiagnosticSearch *call = (OnibiDiagnosticSearch *)(uintptr_t)opaque;
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
    VALUE status =
	rb_ensure(onibi_diagnostic_search_call, (VALUE)(uintptr_t)&call,
		  onibi_diagnostic_search_cleanup, (VALUE)(uintptr_t)&call);
    return NUM2INT(status);
}

static VALUE
onibi_diagnostics_for(VALUE self, VALUE subject)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(subject);
    memset(&onibi_diagnostics, 0, sizeof(onibi_diagnostics));
    uint32_t capture_slots =
	!NIL_P(obj->rseq) ? obj->rseq_view.header->capture_count * 2U : 0;
    long *capture_result =
	capture_slots == 0 ? NULL : ALLOCA_N(long, capture_slots);
    if (capture_result)
	for (uint32_t i = 0; i < capture_slots; i++)
	    capture_result[i] = -1;
    long start = 0, finish = 0;
    int status = NIL_P(obj->rseq)
		     ? ONIBI_EXEC_STATUS_FALLBACK
		     : onibi_diagnostic_search(self, subject, &start, &finish,
					       capture_result);
    VALUE result = rb_hash_new();
    rb_hash_aset(result, ID2SYM(rb_intern("rseq")),
		 NIL_P(obj->rseq) ? Qfalse : Qtrue);
    rb_hash_aset(result, ID2SYM(rb_intern("regular_capable")),
		 NIL_P(obj->rseq)
		     ? Qfalse
		     : (obj->rseq_view.regular_capable ? Qtrue : Qfalse));
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
    VALUE captures = rb_ary_new_capa(
	NIL_P(obj->rseq) ? 0 : obj->rseq_view.header->capture_count);
    for (uint32_t i = 0; i < capture_slots / 2U; i++) {
	if ((capture_result[2U * i] >= 0 && capture_result[2U * i + 1U] < 0) ||
	    (capture_result[2U * i] < 0 && capture_result[2U * i + 1U] >= 0)) {
	    capture_result[2U * i] = -1;
	    capture_result[2U * i + 1U] = -1;
	}
	VALUE range =
	    rb_ary_new_from_args(2, LONG2NUM(capture_result[2U * i]),
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
	    rb_ary_push(edges,
			rb_ary_new_from_args(2, UINT2NUM(e->destination),
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
    int status =
	NIL_P(obj->rseq)
	    ? ONIBI_EXEC_STATUS_FALLBACK
	    : onibi_diagnostic_search(self, subject, &start, &finish, NULL);
    VALUE result = rb_hash_new();
    rb_hash_aset(result, ID2SYM(rb_intern("status")), INT2NUM(status));
    rb_hash_aset(result, ID2SYM(rb_intern("tag_events")),
		 ULONG2NUM(onibi_diagnostics.tag_events));
    return result;
}

typedef struct {
    VALUE source;
    int options;
    OnibiTokenVector tokens;
} OnibiNfaDiagnosticCall;

static VALUE
onibi_nfa_diagnostic_call(VALUE opaque)
{
    OnibiNfaDiagnosticCall *call = (OnibiNfaDiagnosticCall *)(uintptr_t)opaque;
    onibi_token_vector_init(&call->tokens);
    onibi_tokenize_internal(
	call->source, (call->options & ONIBI_OPT_EXTENDED) != 0, &call->tokens);
    VALUE parsed = onibi_parser_parse_internal(
	call->source, INT2NUM(call->options), &call->tokens);
    return onibi_compiler_nfa_diagnostics(parsed);
}

static VALUE
onibi_nfa_diagnostic_cleanup(VALUE opaque)
{
    OnibiNfaDiagnosticCall *call = (OnibiNfaDiagnosticCall *)(uintptr_t)opaque;
    onibi_token_vector_free(&call->tokens);
    return Qnil;
}

static VALUE
onibi_pre_elimination_nfa_diagnostics(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    OnibiNfaDiagnosticCall call = {obj->source, obj->options, {0}};
    return rb_ensure(onibi_nfa_diagnostic_call, (VALUE)(uintptr_t)&call,
		     onibi_nfa_diagnostic_cleanup, (VALUE)(uintptr_t)&call);
}

typedef struct {
    VALUE source;
    VALUE options;
    int phase;
    OnibiTokenVector tokens;
    VALUE parsed;
    int failure_fired;
    OnibiAllocationAccounting accounting;
} OnibiCompileFailureDiagnostic;

static VALUE
onibi_action_operand_diagnostics(void)
{
    OnibiGAction semantic[] = {
	{ONIBI_GA_CAPTURE_CLOSE, 0, 0, 1,
	 onibi_capture_boundary_slot(ONIBI_GIR_MAX_CAPTURE_COUNT - 1, 1)},
	onibi_capture_test_action(ONIBI_GIR_MAX_CAPTURE_COUNT - 1, 1),
	onibi_counter_action(ONIBI_GA_TEST_COUNTER_GE,
			     ONIBI_GIR_MAX_COUNTER_COUNT - 1, 1,
			     (long)UINT32_MAX),
    };
    OnibiRAction physical[sizeof(semantic) / sizeof(semantic[0])];
    for (size_t i = 0; i < sizeof(semantic) / sizeof(semantic[0]); i++)
	onibi_rseq_serialize_action(&semantic[i], &physical[i]);

    VALUE result = rb_hash_new();
#define SET_OPERAND(name, value)                                               \
    rb_hash_aset(result, ID2SYM(rb_intern(name)), ULL2NUM((uint64_t)(value)))
    SET_OPERAND("capture_boundary_slot", physical[0].arg16);
    SET_OPERAND("capture_reference", physical[1].arg16);
    SET_OPERAND("counter_slot", physical[2].arg16);
    SET_OPERAND("counter_value", physical[2].arg32);
#undef SET_OPERAND
    return result;
}

static VALUE
onibi_gir_verifier_diagnostics(VALUE self, VALUE scenario_value)
{
    (void)self;
    ID scenario = rb_to_id(scenario_value);
    if (scenario == rb_intern("action_operand_limits"))
	return onibi_action_operand_diagnostics();
    if (scenario == rb_intern("counter_value_overflow")) {
	(void)onibi_counter_action(ONIBI_GA_TEST_COUNTER_GE, 0, 1,
				   (long)UINT32_MAX + 1L);
    }
    OnibiGirStateEntry states[4];
    OnibiGirEdgeEntry edges[2];
    OnibiGirEdgeEntry starts[1];
    OnibiRSeqSubprogramEntry subprograms[2];
    OnibiGAction actions[2];
    OnibiStateId progress_slots[1] = {0};
    memset(states, 0, sizeof(states));
    memset(edges, 0, sizeof(edges));
    memset(starts, 0, sizeof(starts));
    memset(subprograms, 0, sizeof(subprograms));
    memset(actions, 0, sizeof(actions));
    states[0].id = 0;
    states[0].opcode = ONIBI_G_CHAR;
    states[0].value = 'a';
    states[0].literal[0] = 'a';
    states[0].literal_length = 1;
    states[1].id = 1;
    states[1].opcode = ONIBI_G_CHAR;
    states[1].value = 'b';
    states[1].literal[0] = 'b';
    states[1].literal_length = 1;
    states[2].id = 2;
    states[2].opcode = ONIBI_G_ACCEPT;
    states[3].id = 3;
    states[3].opcode = ONIBI_G_ACCEPT;
    edges[0].from = 0;
    edges[0].to = 1;
    edges[1].from = 1;
    edges[1].to = 3;
    starts[0].from = -1;
    starts[0].to = 0;
    subprograms[0] = (OnibiRSeqSubprogramEntry){0, 3, 0};
    OnibiGirStateVector state_vector = {states, 4, 4, NULL};
    OnibiGirEdgeVector edge_vector = {edges, 2, 2, NULL};
    OnibiGirEdgeVector start_vector = {starts, 1, 1, NULL};
    OnibiRSeqSubprogramVector subprogram_vector = {subprograms, 1, 2, NULL};
    OnibiIdVector progress_vector = {progress_slots, 0, 1, NULL};
    OnibiGIRView view = {&state_vector,
			 &edge_vector,
			 &start_vector,
			 &subprogram_vector,
			 &progress_vector,
			 4,
			 1,
			 1,
			 3,
			 0,
			 1,
			 0};

    if (scenario == rb_intern("state_ids"))
	states[1].id = 2;
    else if (scenario == rb_intern("state_opcode_payload"))
	states[0].literal_length = 0;
    else if (scenario == rb_intern("edge_state_range"))
	edges[0].to = 4;
    else if (scenario == rb_intern("edge_order")) {
	edges[0].from = 1;
	edges[0].to = 3;
	edges[1].from = 0;
	edges[1].to = 1;
    }
    else if (scenario == rb_intern("action_opcode")) {
	actions[0].code = (OnibiGActionOp)99;
	edges[0].actions = (OnibiGActionVector){actions, 1, 2, NULL};
    }
    else if (scenario == rb_intern("action_opcode_payload")) {
	actions[0] = (OnibiGAction){ONIBI_GA_MATCH_RESET, 0, 0, 1, 0};
	edges[0].actions = (OnibiGActionVector){actions, 1, 2, NULL};
    }
    else if (scenario == rb_intern("capture_slot")) {
	actions[0] = (OnibiGAction){ONIBI_GA_CAPTURE_CLOSE, 0, 0, 1, 2};
	edges[0].actions = (OnibiGActionVector){actions, 1, 2, NULL};
    }
    else if (scenario == rb_intern("capture_close_unused_payload")) {
	actions[0] = (OnibiGAction){ONIBI_GA_CAPTURE_CLOSE, 1, 0, 1, 1};
	edges[0].actions = (OnibiGActionVector){actions, 1, 2, NULL};
    }
    else if (scenario == rb_intern("counter_slot")) {
	actions[0] =
	    (OnibiGAction){ONIBI_GA_COUNTER_INIT, 0, 0, 1, 1, 0, 0, 1, 0};
	edges[0].actions = (OnibiGActionVector){actions, 1, 2, NULL};
    }
    else if (scenario == rb_intern("capture_count"))
	view.capture_count = (long)ONIBI_GIR_MAX_CAPTURE_COUNT + 1;
    else if (scenario == rb_intern("counter_count"))
	view.counter_count = (long)ONIBI_GIR_MAX_COUNTER_COUNT + 1;
    else if (scenario == rb_intern("subprogram_reference")) {
	states[0].opcode = ONIBI_G_CALL;
	states[0].value = 1;
	states[0].literal[0] = 0;
	states[0].literal_length = 0;
    }
    else if (scenario == rb_intern("semantic_capture_reference")) {
	states[0].opcode = ONIBI_G_BACKREF;
	states[0].value = 1;
	states[0].literal[0] = 0;
	states[0].literal_length = 0;
    }
    else if (scenario == rb_intern("repeat_progress"))
	progress_vector.count = 1;
    else if (scenario == rb_intern("start_edge"))
	starts[0].from = 0;
    else if (scenario == rb_intern("accept_state")) {
	edges[1].from = 3;
	edges[1].to = 0;
    }
    else if (scenario == rb_intern("lookaround_subprogram")) {
	actions[0] = (OnibiGAction){ONIBI_GA_ASSERT_POSITION, 0, 1, 0, 0, 1,
				    ONIBI_RAP_LOOKAHEAD,      1, 1, 1, 1};
	starts[0].actions = (OnibiGActionVector){actions, 1, 2, NULL};
    }
    else if (scenario == rb_intern("atomic_subprogram") ||
	     scenario == rb_intern("absence_subprogram")) {
	int atomic = scenario == rb_intern("atomic_subprogram");
	states[0].opcode = atomic ? ONIBI_G_ATOMIC : ONIBI_G_ABSENT;
	states[0].value = 1;
	states[0].literal[0] = 0;
	states[0].literal_length = 0;
	subprograms[1] = (OnibiRSeqSubprogramEntry){1, 2, 0};
	subprogram_vector.count = 2;
	view.semantic_subprogram_count = 2;
    }
    else if (scenario == rb_intern("resolved_options"))
	view.options = UINT32_C(0x80000000);
    else if (scenario == rb_intern("physical_limits")) {
	view.capture_count = ONIBI_GIR_MAX_CAPTURE_COUNT;
	view.counter_count = ONIBI_GIR_MAX_COUNTER_COUNT;
	actions[0] = (OnibiGAction){
	    ONIBI_GA_CAPTURE_CLOSE, 0, 0, 1,
	    onibi_capture_boundary_slot(ONIBI_GIR_MAX_CAPTURE_COUNT - 1, 1)};
	actions[1] = onibi_counter_action(
	    ONIBI_GA_COUNTER_INIT, ONIBI_GIR_MAX_COUNTER_COUNT - 1, 1, 0);
	edges[0].actions = (OnibiGActionVector){actions, 2, 2, NULL};
    }
    else if (scenario == rb_intern("capture_operand_overflow")) {
	(void)onibi_capture_boundary_slot(ONIBI_GIR_MAX_CAPTURE_COUNT, 0);
    }
    else if (scenario == rb_intern("counter_operand_overflow")) {
	(void)onibi_counter_action(ONIBI_GA_COUNTER_INIT,
				   ONIBI_GIR_MAX_COUNTER_COUNT, 1, 0);
    }
    else {
	rb_raise(rb_eArgError, "unknown GIR verifier diagnostic");
    }

    onibi_gir_verify(&view);
    VALUE result = rb_hash_new();
    rb_hash_aset(result, ID2SYM(rb_intern("capture_slot")),
		 UINT2NUM(actions[0].slot));
    rb_hash_aset(result, ID2SYM(rb_intern("counter_slot")),
		 UINT2NUM(actions[1].slot));
    return result;
}

static VALUE
onibi_compile_failure_diagnostic_call(VALUE opaque)
{
    OnibiCompileFailureDiagnostic *call =
	(OnibiCompileFailureDiagnostic *)(uintptr_t)opaque;
    int options = NUM2INT(call->options);
    onibi_token_vector_init(&call->tokens);
    onibi_tokenize_internal(call->source, (options & ONIBI_OPT_EXTENDED) != 0,
			    &call->tokens);
    call->parsed =
	onibi_parser_parse_internal(call->source, call->options, &call->tokens);
    int compiler_phase = call->phase <= 8 ? call->phase : 0;
    VALUE compiled = onibi_compiler_compile_with_failure(
	call->parsed, compiler_phase, &call->failure_fired, &call->accounting);
    if (call->phase >= 9)
	(void)onibi_rseq_lower_with_failure(
	    compiled, call->phase - 8, &call->failure_fired, &call->accounting);
    return Qtrue;
}

static VALUE
onibi_compile_failure_diagnostic_cleanup(VALUE opaque)
{
    OnibiCompileFailureDiagnostic *call =
	(OnibiCompileFailureDiagnostic *)(uintptr_t)opaque;
    onibi_token_vector_free(&call->tokens);
    return Qnil;
}

static VALUE
onibi_compile_failure_diagnostics(VALUE self, VALUE phase_value)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    int phase = NUM2INT(phase_value);
    if (phase < 1 || phase > 15)
	rb_raise(rb_eArgError, "compiler failure phase is out of range");
    OnibiCompileFailureDiagnostic call = {
	obj->source, INT2NUM(obj->options), phase, {0}, Qnil, 0, {0}};
    size_t allocations_before = call.accounting.live_count;
    if (allocations_before != 0)
	rb_raise(eRegexpError,
		 "stale compiler allocation exists before injected failure");
    int state = 0;
    rb_protect(onibi_compile_failure_diagnostic_call, (VALUE)(uintptr_t)&call,
	       &state);
    onibi_compile_failure_diagnostic_cleanup((VALUE)(uintptr_t)&call);
    if (!state) rb_raise(eRegexpError, "injected failure did not raise");
    rb_set_errinfo(Qnil);
    size_t allocations_after = call.accounting.live_count;
    if (allocations_after != allocations_before)
	rb_raise(eRegexpError,
		 "compiler allocation count changed after injected failure");
    if (!call.failure_fired)
	rb_raise(eRegexpError, "compiler failed before the injection point");
    VALUE result = rb_hash_new();
    rb_hash_aset(result, ID2SYM(rb_intern("raised")), Qtrue);
    rb_hash_aset(result, ID2SYM(rb_intern("allocations_before")),
		 SIZET2NUM(allocations_before));
    rb_hash_aset(result, ID2SYM(rb_intern("allocations_after")),
		 SIZET2NUM(allocations_after));
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
