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

static const char *const onibi_executor_error_names[] = {
    "none", "contract", "allocation", "malformed_program", "unexpected"};
static const char *const onibi_runtime_fallback_names[] = {"none",
							   "input_ineligible"};
static const char *const onibi_compile_error_names[] = {
    "ok",	  "unsupported", "invalid_pattern", "internal",
    "allocation", "verifier",	 "unexpected"};
static const char *const onibi_unsupported_reason_names[] = {
    "none",  "meta_escape", "escape",	     "grapheme",	  "class",
    "limit", "possessive",  "multiline_any", "zero_width_repeat", "noencoding"};

/* Internal test hook.  It reports the compiled contract and the executor
 * selected for one search.  The hook does not call MRI to obtain a result. */
static VALUE
onibi_diagnostics_for(VALUE self, VALUE subject)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(subject);
    memset(&onibi_diagnostics, 0, sizeof(onibi_diagnostics));
    uint32_t capture_count =
	!NIL_P(obj->rseq) ? obj->rseq_view.header->capture_count : 0;
    if (capture_count == UINT32_MAX)
	rb_raise(eRegexpError, "Onibi capture count is out of range");
    uint32_t num_regs = capture_count + 1U;
    OnibiBytePos *beg = ALLOCA_N(OnibiBytePos, num_regs);
    OnibiBytePos *end = ALLOCA_N(OnibiBytePos, num_regs);
    OnibiRawMatch raw_match = {.begin_byte = -1,
			       .end_byte = -1,
			       .num_regs = num_regs,
			       .beg = beg,
			       .end = end};
    if (!onibi_raw_match_reset(&raw_match))
	rb_raise(eRegexpError, "Onibi raw match setup failed");
    int status = onibi_vm_search(self, subject, 0, &raw_match);
    VALUE result = rb_hash_new();
    VALUE lowering_work = rb_hash_new();
    rb_hash_aset(lowering_work, ID2SYM(rb_intern("gir_class_probes")),
		 ULL2NUM(obj->lowering_work.gir_class_probes));
    rb_hash_aset(lowering_work, ID2SYM(rb_intern("rseq_class_probes")),
		 ULL2NUM(obj->lowering_work.rseq_class_probes));
    rb_hash_aset(lowering_work, ID2SYM(rb_intern("literal_probes")),
		 ULL2NUM(obj->lowering_work.literal_probes));
    rb_hash_aset(lowering_work, ID2SYM(rb_intern("action_probes")),
		 ULL2NUM(obj->lowering_work.action_probes));
    rb_hash_aset(lowering_work, ID2SYM(rb_intern("prefix_edges")),
		 ULL2NUM(obj->lowering_work.prefix_edges));
    rb_hash_aset(result, ID2SYM(rb_intern("lowering_work")), lowering_work);
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
	rb_hash_aset(result, ID2SYM(rb_intern("backref_count")),
		     UINT2NUM(obj->rseq_view.header->backref_count));
	rb_hash_aset(result, ID2SYM(rb_intern("semantic_capture_count")),
		     UINT2NUM(obj->rseq_view.header->semantic_capture_count));
	rb_hash_aset(result, ID2SYM(rb_intern("counter_count")),
		     UINT2NUM(obj->rseq_view.header->counter_count));
	rb_hash_aset(result, ID2SYM(rb_intern("start_edge_base")),
		     UINT2NUM(obj->rseq_view.header->start_edge_base));
	rb_hash_aset(result, ID2SYM(rb_intern("start_edge_count")),
		     UINT2NUM(obj->rseq_view.header->start_edge_count));
	VALUE backref_descriptors =
	    rb_ary_new_capa(obj->rseq_view.header->backref_count);
	for (uint32_t i = 0; i < obj->rseq_view.header->backref_count; i++) {
	    const OnibiBackrefDesc *descriptor = &obj->rseq_view.backrefs[i];
	    VALUE capture_ids = rb_ary_new_capa(descriptor->capture_count);
	    uint32_t list_index =
		(descriptor->capture_list_off -
		 obj->rseq_view.header->backref_lists_offset) /
		(uint32_t)sizeof(uint32_t);
	    for (uint16_t j = 0; j < descriptor->capture_count; j++)
		rb_ary_push(
		    capture_ids,
		    UINT2NUM(
			obj->rseq_view.backref_capture_ids[list_index + j]));
	    rb_ary_push(backref_descriptors,
			rb_ary_new_from_args(
			    4, capture_ids, UINT2NUM(descriptor->capture_count),
			    INT2NUM(descriptor->recursion_level),
			    UINT2NUM(descriptor->flags)));
	}
	rb_hash_aset(result, ID2SYM(rb_intern("backref_descriptors")),
		     backref_descriptors);
    }
    rb_hash_aset(result, ID2SYM(rb_intern("status")), INT2NUM(status));
    rb_hash_aset(
	result, ID2SYM(rb_intern("match_start")),
	LONG2NUM(status == ONIBI_EXEC_STATUS_MATCH ? raw_match.begin_byte : 0));
    rb_hash_aset(
	result, ID2SYM(rb_intern("match_end")),
	LONG2NUM(status == ONIBI_EXEC_STATUS_MATCH ? raw_match.end_byte : 0));
    rb_hash_aset(result, ID2SYM(rb_intern("raw_num_regs")),
		 UINT2NUM(raw_match.num_regs));
    VALUE captures = rb_ary_new_capa(
	NIL_P(obj->rseq) ? 0 : obj->rseq_view.header->capture_count);
    for (uint32_t i = 1; i < raw_match.num_regs; i++) {
	if ((raw_match.beg[i] >= 0 && raw_match.end[i] < 0) ||
	    (raw_match.beg[i] < 0 && raw_match.end[i] >= 0)) {
	    raw_match.beg[i] = -1;
	    raw_match.end[i] = -1;
	}
	VALUE range = rb_ary_new_from_args(2, LONG2NUM(raw_match.beg[i]),
					   LONG2NUM(raw_match.end[i]));
	rb_ary_push(captures, range);
    }
    rb_hash_aset(result, ID2SYM(rb_intern("captures")), captures);
    VALUE raw_registers = rb_ary_new_capa(raw_match.num_regs);
    for (uint32_t i = 0; i < raw_match.num_regs; i++)
	rb_ary_push(raw_registers,
		    rb_ary_new_from_args(2, LONG2NUM(raw_match.beg[i]),
					 LONG2NUM(raw_match.end[i])));
    rb_hash_aset(result, ID2SYM(rb_intern("raw_registers")), raw_registers);
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
    VALUE action_arg32 = rb_ary_new();
    if (!NIL_P(obj->rseq)) {
	for (uint32_t i = 0; i < obj->rseq_view.header->action_count; i++)
	    rb_ary_push(action_arg32,
			UINT2NUM(obj->rseq_view.actions[i].arg32));
    }
    rb_hash_aset(result, ID2SYM(rb_intern("action_arg32")), action_arg32);
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
    VALUE state_payloads = rb_ary_new();
    if (!NIL_P(obj->rseq)) {
	for (uint32_t i = 0; i < obj->rseq_view.header->state_count; i++)
	    rb_ary_push(state_payloads,
			UINT2NUM(obj->rseq_view.states[i].payload));
    }
    rb_hash_aset(result, ID2SYM(rb_intern("state_payloads")), state_payloads);
    VALUE subprograms = rb_ary_new();
    VALUE lookbehind_widths = rb_ary_new();
    if (!NIL_P(obj->rseq)) {
	for (uint32_t i = 0; i < obj->rseq_view.header->subprogram_count; i++) {
	    const OnibiSubprogramDesc *s = &obj->rseq_view.subprograms[i];
	    VALUE record = rb_hash_new();
	    rb_hash_aset(record, ID2SYM(rb_intern("entry")),
			 UINT2NUM(s->entry));
	    rb_hash_aset(record, ID2SYM(rb_intern("accept")),
			 UINT2NUM(s->accept));
	    rb_hash_aset(record, ID2SYM(rb_intern("kind")), INT2NUM(s->kind));
	    rb_hash_aset(record, ID2SYM(rb_intern("effects")),
			 UINT2NUM(s->effects));
	    rb_hash_aset(record, ID2SYM(rb_intern("flags")),
			 UINT2NUM(s->flags));
	    rb_hash_aset(record, ID2SYM(rb_intern("options")),
			 UINT2NUM(s->option_env.options));
	    rb_hash_aset(record, ID2SYM(rb_intern("encoding_index")),
			 INT2NUM(s->option_env.encoding_index));
	    rb_hash_aset(record, ID2SYM(rb_intern("entry_edge_base")),
			 UINT2NUM(s->entry_edge_base));
	    rb_hash_aset(record, ID2SYM(rb_intern("entry_edge_count")),
			 UINT2NUM(s->entry_edge_count));
	    rb_hash_aset(record, ID2SYM(rb_intern("width_base")),
			 UINT2NUM(s->width_base));
	    rb_hash_aset(record, ID2SYM(rb_intern("width_count")),
			 UINT2NUM(s->width_count));
	    rb_ary_push(subprograms, record);
	}
	for (uint32_t i = 0; i < obj->rseq_view.header->lookbehind_width_count;
	     i++)
	    rb_ary_push(lookbehind_widths,
			UINT2NUM(obj->rseq_view.lookbehind_widths[i]));
    }
    rb_hash_aset(result, ID2SYM(rb_intern("subprograms")), subprograms);
    rb_hash_aset(result, ID2SYM(rb_intern("lookbehind_widths")),
		 lookbehind_widths);
    VALUE class_kinds = rb_ary_new();
    if (!NIL_P(obj->rseq)) {
	static const char *const names[] = {"ascii_bitmap", "codepoint_ranges",
					    "encoding_ctype", "mixed"};
	for (uint32_t i = 0; i < obj->rseq_view.header->class_count; i++) {
	    const OnibiClassDesc *klass = &obj->rseq_view.classes[i];
	    rb_ary_push(class_kinds, ID2SYM(rb_intern(names[klass->kind])));
	}
    }
    rb_hash_aset(result, ID2SYM(rb_intern("class_kinds")), class_kinds);
    VALUE class_flags = rb_ary_new();
    if (!NIL_P(obj->rseq)) {
	for (uint32_t i = 0; i < obj->rseq_view.header->class_count; i++)
	    rb_ary_push(class_flags, UINT2NUM(obj->rseq_view.classes[i].flags));
    }
    rb_hash_aset(result, ID2SYM(rb_intern("class_flags")), class_flags);
    rb_hash_aset(result, ID2SYM(rb_intern("regular")),
		 ULONG2NUM(onibi_diagnostics.regular));
    rb_hash_aset(result, ID2SYM(rb_intern("regular_candidate_starts")),
		 ULONG2NUM(onibi_diagnostics.regular_candidate_starts));
    rb_hash_aset(result, ID2SYM(rb_intern("regular_buffer_grows")),
		 ULONG2NUM(onibi_diagnostics.regular_buffer_grows));
    rb_hash_aset(result, ID2SYM(rb_intern("regular_buffer_reuses")),
		 ULONG2NUM(onibi_diagnostics.regular_buffer_reuses));
    rb_hash_aset(result, ID2SYM(rb_intern("tagged")),
		 ULONG2NUM(onibi_diagnostics.tagged));
    rb_hash_aset(result, ID2SYM(rb_intern("dynamic")),
		 ULONG2NUM(onibi_diagnostics.dynamic));
    rb_hash_aset(result, ID2SYM(rb_intern("poll_count")),
		 ULONG2NUM(onibi_diagnostics.poll_count));
    rb_hash_aset(result, ID2SYM(rb_intern("work_polls")),
		 ULONG2NUM(onibi_diagnostics.poll_count));
    rb_hash_aset(result, ID2SYM(rb_intern("work_charged")),
		 ULL2NUM(onibi_diagnostics.work_charged));
    rb_hash_aset(result, ID2SYM(rb_intern("max_charged_work")),
		 ULL2NUM(onibi_diagnostics.max_charged_work));
    rb_hash_aset(result, ID2SYM(rb_intern("dfs")),
		 ULONG2NUM(onibi_diagnostics.dfs));
    rb_hash_aset(result, ID2SYM(rb_intern("fallback")),
		 ULONG2NUM(onibi_diagnostics.fallback));
    rb_hash_aset(
	result, ID2SYM(rb_intern("compile_error_kind")),
	ID2SYM(rb_intern(onibi_compile_error_names[obj->compile_error_kind])));
    rb_hash_aset(result, ID2SYM(rb_intern("unsupported_reason")),
		 ID2SYM(rb_intern(
		     onibi_unsupported_reason_names[obj->unsupported_reason])));
    rb_hash_aset(
	result, ID2SYM(rb_intern("fallback_reason")),
	ID2SYM(rb_intern(
	    onibi_diagnostics.runtime_fallback_reason !=
		    ONIBI_RUNTIME_FALLBACK_NONE
		? onibi_runtime_fallback_names[onibi_diagnostics
						   .runtime_fallback_reason]
		: onibi_unsupported_reason_names[obj->fallback_reason])));
    rb_hash_aset(result, ID2SYM(rb_intern("executor_error_kind")),
		 ID2SYM(rb_intern(
		     onibi_executor_error_names[onibi_diagnostics
						    .executor_error_kind])));
    rb_hash_aset(result, ID2SYM(rb_intern("tag_events")),
		 ULONG2NUM(onibi_diagnostics.tag_events));
    rb_hash_aset(result, ID2SYM(rb_intern("order_nodes")),
		 SIZET2NUM(onibi_diagnostics.order_nodes));
    rb_hash_aset(result, ID2SYM(rb_intern("capture_events")),
		 SIZET2NUM(onibi_diagnostics.capture_events));
    rb_hash_aset(result, ID2SYM(rb_intern("capture_event_roots")),
		 SIZET2NUM(onibi_diagnostics.capture_event_roots));
    rb_hash_aset(result, ID2SYM(rb_intern("capture_event_owners")),
		 SIZET2NUM(onibi_diagnostics.capture_event_owners));
    rb_hash_aset(result, ID2SYM(rb_intern("materialization_event_visits")),
		 SIZET2NUM(onibi_diagnostics.materialization_event_visits));
    return result;
}

static VALUE
onibi_match_p_diagnostics(VALUE self, VALUE subject)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    StringValue(subject);
    memset(&onibi_diagnostics, 0, sizeof(onibi_diagnostics));
    OnibiRawMatch raw_match = {.begin_byte = -1, .end_byte = -1};
    int status = onibi_vm_search(self, subject, 0, &raw_match);
    VALUE result = rb_hash_new();
    rb_hash_aset(result, ID2SYM(rb_intern("status")), INT2NUM(status));
    rb_hash_aset(
	result, ID2SYM(rb_intern("fallback_reason")),
	ID2SYM(rb_intern(
	    onibi_diagnostics.runtime_fallback_reason !=
		    ONIBI_RUNTIME_FALLBACK_NONE
		? onibi_runtime_fallback_names[onibi_diagnostics
						   .runtime_fallback_reason]
		: onibi_unsupported_reason_names[obj->fallback_reason])));
    rb_hash_aset(result, ID2SYM(rb_intern("executor_error_kind")),
		 ID2SYM(rb_intern(
		     onibi_executor_error_names[onibi_diagnostics
						    .executor_error_kind])));
    rb_hash_aset(result, ID2SYM(rb_intern("tag_events")),
		 ULONG2NUM(onibi_diagnostics.tag_events));
    rb_hash_aset(result, ID2SYM(rb_intern("poll_count")),
		 ULONG2NUM(onibi_diagnostics.poll_count));
    rb_hash_aset(result, ID2SYM(rb_intern("work_polls")),
		 ULONG2NUM(onibi_diagnostics.poll_count));
    rb_hash_aset(result, ID2SYM(rb_intern("work_charged")),
		 ULL2NUM(onibi_diagnostics.work_charged));
    rb_hash_aset(result, ID2SYM(rb_intern("max_charged_work")),
		 ULL2NUM(onibi_diagnostics.max_charged_work));
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

static OnibiGAction
onibi_nullable_diagnostic_action(OnibiGActionOp code, uint16_t slot,
				 uint32_t capture)
{
    int has_capture = code == ONIBI_GA_NULL_CAPTURE;
    return (OnibiGAction){code, 0,	     0,	      1, slot, 0,
			  0,	has_capture, capture, 0, 0};
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
    OnibiGirEdgeEntry edges[4];
    OnibiGirEdgeEntry starts[4];
    OnibiRSeqSubprogramEntry subprograms[2];
    OnibiBackrefDesc backrefs[1];
    OnibiStateId backref_capture_ids[1];
    OnibiGAction actions[16];
    unsigned char class_bitmap[32];
    OnibiCodepointRange class_ranges[2] = {{10, 20}, {15, 30}};
    OnibiClassExpr class_expr[1] = {{0, 0, ONIBI_CLASS_EXPR_UNION, 0, 0}};
    OnibiSemanticClass classes[1];
    OnibiStateId progress_slots[1] = {0};
    memset(states, 0, sizeof(states));
    memset(edges, 0, sizeof(edges));
    memset(starts, 0, sizeof(starts));
    memset(subprograms, 0, sizeof(subprograms));
    memset(backrefs, 0, sizeof(backrefs));
    memset(backref_capture_ids, 0, sizeof(backref_capture_ids));
    memset(actions, 0, sizeof(actions));
    memset(class_bitmap, 0, sizeof(class_bitmap));
    classes[0] = (OnibiSemanticClass){class_bitmap, sizeof(class_bitmap),
				      ONIBI_CLASS_ASCII_BITMAP, 0};
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
    OnibiGirEdgeVector edge_vector = {edges, 2, 4, NULL};
    OnibiGirEdgeVector start_vector = {starts, 1, 4, NULL};
    OnibiGirEdgeVector subprogram_entry_vector = {NULL, 0, 0, NULL};
    OnibiRSeqSubprogramVector subprogram_vector = {subprograms, 1, 2, NULL};
    OnibiBackrefDescVector backref_vector = {backrefs, 0, 1, NULL};
    OnibiIdVector backref_capture_vector = {backref_capture_ids, 0, 1, NULL};
    OnibiIdVector lookbehind_width_vector = {NULL, 0, 0, NULL};
    OnibiSemanticClassVector class_vector = {classes, 0, 1, NULL};
    OnibiIdVector progress_vector = {progress_slots, 0, 1, NULL};
    OnibiGIRView view = {&state_vector,
			 &edge_vector,
			 &start_vector,
			 &subprogram_entry_vector,
			 &subprogram_vector,
			 &backref_vector,
			 &backref_capture_vector,
			 &lookbehind_width_vector,
			 &class_vector,
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
    else if (scenario == rb_intern("nullable_owner_range")) {
	view.counter_count = 2;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 1, 0);
	edges[0].actions = (OnibiGActionVector){actions, 1, 8, NULL};
    }
    else if (scenario == rb_intern("nullable_owner_overlap")) {
	view.counter_count = 3;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	actions[1] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 1, 0);
	edges[0].actions = (OnibiGActionVector){actions, 2, 8, NULL};
    }
    else if (scenario == rb_intern("nullable_owner_wrong_base")) {
	view.counter_count = 3;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	actions[1] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_CAPTURE, 1, 0);
	edges[0].actions = (OnibiGActionVector){actions, 2, 8, NULL};
    }
    else if (scenario == rb_intern("nullable_counter_alias")) {
	view.counter_count = 3;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	actions[1] = onibi_counter_action(ONIBI_GA_COUNTER_INIT, 1, 0, 0);
	edges[0].actions = (OnibiGActionVector){actions, 2, 8, NULL};
    }
    else if (scenario == rb_intern("nullable_progress_alias")) {
	view.counter_count = 3;
	progress_slots[0] = 1;
	progress_vector.count = 1;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	starts[0].actions = (OnibiGActionVector){actions, 1, 8, NULL};
	actions[1] = onibi_counter_action(ONIBI_GA_PROGRESS, 1, 0, 0);
	edges[1].from = 1;
	edges[1].to = 0;
	edges[1].actions = (OnibiGActionVector){actions + 1, 1, 1, NULL};
    }
    else if (scenario == rb_intern("nullable_uninitialized_all")) {
	view.counter_count = 2;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_CAPTURE, 0, 0);
	actions[1] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	starts[1].from = -1;
	starts[1].to = 2;
	starts[1].actions = (OnibiGActionVector){actions + 1, 1, 1, NULL};
	start_vector.count = 2;
	start_vector.capacity = 2;
	edges[0].actions = (OnibiGActionVector){actions, 1, 8, NULL};
    }
    else if (scenario == rb_intern("nullable_uninitialized_one_path")) {
	view.counter_count = 2;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	starts[0].actions = (OnibiGActionVector){actions, 1, 8, NULL};
	starts[1].to = 1;
	starts[1].from = -1;
	starts[1].actions = (OnibiGActionVector){NULL, 0, 0, NULL};
	start_vector.count = 2;
	start_vector.capacity = 2;
	actions[1] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_CAPTURE, 0, 0);
	edges[1].actions = (OnibiGActionVector){actions + 1, 1, 1, NULL};
    }
    else if (scenario == rb_intern("nullable_completed_read")) {
	view.counter_count = 2;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	actions[1] = onibi_nullable_diagnostic_action(ONIBI_GA_NULL_STOP, 0, 0);
	actions[2] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_CAPTURE, 0, 0);
	edges[0].actions = (OnibiGActionVector){actions, 3, 8, NULL};
    }
    else if (scenario == rb_intern("nullable_valid_nested")) {
	view.capture_count = 2;
	view.counter_count = 4;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	actions[1] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 2, 0);
	actions[2] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_CAPTURE, 2, 1);
	actions[3] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_CAPTURE, 0, 0);
	actions[4] = onibi_nullable_diagnostic_action(ONIBI_GA_NULL_STOP, 2, 0);
	actions[5] = onibi_nullable_diagnostic_action(ONIBI_GA_NULL_STOP, 0, 0);
	starts[0].actions = (OnibiGActionVector){actions, 6, 8, NULL};
    }
    else if (scenario == rb_intern("nullable_valid_repeated")) {
	view.counter_count = 2;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	actions[1] = onibi_nullable_diagnostic_action(ONIBI_GA_NULL_STOP, 0, 0);
	actions[2] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	actions[3] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_CAPTURE, 0, 0);
	edges[0].actions = (OnibiGActionVector){actions, 4, 8, NULL};
    }
    else if (scenario == rb_intern("nullable_reachability_wrap")) {
	view.counter_count = 2;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	starts[0].actions = (OnibiGActionVector){actions, 1, 16, NULL};
	edges[0] = (OnibiGirEdgeEntry){0, 1, 0, {NULL, 0, 0, NULL}};
	edges[1] = (OnibiGirEdgeEntry){0, 2, 0, {NULL, 0, 0, NULL}};
	edges[2] = (OnibiGirEdgeEntry){0, 3, 0, {NULL, 0, 0, NULL}};
	edge_vector.count = 3;
    }
    else if (scenario == rb_intern("nullable_compact_facts")) {
	view.counter_count = ONIBI_GIR_MAX_COUNTER_COUNT;
	actions[0] =
	    onibi_nullable_diagnostic_action(ONIBI_GA_NULL_ENTER, 0, 0);
	starts[0].actions = (OnibiGActionVector){actions, 1, 16, NULL};
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
    else if (scenario == rb_intern("backref_descriptor_empty") ||
	     scenario == rb_intern("backref_descriptor_flags") ||
	     scenario == rb_intern("backref_descriptor_capture") ||
	     scenario == rb_intern("backref_state_flags")) {
	states[0].opcode = ONIBI_G_BACKREF;
	states[0].value = 0;
	states[0].literal[0] = 0;
	states[0].literal_length = 0;
	backref_vector.count = 1;
	backref_capture_vector.count = 1;
	backrefs[0] = (OnibiBackrefDesc){0, 1, 0, ONIBI_BACKREF_FLAG_NAMED};
	backref_capture_ids[0] = 0;
	if (scenario == rb_intern("backref_descriptor_empty"))
	    backrefs[0].capture_count = 0;
	else if (scenario == rb_intern("backref_descriptor_flags"))
	    backrefs[0].flags = UINT16_C(0x8000);
	else if (scenario == rb_intern("backref_descriptor_capture"))
	    backref_capture_ids[0] = (OnibiStateId)view.capture_count;
	else
	    states[0].flags = ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE;
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
    else if (scenario == rb_intern("class_descriptor_kind")) {
	class_vector.count = 1;
	classes[0].kind = UINT8_MAX;
    }
    else if (scenario == rb_intern("class_descriptor_shape")) {
	class_vector.count = 1;
	classes[0].kind = ONIBI_CLASS_ENCODING_CTYPE;
	classes[0].data_length = 3;
    }
    else if (scenario == rb_intern("class_fold_metadata")) {
	class_vector.count = 1;
	classes[0].incomplete_casefold = 1;
    }
    else if (scenario == rb_intern("class_range_order")) {
	class_vector.count = 1;
	classes[0].kind = ONIBI_CLASS_CODEPOINT_RANGES;
	classes[0].data = (unsigned char *)class_ranges;
	classes[0].data_length = sizeof(class_ranges);
    }
    else if (scenario == rb_intern("class_mixed_stack")) {
	class_vector.count = 1;
	classes[0].kind = ONIBI_CLASS_MIXED;
	classes[0].data = (unsigned char *)class_expr;
	classes[0].data_length = sizeof(class_expr);
    }
    else if (scenario == rb_intern("class_reference")) {
	class_vector.count = 1;
	states[0].opcode = ONIBI_G_CLASS;
	states[0].value = 1;
	states[0].literal[0] = 0;
	states[0].literal_length = 0;
    }
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

    size_t nullable_fact_words = onibi_gir_verify(&view);
    VALUE result = rb_hash_new();
    rb_hash_aset(result, ID2SYM(rb_intern("capture_slot")),
		 UINT2NUM(actions[0].slot));
    rb_hash_aset(result, ID2SYM(rb_intern("counter_slot")),
		 UINT2NUM(actions[1].slot));
    rb_hash_aset(result, ID2SYM(rb_intern("nullable_fact_words")),
		 SIZET2NUM(nullable_fact_words));
    return result;
}

/* This hook changes a private copy of a published blob. It exists only for
 * verifier tests. Normal construction validates the original blob once. */
static VALUE
onibi_rseq_verifier_diagnostics(VALUE self, VALUE scenario_value)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    if (NIL_P(obj->rseq_blob))
	rb_raise(rb_eArgError,
		 "RSeq verifier diagnostic requires an RSeq blob");
    VALUE blob = rb_str_dup(obj->rseq_blob);
    OnibiRSeqHeader *header = (OnibiRSeqHeader *)RSTRING_PTR(blob);
    OnibiRState *states =
	(OnibiRState *)(RSTRING_PTR(blob) + header->states_offset);
    OnibiREdge *edges =
	(OnibiREdge *)(RSTRING_PTR(blob) + header->edges_offset);
    OnibiRAction *actions =
	(OnibiRAction *)(RSTRING_PTR(blob) + header->actions_offset);
    OnibiClassDesc *classes =
	(OnibiClassDesc *)(RSTRING_PTR(blob) + header->classes_offset);
    OnibiLiteralDesc *literals =
	(OnibiLiteralDesc *)(RSTRING_PTR(blob) + header->descriptors_offset);
    OnibiBackrefDesc *backrefs =
	(OnibiBackrefDesc *)(RSTRING_PTR(blob) + header->backrefs_offset);
    uint32_t *backref_capture_ids =
	(uint32_t *)(RSTRING_PTR(blob) + header->backref_lists_offset);
    OnibiSubprogramDesc *subprograms =
	(OnibiSubprogramDesc *)(RSTRING_PTR(blob) + header->subprograms_offset);
    ID scenario = rb_to_id(scenario_value);
    if (scenario == rb_intern("section_order"))
	header->edges_offset = header->states_offset;
    else if (scenario == rb_intern("section_alignment"))
	header->states_offset += 2;
    else if (scenario == rb_intern("section_overflow"))
	header->blob_size = UINT32_MAX;
    else if (scenario == rb_intern("state_edge_range"))
	states[0].edge_base = header->start_edge_base;
    else if (scenario == rb_intern("start_edge_count"))
	header->start_edge_count = 0;
    else if (scenario == rb_intern("state_opcode"))
	states[0].op = UINT8_MAX;
    else if (scenario == rb_intern("state_any_payload")) {
	states[0].op = ONIBI_RS_ANY;
	states[0].payload = 1;
    }
    else if (scenario == rb_intern("edge_destination"))
	edges[0].destination = header->state_count;
    else if (scenario == rb_intern("action_boundary")) {
	uint32_t interior = UINT32_MAX;
	for (uint32_t i = 1; i < header->action_count; i++)
	    if (actions[i].op == ONIBI_RA_END &&
		actions[i - 1].op != ONIBI_RA_END) {
		interior = i;
		break;
	    }
	if (interior == UINT32_MAX)
	    rb_raise(rb_eRuntimeError,
		     "action-boundary diagnostic requires an interior action");
	edges[0].action_offset =
	    (interior + 1U) * (uint32_t)sizeof(OnibiRAction);
    }
    else if (scenario == rb_intern("action_termination"))
	actions[header->action_count - 1].op = ONIBI_RA_CAPTURE;
    else if (scenario == rb_intern("action_capture"))
	actions[0] = (OnibiRAction){ONIBI_RA_CAPTURE, 2, 0, 0};
    else if (scenario == rb_intern("action_match_reset"))
	actions[0] = (OnibiRAction){ONIBI_RA_MATCH_RESET, 0, 1, 0};
    else if (scenario == rb_intern("action_position"))
	actions[0] = (OnibiRAction){ONIBI_RA_ASSERT_POSITION, 0,
				    (uint16_t)ONIBI_RAP_LOOKAHEAD, 0};
    else if (scenario == rb_intern("action_subprogram"))
	actions[0] = (OnibiRAction){ONIBI_RA_ASSERT_SUBPROGRAM, 1,
				    ONIBI_RAP_LOOKAHEAD, 0};
    else if (scenario == rb_intern("action_test_capture"))
	actions[0] =
	    (OnibiRAction){ONIBI_RA_TEST_CAPTURE, ONIBI_RA_TEST_CAPTURE_SET,
			   (uint16_t)header->capture_count, 0};
    else if (scenario == rb_intern("action_counter_set"))
	actions[0] = (OnibiRAction){ONIBI_RA_COUNTER_SET, 0, 0, 0};
    else if (scenario == rb_intern("action_counter_add"))
	actions[0] = (OnibiRAction){ONIBI_RA_COUNTER_ADD, 0, 0, 1};
    else if (scenario == rb_intern("action_counter_test"))
	actions[0] = (OnibiRAction){ONIBI_RA_COUNTER_TEST, 2, 0, 0};
    else if (scenario == rb_intern("action_progress"))
	actions[0] = (OnibiRAction){ONIBI_RA_PROGRESS, 0, 0, 1};
    else if (scenario == rb_intern("nullable_owner_range")) {
	for (uint32_t i = 0; i < header->action_count; i++)
	    if (actions[i].op == ONIBI_RA_NULL_ENTER) {
		actions[i].arg16 = (uint16_t)(header->counter_count - 1U);
		break;
	    }
    }
    else if (scenario == rb_intern("nullable_owner_overlap")) {
	uint16_t first = UINT16_MAX;
	for (uint32_t i = 0; i < header->action_count; i++) {
	    if (actions[i].op != ONIBI_RA_NULL_ENTER) continue;
	    if (first == UINT16_MAX) {
		first = actions[i].arg16;
		continue;
	    }
	    if (actions[i].arg16 != first) {
		actions[i].arg16 = (uint16_t)(first + 1U);
		break;
	    }
	}
    }
    else if (scenario == rb_intern("nullable_owner_wrong_base")) {
	uint16_t owner = UINT16_MAX;
	for (uint32_t i = 0; i < header->action_count; i++)
	    if (actions[i].op == ONIBI_RA_NULL_ENTER) {
		owner = actions[i].arg16;
		break;
	    }
	if (owner == UINT16_MAX)
	    rb_raise(rb_eRuntimeError,
		     "nullable diagnostic requires a nullable owner");
	for (uint32_t i = 0; i < header->action_count; i++)
	    if (actions[i].op == ONIBI_RA_NULL_CAPTURE ||
		actions[i].op == ONIBI_RA_NULL_CONTINUE ||
		actions[i].op == ONIBI_RA_NULL_STOP) {
		actions[i].arg16 = (uint16_t)(owner + 1U);
		break;
	    }
    }
    else if (scenario == rb_intern("nullable_counter_alias")) {
	uint16_t owner = UINT16_MAX;
	for (uint32_t i = 0; i < header->action_count; i++)
	    if (actions[i].op == ONIBI_RA_NULL_ENTER) {
		owner = actions[i].arg16;
		break;
	    }
	if (owner == UINT16_MAX)
	    rb_raise(rb_eRuntimeError,
		     "nullable diagnostic requires a nullable owner");
	for (uint32_t i = 0; i < header->action_count; i++)
	    if (actions[i].op == ONIBI_RA_COUNTER_SET ||
		actions[i].op == ONIBI_RA_COUNTER_ADD ||
		actions[i].op == ONIBI_RA_COUNTER_TEST) {
		actions[i].arg16 = owner;
		break;
	    }
    }
    else if (scenario == rb_intern("nullable_progress_alias")) {
	uint16_t owner = UINT16_MAX;
	for (uint32_t i = 0; i < header->action_count; i++)
	    if (actions[i].op == ONIBI_RA_NULL_ENTER) {
		owner = actions[i].arg16;
		break;
	    }
	if (owner == UINT16_MAX)
	    rb_raise(rb_eRuntimeError,
		     "nullable diagnostic requires a nullable owner");
	for (uint32_t i = 0; i < header->action_count; i++)
	    if (actions[i].op == ONIBI_RA_COUNTER_SET ||
		actions[i].op == ONIBI_RA_COUNTER_ADD ||
		actions[i].op == ONIBI_RA_COUNTER_TEST) {
		actions[i].op = ONIBI_RA_PROGRESS;
		actions[i].flags = 0;
		actions[i].arg16 = (uint16_t)(owner + 1U);
		actions[i].arg32 = 0;
		break;
	    }
    }
    else if (scenario == rb_intern("nullable_uninitialized_all")) {
	int changed = 0;
	uint32_t declaration = UINT32_MAX;
	for (uint32_t i = 0; i < header->action_count; i++)
	    if (actions[i].op == ONIBI_RA_NULL_ENTER) {
		actions[i].op = ONIBI_RA_NULL_CAPTURE;
		actions[i].arg32 = 0;
		changed = 1;
	    }
	for (uint32_t i = header->action_count; i-- > 0;) {
	    if (actions[i].op == ONIBI_RA_NULL_CAPTURE) {
		declaration = i;
		break;
	    }
	}
	if (declaration != UINT32_MAX)
	    actions[declaration].op = ONIBI_RA_NULL_ENTER;
	if (!changed)
	    rb_raise(rb_eRuntimeError,
		     "nullable diagnostic requires a nullable owner");
    }
    else if (scenario == rb_intern("nullable_uninitialized_one_path")) {
	int changed = 0;
	if (header->start_edge_count > 1) {
	    uint32_t offset = edges[header->start_edge_base + 1U].action_offset;
	    uint32_t index = offset / (uint32_t)sizeof(OnibiRAction) - 1U;
	    while (index < header->action_count &&
		   actions[index].op != ONIBI_RA_END) {
		if (actions[index].op == ONIBI_RA_NULL_ENTER) {
		    actions[index].op = ONIBI_RA_NULL_CAPTURE;
		    actions[index].arg32 = 0;
		    changed = 1;
		    break;
		}
		index++;
	    }
	}
	if (!changed)
	    rb_raise(rb_eRuntimeError,
		     "nullable diagnostic requires a branched nullable owner");
    }
    else if (scenario == rb_intern("nullable_completed_read")) {
	int changed = 0;
	for (uint32_t i = 0; i + 1U < header->action_count; i++)
	    if ((actions[i].op == ONIBI_RA_NULL_CONTINUE ||
		 actions[i].op == ONIBI_RA_NULL_STOP) &&
		(actions[i + 1U].op == ONIBI_RA_COUNTER_SET ||
		 actions[i + 1U].op == ONIBI_RA_COUNTER_ADD ||
		 actions[i + 1U].op == ONIBI_RA_COUNTER_TEST)) {
		actions[i + 1U].arg16 = actions[i].arg16;
		actions[i + 1U].op = ONIBI_RA_NULL_CAPTURE;
		actions[i + 1U].flags = 0;
		actions[i + 1U].arg32 = 0;
		changed = 1;
		break;
	    }
	if (!changed)
	    rb_raise(rb_eRuntimeError,
		     "nullable diagnostic requires a completed owner");
    }
    else if (scenario == rb_intern("nullable_bounded_branching") ||
	     scenario == rb_intern("nullable_compact_facts")) {
	/* Keep the private blob unchanged. The verifier run is the assertion.
	 */
    }
    else if (scenario == rb_intern("class_descriptor"))
	classes[0].kind = UINT8_MAX;
    else if (scenario == rb_intern("class_ctype")) {
	uint32_t invalid_ctype = UINT32_MAX;
	if (classes[0].kind != ONIBI_CLASS_ENCODING_CTYPE)
	    rb_raise(rb_eRuntimeError,
		     "CTYPE diagnostic requires an encoding CTYPE class");
	memcpy(RSTRING_PTR(blob) + classes[0].data_offset, &invalid_ctype,
	       sizeof(invalid_ctype));
    }
    else if (scenario == rb_intern("mixed_ctype")) {
	OnibiClassExpr *expr = NULL;
	size_t count = 0;
	for (uint32_t i = 0; i < header->class_count && expr == NULL; i++) {
	    if (classes[i].kind != ONIBI_CLASS_MIXED) continue;
	    OnibiClassExpr *candidate =
		(OnibiClassExpr *)(RSTRING_PTR(blob) + classes[i].data_offset);
	    size_t candidate_count =
		classes[i].data_length / sizeof(*candidate);
	    for (size_t j = 0; j < candidate_count; j++)
		if (candidate[j].op == ONIBI_CLASS_EXPR_CTYPE) {
		    expr = &candidate[j];
		    count = candidate_count;
		    break;
		}
	}
	if (expr == NULL || count == 0)
	    rb_raise(rb_eRuntimeError,
		     "CTYPE diagnostic requires a mixed CTYPE class");
	expr->arg0 = UINT32_MAX;
    }
    else if (scenario == rb_intern("literal_descriptor"))
	literals[0].data_offset = header->descriptors_offset;
    else if (scenario == rb_intern("backref_descriptor_empty"))
	backrefs[0].capture_count = 0;
    else if (scenario == rb_intern("backref_descriptor_offset"))
	backrefs[0].capture_list_off = header->backref_lists_offset - 4U;
    else if (scenario == rb_intern("backref_descriptor_list_range"))
	backrefs[0].capture_list_off = header->subprograms_offset;
    else if (scenario == rb_intern("backref_descriptor_flags"))
	backrefs[0].flags = UINT16_C(0x8000);
    else if (scenario == rb_intern("backref_descriptor_capture"))
	backref_capture_ids[0] = header->capture_count;
    else if (scenario == rb_intern("backref_state_flags")) {
	for (uint32_t i = 0; i < header->state_count; i++) {
	    if (states[i].op != ONIBI_RS_BACKREF) continue;
	    states[i].flags = ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE;
	    break;
	}
    }
    else if (scenario == rb_intern("subprogram_range"))
	subprograms[1].entry_edge_base = header->edge_count;
    else if (scenario == rb_intern("root_entry"))
	subprograms[0].entry = subprograms[0].accept;
    else if (scenario == rb_intern("subprogram_flags"))
	subprograms[1].flags ^= 1U;
    else if (scenario == rb_intern("subprogram_effects"))
	subprograms[1].effects ^= ONIBI_SUBPROGRAM_EFFECT_POSITIVE;
    else if (scenario == rb_intern("subprogram_entry"))
	subprograms[1].entry = subprograms[1].accept;
    else if (scenario == rb_intern("subprogram_width"))
	subprograms[1].width_count = 0;
    else if (scenario == rb_intern("subprogram_options"))
	subprograms[1].option_env.options = UINT32_C(0x80000000);
    else if (scenario == rb_intern("subprogram_encoding"))
	subprograms[1].option_env.encoding_index = INT32_MAX;
    else if (scenario == rb_intern("features"))
	header->features ^= ONIBI_RSEQ_FEATURE_CAPTURE;
    else if (scenario == rb_intern("zero_width_only"))
	header->features ^= ONIBI_RSEQ_FEATURE_ZERO_WIDTH_ONLY;
    else if (scenario == rb_intern("counter_count_none")) {
	if (header->counter_count != 0)
	    rb_raise(rb_eRuntimeError,
		     "unused-counter diagnostic requires no counters");
	header->counter_count = 1;
    }
    else if (scenario == rb_intern("progress_counter_count")) {
	int counter_seen = 0;
	uint32_t highest_counter_slot = 0;
	for (uint32_t i = 0; i < header->action_count; i++) {
	    uint32_t last = 0;
	    switch (actions[i].op) {
	    case ONIBI_RA_COUNTER_SET:
	    case ONIBI_RA_COUNTER_ADD:
	    case ONIBI_RA_COUNTER_TEST:
	    case ONIBI_RA_PROGRESS:
		last = actions[i].arg16;
		counter_seen = 1;
		break;
	    case ONIBI_RA_NULL_ENTER:
	    case ONIBI_RA_NULL_CAPTURE:
	    case ONIBI_RA_NULL_CONTINUE:
	    case ONIBI_RA_NULL_STOP:
		last = (uint32_t)actions[i].arg16 + 1U;
		counter_seen = 1;
		break;
	    default: continue;
	    }
	    if (last > highest_counter_slot) highest_counter_slot = last;
	}
	if (!counter_seen || header->counter_count == 0 ||
	    header->counter_count != highest_counter_slot + 1U)
	    rb_raise(rb_eRuntimeError,
		     "progress diagnostic requires a contiguous counter range");
	header->counter_count++;
    }
    else if (scenario == rb_intern("exec_kind"))
	header->exec_kind = ONIBI_EXEC_DYNAMIC;
    else if (scenario == rb_intern("first_bitmap"))
	header->first_bitmap[0] ^= 1U;
    else if (scenario == rb_intern("prefix"))
	header->prefix[0] ^= 1U;
    else
	rb_raise(rb_eArgError, "unknown RSeq verifier diagnostic");
    rb_obj_freeze(blob);
    onibi_rseq_blob_validate(blob);
    return Qtrue;
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

static VALUE
onibi_compile_outcome_raise_internal(VALUE opaque)
{
    (void)opaque;
    rb_raise(eRegexpError, "injected internal compile failure");
}

static VALUE
onibi_compile_outcome_internal_diagnostics(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    OnibiCompileOutcome outcome = {ONIBI_COMPILE_INTERNAL_ERROR,
				   ONIBI_UNSUPPORTED_NONE};
    int state = 0;
    rb_protect(onibi_compile_outcome_raise_internal, Qnil, &state);
    if (onibi_compile_outcome_select_fallback(obj, &outcome, state))
	rb_raise(eRegexpError, "internal compile failure selected fallback");
    if (!state)
	rb_raise(eRegexpError, "internal compile failure did not raise");
    rb_jump_tag(state);
    return Qnil;
}
/* Diagnostic and compatibility payload adapters.  Ruby Hash records created
 * here are never canonical compiler or runtime state. */
