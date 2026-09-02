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

static void
onibi_rseq_serialize_action(const OnibiGAction *action,
			    OnibiRAction *physical_action)
{
    memset(physical_action, 0, sizeof(*physical_action));
    physical_action->op = onibi_rseq_physical_action_op(action->code);
    physical_action->flags = onibi_g_action_flags(action);
    physical_action->arg16 = action->has_assert_kind
				 ? action->assert_kind
				 : onibi_g_action_assert_kind(action);

    if (action->code == ONIBI_GA_ASSERT_POSITION &&
	(action->assert_kind == ONIBI_RAP_LOOKAHEAD ||
	 action->assert_kind == ONIBI_RAP_LOOKBEHIND))
	physical_action->flags = action->assert_kind == ONIBI_RAP_LOOKAHEAD
				     ? (action->positive ? 1 : 2)
				     : (action->positive ? 5 : 6);
    if (action->has_slot) physical_action->arg16 = action->slot;
    if (action->has_arg32) physical_action->arg32 = action->arg32;
}

/* RSeq lowering uses one scoped owner for all mutable lowering records.  The
 * owner remains active until the protected body publishes or discards them. */
typedef struct {
    onibi_allocation_owner_t allocations;
    OnibiGirStateVector states;
    OnibiRSeqSubprogramVector subprograms;
    OnibiRSeqClassPayloadVector class_payloads;
    OnibiRSeqLiteralPayloadVector literal_payloads;
    OnibiGActionVector actions;
    OnibiGActionVector pending_actions;
    OnibiGirEdgeVector edges;
    OnibiGirEdgeVector start_edges;
    int failure_phase;
    int *failure_fired;
} OnibiRSeqLowerOwner;
typedef struct {
    OnibiRSeqLowerOwner *owner;
    VALUE compiled;
} OnibiRSeqLowerCall;

static void
onibi_rseq_lower_fail_if(OnibiRSeqLowerOwner *owner, int phase)
{
    if (owner->failure_phase == phase) {
	if (owner->failure_fired) *owner->failure_fired = 1;
	rb_raise(eRegexpError, "injected RSeq lowering failure at pass %d",
		 phase);
    }
}

static void
onibi_rseq_lower_owner_cleanup(OnibiRSeqLowerOwner *owner)
{
    onibi_rseq_class_payload_vector_free(&owner->class_payloads);
    onibi_rseq_literal_payload_vector_free(&owner->literal_payloads);
    onibi_g_action_vector_free(&owner->actions);
    onibi_g_action_vector_free(&owner->pending_actions);
    onibi_gir_edge_vector_free(&owner->edges);
    onibi_gir_edge_vector_free(&owner->start_edges);
    onibi_gir_state_vector_free(&owner->states);
    onibi_rseq_subprogram_vector_free(&owner->subprograms);
    onibi_allocation_owner_cleanup(&owner->allocations);
}

static VALUE
onibi_rseq_lower_owner_ensure(VALUE opaque)
{
    onibi_rseq_lower_owner_cleanup((OnibiRSeqLowerOwner *)(uintptr_t)opaque);
    return Qnil;
}

static VALUE
onibi_rseq_lower_body(VALUE opaque)
{
    OnibiRSeqLowerCall *call = (OnibiRSeqLowerCall *)(uintptr_t)opaque;
    OnibiRSeqLowerOwner *owner = call->owner;
    VALUE compiled = call->compiled;
#define state_records (owner->states)
#define subprogram_records (owner->subprograms)
#define class_payloads (owner->class_payloads)
#define literal_payloads (owner->literal_payloads)
#define action_records (owner->actions)
#define r_edge_records (owner->edges)
#define r_start_edge_records (owner->start_edges)
    onibi_g_action_vector_init(&owner->pending_actions);
    onibi_g_action_vector_bind(&owner->pending_actions, &owner->allocations);
    OnibiCompiled *compiled_data = onibi_compiled_get(compiled);
    if (compiled_data->states.count == 0)
	rb_raise(rb_eArgError, "RSeq lowering requires compiler output");
    if (!RTEST(rb_obj_frozen_p(compiled)) ||
	compiled_data->subprograms.count == 0)
	rb_raise(rb_eArgError, "RSeq lowering requires immutable GIR");
    long gir_capture_count = compiled_data->capture_count;
    if (gir_capture_count < 0 || (uint64_t)gir_capture_count > UINT32_MAX)
	rb_raise(rb_eArgError, "RSeq capture count is out of range");
    uint32_t capture_count = (uint32_t)gir_capture_count;
    size_t state_count = compiled_data->states.count;
    onibi_allocation_owner_set_phase(&owner->allocations, 1);
    onibi_gir_state_vector_init(&state_records);
    onibi_gir_state_vector_bind(&state_records, &owner->allocations);
    if (state_count > 0) {
	state_records.entries =
	    onibi_owned_realloc(&owner->allocations, NULL,
				state_count * sizeof(OnibiGirStateEntry));
	memcpy(state_records.entries, compiled_data->states.entries,
	       state_count * sizeof(*state_records.entries));
	state_records.count = state_records.capacity = state_count;
    }
    onibi_rseq_lower_fail_if(owner, 1);
    onibi_allocation_owner_set_phase(&owner->allocations, 2);
    onibi_rseq_subprogram_vector_init(&subprogram_records);
    onibi_rseq_subprogram_vector_bind(&subprogram_records, &owner->allocations);
    for (size_t i = 0; i < compiled_data->subprograms.count; i++)
	onibi_rseq_subprogram_vector_push(
	    &subprogram_records, compiled_data->subprograms.entries[i]);
    onibi_rseq_lower_fail_if(owner, 2);
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
    onibi_allocation_owner_set_phase(&owner->allocations, 3);
    onibi_rseq_class_payload_vector_init(&class_payloads);
    onibi_rseq_class_payload_vector_bind(&class_payloads, &owner->allocations);
    for (size_t i = 0; i < state_records.count; i++) {
	OnibiGirStateEntry *state = &state_records.entries[i];
	if (state->opcode != ONIBI_G_CLASS) continue;
	int found = 0;
	size_t payload_index = class_payloads.count;
	for (size_t j = 0; j < class_payloads.count; j++) {
	    OnibiRSeqClassPayloadEntry *prior = &class_payloads.entries[j];
	    if (memcmp(prior->bitmap, state->bitmap, sizeof(prior->bitmap)) ==
		    0 &&
		prior->negated ==
		    ((state->flags & ONIBI_RSEQ_STATE_FLAG_NEGATED) != 0)) {
		found = 1;
		payload_index = j;
		break;
	    }
	}
	if (!found)
	    onibi_rseq_class_payload_vector_push(&class_payloads, state);
	state->payload_index = (uint32_t)payload_index;
    }
    onibi_rseq_lower_fail_if(owner, 3);
    uint32_t class_count = (uint32_t)class_payloads.count;
    onibi_allocation_owner_set_phase(&owner->allocations, 4);
    onibi_g_action_vector_init(&action_records);
    onibi_g_action_vector_bind(&action_records, &owner->allocations);
    onibi_gir_edge_vector_init(&r_edge_records);
    onibi_gir_edge_vector_bind(&r_edge_records, &owner->allocations);
    for (size_t i = 0; i < compiled_data->edges.count; i++) {
	const OnibiGirEdgeEntry *edge = &compiled_data->edges.entries[i];
	const OnibiGActionVector *edge_actions = &edge->actions;
	long from = edge->from;
	long to = edge->to;
	long action_offset =
	    edge_actions->count == 0 ? 0 : (long)action_records.count;
	onibi_g_action_vector_append(&action_records, edge_actions);
	if (edge_actions->count > 0)
	    onibi_g_action_vector_push(
		&action_records,
		(OnibiGAction){ONIBI_GA_END, 0, 0, 0, 0, 0, 0, 0, 0});
	owner->pending_actions =
	    onibi_g_action_vector_copy(edge_actions, &owner->allocations);
	onibi_gir_edge_vector_push(&r_edge_records,
				   (OnibiGirEdgeEntry){from, to, action_offset,
						       owner->pending_actions});
	onibi_g_action_vector_init(&owner->pending_actions);
    }
    onibi_gir_edge_vector_group_by_from(&r_edge_records, (size_t)state_count);
    onibi_rseq_lower_fail_if(owner, 4);
    onibi_allocation_owner_set_phase(&owner->allocations, 5);
    onibi_gir_edge_vector_init(&r_start_edge_records);
    onibi_gir_edge_vector_bind(&r_start_edge_records, &owner->allocations);
    for (size_t i = 0; i < compiled_data->start_edges.count; i++) {
	const OnibiGirEdgeEntry *edge = &compiled_data->start_edges.entries[i];
	const OnibiGActionVector *edge_actions = &edge->actions;
	long to = edge->to;
	long action_offset =
	    edge_actions->count == 0 ? 0 : (long)action_records.count;
	onibi_g_action_vector_append(&action_records, edge_actions);
	if (edge_actions->count > 0)
	    onibi_g_action_vector_push(
		&action_records,
		(OnibiGAction){ONIBI_GA_END, 0, 0, 0, 0, 0, 0, 0, 0});
	owner->pending_actions =
	    onibi_g_action_vector_copy(edge_actions, &owner->allocations);
	onibi_gir_edge_vector_push(
	    &r_start_edge_records,
	    (OnibiGirEdgeEntry){-1, to, action_offset, owner->pending_actions});
	onibi_g_action_vector_init(&owner->pending_actions);
    }
    onibi_rseq_lower_fail_if(owner, 5);
    int options = compiled_data->options;
    int ignorecase = (options & ONIBI_OPT_IGNORECASE) != 0;
    int multiline = (options & ONIBI_OPT_MULTILINE) != 0;
    uint64_t physical_edge_count =
	(uint64_t)r_edge_records.count + (uint64_t)r_start_edge_records.count;
    onibi_allocation_owner_set_phase(&owner->allocations, 6);
    onibi_rseq_literal_payload_vector_init(&literal_payloads);
    onibi_rseq_literal_payload_vector_bind(&literal_payloads,
					   &owner->allocations);
    for (size_t i = 0; i < state_records.count; i++) {
	unsigned int opcode = state_records.entries[i].opcode;
	if (opcode != ONIBI_G_CHAR) continue;
	OnibiGirStateEntry *state = &state_records.entries[i];
	int found = 0;
	size_t payload_index = literal_payloads.count;
	for (size_t j = 0; j < literal_payloads.count; j++) {
	    OnibiRSeqLiteralPayloadEntry *prior = &literal_payloads.entries[j];
	    if (prior->length ==
		    (state->literal_length ? state->literal_length : 1) &&
		memcmp(prior->bytes, state->literal,
		       state->literal_length ? state->literal_length : 1) ==
		    0 &&
		prior->ignorecase ==
		    ((state->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) !=
		     0)) {
		found = 1;
		payload_index = j;
		break;
	    }
	}
	if (!found)
	    onibi_rseq_literal_payload_vector_push(&literal_payloads, state);
	state_records.entries[i].payload_index = (uint32_t)payload_index;
    }
    onibi_rseq_lower_fail_if(owner, 6);
    for (size_t i = 0; i < state_records.count; i++) {
	OnibiGirStateEntry *state = &state_records.entries[i];
	if (state->opcode != ONIBI_G_BACKREF) continue;
	state->payload_index = state->value;
    }
    uint32_t literal_count = (uint32_t)literal_payloads.count;
    uint64_t class_section_size =
	(uint64_t)class_count * (sizeof(OnibiClassDesc) + 32U);
    uint64_t literal_desc_size =
	(uint64_t)literal_count * sizeof(OnibiLiteralDesc);
    uint64_t literal_data_size = 0;
    for (size_t i = 0; i < literal_payloads.count; i++)
	literal_data_size += literal_payloads.entries[i].length;
    literal_data_size = (literal_data_size + 3U) & ~UINT64_C(3);
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
	action_records.count > UINT32_MAX ||
	subprogram_records.count > UINT32_MAX || physical_size > UINT32_MAX) {
	rb_raise(eRegexpError, "RSeq program exceeds the v1 size limit");
    }
    VerifiedGIRAnalysis analysis = compiled_data->analysis;
    uint32_t features = analysis.rseq_features;
    uint32_t counter_count = analysis.counter_count;
    OnibiRSeqHeader physical;
    memset(&physical, 0, sizeof(physical));
    physical.magic = ONIBI_RSEQ_MAGIC;
    physical.version = ONIBI_RSEQ_VERSION;
    physical.flags = (ignorecase ? ONIBI_RSEQ_HEADER_FLAG_IGNORECASE : 0) |
		     (multiline ? ONIBI_RSEQ_HEADER_FLAG_MULTILINE : 0);
    physical.class_count = class_count;
    physical.subprogram_count = (uint32_t)subprogram_records.count;
    physical.capture_count = capture_count;
    physical.semantic_capture_count = analysis.semantic_capture_count;
    physical.counter_count = counter_count;
    physical.exec_kind = (uint8_t)analysis.execution_kind;
    physical.start_edge_base = (uint32_t)r_edge_records.count;
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
    int bitmap_valid = 1;
    int bitmap_have = 0;
    memset(physical.first_bitmap, 0, sizeof(physical.first_bitmap));
    for (size_t i = 0; i < r_start_edge_records.count; i++) {
	OnibiGirEdgeEntry *edge = &r_start_edge_records.entries[i];
	if (edge->to < 0 || (size_t)edge->to >= state_records.count) {
	    bitmap_valid = 0;
	    continue;
	}
	OnibiGirStateEntry *state = &state_records.entries[edge->to];
	if (edge->actions.count != 0 || state->opcode == ONIBI_G_ACCEPT ||
	    state->opcode == ONIBI_G_ANY) {
	    bitmap_valid = 0;
	    continue;
	}
	if (state->opcode == ONIBI_G_CHAR && state->literal_length == 1 &&
	    (state->flags & 1U) == 0) {
	    physical.first_bitmap[state->literal[0] >> 3] |=
		(unsigned char)(1U << (state->literal[0] & 7));
	    bitmap_have = 1;
	}
	else {
	    bitmap_valid = 0;
	}
    }
    if (bitmap_valid && bitmap_have)
	features |= ONIBI_RSEQ_FEATURE_FIRST_BITMAP;
    else
	memset(physical.first_bitmap, 0, sizeof(physical.first_bitmap));
    physical.features = features;
    physical.prefix_length = 0;
    memset(physical.prefix, 0, sizeof(physical.prefix));
    if (!ignorecase && r_start_edge_records.count == 1 &&
	r_start_edge_records.entries[0].actions.count == 0) {
	long current = r_start_edge_records.entries[0].to;
	while (current >= 0 && (size_t)current < state_records.count &&
	       physical.prefix_length < sizeof(physical.prefix)) {
	    OnibiGirStateEntry *state = &state_records.entries[current];
	    if (state->opcode != ONIBI_G_CHAR ||
		(state->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0 ||
		state->literal_length == 0 ||
		state->literal_length >
		    sizeof(physical.prefix) - physical.prefix_length)
		break;
	    memcpy(physical.prefix + physical.prefix_length, state->literal,
		   state->literal_length);
	    physical.prefix_length += state->literal_length;
	    size_t outgoing = 0;
	    for (size_t e = 0; e < r_edge_records.count; e++)
		if (r_edge_records.entries[e].from == current) outgoing++;
	    if (outgoing != 1) break;
	    OnibiGirEdgeEntry *next = NULL;
	    for (size_t e = 0; e < r_edge_records.count; e++)
		if (r_edge_records.entries[e].from == current) {
		    if (r_edge_records.entries[e].actions.count != 0)
			next = NULL;
		    else
			next = &r_edge_records.entries[e];
		    break;
		}
	    if (!next || next->to < 0 ||
		(size_t)next->to >= state_records.count)
		break;
	    current = next->to;
	}
    }
    if (physical.prefix_length == 0)
	memset(physical.prefix, 0, sizeof(physical.prefix));
    physical.features = features;
    onibi_allocation_owner_set_phase(&owner->allocations, 7);
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
	else if (opcode == ONIBI_G_CALL || opcode == ONIBI_G_ATOMIC ||
		 opcode == ONIBI_G_ABSENT)
	    physical_states[i].payload = state->value;
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
	    record->actions.count == 0
		? 0
		: (uint32_t)(sizeof(OnibiRAction) *
			     ((uint32_t)record->action_offset + 1));
    }
    for (size_t i = 0; i < r_start_edge_records.count; i++) {
	OnibiGirEdgeEntry *record = &r_start_edge_records.entries[i];
	size_t index = r_edge_records.count + i;
	physical_edges[index].destination = (uint32_t)record->to;
	physical_edges[index].action_offset =
	    record->actions.count == 0
		? 0
		: (uint32_t)(sizeof(OnibiRAction) *
			     ((uint32_t)record->action_offset + 1));
    }
    OnibiRAction *physical_actions =
	(OnibiRAction *)(RSTRING_PTR(blob) + physical.actions_offset);
    for (size_t i = 0; i < action_records.count; i++)
	onibi_rseq_serialize_action(&action_records.entries[i],
				    &physical_actions[i]);
    OnibiClassDesc *class_descs =
	(OnibiClassDesc *)(RSTRING_PTR(blob) + physical.classes_offset);
    unsigned char *class_data = (unsigned char *)(class_descs + class_count);
    class_index = 0;
    for (size_t i = 0; i < class_payloads.count; i++) {
	OnibiRSeqClassPayloadEntry *entry = &class_payloads.entries[i];
	class_descs[class_index].data_offset =
	    (uint32_t)(physical.classes_offset +
		       class_count * sizeof(OnibiClassDesc) +
		       class_index * 32U);
	class_descs[class_index].data_length = 32;
	class_descs[class_index].kind = 0;
	class_descs[class_index].flags = entry->negated ? 1 : 0;
	memcpy(class_data + class_index * 32U, entry->bitmap, 32);
	class_index++;
    }
    unsigned char *literal_data =
	(unsigned char *)(RSTRING_PTR(blob) + physical.literals_offset);
    OnibiLiteralDesc *literal_descs =
	(OnibiLiteralDesc *)(RSTRING_PTR(blob) + physical.descriptors_offset);
    literal_index = 0;
    for (size_t i = 0; i < literal_payloads.count; i++) {
	OnibiRSeqLiteralPayloadEntry *entry = &literal_payloads.entries[i];
	literal_descs[literal_index].data_offset = physical.literals_offset;
	for (size_t prior = 0; prior < literal_index; prior++)
	    literal_descs[literal_index].data_offset +=
		literal_payloads.entries[prior].length;
	literal_descs[literal_index].data_length = entry->length;
	literal_descs[literal_index].flags = entry->ignorecase ? 1 : 0;
	memcpy(literal_data + literal_descs[literal_index].data_offset -
		   physical.literals_offset,
	       entry->bytes, entry->length);
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
    /* Validate once. Publish only the relocatable blob. The typed GIR vectors
	 remain compiler-owned and are released after lowering. */
    onibi_rseq_blob_validate(blob);
    onibi_rseq_lower_fail_if(owner, 7);
    onibi_rseq_class_payload_vector_free(&class_payloads);
    onibi_rseq_literal_payload_vector_free(&literal_payloads);
    onibi_g_action_vector_free(&action_records);
    onibi_g_action_vector_free(&owner->pending_actions);
    onibi_gir_edge_vector_free(&r_edge_records);
    onibi_gir_edge_vector_free(&r_start_edge_records);
    onibi_gir_state_vector_free(&state_records);
    onibi_rseq_subprogram_vector_free(&subprogram_records);
#undef state_records
#undef subprogram_records
#undef class_payloads
#undef literal_payloads
#undef action_records
#undef r_edge_records
#undef r_start_edge_records
    return blob;
}

static VALUE
onibi_rseq_lower_with_failure(VALUE compiled, int failure_phase,
			      int *failure_fired,
			      OnibiAllocationAccounting *accounting)
{
    OnibiRSeqLowerOwner owner;
    memset(&owner, 0, sizeof(owner));
    onibi_allocation_owner_init(&owner.allocations, accounting);
    owner.failure_phase = failure_phase;
    owner.failure_fired = failure_fired;
    owner.allocations.failure_phase = failure_phase;
    owner.allocations.failure_fired = failure_fired;
    OnibiRSeqLowerCall call = {&owner, compiled};
    return rb_ensure(onibi_rseq_lower_body, (VALUE)(uintptr_t)&call,
		     onibi_rseq_lower_owner_ensure, (VALUE)(uintptr_t)&owner);
}

static VALUE
onibi_rseq_lower(VALUE self, VALUE compiled)
{
    (void)self;
    return onibi_rseq_lower_with_failure(compiled, 0, NULL, NULL);
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
	    if (obj->rseq_view_valid) onibi_rseq_view_prepare(&obj->rseq_view);
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
    if (NIL_P(str)) {
	if (!NIL_P(pos))
	    rb_raise(rb_eTypeError,
		     "no implicit conversion from nil to String");
	return Qnil;
    }
    if (SYMBOL_P(str)) str = rb_sym2str(str);
    if (!RB_TYPE_P(str, T_STRING)) StringValue(str);
    long origin = 0;
    if (!NIL_P(pos)) {
	origin = NUM2LONG(pos);
	if (origin < 0) origin += RSTRING_LEN(str);
	if (origin < 0) return Qnil;
	if (origin > RSTRING_LEN(str)) origin = RSTRING_LEN(str);
    }
    long start = 0, end = 0;
    OnibiExecStatus search_status =
	onibi_vm_search(self, str, origin, &start, &end);
    if (search_status == ONIBI_EXEC_STATUS_INTERNAL_ERROR)
	rb_raise(eRegexpError, "Onibi execution failed");
    if (search_status == ONIBI_EXEC_STATUS_NO_MATCH) {
	rb_backref_set(Qnil);
	return Qnil;
    }
    onibi_regexp_t *obj;
    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
    /* VM execution selects the match.  MRI materializes MatchData and
     * capture offsets from the same source regexp for API compatibility. */
    VALUE match = NIL_P(pos) ? rb_funcall(obj->regexp, id_match, 1, str)
			     : rb_funcall(obj->regexp, id_match, 2, str,
					  LONG2NUM(origin));
    if (NIL_P(match)) return Qnil;
    return rb_block_given_p() ? rb_yield(match) : match;
}

static VALUE
onibi_match_p(int argc, VALUE *argv, VALUE self)
{
    VALUE str, pos = Qnil;
    rb_scan_args(argc, argv, "11", &str, &pos);
    if (SYMBOL_P(str)) str = rb_sym2str(str);
    if (NIL_P(str))
	rb_raise(rb_eTypeError, "no implicit conversion from nil to String");
    if (!RB_TYPE_P(str, T_STRING)) StringValue(str);
    {
	long origin = 0;
	if (!NIL_P(pos)) {
	    origin = NUM2LONG(pos);
	    if (origin < 0) origin += RSTRING_LEN(str);
	    if (origin < 0) return Qfalse;
	}
	long start = 0, end = 0;
	OnibiExecStatus result =
	    onibi_vm_search(self, str, origin, &start, &end);
	if (result == ONIBI_EXEC_STATUS_MATCH ||
	    result == ONIBI_EXEC_STATUS_NO_MATCH)
	    return result == ONIBI_EXEC_STATUS_MATCH ? Qtrue : Qfalse;
	if (result == ONIBI_EXEC_STATUS_INTERNAL_ERROR)
	    rb_raise(eRegexpError, "Onibi execution failed");
	if (result == ONIBI_EXEC_STATUS_FALLBACK) {
	    onibi_regexp_t *obj;
	    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
	    VALUE match = NIL_P(pos) ? rb_funcall(obj->regexp, id_match, 1, str)
				     : rb_funcall(obj->regexp, id_match, 2, str,
						  LONG2NUM(origin));
	    return NIL_P(match) ? Qfalse : Qtrue;
	}
    }
    return Qfalse;
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
    return (obj->options & ONIBI_OPT_IGNORECASE) ? Qtrue : Qfalse;
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
		   ((obj->options & ONIBI_OPT_NOENCODING) &&
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
    return (obj->options & ONIBI_OPT_NOENCODING) ? Qtrue : Qfalse;
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
