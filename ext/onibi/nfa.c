/* Tagged epsilon-NFA intermediate representation. */
typedef enum {
    ONIBI_NFA_EPSILON = 0,
    ONIBI_NFA_CONSUME = 1
} OnibiNfaTransitionKind;
typedef enum {
    ONIBI_NFA_STATE_EPSILON = 0,
    ONIBI_NFA_STATE_CONSUMING,
    ONIBI_NFA_STATE_ACCEPT
} OnibiNfaStateKind;
typedef long OnibiNfaStateId;

/* NFA states are independent from GIR states. */
typedef struct {
    OnibiNfaStateId id;
    OnibiNfaStateKind kind;
    OnibiGStateOp opcode;
    uint32_t value;
    uint8_t flags;
    unsigned char bitmap[32];
    unsigned char literal[4];
    uint8_t literal_length;
} OnibiNfaState;
typedef ONIBI_VECTOR(OnibiNfaState) OnibiNfaStateVector;
typedef OnibiGActionVector OnibiActionSlice;
typedef struct {
    OnibiNfaStateId from;
    OnibiNfaStateId to;
    OnibiNfaTransitionKind kind;
    OnibiActionSlice actions;
} OnibiNfaEdge;
typedef ONIBI_VECTOR(OnibiNfaEdge) OnibiNfaEdgeVector;

struct OnibiTaggedNfa {
    OnibiNfaStateVector states;
    OnibiNfaEdgeVector edges;
    OnibiIdVector starts;
    long accept;
};

ONIBI_VECTOR_DEFINE(onibi_nfa_state_vector, OnibiNfaStateVector, OnibiNfaState,
		    8, "NFA state vector is too large")
ONIBI_VECTOR_DEFINE(onibi_nfa_edge_vector, OnibiNfaEdgeVector, OnibiNfaEdge, 8,
		    "NFA edge vector is too large")

static void
onibi_nfa_init(OnibiTaggedNfa *nfa, onibi_allocation_owner_t *owner)
{
    memset(nfa, 0, sizeof(*nfa));
    onibi_nfa_state_vector_init(&nfa->states);
    onibi_nfa_state_vector_bind(&nfa->states, owner);
    onibi_nfa_edge_vector_init(&nfa->edges);
    onibi_nfa_edge_vector_bind(&nfa->edges, owner);
    onibi_id_vector_init(&nfa->starts);
    onibi_id_vector_bind(&nfa->starts, owner);
    nfa->accept = -1;
}

static void
onibi_nfa_free(OnibiTaggedNfa *nfa)
{
    onibi_nfa_state_vector_free(&nfa->states);
    for (size_t i = 0; i < nfa->edges.count; i++)
	onibi_g_action_vector_free(&nfa->edges.entries[i].actions);
    ONIBI_OWNED_VECTOR_RELEASE(&nfa->edges);
    onibi_id_vector_free(&nfa->starts);
    nfa->accept = -1;
}

static OnibiNfaState *
onibi_nfa_state_get(OnibiTaggedNfa *nfa, long id)
{
    if (id < 0 || (size_t)id >= nfa->states.count ||
	nfa->states.entries[id].id != id)
	rb_raise(eRegexpError, "NFA state ID is invalid");
    return &nfa->states.entries[id];
}

static void
onibi_nfa_state_push(onibi_gir_builder_t *builder, OnibiNfaState entry)
{
    if (entry.id != (long)builder->nfa->states.count)
	rb_raise(eRegexpError, "NFA state IDs are not sequential");
    onibi_nfa_state_vector_push(&builder->nfa->states, entry);
}

static long
onibi_nfa_epsilon_state(onibi_gir_builder_t *builder)
{
    long id = builder->next_id++;
    OnibiNfaState entry;
    memset(&entry, 0, sizeof(entry));
    entry.id = id;
    entry.kind = ONIBI_NFA_STATE_EPSILON;
    onibi_nfa_state_push(builder, entry);
    return id;
}

static void
onibi_nfa_state(onibi_gir_builder_t *builder, long id, OnibiGStateOp opcode,
		uint32_t value, uint8_t flags)
{
    OnibiNfaState entry;
    memset(&entry, 0, sizeof(entry));
    entry.id = id;
    entry.kind = opcode == ONIBI_G_ACCEPT ? ONIBI_NFA_STATE_ACCEPT
					  : ONIBI_NFA_STATE_CONSUMING;
    entry.opcode = opcode;
    entry.value = value;
    entry.flags = flags;
    onibi_nfa_state_push(builder, entry);
}

static void
onibi_nfa_state_literal(onibi_gir_builder_t *builder, long id,
			const unsigned char *bytes, size_t length,
			int ignorecase)
{
    OnibiNfaState entry;
    memset(&entry, 0, sizeof(entry));
    entry.id = id;
    entry.kind = ONIBI_NFA_STATE_CONSUMING;
    entry.opcode = ONIBI_G_CHAR;
    if (length == 0 || length > sizeof(entry.literal))
	rb_raise(eRegexpError, "literal descriptor has invalid length");
    entry.literal_length = (uint8_t)length;
    memcpy(entry.literal, bytes, length);
    entry.value = bytes[0];
    if (ignorecase) entry.flags |= 1U;
    onibi_nfa_state_push(builder, entry);
}

static void
onibi_nfa_state_class(onibi_gir_builder_t *builder, long id,
		      const unsigned char bitmap[32], int negated)
{
    OnibiNfaState entry;
    memset(&entry, 0, sizeof(entry));
    entry.id = id;
    entry.kind = ONIBI_NFA_STATE_CONSUMING;
    entry.opcode = ONIBI_G_CLASS;
    memcpy(entry.bitmap, bitmap, sizeof(entry.bitmap));
    if (negated) entry.flags |= 1U;
    onibi_nfa_state_push(builder, entry);
}

static int
onibi_nfa_actions_equal(const OnibiGActionVector *left,
			const OnibiGActionVector *right)
{
    return left->count == right->count &&
	   (left->count == 0 ||
	    memcmp(left->entries, right->entries,
		   left->count * sizeof(*left->entries)) == 0);
}

static OnibiGActionVector
onibi_nfa_compose_edge_actions(onibi_gir_builder_t *builder, long from, long to,
			       const OnibiGActionVector *explicit_actions)
{
    const OnibiGuardEntry *capture_guard = onibi_guard_vector_find_entry(
	&builder->capture_guards, (OnibiStateId)to);
    const OnibiGuardEntry *exit_guard =
	from < 0 ? NULL
		 : onibi_guard_vector_find_entry(&builder->exit_guards,
						 (OnibiStateId)from);
    OnibiGActionVector actions;
    onibi_g_action_vector_init(&actions);
    onibi_g_action_vector_bind(&actions, builder->allocation_owner);
    if (exit_guard)
	onibi_g_action_vector_append(&actions, &exit_guard->actions);
    onibi_g_action_vector_append(&actions, explicit_actions);
    if (capture_guard)
	onibi_g_action_vector_append(&actions, &capture_guard->actions);
    return actions;
}

static void
onibi_nfa_edge_insert(OnibiNfaEdgeVector *edges, size_t index,
		      OnibiNfaEdge edge)
{
    ONIBI_OWNED_VECTOR_INSERT(edges, OnibiNfaEdge, index, edge, 8,
			      "NFA edge vector is too large");
}

static void
onibi_nfa_add_raw_edge(onibi_gir_builder_t *builder, long from, long to,
		       OnibiNfaTransitionKind kind, OnibiGActionVector actions,
		       int prepend)
{
    OnibiNfaEdgeVector *edges = &builder->nfa->edges;
    for (size_t i = 0; i < edges->count; i++) {
	const OnibiNfaEdge *prior = &edges->entries[i];
	if (prior->from == from && prior->to == to && prior->kind == kind &&
	    onibi_nfa_actions_equal(&prior->actions, &actions)) {
	    onibi_g_action_vector_free(&actions);
	    return;
	}
    }
    OnibiNfaEdge edge = {from, to, kind, actions};
    if (prepend) {
	size_t insert_at = edges->count;
	for (size_t i = 0; i < edges->count; i++) {
	    if (edges->entries[i].from == from) {
		insert_at = i;
		break;
	    }
	}
	onibi_nfa_edge_insert(edges, insert_at, edge);
    }
    else
	onibi_nfa_edge_vector_push(edges, edge);
}

/* Add one semantic connection.  The epsilon state keeps zero-width path
 * structure separate from the following consuming transition. */
static void
onibi_nfa_add_connection(onibi_gir_builder_t *builder, long from, long to,
			 const OnibiGActionVector *actions, int prepend)
{
    OnibiGActionVector composed =
	onibi_nfa_compose_edge_actions(builder, from, to, actions);
    OnibiNfaState *destination = onibi_nfa_state_get(builder->nfa, to);
    if (destination->kind == ONIBI_NFA_STATE_ACCEPT) {
	onibi_nfa_add_raw_edge(builder, from, to, ONIBI_NFA_EPSILON, composed,
			       prepend);
	return;
    }
    long boundary = onibi_nfa_epsilon_state(builder);
    onibi_nfa_add_raw_edge(builder, from, boundary, ONIBI_NFA_EPSILON, composed,
			   prepend);
    OnibiGActionVector empty;
    onibi_g_action_vector_init(&empty);
    onibi_g_action_vector_bind(&empty, builder->allocation_owner);
    onibi_nfa_add_raw_edge(builder, boundary, to, ONIBI_NFA_CONSUME, empty, 0);
}

static void
onibi_connect_fragment_actions(onibi_gir_builder_t *builder,
			       const OnibiIdVector *exits,
			       const OnibiIdVector *starts,
			       const OnibiGActionVector *actions, int prepend)
{
    for (size_t i = 0; i < exits->count; i++)
	for (size_t j = 0; j < starts->count; j++)
	    onibi_nfa_add_connection(builder, (long)exits->entries[i],
				     (long)starts->entries[j], actions,
				     prepend);
}

static void
onibi_connect_fragment(onibi_gir_builder_t *builder, const OnibiIdVector *exits,
		       const OnibiIdVector *starts)
{
    OnibiGActionVector empty;
    onibi_g_action_vector_init(&empty);
    onibi_g_action_vector_bind(&empty, builder->allocation_owner);
    onibi_connect_fragment_actions(builder, exits, starts, &empty, 0);
}

static void
onibi_nfa_add_start(onibi_gir_builder_t *builder, long destination,
		    const OnibiGActionVector *actions)
{
    onibi_id_vector_push(&builder->nfa->starts, (OnibiStateId)destination);
    onibi_nfa_add_connection(builder, -1, destination, actions, 0);
}

static int
onibi_nfa_edge_seen(const OnibiGirEdgeVector *edges, long from, long to,
		    const OnibiGActionVector *actions)
{
    for (size_t i = 0; i < edges->count; i++) {
	const OnibiGirEdgeEntry *edge = &edges->entries[i];
	if (edge->from == from && edge->to == to &&
	    onibi_nfa_actions_equal(&edge->actions, actions))
	    return 1;
    }
    return 0;
}

typedef struct {
    const OnibiTaggedNfa *nfa;
    OnibiGirEdgeVector *out;
    const long *state_map;
    unsigned char *visiting;
    long state_count;
} OnibiNfaClosure;

static void onibi_nfa_emit_closure(OnibiNfaClosure *closure, long origin,
				   long state,
				   const OnibiGActionVector *actions);

typedef struct {
    OnibiNfaClosure *closure;
    long origin;
    long state;
    OnibiGActionVector actions;
} OnibiNfaClosureCall;

static VALUE
onibi_nfa_closure_call_body(VALUE opaque)
{
    OnibiNfaClosureCall *call = (OnibiNfaClosureCall *)(uintptr_t)opaque;
    onibi_nfa_emit_closure(call->closure, call->origin, call->state,
			   &call->actions);
    return Qnil;
}

static VALUE
onibi_nfa_closure_call_ensure(VALUE opaque)
{
    OnibiNfaClosureCall *call = (OnibiNfaClosureCall *)(uintptr_t)opaque;
    onibi_g_action_vector_free(&call->actions);
    return Qnil;
}

typedef struct {
    OnibiGirEdgeVector *out;
    long from;
    long to;
    OnibiGActionVector actions;
    int transferred;
} OnibiNfaOutputEdgeCall;

static VALUE
onibi_nfa_output_edge_body(VALUE opaque)
{
    OnibiNfaOutputEdgeCall *call = (OnibiNfaOutputEdgeCall *)(uintptr_t)opaque;
    onibi_gir_edge_vector_push(
	call->out, (OnibiGirEdgeEntry){call->from, call->to, 0, call->actions});
    call->transferred = 1;
    return Qnil;
}

static VALUE
onibi_nfa_output_edge_ensure(VALUE opaque)
{
    OnibiNfaOutputEdgeCall *call = (OnibiNfaOutputEdgeCall *)(uintptr_t)opaque;
    if (!call->transferred) onibi_g_action_vector_free(&call->actions);
    return Qnil;
}

static void
onibi_nfa_emit_edge(OnibiNfaClosure *closure, long origin, long destination,
		    OnibiGActionVector actions)
{
    long mapped = closure->state_map[destination];
    if (mapped < 0)
	rb_raise(eRegexpError, "NFA closure reached an epsilon state");
    if (onibi_nfa_edge_seen(closure->out, origin, mapped, &actions)) {
	onibi_g_action_vector_free(&actions);
	return;
    }
    OnibiNfaOutputEdgeCall call = {closure->out, origin, mapped, actions, 0};
    (void)rb_ensure(onibi_nfa_output_edge_body, (VALUE)(uintptr_t)&call,
		    onibi_nfa_output_edge_ensure, (VALUE)(uintptr_t)&call);
}

/* Traverse ordered epsilon paths and stop at a consume or accept state. */
static void
onibi_nfa_emit_closure(OnibiNfaClosure *closure, long origin, long state,
		       const OnibiGActionVector *actions)
{
    if (state >= 0) {
	if (state >= closure->state_count)
	    rb_raise(eRegexpError, "NFA closure state is out of range");
	const OnibiNfaState *current = &closure->nfa->states.entries[state];
	if (current->kind == ONIBI_NFA_STATE_ACCEPT) {
	    onibi_nfa_emit_edge(closure, origin, state,
				onibi_g_action_vector_copy(
				    actions, closure->out->allocation_owner));
	    return;
	}
    }
    for (size_t i = 0; i < closure->nfa->edges.count; i++) {
	const OnibiNfaEdge *edge = &closure->nfa->edges.entries[i];
	if (edge->from != state) continue;
	OnibiGActionVector combined = onibi_g_action_vector_concat(
	    actions, &edge->actions, closure->out->allocation_owner);
	if (edge->kind == ONIBI_NFA_CONSUME) {
	    onibi_nfa_emit_edge(closure, origin, edge->to, combined);
	    continue;
	}
	if (edge->to < 0 || edge->to >= closure->state_count) {
	    onibi_g_action_vector_free(&combined);
	    rb_raise(eRegexpError, "NFA epsilon destination is out of range");
	}
	if (closure->visiting[edge->to]) {
	    onibi_g_action_vector_free(&combined);
	    rb_raise(eRegexpError, "epsilon transition cycle");
	}
	closure->visiting[edge->to] = 1;
	OnibiNfaClosureCall call = {closure, origin, edge->to, combined};
	(void)rb_ensure(onibi_nfa_closure_call_body, (VALUE)(uintptr_t)&call,
			onibi_nfa_closure_call_ensure, (VALUE)(uintptr_t)&call);
	closure->visiting[edge->to] = 0;
    }
}

typedef struct {
    OnibiTaggedNfa *nfa;
    onibi_gir_builder_t *gir;
    OnibiGirEdgeVector *start_edges;
    long *state_map;
    unsigned char *visiting;
} OnibiNfaEliminateOwner;

static VALUE
onibi_nfa_eliminate_ensure(VALUE opaque)
{
    OnibiNfaEliminateOwner *owner = (OnibiNfaEliminateOwner *)(uintptr_t)opaque;
    onibi_owned_free(owner->gir->allocation_owner, owner->state_map);
    onibi_owned_free(owner->gir->allocation_owner, owner->visiting);
    owner->state_map = NULL;
    owner->visiting = NULL;
    return Qnil;
}

static VALUE
onibi_epsilon_eliminate_body(VALUE opaque)
{
    OnibiNfaEliminateOwner *owner = (OnibiNfaEliminateOwner *)(uintptr_t)opaque;
    OnibiTaggedNfa *nfa = owner->nfa;
    onibi_gir_builder_t *gir = owner->gir;
    long state_count = (long)nfa->states.count;
    size_t map_bytes = (size_t)state_count * sizeof(*owner->state_map);
    owner->state_map = state_count ? onibi_owned_realloc(gir->allocation_owner,
							 NULL, map_bytes)
				   : NULL;
    owner->visiting = state_count
			  ? onibi_owned_realloc(gir->allocation_owner, NULL,
						(size_t)state_count)
			  : NULL;
    if (owner->visiting) memset(owner->visiting, 0, (size_t)state_count);

    onibi_gir_state_vector_free(&gir->states);
    onibi_gir_edge_vector_free(&gir->edges);
    onibi_gir_state_vector_init(&gir->states);
    onibi_gir_state_vector_bind(&gir->states, gir->allocation_owner);
    onibi_gir_edge_vector_init(&gir->edges);
    onibi_gir_edge_vector_bind(&gir->edges, gir->allocation_owner);
    onibi_gir_edge_vector_free(owner->start_edges);
    onibi_gir_edge_vector_init(owner->start_edges);
    onibi_gir_edge_vector_bind(owner->start_edges, gir->allocation_owner);

    long next_gir_id = 0;
    for (long i = 0; i < state_count; i++) {
	const OnibiNfaState *state = &nfa->states.entries[i];
	if (state->kind == ONIBI_NFA_STATE_EPSILON) {
	    owner->state_map[i] = -1;
	    continue;
	}
	owner->state_map[i] = next_gir_id;
	OnibiGirStateEntry finalized;
	memset(&finalized, 0, sizeof(finalized));
	finalized.id = next_gir_id++;
	finalized.opcode = state->opcode;
	finalized.value = state->value;
	finalized.flags = state->flags;
	memcpy(finalized.bitmap, state->bitmap, sizeof(finalized.bitmap));
	memcpy(finalized.literal, state->literal, sizeof(finalized.literal));
	finalized.literal_length = state->literal_length;
	onibi_gir_state_vector_push(&gir->states, finalized);
    }

    OnibiGActionVector empty;
    onibi_g_action_vector_init(&empty);
    onibi_g_action_vector_bind(&empty, gir->allocation_owner);
    OnibiNfaClosure start_closure = {nfa, owner->start_edges, owner->state_map,
				     owner->visiting, state_count};
    onibi_nfa_emit_closure(&start_closure, -1, -1, &empty);
    OnibiNfaClosure state_closure = {nfa, &gir->edges, owner->state_map,
				     owner->visiting, state_count};
    for (long i = 0; i < state_count; i++) {
	if (nfa->states.entries[i].kind != ONIBI_NFA_STATE_CONSUMING) continue;
	onibi_nfa_emit_closure(&state_closure, owner->state_map[i], i, &empty);
    }

    for (size_t i = 1; i < gir->subprograms.count; i++) {
	OnibiRSeqSubprogramEntry *subprogram = &gir->subprograms.entries[i];
	if ((long)subprogram->entry >= state_count ||
	    (long)subprogram->accept >= state_count)
	    rb_raise(eRegexpError, "NFA subprogram state is out of range");
	long entry = owner->state_map[subprogram->entry];
	long accept = owner->state_map[subprogram->accept];
	if (entry < 0 || accept < 0)
	    rb_raise(eRegexpError, "NFA subprogram maps to epsilon state");
	subprogram->entry = (OnibiStateId)entry;
	subprogram->accept = (OnibiStateId)accept;
    }
    gir->next_id = next_gir_id;
    return Qnil;
}

static void
onibi_epsilon_eliminate(OnibiTaggedNfa *nfa, onibi_gir_builder_t *gir,
			OnibiGirEdgeVector *start_edges, long *accept,
			long *root_entry)
{
    OnibiNfaEliminateOwner owner;
    memset(&owner, 0, sizeof(owner));
    owner.nfa = nfa;
    owner.gir = gir;
    owner.start_edges = start_edges;
    (void)rb_ensure(onibi_epsilon_eliminate_body, (VALUE)(uintptr_t)&owner,
		    onibi_nfa_eliminate_ensure, (VALUE)(uintptr_t)&owner);
    if (*accept < 0 || (size_t)*accept >= nfa->states.count ||
	*root_entry < 0 || (size_t)*root_entry >= nfa->states.count)
	rb_raise(eRegexpError, "NFA root state is out of range");
    /* The map is released by rb_ensure.  Find the finalized IDs by order. */
    long mapped_accept = -1;
    long mapped_root = -1;
    long next = 0;
    for (size_t i = 0; i < nfa->states.count; i++) {
	if (nfa->states.entries[i].kind == ONIBI_NFA_STATE_EPSILON) continue;
	if ((long)i == nfa->accept) mapped_accept = next;
	if ((long)i == *root_entry) mapped_root = next;
	next++;
    }
    if (mapped_accept < 0 || mapped_root < 0)
	rb_raise(eRegexpError, "NFA root maps to epsilon state");
    *accept = mapped_accept;
    *root_entry = mapped_root;
}

static VALUE
onibi_nfa_action_name(OnibiGActionOp code)
{
    const char *name;
    switch (code) {
    case ONIBI_GA_CAPTURE_OPEN: name = "capture_open"; break;
    case ONIBI_GA_CAPTURE_CLOSE: name = "capture_close"; break;
    case ONIBI_GA_MATCH_RESET: name = "match_reset"; break;
    case ONIBI_GA_ASSERT_POSITION: name = "assert_position"; break;
    case ONIBI_GA_TEST_CAPTURE: name = "test_capture"; break;
    case ONIBI_GA_COUNTER_INIT: name = "counter_init"; break;
    case ONIBI_GA_COUNTER_INCREMENT: name = "counter_increment"; break;
    case ONIBI_GA_TEST_COUNTER_LT: name = "test_counter_lt"; break;
    case ONIBI_GA_TEST_COUNTER_GE: name = "test_counter_ge"; break;
    case ONIBI_GA_PROGRESS: name = "progress"; break;
    default: name = "end"; break;
    }
    return ID2SYM(rb_intern(name));
}

static VALUE
onibi_nfa_state_kind_name(OnibiNfaStateKind kind)
{
    const char *name =
	kind == ONIBI_NFA_STATE_EPSILON
	    ? "epsilon"
	    : (kind == ONIBI_NFA_STATE_ACCEPT ? "accept" : "consume");
    return ID2SYM(rb_intern(name));
}

/* This adapter exists only for focused internal tests. */
static VALUE
onibi_nfa_diagnostics(const OnibiTaggedNfa *nfa)
{
    VALUE result = rb_hash_new();
    VALUE states = rb_ary_new_capa((long)nfa->states.count);
    VALUE edges = rb_ary_new_capa((long)nfa->edges.count);
    for (size_t i = 0; i < nfa->states.count; i++) {
	const OnibiNfaState *state = &nfa->states.entries[i];
	VALUE record = rb_hash_new();
	rb_hash_aset(record, ID2SYM(rb_intern("id")), LONG2NUM(state->id));
	rb_hash_aset(record, ID2SYM(rb_intern("kind")),
		     onibi_nfa_state_kind_name(state->kind));
	rb_hash_aset(record, ID2SYM(rb_intern("op")), INT2NUM(state->opcode));
	rb_hash_aset(record, ID2SYM(rb_intern("value")),
		     UINT2NUM(state->value));
	rb_ary_push(states, record);
    }
    for (size_t i = 0; i < nfa->edges.count; i++) {
	const OnibiNfaEdge *edge = &nfa->edges.entries[i];
	VALUE actions = rb_ary_new_capa((long)edge->actions.count);
	for (size_t j = 0; j < edge->actions.count; j++)
	    rb_ary_push(actions,
			onibi_nfa_action_name(edge->actions.entries[j].code));
	VALUE record = rb_hash_new();
	rb_hash_aset(record, ID2SYM(rb_intern("from")), LONG2NUM(edge->from));
	rb_hash_aset(record, ID2SYM(rb_intern("to")), LONG2NUM(edge->to));
	rb_hash_aset(
	    record, ID2SYM(rb_intern("kind")),
	    ID2SYM(rb_intern(edge->kind == ONIBI_NFA_EPSILON ? "epsilon"
							     : "consume")));
	rb_hash_aset(record, ID2SYM(rb_intern("actions")), actions);
	rb_ary_push(edges, record);
    }
    rb_hash_aset(result, ID2SYM(rb_intern("states")), states);
    rb_hash_aset(result, ID2SYM(rb_intern("edges")), edges);
    rb_hash_aset(result, ID2SYM(rb_intern("accept")), LONG2NUM(nfa->accept));
    return result;
}
