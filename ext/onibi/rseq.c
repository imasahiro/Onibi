static uint8_t
onibi_g_action_flags(const OnibiGAction *action)
{
    if (action->code == ONIBI_GA_CAPTURE_CLOSE) return ONIBI_RA_CAPTURE_CLOSE;
    if (action->code == ONIBI_GA_TEST_CAPTURE)
	return action->set ? ONIBI_RA_TEST_CAPTURE_SET
			   : ONIBI_RA_TEST_CAPTURE_UNSET;
    if (action->code == ONIBI_GA_TEST_COUNTER_GE) return ONIBI_RA_COUNTER_GE;
    return 0;
}

static OnibiRAssertKind
onibi_g_action_assert_kind(const OnibiGAction *action)
{
    return action->has_assert_kind ? (OnibiRAssertKind)action->assert_kind : 0;
}

/* Debug validator adapter. Runtime lowering uses OnibiGAction enums. */
static OnibiRAssertKind
onibi_rseq_assert_kind(ID op)
{
    if (op == id_a_assert_begin_buffer) return ONIBI_RAP_BEGIN_BUFFER;
    if (op == id_a_assert_end_buffer) return ONIBI_RAP_END_BUFFER;
    if (op == id_a_assert_begin_line) return ONIBI_RAP_BEGIN_LINE;
    if (op == id_a_assert_end_line) return ONIBI_RAP_END_LINE;
    if (op == id_a_assert_semi_end_buffer) return ONIBI_RAP_SEMI_END_BUFFER;
    if (op == id_a_assert_search_origin) return ONIBI_RAP_SEARCH_ORIGIN;
    if (op == id_a_assert_word_boundary) return ONIBI_RAP_WORD_BOUNDARY;
    if (op == id_a_assert_nonword_boundary) return ONIBI_RAP_NONWORD_BOUNDARY;
    if (op == id_a_assert_lookahead) return ONIBI_RAP_LOOKAHEAD;
    if (op == id_a_assert_lookbehind) return ONIBI_RAP_LOOKBEHIND;
    return 0;
}

static VALUE
onibi_rseq_lower(VALUE self, VALUE compiled)
{
    (void)self;
    OnibiCompiled *compiled_data = onibi_compiled_get(compiled);
    if (compiled_data->states.count == 0)
	rb_raise(rb_eArgError, "RSeq lowering requires compiler output");
    if (!RTEST(rb_obj_frozen_p(compiled)) ||
	!RB_TYPE_P(compiled_data->subprograms, T_ARRAY))
	rb_raise(rb_eArgError, "RSeq lowering requires immutable GIR");
    long gir_capture_count = compiled_data->capture_count;
    if (gir_capture_count < 0 || (uint64_t)gir_capture_count > UINT32_MAX)
	rb_raise(rb_eArgError, "RSeq capture count is out of range");
    uint32_t capture_count = (uint32_t)gir_capture_count;
    size_t state_count = compiled_data->states.count;
    OnibiGirStateVector state_records;
    onibi_gir_state_vector_init(&state_records);
    if (state_count > 0) {
	state_records.entries = ALLOC_N(OnibiGirStateEntry, state_count);
	memcpy(state_records.entries, compiled_data->states.entries,
	       state_count * sizeof(*state_records.entries));
	state_records.count = state_records.capacity = state_count;
    }
    VALUE subprograms = compiled_data->subprograms;
    OnibiRSeqSubprogramVector subprogram_records;
    onibi_rseq_subprogram_vector_init(&subprogram_records);
    for (long i = 0; i < RARRAY_LEN(subprograms); i++)
	onibi_rseq_subprogram_vector_push(&subprogram_records,
					  rb_ary_entry(subprograms, i));
    long accept_state = compiled_data->accept;
    if (accept_state < 0 || (size_t)accept_state >= state_count)
	rb_raise(rb_eArgError,
		 "RSeq lowering received an invalid accept state");
    for (size_t i = 0; i < compiled_data->edges.count; i++) {
	const OnibiGirEdgeEntry *edge = &compiled_data->edges.entries[i];
	if (edge->from < 0 || (size_t)edge->from >= state_count ||
	    edge->to < 0 || (size_t)edge->to >= state_count)
	    rb_raise(rb_eArgError, "RSeq lowering received an invalid edge");
    }
    for (size_t i = 0; i < compiled_data->start_edges.count; i++) {
	long to = compiled_data->start_edges.entries[i].to;
	if (to < 0 || (size_t)to >= state_count)
	    rb_raise(rb_eArgError,
		     "RSeq lowering received an invalid start edge");
    }
    OnibiRSeqClassPayloadVector class_payloads;
    onibi_rseq_class_payload_vector_init(&class_payloads);
    for (size_t i = 0; i < state_records.count; i++) {
	OnibiGirStateEntry *state = &state_records.entries[i];
	if (state->opcode != ONIBI_G_CLASS) continue;
	VALUE payload = state->payload;
	int found = 0;
	size_t payload_index = class_payloads.count;
	for (size_t j = 0; j < class_payloads.count; j++) {
	    OnibiRSeqClassPayloadEntry *prior = &class_payloads.entries[j];
	    if (rb_equal(prior->bitmap,
			 onibi_hash_value_id(payload, id_key_bitmap)) &&
		prior->negated ==
		    RTEST(onibi_hash_value_id(payload, id_key_negated))) {
		found = 1;
		payload_index = j;
		break;
	    }
	}
	if (!found)
	    onibi_rseq_class_payload_vector_push(&class_payloads, payload);
	state->payload_index = (uint32_t)payload_index;
    }
    uint32_t class_count = (uint32_t)class_payloads.count;
    OnibiGActionVector action_records;
    onibi_rseq_action_vector_init(&action_records);
    VALUE action_roots = rb_ary_new();
    OnibiGirEdgeVector r_edge_records;
    onibi_gir_edge_vector_init(&r_edge_records);
    for (size_t i = 0; i < compiled_data->edges.count; i++) {
	const OnibiGirEdgeEntry *edge = &compiled_data->edges.entries[i];
	VALUE edge_actions = edge->actions;
	if (!RTEST(rb_obj_frozen_p(edge_actions)))
	    rb_raise(rb_eArgError,
		     "RSeq lowering requires immutable GIR edges");
	long from = edge->from;
	long to = edge->to;
	long action_offset =
	    RARRAY_LEN(edge_actions) == 0 ? 0 : (long)action_records.count;
	VALUE copied_actions = rb_ary_new();
	for (long j = 0; j < RARRAY_LEN(edge_actions); j++) {
	    VALUE action = rb_ary_entry(edge_actions, j);
	    VALUE copy = onibi_deep_freeze(rb_hash_dup(action));
	    rb_ary_push(copied_actions, copy);
	    onibi_rseq_action_vector_push(&action_records, copy);
	}
	if (RARRAY_LEN(edge_actions) > 0) {
	    VALUE terminator = rb_hash_new();
	    rb_hash_aset(terminator, ID2SYM(id_key_op), ID2SYM(id_a_end));
	    onibi_set_gir_action_opcode(terminator, id_a_end);
	    terminator = onibi_deep_freeze(terminator);
	    rb_ary_push(copied_actions, terminator);
	    onibi_rseq_action_vector_push(&action_records, terminator);
	}
	rb_obj_freeze(copied_actions);
	onibi_gir_edge_vector_push(
	    &r_edge_records,
	    (OnibiGirEdgeEntry){from, to, action_offset,
				(uint32_t)RARRAY_LEN(copied_actions),
				copied_actions},
	    action_roots);
    }
    onibi_gir_edge_vector_group_by_from(&r_edge_records, (size_t)state_count);
    OnibiGirEdgeVector r_start_edge_records;
    onibi_gir_edge_vector_init(&r_start_edge_records);
    for (size_t i = 0; i < compiled_data->start_edges.count; i++) {
	const OnibiGirEdgeEntry *edge = &compiled_data->start_edges.entries[i];
	VALUE edge_actions = edge->actions;
	if (!RTEST(rb_obj_frozen_p(edge_actions)))
	    rb_raise(rb_eArgError,
		     "RSeq lowering requires immutable GIR start edges");
	long to = edge->to;
	long action_offset =
	    RARRAY_LEN(edge_actions) == 0 ? 0 : (long)action_records.count;
	VALUE copied_actions = rb_ary_new();
	for (long j = 0; j < RARRAY_LEN(edge_actions); j++) {
	    VALUE action = rb_ary_entry(edge_actions, j);
	    VALUE copy = onibi_deep_freeze(rb_hash_dup(action));
	    rb_ary_push(copied_actions, copy);
	    onibi_rseq_action_vector_push(&action_records, copy);
	}
	if (RARRAY_LEN(edge_actions) > 0) {
	    VALUE terminator = rb_hash_new();
	    rb_hash_aset(terminator, ID2SYM(id_key_op), ID2SYM(id_a_end));
	    onibi_set_gir_action_opcode(terminator, id_a_end);
	    terminator = onibi_deep_freeze(terminator);
	    rb_ary_push(copied_actions, terminator);
	    onibi_rseq_action_vector_push(&action_records, terminator);
	}
	rb_obj_freeze(copied_actions);
	onibi_gir_edge_vector_push(
	    &r_start_edge_records,
	    (OnibiGirEdgeEntry){-1, to, action_offset,
				(uint32_t)RARRAY_LEN(copied_actions),
				copied_actions},
	    action_roots);
    }
    int options = compiled_data->options;
    int ignorecase = (options & 1) != 0;
    int multiline = (options & 4) != 0;
    uint64_t physical_edge_count =
	(uint64_t)r_edge_records.count + (uint64_t)r_start_edge_records.count;
    OnibiRSeqLiteralPayloadVector literal_payloads;
    onibi_rseq_literal_payload_vector_init(&literal_payloads);
    for (size_t i = 0; i < state_records.count; i++) {
	unsigned int opcode = state_records.entries[i].opcode;
	if (opcode != ONIBI_G_CHAR) continue;
	VALUE payload = state_records.entries[i].payload;
	int found = 0;
	size_t payload_index = literal_payloads.count;
	for (size_t j = 0; j < literal_payloads.count; j++) {
	    OnibiRSeqLiteralPayloadEntry *prior = &literal_payloads.entries[j];
	    if (prior->byte ==
		    NUM2INT(onibi_hash_value_id(payload, id_key_byte)) &&
		prior->ignorecase ==
		    RTEST(onibi_hash_value_id(payload, id_key_ignorecase))) {
		found = 1;
		payload_index = j;
		break;
	    }
	}
	if (!found)
	    onibi_rseq_literal_payload_vector_push(&literal_payloads, payload);
	state_records.entries[i].payload_index = (uint32_t)payload_index;
    }
    for (size_t i = 0; i < state_records.count; i++) {
	OnibiGirStateEntry *state = &state_records.entries[i];
	if (state->opcode != ONIBI_G_BACKREF) continue;
	VALUE capture = onibi_hash_value_id(state->payload, id_key_capture);
	if (NIL_P(capture) || NUM2LONG(capture) <= 0)
	    rb_raise(eRegexpError, "invalid GIR backreference capture");
	state->payload_index = (uint32_t)(NUM2ULONG(capture) - 1U);
    }
    uint32_t literal_count = (uint32_t)literal_payloads.count;
    uint64_t class_section_size =
	(uint64_t)class_count * (sizeof(OnibiClassDesc) + 32U);
    uint64_t literal_desc_size =
	(uint64_t)literal_count * sizeof(OnibiLiteralDesc);
    uint64_t literal_data_size = ((uint64_t)literal_count + 3U) & ~UINT64_C(3);
    uint64_t subprogram_section_size =
	(uint64_t)subprogram_records.count * sizeof(OnibiSubprogramDesc);
    uint64_t physical_size =
	sizeof(OnibiRSeqHeader) +
	(uint64_t)sizeof(OnibiRState) * (uint64_t)state_records.count +
	(uint64_t)sizeof(OnibiREdge) * physical_edge_count +
	(uint64_t)sizeof(OnibiRAction) * (uint64_t)action_records.count +
	class_section_size + literal_desc_size + literal_data_size +
	subprogram_section_size;
    if (state_records.count > UINT32_MAX || physical_edge_count > UINT32_MAX ||
	action_records.count > UINT32_MAX || physical_size > UINT32_MAX)
	rb_raise(eRegexpError, "RSeq program exceeds the v1 size limit");
    uint32_t features = capture_count > 0 ? 2U : 0U;
    uint32_t counter_count = 0;
    for (size_t i = 0; i < state_records.count; i++) {
	if (state_records.entries[i].opcode == ONIBI_G_BACKREF) features |= 1U;
    }
    for (size_t i = 0; i < action_records.count; i++) {
	VALUE action = action_records.entries[i].value;
	OnibiGActionOp code = action_records.entries[i].code;
	if (code == ONIBI_GA_CAPTURE_OPEN) features |= 2U;
	if (code == ONIBI_GA_COUNTER_INIT) features |= 4U;
	if (code == ONIBI_GA_COUNTER_INIT ||
	    code == ONIBI_GA_COUNTER_INCREMENT ||
	    code == ONIBI_GA_TEST_COUNTER_LT ||
	    code == ONIBI_GA_TEST_COUNTER_GE) {
	    VALUE slot = onibi_hash_value_id(action, id_key_slot);
	    if (!NIL_P(slot) && RB_INTEGER_TYPE_P(slot)) {
		uint32_t required = (uint32_t)NUM2ULONG(slot) + 1U;
		if (required > counter_count) counter_count = required;
	    }
	}
	if (code == ONIBI_GA_MATCH_RESET) features |= 8U;
	if (code == ONIBI_GA_ASSERT_POSITION) features |= 16U;
    }
    OnibiRSeqHeader physical;
    memset(&physical, 0, sizeof(physical));
    physical.magic = ONIBI_RSEQ_MAGIC;
    physical.version = ONIBI_RSEQ_VERSION;
    physical.flags = (ignorecase ? 1 : 0) | (multiline ? 2 : 0);
    physical.features = features;
    physical.class_count = class_count;
    physical.subprogram_count = (uint32_t)subprogram_records.count;
    physical.capture_count = capture_count;
    physical.semantic_capture_count = capture_count;
    physical.counter_count = counter_count;
    physical.start_edge_base = (uint32_t)r_edge_records.count;
    for (size_t i = 0; i < state_records.count; i++) {
	unsigned int opcode = state_records.entries[i].opcode;
	if (opcode == ONIBI_G_GRAPHEME || opcode == ONIBI_G_BACKREF ||
	    opcode == ONIBI_G_CALL || opcode == ONIBI_G_ATOMIC ||
	    opcode == ONIBI_G_ABSENT) {
	    physical.exec_kind = 2;
	    break;
	}
	if (opcode == ONIBI_G_ACCEPT) continue;
    }
    if (physical.exec_kind == 0) {
	for (size_t i = 0; i < action_records.count; i++) {
	    OnibiGActionOp code = action_records.entries[i].code;
	    if (code == ONIBI_GA_CAPTURE_OPEN ||
		code == ONIBI_GA_CAPTURE_CLOSE ||
		code == ONIBI_GA_COUNTER_INIT ||
		code == ONIBI_GA_COUNTER_INCREMENT ||
		code == ONIBI_GA_TEST_COUNTER_LT ||
		code == ONIBI_GA_TEST_COUNTER_GE) {
		physical.exec_kind = 1;
		break;
	    }
	}
	for (size_t i = 0;
	     i < compiled_data->start_edges.count && physical.exec_kind == 0;
	     i++) {
	    VALUE edge_actions = compiled_data->start_edges.entries[i].actions;
	    for (long j = 0; j < RARRAY_LEN(edge_actions); j++) {
		OnibiGActionOp code =
		    (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(
			rb_ary_entry(edge_actions, j), id_key_action_code));
		if (code == ONIBI_GA_CAPTURE_OPEN ||
		    code == ONIBI_GA_COUNTER_INIT) {
		    physical.exec_kind = 1;
		    break;
		}
	    }
	}
    }
    physical.state_count = (uint32_t)state_records.count;
    physical.edge_count =
	(uint32_t)(r_edge_records.count + r_start_edge_records.count);
    physical.action_count = (uint32_t)action_records.count;
    physical.start_edge_count = (uint32_t)r_start_edge_records.count;
    uint64_t offset = sizeof(OnibiRSeqHeader);
    physical.states_offset = (uint32_t)offset;
    offset += (uint64_t)sizeof(OnibiRState) * (uint64_t)state_records.count;
    physical.edges_offset = (uint32_t)offset;
    offset += (uint64_t)sizeof(OnibiREdge) * (uint64_t)physical.edge_count;
    physical.actions_offset = (uint32_t)offset;
    offset += (uint64_t)sizeof(OnibiRAction) * (uint64_t)action_records.count;
    physical.classes_offset = (uint32_t)offset;
    offset += class_section_size;
    physical.literals_offset = (uint32_t)offset;
    offset += literal_data_size;
    physical.descriptors_offset = (uint32_t)offset;
    offset += literal_desc_size;
    physical.subprograms_offset = (uint32_t)offset;
    offset += subprogram_section_size;
    physical.blob_size = (uint32_t)offset;
    VALUE blob = rb_str_new(NULL, (long)offset);
    memset(RSTRING_PTR(blob), 0, (size_t)offset);
    memcpy(RSTRING_PTR(blob), &physical, sizeof(physical));
    OnibiRState *physical_states =
	(OnibiRState *)(RSTRING_PTR(blob) + physical.states_offset);
    uint32_t class_index = 0, literal_index = 0;
    size_t physical_edge_index = 0;
    for (size_t i = 0; i < state_records.count; i++) {
	OnibiGirStateEntry *state = &state_records.entries[i];
	unsigned int opcode = state->opcode;
	physical_states[i].op =
	    (uint8_t)(opcode == ONIBI_G_CHAR	   ? ONIBI_RS_CHAR
		      : opcode == ONIBI_G_CLASS	   ? ONIBI_RS_CLASS
		      : opcode == ONIBI_G_ANY	   ? ONIBI_RS_ANY
		      : opcode == ONIBI_G_GRAPHEME ? ONIBI_RS_GRAPHEME
		      : opcode == ONIBI_G_BACKREF  ? ONIBI_RS_BACKREF
		      : opcode == ONIBI_G_CALL	   ? ONIBI_RS_CALL
		      : opcode == ONIBI_G_ATOMIC   ? ONIBI_RS_ATOMIC
		      : opcode == ONIBI_G_ABSENT   ? ONIBI_RS_ABSENT
		      : opcode == ONIBI_G_ACCEPT   ? 0
						   : 0xff);
	size_t edge_base = physical_edge_index;
	while (physical_edge_index < r_edge_records.count &&
	       r_edge_records.entries[physical_edge_index].from == (long)i)
	    physical_edge_index++;
	size_t edge_count = physical_edge_index - edge_base;
	if (edge_count > UINT16_MAX)
	    rb_raise(eRegexpError, "RSeq state has too many outgoing edges");
	physical_states[i].edge_base = (uint32_t)edge_base;
	physical_states[i].edge_count = (uint16_t)edge_count;
	if (opcode == ONIBI_G_CLASS || opcode == ONIBI_G_CHAR ||
	    opcode == ONIBI_G_BACKREF)
	    physical_states[i].payload = state->payload_index;
    }
    if (physical_edge_index != r_edge_records.count)
	rb_raise(eRegexpError,
		 "RSeq edge index is not grouped by source state");
    OnibiREdge *physical_edges =
	(OnibiREdge *)(RSTRING_PTR(blob) + physical.edges_offset);
    for (size_t i = 0; i < r_edge_records.count; i++) {
	OnibiGirEdgeEntry *record = &r_edge_records.entries[i];
	uint32_t destination = (uint32_t)record->to;
	if (destination == (uint32_t)(state_records.count - 1))
	    destination = ONIBI_ACCEPT_STATE;
	physical_edges[i].destination = destination;
	physical_edges[i].action_offset =
	    record->action_count == 0
		? 0
		: (uint32_t)(sizeof(OnibiRAction) *
			     ((uint32_t)record->action_offset + 1));
    }
    for (size_t i = 0; i < r_start_edge_records.count; i++) {
	OnibiGirEdgeEntry *record = &r_start_edge_records.entries[i];
	size_t index = r_edge_records.count + i;
	physical_edges[index].destination = (uint32_t)record->to;
	physical_edges[index].action_offset =
	    record->action_count == 0
		? 0
		: (uint32_t)(sizeof(OnibiRAction) *
			     ((uint32_t)record->action_offset + 1));
    }
    OnibiRAction *physical_actions =
	(OnibiRAction *)(RSTRING_PTR(blob) + physical.actions_offset);
    for (size_t i = 0; i < action_records.count; i++) {
	const OnibiGAction *action = &action_records.entries[i];
	physical_actions[i].op = action_records.entries[i].physical_op;
	physical_actions[i].flags = onibi_g_action_flags(action);
	physical_actions[i].arg16 = action_records.entries[i].has_assert_kind
					? action_records.entries[i].assert_kind
					: onibi_g_action_assert_kind(action);
	if (action->code == ONIBI_GA_ASSERT_POSITION &&
	    (action->assert_kind == ONIBI_RAP_LOOKAHEAD ||
	     action->assert_kind == ONIBI_RAP_LOOKBEHIND)) {
	    int positive = action_records.entries[i].positive;
	    physical_actions[i].flags =
		action->assert_kind == ONIBI_RAP_LOOKAHEAD ? (positive ? 1 : 2)
							   : (positive ? 5 : 6);
	}
	if (action_records.entries[i].has_slot)
	    physical_actions[i].arg16 = action_records.entries[i].slot;
	if (action_records.entries[i].has_arg32)
	    physical_actions[i].arg32 = action_records.entries[i].arg32;
    }
    OnibiClassDesc *class_descs =
	(OnibiClassDesc *)(RSTRING_PTR(blob) + physical.classes_offset);
    unsigned char *class_data = (unsigned char *)(class_descs + class_count);
    class_index = 0;
    for (size_t i = 0; i < class_payloads.count; i++) {
	OnibiRSeqClassPayloadEntry *entry = &class_payloads.entries[i];
	VALUE bitmap = entry->bitmap;
	class_descs[class_index].data_offset =
	    (uint32_t)(physical.classes_offset +
		       class_count * sizeof(OnibiClassDesc) +
		       class_index * 32U);
	class_descs[class_index].data_length = 32;
	class_descs[class_index].kind = 0;
	class_descs[class_index].flags = entry->negated ? 1 : 0;
	if (!NIL_P(bitmap) && RSTRING_LEN(bitmap) == 32)
	    memcpy(class_data + class_index * 32U, RSTRING_PTR(bitmap), 32);
	class_index++;
    }
    unsigned char *literal_data =
	(unsigned char *)(RSTRING_PTR(blob) + physical.literals_offset);
    OnibiLiteralDesc *literal_descs =
	(OnibiLiteralDesc *)(RSTRING_PTR(blob) + physical.descriptors_offset);
    literal_index = 0;
    for (size_t i = 0; i < literal_payloads.count; i++) {
	OnibiRSeqLiteralPayloadEntry *entry = &literal_payloads.entries[i];
	literal_descs[literal_index].data_offset =
	    physical.literals_offset + literal_index;
	literal_descs[literal_index].data_length = 1;
	literal_descs[literal_index].flags = entry->ignorecase ? 1 : 0;
	literal_data[literal_index] = (unsigned char)entry->byte;
	literal_index++;
    }
    OnibiSubprogramDesc *physical_subprograms =
	(OnibiSubprogramDesc *)(RSTRING_PTR(blob) +
				physical.subprograms_offset);
    for (size_t i = 0; i < subprogram_records.count; i++) {
	OnibiRSeqSubprogramEntry *record = &subprogram_records.entries[i];
	physical_subprograms[i].entry = record->entry;
	physical_subprograms[i].accept = record->accept;
	physical_subprograms[i].flags = record->flags;
    }
    rb_obj_freeze(blob);
    /* Validate once, then publish only the relocatable blob. Semantic Ruby
	 mirrors are compile-time adapters and are not retained by the regexp.
     */
    onibi_rseq_blob_validate(blob);
    onibi_rseq_class_payload_vector_free(&class_payloads);
    onibi_rseq_literal_payload_vector_free(&literal_payloads);
    onibi_rseq_action_vector_free(&action_records);
    onibi_gir_edge_vector_free(&r_edge_records);
    onibi_gir_edge_vector_free(&r_start_edge_records);
    onibi_gir_state_vector_free(&state_records);
    onibi_rseq_subprogram_vector_free(&subprogram_records);
    return blob;
}

static VALUE
onibi_alloc(VALUE klass)
{
    onibi_regexp_t *obj;
    VALUE result =
	TypedData_Make_Struct(klass, onibi_regexp_t, &onibi_type, obj);
    MEMZERO(obj, onibi_regexp_t, 1);
    return result;
}

typedef struct {
    VALUE source;
    VALUE options;
    const OnibiTokenVector *tokens;
} OnibiProgramArgs;

typedef struct {
    VALUE source;
    int extended;
    OnibiTokenVector *tokens;
} OnibiTokenizeArgs;

static VALUE
onibi_tokenize_protected(VALUE argument)
{
    OnibiTokenizeArgs *args = (OnibiTokenizeArgs *)(uintptr_t)argument;
    onibi_tokenize_internal(args->source, args->extended, args->tokens);
    return Qnil;
}

static VALUE
onibi_build_program(VALUE argument)
{
    OnibiProgramArgs *args = (OnibiProgramArgs *)(uintptr_t)argument;
    VALUE source = args->source;
    VALUE options = args->options;
    const OnibiTokenVector *tokens = args->tokens;
    VALUE parsed = onibi_parser_parse_internal(source, options, tokens);
    VALUE compiled = onibi_compiler_compile(Qnil, parsed);
    VALUE rseq = onibi_rseq_lower(Qnil, compiled);
    onibi_ast_arena_free(&onibi_parsed_get(parsed)->arena);
    return rb_ary_new_from_args(2, parsed, rseq);
}

static VALUE
onibi_parse_program(VALUE argument)
{
    OnibiProgramArgs *args = (OnibiProgramArgs *)(uintptr_t)argument;
    VALUE source = args->source;
    VALUE options = args->options;
    const OnibiTokenVector *tokens = args->tokens;
    return onibi_parser_parse_internal(source, options, tokens);
}

static VALUE
onibi_make_mri_regexp(VALUE argument)
{
    OnibiProgramArgs *args = (OnibiProgramArgs *)(uintptr_t)argument;
    VALUE source = args->source;
    VALUE options = args->options;
    return rb_funcall(rb_cRegexp, id_new, 2, source, options);
}

/* Compute all dispatch/compiler feature bits in one pass over the immutable
   token stream.  Runtime entry points use these bits and never rescan source.
 */
static void
onibi_token_features(const OnibiTokenVector *feature_tokens,
		     onibi_regexp_t *obj)
{
    int in_class = 0;
    long class_depth = 0;
    int repeat_active = 0;
    uint64_t repeat_value = 0;
    int repeat_have_digit = 0;
    int repeat_over_limit = 0;
    const OnibiTokenRecord *previous = NULL;
    obj->feature_flags &=
	~(ONIBI_FEATURE_CLASS_INTERSECTION | ONIBI_FEATURE_NESTED_CLASS |
	  ONIBI_FEATURE_LARGE_REPEAT | ONIBI_FEATURE_ABSENCE |
	  ONIBI_FEATURE_CONDITIONAL | ONIBI_FEATURE_BACKREF |
	  ONIBI_FEATURE_SUBROUTINE);
    obj->feature_flags &=
	~(ONIBI_FEATURE_ASCII_PROPERTY | ONIBI_FEATURE_UNICODE_PROPERTY |
	  ONIBI_FEATURE_UNICODE_PROPERTY_CLASS | ONIBI_FEATURE_PROPERTY_ESCAPE |
	  ONIBI_FEATURE_NON_ASCII_LITERAL | ONIBI_FEATURE_NON_ASCII_CLASS |
	  ONIBI_FEATURE_INLINE_IGNORECASE);
    obj->ast_flags = 0;
    obj->feature_flags = 0;
    obj->execution_flags = 0;
    for (size_t i = 0; i < feature_tokens->count; i++) {
	const OnibiTokenRecord *token = &feature_tokens->items[i];
	OnibiTokenKind kind_code = token->kind;
	if (kind_code == ONIBI_TOKEN_LITERAL && token->byte > 127) {
	    obj->feature_flags |= ONIBI_FEATURE_NON_ASCII_LITERAL;
	    if (in_class) obj->feature_flags |= ONIBI_FEATURE_NON_ASCII_CLASS;
	}
	if (kind_code == ONIBI_TOKEN_WILDCARD)
	    obj->feature_flags |= ONIBI_FEATURE_WILDCARD;
	if (kind_code == ONIBI_TOKEN_ANCHOR)
	    obj->feature_flags |= ONIBI_FEATURE_ANCHOR;
	if (kind_code == ONIBI_TOKEN_OPTION_SCOPE_START ||
	    kind_code == ONIBI_TOKEN_OPTION_GLOBAL) {
	    if (token->inline_ignorecase)
		obj->feature_flags |= ONIBI_FEATURE_INLINE_IGNORECASE;
	}
	if (kind_code == ONIBI_TOKEN_CLASS_START) {
	    if (in_class) obj->feature_flags |= ONIBI_FEATURE_NESTED_CLASS;
	    in_class = 1;
	    class_depth++;
	    previous = NULL;
	    continue;
	}
	if (kind_code == ONIBI_TOKEN_CLASS_END) {
	    if (class_depth > 0) class_depth--;
	    in_class = class_depth > 0;
	    previous = NULL;
	    continue;
	}
	if (repeat_active) {
	    long value = token->byte;
	    if (kind_code == ONIBI_TOKEN_QUANTIFIER && value == '}') {
		if (repeat_have_digit && repeat_over_limit)
		    obj->feature_flags |= ONIBI_FEATURE_LARGE_REPEAT;
		repeat_active = 0;
	    }
	    else if (kind_code == ONIBI_TOKEN_QUANTIFIER && value == ',') {
		if (repeat_have_digit && repeat_over_limit)
		    obj->feature_flags |= ONIBI_FEATURE_LARGE_REPEAT;
		repeat_value = 0;
		repeat_have_digit = 0;
		repeat_over_limit = 0;
	    }
	    else if (kind_code == ONIBI_TOKEN_LITERAL && value >= '0' &&
		     value <= '9') {
		repeat_have_digit = 1;
		if (repeat_value > (uint64_t)ONIBI_RSEQ_REPEAT_UNROLL_LIMIT ||
		    (repeat_value == (uint64_t)ONIBI_RSEQ_REPEAT_UNROLL_LIMIT &&
		     (uint64_t)(value - '0') > 0U))
		    repeat_over_limit = 1;
		else if (repeat_value <= UINT64_MAX / 10U)
		    repeat_value = repeat_value * 10U + (uint64_t)(value - '0');
	    }
	    else {
		repeat_active = 0;
	    }
	}
	if (in_class && kind_code == ONIBI_TOKEN_LITERAL && token->byte == '[')
	    obj->feature_flags |= ONIBI_FEATURE_NESTED_CLASS;
	if (!in_class && kind_code == ONIBI_TOKEN_QUANTIFIER &&
	    token->byte == '{') {
	    repeat_active = 1;
	    repeat_value = 0;
	    repeat_have_digit = 0;
	    repeat_over_limit = 0;
	}
	if (in_class && previous && previous->kind == ONIBI_TOKEN_LITERAL &&
	    kind_code == ONIBI_TOKEN_LITERAL && previous->byte == '&' &&
	    token->byte == '&')
	    obj->feature_flags |= ONIBI_FEATURE_CLASS_INTERSECTION;
	if (kind_code == ONIBI_TOKEN_SUBROUTINE) {
	    obj->feature_flags |= ONIBI_FEATURE_SUBROUTINE;
	    obj->execution_flags |= ONIBI_FEATURE_DYNAMIC;
	}
	else if (kind_code == ONIBI_TOKEN_BACKREF ||
		 kind_code == ONIBI_TOKEN_ATOMIC_START ||
		 kind_code == ONIBI_TOKEN_ABSENCE_START) {
	    obj->execution_flags |= ONIBI_FEATURE_DYNAMIC;
	    if (kind_code == ONIBI_TOKEN_BACKREF)
		obj->feature_flags |= ONIBI_FEATURE_BACKREF;
	    if (kind_code == ONIBI_TOKEN_ATOMIC_START)
		obj->execution_flags |= ONIBI_FEATURE_ATOMIC;
	    if (kind_code == ONIBI_TOKEN_ABSENCE_START)
		obj->feature_flags |= ONIBI_FEATURE_ABSENCE;
	}
	else if (kind_code == ONIBI_TOKEN_CONDITIONAL_START) {
	    /* Simple capture conditionals lower to guarded GIR edges.  Mark the
	       construct only for diagnostics; compile failure selects MRI. */
	    obj->feature_flags |= ONIBI_FEATURE_CONDITIONAL;
	}
	else if (kind_code == ONIBI_TOKEN_ESCAPE) {
	    if (token->byte == 'X') {
		obj->feature_flags |= ONIBI_FEATURE_GRAPHEME;
		obj->execution_flags |= ONIBI_FEATURE_DYNAMIC;
	    }
	    if (token->byte == 'p' || token->byte == 'P') {
		if (token->property_kind != ONIBI_ASCII_PROP_UNKNOWN) {
		    obj->feature_flags |= ONIBI_FEATURE_ASCII_PROPERTY;
		    ID property_id = token->name_id;
		    if (property_id != id_prop_ascii &&
			property_id != id_prop_ascii_hex)
			obj->feature_flags |= ONIBI_FEATURE_UNICODE_PROPERTY;
		    if (in_class)
			obj->feature_flags |=
			    ONIBI_FEATURE_UNICODE_PROPERTY_CLASS;
		}
		else {
		    obj->feature_flags |= ONIBI_FEATURE_PROPERTY_ESCAPE;
		    obj->execution_flags |= ONIBI_FEATURE_DYNAMIC;
		}
	    }
	    if (token->byte == 'u')
		obj->feature_flags |= ONIBI_FEATURE_UNICODE_ESCAPE;
	}
	else if (kind_code == ONIBI_TOKEN_META_ESCAPE) {
	    obj->feature_flags |= ONIBI_FEATURE_META_ESCAPE;
	    obj->execution_flags |= ONIBI_FEATURE_DYNAMIC;
	}
	else if (kind_code == ONIBI_TOKEN_GROUP_START ||
		 (kind_code == ONIBI_TOKEN_QUANTIFIER && token->byte == '{')) {
	    obj->execution_flags |= ONIBI_FEATURE_TAGGED;
	}
	previous = token;
    }
}

static int
onibi_ast_safe_multibyte_class(const OnibiAstArena *arena, OnibiAstId id)
{
    const OnibiAstNode *node = onibi_ast_node_const(arena, id);
    if (node->kind == ONIBI_AST_CHARACTER_CLASS) {
	if ((node->flags & ONIBI_AST_NODE_NEGATED) || node->child_count == 0)
	    return 0;
	for (size_t i = 0; i < node->child_count; i++) {
	    const OnibiAstNode *child =
		onibi_ast_node_const(arena, node->children[i]);
	    if (child->kind == ONIBI_AST_LITERAL) continue;
	    if (child->kind == ONIBI_AST_ESCAPE && child->name.present &&
		onibi_unicode_ctype_id(child->name_id) >= 0)
		continue;
	    return 0;
	}
	return 1;
    }
    if (node->kind == ONIBI_AST_SEQUENCE) {
	for (size_t i = 0; i < node->child_count; i++)
	    if (!onibi_ast_safe_multibyte_class(arena, node->children[i]))
		return 0;
	return 1;
    }
    return node->kind == ONIBI_AST_LITERAL || node->kind == ONIBI_AST_ANCHOR;
}

static int
onibi_ast_nullable_scan(const OnibiAstArena *arena, OnibiAstId id,
			OnibiAstAnalysis *analysis)
{
    const OnibiAstNode *node = onibi_ast_node_const(arena, id);
    OnibiAstKind type = node->kind;
    if (type == ONIBI_AST_ANCHOR)
	analysis->flags |= ONIBI_AST_ANALYSIS_HAS_ANCHOR;
    if (type == ONIBI_AST_CAPTURE) {
	analysis->flags |= ONIBI_AST_ANALYSIS_HAS_CAPTURE;
	int nullable = onibi_ast_nullable_scan(arena, node->body, analysis);
	if (nullable) analysis->flags |= ONIBI_AST_ANALYSIS_NULLABLE_CAPTURE;
	return nullable;
    }
    if (type == ONIBI_AST_QUANTIFIER) {
	OnibiAstAnalysis atom_analysis = {0};
	int nullable =
	    onibi_ast_nullable_scan(arena, node->atom, &atom_analysis);
	analysis->flags |=
	    atom_analysis.flags &
	    (ONIBI_AST_ANALYSIS_HAS_ANCHOR | ONIBI_AST_ANALYSIS_ANCHOR_REPEAT);
	if (atom_analysis.flags & ONIBI_AST_ANALYSIS_HAS_ANCHOR)
	    analysis->flags |= ONIBI_AST_ANALYSIS_ANCHOR_REPEAT;
	if (atom_analysis.flags & ONIBI_AST_ANALYSIS_HAS_CAPTURE)
	    analysis->flags |= ONIBI_AST_ANALYSIS_HAS_CAPTURE;
	if (node->min == 0) {
	    if (atom_analysis.flags & ONIBI_AST_ANALYSIS_HAS_CAPTURE)
		analysis->flags |= ONIBI_AST_ANALYSIS_NULLABLE_CAPTURE;
	    return 1;
	}
	return nullable;
    }
    if (type == ONIBI_AST_ABSENCE) {
	OnibiAstAnalysis body_analysis = {0};
	int nullable =
	    onibi_ast_nullable_scan(arena, node->body, &body_analysis);
	analysis->flags |=
	    body_analysis.flags &
	    (ONIBI_AST_ANALYSIS_HAS_ANCHOR | ONIBI_AST_ANALYSIS_ANCHOR_REPEAT);
	if (nullable) analysis->flags |= ONIBI_AST_ANALYSIS_NULLABLE_ABSENCE;
	return 0;
    }
    if (type == ONIBI_AST_SEQUENCE || type == ONIBI_AST_ALTERNATIVE) {
	int result = type == ONIBI_AST_SEQUENCE;
	for (size_t i = 0; i < node->child_count; i++) {
	    int nullable =
		onibi_ast_nullable_scan(arena, node->children[i], analysis);
	    if (type == ONIBI_AST_SEQUENCE && !nullable) result = 0;
	    if (type == ONIBI_AST_ALTERNATIVE && nullable) result = 1;
	}
	return result;
    }
    if (type == ONIBI_AST_GROUP || type == ONIBI_AST_OPTION_SCOPE ||
	type == ONIBI_AST_ATOMIC)
	return onibi_ast_nullable_scan(arena, node->body, analysis);
    if (type == ONIBI_AST_LOOKAHEAD || type == ONIBI_AST_LOOKBEHIND ||
	type == ONIBI_AST_ANCHOR || type == ONIBI_AST_MATCH_RESET)
	return 1;
    return 0;
}

static int
onibi_option_mask(VALUE options)
{
    if (NIL_P(options)) return 0;
    if (options == Qtrue) return 1;
    if (options == Qfalse) return 0;
    if (RB_TYPE_P(options, T_STRING)) {
	int mask = 0;
	const char *text = StringValueCStr(options);
	for (long i = 0; i < RSTRING_LEN(options); i++) {
	    if (text[i] == 'i')
		mask |= 1;
	    else if (text[i] == 'x')
		mask |= 2;
	    else if (text[i] == 'm')
		mask |= 4;
	    else if (text[i] == 'n')
		mask |= 32;
	    else
		rb_raise(rb_eArgError, "unknown regexp option: %s", text);
	}
	return mask;
    }
    if (RB_TYPE_P(options, T_ARRAY)) {
	int mask = 0;
	for (long i = 0; i < RARRAY_LEN(options); i++) {
	    VALUE item = rb_ary_entry(options, i);
	    ID option_id = SYMBOL_P(item) ? SYM2ID(item)
					  : rb_intern_str(StringValue(item));
	    if (option_id == id_opt_ignorecase)
		mask |= 1;
	    else if (option_id == id_opt_multiline)
		mask |= 4;
	    else if (option_id == id_opt_extended)
		mask |= 2;
	    else if (option_id == id_opt_fixedencoding)
		mask |= 16;
	    else if (option_id == id_opt_noencoding)
		mask |= 32;
	    else
		rb_raise(rb_eArgError, "unknown regexp option");
	}
	return mask;
    }
    /* MRI treats any other truthy scalar as the default true option. */
    if (RTEST(options) && !RB_INTEGER_TYPE_P(options)) return 1;
    /* MRI ignores option bits that are not part of the public regexp mask. */
    return NUM2INT(options) & (1 | 2 | 4 | 16 | 32);
}

static VALUE
onibi_initialize(int argc, VALUE *argv, VALUE self)
{
    VALUE pattern, options = Qnil;
    rb_scan_args(argc, argv, "11", &pattern, &options);
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    VALUE inherited_timeout = Qnil;
    if (rb_obj_is_kind_of(pattern, cRegexp)) {
	onibi_regexp_t *prior;
	TypedData_Get_Struct(pattern, onibi_regexp_t, &onibi_type, prior);
	pattern = rb_funcall(prior->regexp, id_source, 0);
	if (NIL_P(options)) options = INT2NUM(prior->options);
	inherited_timeout = prior->timeout_seconds > 0.0
				? DBL2NUM(prior->timeout_seconds)
				: Qnil;
    }
    else if (rb_obj_is_kind_of(pattern, rb_cRegexp)) {
	VALUE prior = pattern;
	pattern = rb_funcall(prior, id_source, 0);
	if (NIL_P(options)) options = rb_funcall(prior, id_options, 0);
    }
    VALUE timeout = Qnil;
    if (RB_TYPE_P(options, T_HASH)) {
	timeout = onibi_hash_value_id(options, id_timeout);
	options = onibi_hash_value_id(options, id_options);
    }
    if (NIL_P(timeout)) timeout = inherited_timeout;
    int opts = onibi_option_mask(options);
    obj->timeout_seconds =
	NIL_P(timeout) ? onibi_default_timeout : onibi_timeout_value(timeout);
    VALUE source = StringValue(pattern);
    int source_encoding_index = rb_enc_get_index(source);
    int source_ascii_only = rb_enc_str_asciionly_p(source);
    obj->source_encoding_index = source_encoding_index;
    obj->source_ascii_only = source_ascii_only;
    if ((opts & 32) && source_encoding_index != rb_ascii8bit_encindex() &&
	!source_ascii_only)
	rb_raise(eRegexpError, "non-ASCII pattern with no encoding");
    if (!(opts & 32) && !source_ascii_only && !(opts & 16)) opts |= 16;
    obj->options = opts;
    obj->source = rb_str_dup(source);
    rb_obj_freeze(obj->source);
    obj->names = Qnil;
    obj->named_captures = Qnil;
    obj->rseq = Qnil;
    obj->rseq_blob = Qnil;
    obj->rseq_view_valid = 0;
    OnibiTokenVector tokens;
    onibi_token_vector_init(&tokens);
    OnibiTokenizeArgs tokenize_args = {source, (opts & 2) != 0, &tokens};
    int tokenize_state = 0;
    rb_protect(onibi_tokenize_protected, (VALUE)(uintptr_t)&tokenize_args,
	       &tokenize_state);
    if (tokenize_state) {
	onibi_token_vector_free(&tokens);
	rb_jump_tag(tokenize_state);
    }
    onibi_token_features(&tokens, obj);
    if (!(opts & 32) && source_encoding_index == rb_utf8_encindex() &&
	ONIBI_FEATURE_P(obj, ONIBI_FEATURE_PROPERTY_ESCAPE))
	opts |= 16;
    if (((opts & 32) && source_ascii_only &&
	 (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_NON_ASCII_LITERAL) ||
	  ONIBI_FEATURE_P(obj, ONIBI_FEATURE_PROPERTY_ESCAPE))) ||
	(!(opts & 32) && source_encoding_index != rb_utf8_encindex() &&
	 source_encoding_index != rb_usascii_encindex() &&
	 (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_NON_ASCII_LITERAL) ||
	  ONIBI_FEATURE_P(obj, ONIBI_FEATURE_PROPERTY_ESCAPE))))
	opts |= 16;
    obj->options = opts;
    VALUE regexp_source = source;
    if (source_encoding_index != rb_utf8_encindex() &&
	(obj->feature_flags & ONIBI_FEATURE_UNICODE_ESCAPE)) {
	regexp_source = rb_funcall(source, id_encode, 1,
				   rb_enc_from_encoding(rb_utf8_encoding()));
	opts |= 16;
	obj->options = opts;
    }
    OnibiProgramArgs regexp_args = {regexp_source, INT2NUM(opts), NULL};
    int regexp_state = 0;
    obj->regexp = rb_protect(onibi_make_mri_regexp,
			     (VALUE)(uintptr_t)&regexp_args, &regexp_state);
    if (regexp_state) {
	VALUE error = rb_errinfo();
	VALUE message = rb_funcall(error, id_message, 0);
	rb_set_errinfo(Qnil);
	onibi_token_vector_free(&tokens);
	rb_raise(eRegexpError, "%s", StringValueCStr(message));
    }
    obj->names = rb_funcall(obj->regexp, id_names, 0);
    obj->named_captures = rb_funcall(obj->regexp, id_named_captures, 0);
    rb_obj_freeze(obj->names);
    rb_obj_freeze(obj->named_captures);
    OnibiProgramArgs program_args = {source, INT2NUM(opts), &tokens};
    int program_state = 0;
    VALUE parsed = Qnil;
    VALUE program =
	(ONIBI_FEATURE_P(obj, ONIBI_FEATURE_LARGE_REPEAT) ||
	 ONIBI_FEATURE_P(obj, ONIBI_FEATURE_PROPERTY_ESCAPE) ||
	 (obj->feature_flags & ONIBI_FEATURE_META_ESCAPE))
	    ? rb_protect(onibi_parse_program, (VALUE)(uintptr_t)&program_args,
			 &program_state)
	    : rb_protect(onibi_build_program, (VALUE)(uintptr_t)&program_args,
			 &program_state);
    if (!program_state) {
	parsed = (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_LARGE_REPEAT) ||
		  ONIBI_FEATURE_P(obj, ONIBI_FEATURE_PROPERTY_ESCAPE) ||
		  (obj->feature_flags & ONIBI_FEATURE_META_ESCAPE))
		     ? program
		     : rb_ary_entry(program, 0);
	obj->rseq = (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_LARGE_REPEAT) ||
		     ONIBI_FEATURE_P(obj, ONIBI_FEATURE_PROPERTY_ESCAPE) ||
		     (obj->feature_flags & ONIBI_FEATURE_META_ESCAPE))
			? Qnil
			: rb_ary_entry(program, 1);
	if (!NIL_P(parsed)) {
	    OnibiParsed *parsed_data = onibi_parsed_get(parsed);
	    obj->ast_flags = parsed_data->ast_flags;
	    /* The AST is an initialization artifact.  The published RSeq/GIR
	       objects carry all runtime data. */
	    if (parsed_data->arena.root != ONIBI_AST_NONE)
		onibi_ast_arena_free(&parsed_data->arena);
	}
	/* Keep constructs without a complete GIR lowering on MRI.  This test
	   runs once during compilation.  Match calls do not inspect source. */
	int encoded_literal_program =
	    (opts & 16) && !(opts & (1 | 32)) &&
	    source_encoding_index != rb_ascii8bit_encindex() &&
	    !source_ascii_only &&
	    ONIBI_FEATURE_P(obj, ONIBI_FEATURE_NON_ASCII_LITERAL) &&
	    !(obj->feature_flags & ONIBI_FEATURE_WILDCARD) &&
	    !(obj->feature_flags & ONIBI_FEATURE_ANCHOR) &&
	    (!ONIBI_FEATURE_P(obj, ONIBI_FEATURE_NON_ASCII_CLASS) ||
	     (obj->ast_flags & ONIBI_AST_FLAG_SAFE_MULTIBYTE_CLASS) != 0);
	if ((!onibi_ascii_pattern(source) && !encoded_literal_program) ||
	    ((opts & 16) && !encoded_literal_program) || (opts & 32)) {
	    parsed = obj->rseq = Qnil;
	}
	if (!NIL_P(obj->rseq)) {
	    obj->rseq_blob = obj->rseq;
	    obj->rseq_view_valid =
		onibi_rseq_view_init(obj->rseq_blob, &obj->rseq_view) ? 1 : 0;
	}
    }
    else {
	rb_set_errinfo(Qnil);
	/* Keep a failed lowering on the dynamic MRI boundary. */
	obj->execution_flags |= ONIBI_FEATURE_DYNAMIC;
    }
    onibi_token_vector_free(&tokens);
    if (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_SUBROUTINE) && !NIL_P(obj->rseq))
	obj->execution_flags &= ~ONIBI_FEATURE_DYNAMIC;
    obj->execution_kind = (obj->execution_flags & ONIBI_FEATURE_DYNAMIC)
			      ? ONIBI_EXEC_DYNAMIC
			      : ((obj->execution_flags & ONIBI_FEATURE_TAGGED)
				     ? ONIBI_EXEC_TAGGED
				     : ONIBI_EXEC_REGULAR);
    rb_obj_freeze(self);
    return self;
}

static VALUE
onibi_match(int argc, VALUE *argv, VALUE self)
{
    VALUE str, pos = Qnil;
    rb_scan_args(argc, argv, "11", &str, &pos);
    if (argc == 2 && NIL_P(pos))
	rb_raise(rb_eTypeError, "no implicit conversion from nil to integer");
    if (argc == 2 && RB_TYPE_P(pos, T_STRING))
	rb_raise(rb_eTypeError,
		 "no implicit conversion of String into Integer");
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    int str_encoding_index =
	RB_TYPE_P(str, T_STRING) ? rb_enc_get_index(str) : -1;
    int str_ascii_only =
	RB_TYPE_P(str, T_STRING) && rb_enc_str_asciionly_p(str);
    /* Run the compiled C interpreter before MatchData materialization.  The
       MRI call below remains only the final host-side MatchData constructor. */
    if (NIL_P(pos) && RB_TYPE_P(str, T_STRING) && !NIL_P(obj->rseq) &&
	!onibi_mri_compat_path_p(obj) && !(obj->options & 32) &&
	(!onibi_regexp_fixed_p(obj) || onibi_encoded_literal_program_p(obj)) &&
	onibi_vm_input_eligible(obj, str) &&
	(!ONIBI_FEATURE_P(obj, ONIBI_FEATURE_ASCII_PROPERTY) ||
	 str_ascii_only ||
	 (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_UNICODE_PROPERTY) &&
	  (str_encoding_index == rb_utf8_encindex() ||
	   str_encoding_index == obj->source_encoding_index))) &&
	(str_ascii_only || onibi_valid_encoding(str))) {
	if (!RTEST(onibi_vm_match_p(self, str))) {
	    rb_backref_set(Qnil);
	    return Qnil;
	}
    }
    VALUE match = NIL_P(pos) ? rb_funcall(obj->regexp, id_match, 1, str)
			     : rb_funcall(obj->regexp, id_match, 2, str, pos);
    if (NIL_P(match)) {
	rb_backref_set(Qnil);
	return Qnil;
    }
    return rb_block_given_p() ? rb_yield(match) : match;
}

static VALUE
onibi_match_p(int argc, VALUE *argv, VALUE self)
{
    VALUE str, pos = Qnil;
    rb_scan_args(argc, argv, "11", &str, &pos);
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    int str_encoding_index =
	RB_TYPE_P(str, T_STRING) ? rb_enc_get_index(str) : -1;
    int str_ascii_only =
	RB_TYPE_P(str, T_STRING) && rb_enc_str_asciionly_p(str);
    if (NIL_P(pos) && !NIL_P(obj->rseq) && RB_TYPE_P(str, T_STRING) &&
	!onibi_mri_compat_path_p(obj) && !(obj->options & 32) &&
	(!onibi_regexp_fixed_p(obj) || onibi_encoded_literal_program_p(obj)) &&
	onibi_vm_input_eligible(obj, str) &&
	(!ONIBI_FEATURE_P(obj, ONIBI_FEATURE_ASCII_PROPERTY) ||
	 str_ascii_only ||
	 (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_UNICODE_PROPERTY) &&
	  (str_encoding_index == rb_utf8_encindex() ||
	   str_encoding_index == obj->source_encoding_index))) &&
	(str_ascii_only || onibi_valid_encoding(str)))
	return onibi_vm_match_p(self, str);
    return NIL_P(pos) ? rb_funcall(obj->regexp, id_match_p, 1, str)
		      : rb_funcall(obj->regexp, id_match_p, 2, str, pos);
}

/* The parser and compiler decide support at initialize time.  Keep this
   entry point free of source inspection. */
static VALUE
onibi_source(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return rb_funcall(obj->regexp, id_source, 0);
}
static VALUE
onibi_names(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return obj->names;
}
static VALUE
onibi_named_captures(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return obj->named_captures;
}
static VALUE
onibi_casefold_p(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return (obj->options & 1) ? Qtrue : Qfalse;
}
static VALUE
onibi_hash(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    st_index_t value = rb_str_hash(obj->source);
    value ^= (st_index_t)(unsigned int)obj->options;
    return ULONG2NUM((unsigned long)value);
}
static VALUE
onibi_equal(VALUE self, VALUE other)
{
    if (!rb_obj_is_kind_of(other, cRegexp)) return Qfalse;
    onibi_regexp_t *left;
    onibi_regexp_t *right;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, left);
    TypedData_Get_Struct(other, onibi_regexp_t, &onibi_type, right);
    return (left->options == right->options &&
	    rb_str_equal(left->source, right->source))
	       ? Qtrue
	       : Qfalse;
}
static VALUE
onibi_options(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return INT2NUM(obj->options);
}
static VALUE
onibi_fixed_encoding_p(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    /* MRI fixes NOENCODING only when syntax forces a binary property mode. */
    return onibi_regexp_fixed_p(obj) ||
		   ((obj->options & 32) &&
		    ONIBI_FEATURE_P(obj, ONIBI_FEATURE_ASCII_PROPERTY)) ||
		   (obj->source_ascii_only &&
		    ONIBI_FEATURE_P(obj, ONIBI_FEATURE_NON_ASCII_LITERAL))
	       ? Qtrue
	       : Qfalse;
}
static VALUE
onibi_no_encoding_p(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return (obj->options & 32) ? Qtrue : Qfalse;
}
static VALUE
onibi_inspect(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return rb_funcall(obj->regexp, id_inspect, 0);
}
static VALUE
onibi_to_s(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return rb_funcall(obj->regexp, id_to_s, 0);
}
static VALUE
onibi_encoding(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return rb_funcall(obj->regexp, id_encoding, 0);
}
static VALUE
onibi_timeout(VALUE self)
{
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    return obj->timeout_seconds > 0.0 ? DBL2NUM(obj->timeout_seconds) : Qnil;
}
static VALUE
onibi_timeout_set(VALUE klass, VALUE value)
{
    (void)klass;
    onibi_default_timeout = onibi_timeout_value(value);
    return NIL_P(value) ? Qnil : DBL2NUM(onibi_default_timeout);
}
static VALUE
onibi_timeout_default(VALUE klass)
{
    (void)klass;
    return onibi_default_timeout > 0.0 ? DBL2NUM(onibi_default_timeout) : Qnil;
}

static VALUE
onibi_regexp_escape(VALUE klass, VALUE string)
{
    (void)klass;
    return rb_funcall(rb_cRegexp, id_escape, 1, string);
}

static VALUE
onibi_native_regexp_source(VALUE regexp)
{
    VALUE method =
	rb_funcall(rb_cRegexp, id_instance_method, 1, ID2SYM(id_source));
    VALUE bound = rb_funcall(method, id_bind, 1, regexp);
    return rb_funcall(bound, id_call, 0);
}

static VALUE
onibi_regexp_union(int argc, VALUE *argv, VALUE klass)
{
    VALUE normalized = rb_ary_new_capa(argc);
    for (int i = 0; i < argc; i++) {
	VALUE item = argv[i];
	if (rb_obj_is_kind_of(item, rb_cRegexp) &&
	    rb_obj_class(item) != rb_cRegexp) {
	    VALUE source = onibi_native_regexp_source(item);
	    item = rb_funcall(rb_cRegexp, id_new, 2, source,
			      INT2NUM(rb_reg_options(item)));
	}
	rb_ary_push(normalized, item);
    }
    VALUE mri_regexp =
	rb_funcallv(rb_cRegexp, id_union, (int)RARRAY_LEN(normalized),
		    RARRAY_PTR(normalized));
    return rb_funcall(klass, id_new, 1, mri_regexp);
}

static VALUE
onibi_regexp_try_convert(VALUE klass, VALUE value)
{
    (void)klass;
    if (rb_obj_is_kind_of(value, cRegexp) ||
	rb_obj_is_kind_of(value, rb_cRegexp))
	return value;
    if (!rb_respond_to(value, id_to_regexp)) return Qnil;
    VALUE converted = rb_funcall(value, id_to_regexp, 0);
    if (NIL_P(converted)) return Qnil;
    if (!rb_obj_is_kind_of(converted, cRegexp) &&
	!rb_obj_is_kind_of(converted, rb_cRegexp))
	rb_raise(rb_eTypeError, "can't convert %s into Regexp",
		 rb_obj_classname(value));
    return converted;
}

static VALUE
onibi_regexp_linear_time_p(VALUE klass, VALUE pattern)
{
    VALUE regexp = rb_funcall(klass, id_new, 1, pattern);
    onibi_regexp_t *obj;
    TypedData_Get_Struct(regexp, onibi_regexp_t, &onibi_type, obj);
    return (!(obj->execution_flags &
	      (ONIBI_FEATURE_DYNAMIC | ONIBI_FEATURE_ATOMIC)) &&
	    !ONIBI_FEATURE_P(obj, ONIBI_FEATURE_BACKREF) &&
	    !ONIBI_FEATURE_P(obj, ONIBI_FEATURE_SUBROUTINE) &&
	    !ONIBI_FEATURE_P(obj, ONIBI_FEATURE_ABSENCE) &&
	    !ONIBI_FEATURE_P(obj, ONIBI_FEATURE_CONDITIONAL))
	       ? Qtrue
	       : Qfalse;
}

static int __attribute__((unused))
onibi_vm_counter_actions_ok(VALUE actions, const OnibiCounterState *counters)
{
    if (!counters || !counters->values) return 1;
    for (long i = 0; i < RARRAY_LEN(actions); i++) {
	VALUE action = rb_ary_entry(actions, i);
	OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(
	    onibi_hash_value_id(action, id_key_action_code));
	if (code != ONIBI_GA_TEST_COUNTER_LT &&
	    code != ONIBI_GA_TEST_COUNTER_GE)
	    continue;
	VALUE slot_value = onibi_hash_value_id(action, id_key_slot);
	if (NIL_P(slot_value)) continue;
	long slot = NUM2LONG(slot_value);
	long count = (slot >= 0 && (uint32_t)slot < counters->count)
			 ? counters->values[slot]
			 : 0;
	VALUE limit_value = onibi_hash_value_id(action, id_key_limit);
	if (NIL_P(limit_value)) return 0;
	long limit = NUM2LONG(limit_value);
	if ((code == ONIBI_GA_TEST_COUNTER_LT && !(count < limit)) ||
	    (code == ONIBI_GA_TEST_COUNTER_GE && !(count >= limit)))
	    return 0;
    }
    return 1;
}

static void __attribute__((unused))
onibi_vm_apply_counter_actions_c(VALUE actions, OnibiCounterState *counters)
{
    if (!counters || !counters->values) return;
    for (long i = 0; i < RARRAY_LEN(actions); i++) {
	VALUE action = rb_ary_entry(actions, i);
	OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(
	    onibi_hash_value_id(action, id_key_action_code));
	VALUE slot_value = onibi_hash_value_id(action, id_key_slot);
	if (NIL_P(slot_value)) continue;
	long slot = NUM2LONG(slot_value);
	if (slot < 0 || (uint32_t)slot >= counters->count) continue;
	if (code == ONIBI_GA_COUNTER_INIT) {
	    VALUE value = onibi_hash_value_id(action, id_key_value);
	    counters->values[slot] = NIL_P(value) ? 0 : NUM2LONG(value);
	}
	else if (code == ONIBI_GA_COUNTER_INCREMENT)
	    counters->values[slot]++;
    }
}

static int __attribute__((unused))
onibi_vm_actions_ok(VALUE actions, VALUE subject, long pos, long length,
		    long search_origin, VALUE counters,
		    const OnibiCounterState *counter_state, VALUE captures)
{
    for (long i = 0; i < RARRAY_LEN(actions); i++) {
	VALUE action = rb_ary_entry(actions, i);
	OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(
	    onibi_hash_value_id(action, id_key_action_code));
	if (code == ONIBI_GA_TEST_CAPTURE) {
	    long capture = NUM2LONG(onibi_hash_value_id(action, id_key_slot));
	    int set = !NIL_P(captures) &&
		      !NIL_P(rb_hash_aref(captures, LONG2NUM(2 * capture))) &&
		      !NIL_P(rb_hash_aref(captures, LONG2NUM(2 * capture + 1)));
	    if (!set && !NIL_P(captures)) {
		for (long event = 0; event < RARRAY_LEN(actions); event++) {
		    VALUE event_action = rb_ary_entry(actions, event);
		    if ((OnibiGActionOp)NUM2UINT(onibi_hash_value_id(
			    event_action, id_key_action_code)) ==
