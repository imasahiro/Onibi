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
    if (left->count != right->count) return 0;
    for (size_t i = 0; i < left->count; i++) {
	const OnibiGAction *a = &left->entries[i];
	const OnibiGAction *b = &right->entries[i];
	if (a->code != b->code || a->set != b->set ||
	    a->positive != b->positive || a->has_slot != b->has_slot ||
	    a->slot != b->slot || a->has_assert_kind != b->has_assert_kind ||
	    a->assert_kind != b->assert_kind || a->has_arg32 != b->has_arg32 ||
	    a->arg32 != b->arg32 || a->has_subprogram != b->has_subprogram ||
	    a->subprogram_id != b->subprogram_id)
	    return 0;
    }
    return 1;
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

typedef struct {
    size_t offset;
    size_t count;
} OnibiNfaAdjacencyRange;

typedef struct {
    OnibiNfaAdjacencyRange *ranges;
    size_t *edge_indices;
} OnibiNfaAdjacency;

typedef struct {
    uint64_t hash;
    size_t output_index;
    unsigned char used;
} OnibiNfaDedupSlot;

typedef struct {
    OnibiNfaDedupSlot *slots;
    size_t capacity;
    size_t count;
} OnibiNfaDedup;

typedef struct {
    const OnibiTaggedNfa *nfa;
    const OnibiNfaAdjacency *adjacency;
    OnibiGirEdgeVector *out;
    const long *state_map;
    size_t *visiting_action_bases;
    OnibiNfaDedup *dedup;
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

static uint64_t
onibi_nfa_hash_bytes(uint64_t hash, const void *data, size_t length)
{
    const unsigned char *bytes = data;
    for (size_t i = 0; i < length; i++) {
	hash ^= bytes[i];
	hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static uint64_t
onibi_nfa_edge_key_hash(long destination, const OnibiGActionVector *actions)
{
    uint64_t hash = UINT64_C(1469598103934665603);
    hash = onibi_nfa_hash_bytes(hash, &destination, sizeof(destination));
    hash = onibi_nfa_hash_bytes(hash, &actions->count, sizeof(actions->count));
    for (size_t i = 0; i < actions->count; i++) {
	const OnibiGAction *action = &actions->entries[i];
	hash = onibi_nfa_hash_bytes(hash, &action->code, sizeof(action->code));
	hash = onibi_nfa_hash_bytes(hash, &action->set, sizeof(action->set));
	hash = onibi_nfa_hash_bytes(hash, &action->positive,
				    sizeof(action->positive));
	hash = onibi_nfa_hash_bytes(hash, &action->has_slot,
				    sizeof(action->has_slot));
	hash = onibi_nfa_hash_bytes(hash, &action->slot, sizeof(action->slot));
	hash = onibi_nfa_hash_bytes(hash, &action->has_assert_kind,
				    sizeof(action->has_assert_kind));
	hash = onibi_nfa_hash_bytes(hash, &action->assert_kind,
				    sizeof(action->assert_kind));
	hash = onibi_nfa_hash_bytes(hash, &action->has_arg32,
				    sizeof(action->has_arg32));
	hash =
	    onibi_nfa_hash_bytes(hash, &action->arg32, sizeof(action->arg32));
	hash = onibi_nfa_hash_bytes(hash, &action->has_subprogram,
				    sizeof(action->has_subprogram));
	hash = onibi_nfa_hash_bytes(hash, &action->subprogram_id,
				    sizeof(action->subprogram_id));
    }
    return hash;
}

static void
onibi_nfa_dedup_reset(OnibiNfaDedup *dedup)
{
    if (dedup->slots)
	memset(dedup->slots, 0, dedup->capacity * sizeof(*dedup->slots));
    dedup->count = 0;
}

static void
onibi_nfa_dedup_insert_slot(OnibiNfaDedupSlot *slots, size_t capacity,
			    uint64_t hash, size_t output_index)
{
    size_t slot = (size_t)hash & (capacity - 1);
    while (slots[slot].used)
	slot = (slot + 1) & (capacity - 1);
    slots[slot] = (OnibiNfaDedupSlot){hash, output_index, 1};
}

static void
onibi_nfa_dedup_reserve(OnibiNfaDedup *dedup, onibi_allocation_owner_t *owner)
{
    if (dedup->capacity != 0 && dedup->count + 1 <= dedup->capacity / 2) return;
    if (dedup->capacity > SIZE_MAX / 2 / sizeof(*dedup->slots))
	rb_raise(rb_eNoMemError, "NFA edge dedup index is too large");
    size_t capacity = dedup->capacity == 0 ? 16 : dedup->capacity * 2;
    OnibiNfaDedupSlot *slots =
	onibi_owned_realloc(owner, NULL, capacity * sizeof(*slots));
    memset(slots, 0, capacity * sizeof(*slots));
    for (size_t i = 0; i < dedup->capacity; i++) {
	const OnibiNfaDedupSlot *prior = &dedup->slots[i];
	if (prior->used)
	    onibi_nfa_dedup_insert_slot(slots, capacity, prior->hash,
					prior->output_index);
    }
    onibi_owned_free(owner, dedup->slots);
    dedup->slots = slots;
    dedup->capacity = capacity;
}

static int
onibi_nfa_dedup_find(const OnibiNfaDedup *dedup, const OnibiGirEdgeVector *out,
		     long destination, const OnibiGActionVector *actions,
		     uint64_t hash, size_t *slot_out)
{
    size_t slot = (size_t)hash & (dedup->capacity - 1);
    while (dedup->slots[slot].used) {
	const OnibiNfaDedupSlot *candidate = &dedup->slots[slot];
	const OnibiGirEdgeEntry *edge = &out->entries[candidate->output_index];
	if (candidate->hash == hash && edge->to == destination &&
	    onibi_nfa_actions_equal(&edge->actions, actions))
	    return 1;
	slot = (slot + 1) & (dedup->capacity - 1);
    }
    *slot_out = slot;
    return 0;
}

static void
onibi_nfa_emit_edge(OnibiNfaClosure *closure, long origin, long destination,
		    OnibiGActionVector actions)
{
    long mapped = closure->state_map[destination];
    if (mapped < 0)
	rb_raise(eRegexpError, "NFA closure reached an epsilon state");
    onibi_nfa_dedup_reserve(closure->dedup, closure->out->allocation_owner);
    uint64_t hash = onibi_nfa_edge_key_hash(mapped, &actions);
    size_t slot;
    if (onibi_nfa_dedup_find(closure->dedup, closure->out, mapped, &actions,
			     hash, &slot)) {
	onibi_g_action_vector_free(&actions);
	return;
    }
    OnibiNfaOutputEdgeCall call = {closure->out, origin, mapped, actions, 0};
    (void)rb_ensure(onibi_nfa_output_edge_body, (VALUE)(uintptr_t)&call,
		    onibi_nfa_output_edge_ensure, (VALUE)(uintptr_t)&call);
    closure->dedup->slots[slot] =
	(OnibiNfaDedupSlot){hash, closure->out->count - 1, 1};
    closure->dedup->count++;
}

static int
onibi_nfa_cycle_has_progress(const OnibiGActionVector *actions, size_t base)
{
    for (size_t i = base; i < actions->count; i++)
	if (actions->entries[i].code == ONIBI_GA_PROGRESS) return 1;
    return 0;
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
    size_t source_slot = (size_t)(state + 1);
    const OnibiNfaAdjacencyRange *range =
	&closure->adjacency->ranges[source_slot];
    for (size_t i = 0; i < range->count; i++) {
	size_t edge_index = closure->adjacency->edge_indices[range->offset + i];
	const OnibiNfaEdge *edge = &closure->nfa->edges.entries[edge_index];
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
	size_t visit_base = closure->visiting_action_bases[edge->to];
	if (visit_base != SIZE_MAX) {
	    /* Nullable-repeat normalization puts a progress action inside each
	     * valid all-epsilon cycle.  Skip that normalized cycle and keep its
	     * later ordered exits. */
	    int valid_cycle =
		onibi_nfa_cycle_has_progress(&combined, visit_base);
	    onibi_g_action_vector_free(&combined);
	    if (!valid_cycle)
		rb_raise(eRegexpError, "NFA structure is invalid: epsilon "
				       "cycle has no progress action");
	    continue;
	}
	closure->visiting_action_bases[edge->to] = combined.count;
	OnibiNfaClosureCall call = {closure, origin, edge->to, combined};
	(void)rb_ensure(onibi_nfa_closure_call_body, (VALUE)(uintptr_t)&call,
			onibi_nfa_closure_call_ensure, (VALUE)(uintptr_t)&call);
	closure->visiting_action_bases[edge->to] = SIZE_MAX;
    }
}

typedef struct {
    OnibiTaggedNfa *nfa;
    onibi_gir_builder_t *gir;
    OnibiGirEdgeVector *start_edges;
    long *state_map;
    size_t *visiting_action_bases;
    OnibiNfaAdjacency adjacency;
    size_t *adjacency_next;
    OnibiNfaDedup dedup;
} OnibiNfaEliminateOwner;

static VALUE
onibi_nfa_eliminate_ensure(VALUE opaque)
{
    OnibiNfaEliminateOwner *owner = (OnibiNfaEliminateOwner *)(uintptr_t)opaque;
    onibi_owned_free(owner->gir->allocation_owner, owner->state_map);
    onibi_owned_free(owner->gir->allocation_owner,
		     owner->visiting_action_bases);
    onibi_owned_free(owner->gir->allocation_owner, owner->adjacency.ranges);
    onibi_owned_free(owner->gir->allocation_owner,
		     owner->adjacency.edge_indices);
    onibi_owned_free(owner->gir->allocation_owner, owner->adjacency_next);
    onibi_owned_free(owner->gir->allocation_owner, owner->dedup.slots);
    owner->state_map = NULL;
    owner->visiting_action_bases = NULL;
    owner->adjacency.ranges = NULL;
    owner->adjacency.edge_indices = NULL;
    owner->adjacency_next = NULL;
    owner->dedup.slots = NULL;
    return Qnil;
}

static void
onibi_nfa_validate_state(const OnibiTaggedNfa *nfa, size_t index)
{
    const OnibiNfaState *state = &nfa->states.entries[index];
    if (state->id != (long)index)
	rb_raise(eRegexpError,
		 "NFA structure is invalid: state IDs are not sequential");
    if (state->kind != ONIBI_NFA_STATE_EPSILON &&
	state->kind != ONIBI_NFA_STATE_CONSUMING &&
	state->kind != ONIBI_NFA_STATE_ACCEPT)
	rb_raise(eRegexpError,
		 "NFA structure is invalid: state kind is unknown");
}

static void
onibi_nfa_validate_edge(const OnibiTaggedNfa *nfa, const OnibiNfaEdge *edge)
{
    size_t state_count = nfa->states.count;
    if (edge->from < -1 ||
	(edge->from >= 0 && (size_t)edge->from >= state_count))
	rb_raise(eRegexpError,
		 "NFA structure is invalid: edge source is out of range");
    if (edge->to < 0 || (size_t)edge->to >= state_count)
	rb_raise(eRegexpError,
		 "NFA structure is invalid: edge destination is out of range");
    if (edge->from >= 0 &&
	nfa->states.entries[edge->from].kind == ONIBI_NFA_STATE_ACCEPT)
	rb_raise(eRegexpError,
		 "NFA structure is invalid: accept state has an outgoing edge");
    const OnibiNfaState *destination = &nfa->states.entries[edge->to];
    if (edge->kind == ONIBI_NFA_EPSILON) {
	if (destination->kind != ONIBI_NFA_STATE_EPSILON &&
	    destination->kind != ONIBI_NFA_STATE_ACCEPT)
	    rb_raise(eRegexpError, "NFA structure is invalid: epsilon edge has "
				   "a consuming destination");
	return;
    }
    if (edge->kind != ONIBI_NFA_CONSUME)
	rb_raise(eRegexpError,
		 "NFA structure is invalid: transition kind is unknown");
    if (edge->from < 0 ||
	nfa->states.entries[edge->from].kind != ONIBI_NFA_STATE_EPSILON)
	rb_raise(
	    eRegexpError,
	    "NFA structure is invalid: consume edge has a non-epsilon source");
    if (destination->kind != ONIBI_NFA_STATE_CONSUMING)
	rb_raise(eRegexpError, "NFA structure is invalid: consume edge has a "
			       "non-consuming destination");
}

static void
onibi_nfa_build_adjacency(OnibiNfaEliminateOwner *owner)
{
    OnibiTaggedNfa *nfa = owner->nfa;
    size_t state_count = nfa->states.count;
    if (state_count == SIZE_MAX ||
	state_count + 1 > SIZE_MAX / sizeof(*owner->adjacency.ranges) ||
	nfa->edges.count > SIZE_MAX / sizeof(*owner->adjacency.edge_indices))
	rb_raise(rb_eNoMemError, "NFA adjacency index is too large");
    for (size_t i = 0; i < state_count; i++)
	onibi_nfa_validate_state(nfa, i);
    if (nfa->accept < 0 || (size_t)nfa->accept >= state_count ||
	nfa->states.entries[nfa->accept].kind != ONIBI_NFA_STATE_ACCEPT)
	rb_raise(eRegexpError,
		 "NFA structure is invalid: root accept state is invalid");

    size_t range_count = state_count + 1;
    owner->adjacency.ranges =
	onibi_owned_realloc(owner->gir->allocation_owner, NULL,
			    range_count * sizeof(*owner->adjacency.ranges));
    owner->adjacency_next =
	onibi_owned_realloc(owner->gir->allocation_owner, NULL,
			    range_count * sizeof(*owner->adjacency_next));
    owner->adjacency.edge_indices =
	nfa->edges.count
	    ? onibi_owned_realloc(owner->gir->allocation_owner, NULL,
				  nfa->edges.count *
				      sizeof(*owner->adjacency.edge_indices))
	    : NULL;
    memset(owner->adjacency.ranges, 0,
	   range_count * sizeof(*owner->adjacency.ranges));
    for (size_t i = 0; i < nfa->edges.count; i++) {
	const OnibiNfaEdge *edge = &nfa->edges.entries[i];
	onibi_nfa_validate_edge(nfa, edge);
	owner->adjacency.ranges[edge->from + 1].count++;
    }
    size_t offset = 0;
    for (size_t i = 0; i < range_count; i++) {
	owner->adjacency.ranges[i].offset = offset;
	owner->adjacency_next[i] = offset;
	offset += owner->adjacency.ranges[i].count;
    }
    for (size_t i = 0; i < nfa->edges.count; i++) {
	size_t source = (size_t)(nfa->edges.entries[i].from + 1);
	owner->adjacency.edge_indices[owner->adjacency_next[source]++] = i;
    }
    onibi_owned_free(owner->gir->allocation_owner, owner->adjacency_next);
    owner->adjacency_next = NULL;
}

static VALUE
onibi_epsilon_eliminate_body(VALUE opaque)
{
    OnibiNfaEliminateOwner *owner = (OnibiNfaEliminateOwner *)(uintptr_t)opaque;
    OnibiTaggedNfa *nfa = owner->nfa;
    onibi_gir_builder_t *gir = owner->gir;
    if (nfa->states.count > LONG_MAX)
	rb_raise(rb_eNoMemError, "NFA state map is too large");
    long state_count = (long)nfa->states.count;
    onibi_nfa_build_adjacency(owner);
    size_t map_bytes = (size_t)state_count * sizeof(*owner->state_map);
    owner->state_map = state_count ? onibi_owned_realloc(gir->allocation_owner,
							 NULL, map_bytes)
				   : NULL;
    owner->visiting_action_bases =
	state_count
	    ? onibi_owned_realloc(gir->allocation_owner, NULL,
				  (size_t)state_count *
				      sizeof(*owner->visiting_action_bases))
	    : NULL;
    for (long i = 0; i < state_count; i++)
	owner->visiting_action_bases[i] = SIZE_MAX;

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
    OnibiNfaClosure start_closure = {nfa,
				     &owner->adjacency,
				     owner->start_edges,
				     owner->state_map,
				     owner->visiting_action_bases,
				     &owner->dedup,
				     state_count};
    onibi_nfa_dedup_reset(&owner->dedup);
    onibi_nfa_emit_closure(&start_closure, -1, -1, &empty);
    OnibiNfaClosure state_closure = {nfa,
				     &owner->adjacency,
				     &gir->edges,
				     owner->state_map,
				     owner->visiting_action_bases,
				     &owner->dedup,
				     state_count};
    for (long i = 0; i < state_count; i++) {
	if (nfa->states.entries[i].kind != ONIBI_NFA_STATE_CONSUMING) continue;
	onibi_nfa_dedup_reset(&owner->dedup);
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

static VALUE
onibi_nfa_action_program_diagnostics(const OnibiGActionVector *actions)
{
    VALUE program = rb_ary_new_capa((long)actions->count);
    for (size_t i = 0; i < actions->count; i++) {
	const OnibiGAction *action = &actions->entries[i];
	VALUE record = rb_hash_new();
	rb_hash_aset(record, ID2SYM(rb_intern("op")),
		     onibi_nfa_action_name(action->code));
	if (action->has_slot)
	    rb_hash_aset(record, ID2SYM(rb_intern("slot")),
			 UINT2NUM(action->slot));
	if (action->has_assert_kind)
	    rb_hash_aset(record, ID2SYM(rb_intern("assert_kind")),
			 UINT2NUM(action->assert_kind));
	if (action->has_arg32)
	    rb_hash_aset(record, ID2SYM(rb_intern("arg32")),
			 UINT2NUM(action->arg32));
	if (action->has_subprogram)
	    rb_hash_aset(record, ID2SYM(rb_intern("subprogram_id")),
			 UINT2NUM(action->subprogram_id));
	rb_hash_aset(record, ID2SYM(rb_intern("set")),
		     action->set ? Qtrue : Qfalse);
	rb_hash_aset(record, ID2SYM(rb_intern("positive")),
		     action->positive ? Qtrue : Qfalse);
	rb_ary_push(program, record);
    }
    return program;
}

static VALUE
onibi_nfa_gir_edge_diagnostics(const OnibiGirEdgeVector *edges)
{
    VALUE records = rb_ary_new_capa((long)edges->count);
    for (size_t i = 0; i < edges->count; i++) {
	const OnibiGirEdgeEntry *edge = &edges->entries[i];
	VALUE record = rb_hash_new();
	rb_hash_aset(record, ID2SYM(rb_intern("from")), LONG2NUM(edge->from));
	rb_hash_aset(record, ID2SYM(rb_intern("to")), LONG2NUM(edge->to));
	rb_hash_aset(record, ID2SYM(rb_intern("action_program")),
		     onibi_nfa_action_program_diagnostics(&edge->actions));
	rb_ary_push(records, record);
    }
    return records;
}

/* Add the finalized form to the private NFA diagnostic result. */
static void
onibi_nfa_add_elimination_diagnostics(VALUE result,
				      const onibi_gir_builder_t *gir,
				      const OnibiGirEdgeVector *start_edges)
{
    VALUE eliminated = rb_hash_new();
    VALUE states = rb_ary_new_capa((long)gir->states.count);
    for (size_t i = 0; i < gir->states.count; i++) {
	const OnibiGirStateEntry *state = &gir->states.entries[i];
	VALUE record = rb_hash_new();
	rb_hash_aset(record, ID2SYM(rb_intern("id")), LONG2NUM(state->id));
	rb_hash_aset(
	    record, ID2SYM(rb_intern("kind")),
	    ID2SYM(rb_intern(state->opcode == ONIBI_G_ACCEPT ? "accept"
							     : "consume")));
	rb_hash_aset(record, ID2SYM(rb_intern("op")), INT2NUM(state->opcode));
	rb_hash_aset(record, ID2SYM(rb_intern("value")),
		     UINT2NUM(state->value));
	rb_ary_push(states, record);
    }
    rb_hash_aset(eliminated, ID2SYM(rb_intern("states")), states);
    rb_hash_aset(eliminated, ID2SYM(rb_intern("start_edges")),
		 onibi_nfa_gir_edge_diagnostics(start_edges));
    rb_hash_aset(eliminated, ID2SYM(rb_intern("edges")),
		 onibi_nfa_gir_edge_diagnostics(&gir->edges));
    rb_hash_aset(result, ID2SYM(rb_intern("eliminated")), eliminated);
}
