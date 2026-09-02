/* GIR builder, fragment records, and mutable graph construction. */
typedef struct {
    OnibiGActionOp code;
    uint8_t set;
    uint8_t positive;
    uint8_t has_slot;
    uint16_t slot;
    uint8_t has_assert_kind;
    uint16_t assert_kind;
    uint8_t has_arg32;
    uint32_t arg32;
    uint8_t has_subprogram;
    OnibiSubprogramId subprogram_id;
} OnibiGAction;
typedef ONIBI_VECTOR(OnibiGAction) OnibiGActionVector;
typedef struct {
    OnibiIdVector starts;
    OnibiIdVector exits;
    OnibiGActionVector start_actions;
    OnibiGActionVector pending_actions;
    int nullable;
    int lazy;
} onibi_fragment_t;
typedef struct {
    OnibiStateId state;
    OnibiGActionVector actions;
} OnibiGuardEntry;
typedef ONIBI_VECTOR(OnibiGuardEntry) OnibiGuardVector;
typedef struct {
    long id;
    OnibiGStateOp opcode;
    uint32_t payload_index;
    uint32_t value;
    uint8_t flags;
    unsigned char bitmap[32];
    unsigned char literal[4];
    uint8_t literal_length;
} OnibiGirStateEntry;
typedef ONIBI_VECTOR(OnibiGirStateEntry) OnibiGirStateVector;
typedef struct {
    long from;
    long to;
    long action_offset;
    OnibiGActionVector actions;
} OnibiGirEdgeEntry;
typedef ONIBI_VECTOR(OnibiGirEdgeEntry) OnibiGirEdgeVector;
typedef struct {
    unsigned char bitmap[32];
    int negated;
} OnibiRSeqClassPayloadEntry;
typedef ONIBI_VECTOR(OnibiRSeqClassPayloadEntry) OnibiRSeqClassPayloadVector;
typedef struct {
    unsigned char bytes[4];
    uint8_t length;
    int ignorecase;
} OnibiRSeqLiteralPayloadEntry;
typedef ONIBI_VECTOR(OnibiRSeqLiteralPayloadEntry)
    OnibiRSeqLiteralPayloadVector;
typedef struct {
    OnibiStateId entry;
    OnibiStateId accept;
    uint32_t flags;
} OnibiRSeqSubprogramEntry;
typedef ONIBI_VECTOR(OnibiRSeqSubprogramEntry) OnibiRSeqSubprogramVector;
typedef struct OnibiTaggedNfa OnibiTaggedNfa;
typedef struct {
    OnibiGirStateVector states;
    OnibiGirEdgeVector edges;
    long next_id;
    long capture_count;
    long counter_count;
    OnibiGuardVector capture_guards;
    OnibiGuardVector exit_guards;
    OnibiRSeqSubprogramVector subprograms;
    OnibiIdVector progress_slots;
    OnibiAstArena *ast;
    const OnibiResolvedArena *semantics;
    unsigned char *subprogram_status;
    size_t resolved_subprogram_count;
    size_t semantic_subprogram_count;
    int optional_seen;
    onibi_allocation_owner_t *allocation_owner;
    OnibiTaggedNfa *nfa;
} onibi_gir_builder_t;

/* This view is the complete verifier input.  It contains typed GIR only. */
typedef struct {
    const OnibiGirStateVector *states;
    const OnibiGirEdgeVector *edges;
    const OnibiGirEdgeVector *start_edges;
    const OnibiRSeqSubprogramVector *subprograms;
    const OnibiIdVector *progress_slots;
    long next_id;
    long capture_count;
    long counter_count;
    long accept;
    long root_entry;
    size_t semantic_subprogram_count;
    uint32_t options;
} OnibiGIRView;
ONIBI_VECTOR_DEFINE(onibi_id_vector, OnibiIdVector, OnibiStateId, 8,
		    "GIR state vector is too large")

static void
onibi_id_vector_move(OnibiIdVector *destination, OnibiIdVector *source)
{
    onibi_id_vector_free(destination);
    *destination = *source;
    onibi_id_vector_init(source);
}

static void
onibi_id_vector_single(OnibiIdVector *vector, OnibiStateId value,
		       onibi_allocation_owner_t *owner)
{
    onibi_id_vector_init(vector);
    onibi_id_vector_bind(vector, owner);
    onibi_id_vector_push(vector, value);
}

ONIBI_VECTOR_DEFINE(onibi_g_action_vector, OnibiGActionVector, OnibiGAction, 8,
		    "GIR action vector is too large")

static OnibiGActionVector
onibi_g_action_vector_concat(const OnibiGActionVector *first,
			     const OnibiGActionVector *second,
			     onibi_allocation_owner_t *owner)
{
    OnibiGActionVector result;
    onibi_g_action_vector_init(&result);
    onibi_g_action_vector_bind(&result, owner);
    onibi_g_action_vector_append(&result, first);
    onibi_g_action_vector_append(&result, second);
    return result;
}

static OnibiGActionVector
onibi_g_action_vector_copy(const OnibiGActionVector *source,
			   onibi_allocation_owner_t *owner)
{
    OnibiGActionVector result;
    onibi_g_action_vector_init(&result);
    onibi_g_action_vector_bind(&result, owner);
    onibi_g_action_vector_append(&result, source);
    return result;
}

static void
onibi_guard_vector_init(OnibiGuardVector *vector)
{
    ONIBI_VECTOR_INIT(vector->entries, vector->count, vector->capacity);
    vector->allocation_owner = NULL;
}

static void
onibi_guard_vector_bind(OnibiGuardVector *vector,
			onibi_allocation_owner_t *owner)
{
    vector->allocation_owner = owner;
}

static const OnibiGuardEntry *
onibi_guard_vector_find_entry(const OnibiGuardVector *vector,
			      OnibiStateId state)
{
    for (size_t i = 0; i < vector->count; i++)
	if (vector->entries[i].state == state) return &vector->entries[i];
    return NULL;
}

static void
onibi_guard_vector_add(OnibiGuardVector *vector, OnibiStateId state,
		       const OnibiGActionVector *actions)
{
    for (size_t i = 0; i < vector->count; i++) {
	if (vector->entries[i].state == state) {
	    onibi_g_action_vector_append(&vector->entries[i].actions, actions);
	    return;
	}
    }
    OnibiGuardEntry entry = {
	state, onibi_g_action_vector_copy(actions, vector->allocation_owner)};
    ONIBI_OWNED_VECTOR_PUSH(vector, OnibiGuardEntry, entry, 8,
			    "GIR guard vector is too large");
}

static void
onibi_guard_vector_free(OnibiGuardVector *vector)
{
    for (size_t i = 0; i < vector->count; i++)
	onibi_g_action_vector_free(&vector->entries[i].actions);
    ONIBI_OWNED_VECTOR_RELEASE(vector);
}

ONIBI_VECTOR_DEFINE(onibi_gir_state_vector, OnibiGirStateVector,
		    OnibiGirStateEntry, 8, "GIR state vector is too large")

static void
onibi_gir_edge_vector_init(OnibiGirEdgeVector *vector)
{
    ONIBI_VECTOR_INIT(vector->entries, vector->count, vector->capacity);
    vector->allocation_owner = NULL;
}

static void
onibi_gir_edge_vector_bind(OnibiGirEdgeVector *vector,
			   onibi_allocation_owner_t *owner)
{
    vector->allocation_owner = owner;
}

static void
onibi_gir_edge_vector_push(OnibiGirEdgeVector *vector, OnibiGirEdgeEntry entry)
{
    ONIBI_OWNED_VECTOR_PUSH(vector, OnibiGirEdgeEntry, entry, 8,
			    "GIR edge vector is too large");
}

typedef struct {
    OnibiGirEdgeVector *vector;
    size_t state_count;
    size_t *counts;
    size_t *next;
    OnibiGirEdgeEntry *ordered;
} OnibiGirGroupOwner;

static void
onibi_gir_group_owner_cleanup(OnibiGirGroupOwner *owner)
{
    onibi_owned_free(owner->vector->allocation_owner, owner->counts);
    onibi_owned_free(owner->vector->allocation_owner, owner->next);
    onibi_owned_free(owner->vector->allocation_owner, owner->ordered);
    owner->counts = NULL;
    owner->next = NULL;
    owner->ordered = NULL;
}

static VALUE
onibi_gir_group_ensure(VALUE opaque)
{
    onibi_gir_group_owner_cleanup((OnibiGirGroupOwner *)(uintptr_t)opaque);
    return Qnil;
}

static VALUE
onibi_gir_edge_vector_group_by_from_body(VALUE opaque)
{
    OnibiGirGroupOwner *owner = (OnibiGirGroupOwner *)(uintptr_t)opaque;
    OnibiGirEdgeVector *vector = owner->vector;
    size_t state_count = owner->state_count;
    if (vector->count < 2) return Qnil;
    for (size_t i = 0; i < vector->count; i++) {
	if (vector->entries[i].from < 0 ||
	    (size_t)vector->entries[i].from >= state_count)
	    rb_raise(rb_eArgError, "RSeq edge source is out of range");
    }
    if (state_count > SIZE_MAX / sizeof(size_t) ||
	vector->count > SIZE_MAX / sizeof(*vector->entries))
	rb_raise(rb_eNoMemError, "RSeq edge index is too large");
    owner->counts = onibi_owned_realloc(vector->allocation_owner, NULL,
					state_count * sizeof(size_t));
    owner->next = onibi_owned_realloc(vector->allocation_owner, NULL,
				      state_count * sizeof(size_t));
    owner->ordered =
	onibi_owned_realloc(vector->allocation_owner, NULL,
			    vector->count * sizeof(OnibiGirEdgeEntry));
    memset(owner->counts, 0, sizeof(*owner->counts) * state_count);
    for (size_t i = 0; i < vector->count; i++)
	owner->counts[vector->entries[i].from]++;
    size_t offset = 0;
    for (size_t i = 0; i < state_count; i++) {
	owner->next[i] = offset;
	offset += owner->counts[i];
    }
    for (size_t i = 0; i < vector->count; i++) {
	size_t from = (size_t)vector->entries[i].from;
	owner->ordered[owner->next[from]++] = vector->entries[i];
    }
    onibi_owned_free(vector->allocation_owner, vector->entries);
    vector->entries = owner->ordered;
    vector->capacity = vector->count;
    owner->ordered = NULL;
    return Qnil;
}

static void
onibi_gir_edge_vector_group_by_from(OnibiGirEdgeVector *vector,
				    size_t state_count)
{
    if (vector->count < 2) return;
    OnibiGirGroupOwner owner;
    memset(&owner, 0, sizeof(owner));
    owner.vector = vector;
    owner.state_count = state_count;
    (void)rb_ensure(onibi_gir_edge_vector_group_by_from_body,
		    (VALUE)(uintptr_t)&owner, onibi_gir_group_ensure,
		    (VALUE)(uintptr_t)&owner);
}

static void
onibi_gir_edge_vector_free(OnibiGirEdgeVector *vector)
{
    for (size_t i = 0; i < vector->count; i++)
	onibi_g_action_vector_free(&vector->entries[i].actions);
    ONIBI_OWNED_VECTOR_RELEASE(vector);
}

NORETURN(static void onibi_gir_verification_error(const char *message));
static void
onibi_gir_verification_error(const char *message)
{
    rb_raise(eRegexpError, "GIR verification failed: %s", message);
}

static int
onibi_gir_zero_bytes(const unsigned char *bytes, size_t count)
{
    for (size_t i = 0; i < count; i++)
	if (bytes[i] != 0) return 0;
    return 1;
}

static int
onibi_gir_action_equal(const OnibiGAction *left, const OnibiGAction *right)
{
    return left->code == right->code && left->set == right->set &&
	   left->positive == right->positive &&
	   left->has_slot == right->has_slot && left->slot == right->slot &&
	   left->has_assert_kind == right->has_assert_kind &&
	   left->assert_kind == right->assert_kind &&
	   left->has_arg32 == right->has_arg32 && left->arg32 == right->arg32 &&
	   left->has_subprogram == right->has_subprogram &&
	   left->subprogram_id == right->subprogram_id;
}

static int
onibi_gir_action_vectors_equal(const OnibiGActionVector *left,
			       const OnibiGActionVector *right)
{
    if (left->count != right->count) return 0;
    for (size_t i = 0; i < left->count; i++)
	if (!onibi_gir_action_equal(&left->entries[i], &right->entries[i]))
	    return 0;
    return 1;
}

static uint16_t
onibi_assertion_kind_operand(int32_t assertion_kind)
{
    if (assertion_kind < ONIBI_RAP_BEGIN_BUFFER ||
	assertion_kind > ONIBI_RAP_LOOKBEHIND)
	rb_raise(eRegexpError, "assertion kind exceeds the GIR operand limit");
    return (uint16_t)assertion_kind;
}

typedef struct {
    uint64_t hash;
    size_t index;
    uint8_t start;
    uint8_t used;
} OnibiGIREdgeIndexSlot;

typedef struct {
    onibi_allocation_owner_t allocations;
    unsigned char *physical_subprogram_references;
    unsigned char *semantic_subprogram_references;
    unsigned char *progress_slot_states;
    OnibiGIREdgeIndexSlot *edge_index;
    size_t edge_index_capacity;
} OnibiGIRVerifyOwner;

typedef struct {
    const OnibiGIRView *view;
    OnibiGIRVerifyOwner owner;
} OnibiGIRVerifyCall;

static uint64_t
onibi_gir_hash_bytes(uint64_t hash, const void *data, size_t length)
{
    const unsigned char *bytes = data;
    for (size_t i = 0; i < length; i++) {
	hash ^= bytes[i];
	hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static uint64_t
onibi_gir_action_vector_hash(long from, long to,
			     const OnibiGActionVector *actions)
{
    uint64_t hash = UINT64_C(1469598103934665603);
    hash = onibi_gir_hash_bytes(hash, &from, sizeof(from));
    hash = onibi_gir_hash_bytes(hash, &to, sizeof(to));
    hash = onibi_gir_hash_bytes(hash, &actions->count, sizeof(actions->count));
    for (size_t i = 0; i < actions->count; i++) {
	const OnibiGAction *action = &actions->entries[i];
	hash = onibi_gir_hash_bytes(hash, &action->code, sizeof(action->code));
	hash = onibi_gir_hash_bytes(hash, &action->set, sizeof(action->set));
	hash = onibi_gir_hash_bytes(hash, &action->positive,
				    sizeof(action->positive));
	hash = onibi_gir_hash_bytes(hash, &action->has_slot,
				    sizeof(action->has_slot));
	hash = onibi_gir_hash_bytes(hash, &action->slot, sizeof(action->slot));
	hash = onibi_gir_hash_bytes(hash, &action->has_assert_kind,
				    sizeof(action->has_assert_kind));
	hash = onibi_gir_hash_bytes(hash, &action->assert_kind,
				    sizeof(action->assert_kind));
	hash = onibi_gir_hash_bytes(hash, &action->has_arg32,
				    sizeof(action->has_arg32));
	hash =
	    onibi_gir_hash_bytes(hash, &action->arg32, sizeof(action->arg32));
	hash = onibi_gir_hash_bytes(hash, &action->has_subprogram,
				    sizeof(action->has_subprogram));
	hash = onibi_gir_hash_bytes(hash, &action->subprogram_id,
				    sizeof(action->subprogram_id));
    }
    return hash;
}

static void
onibi_gir_verify_edge_index_insert(const OnibiGIRView *view,
				   OnibiGIRVerifyOwner *owner,
				   const OnibiGirEdgeEntry *edge, size_t index,
				   int start)
{
    uint64_t hash =
	onibi_gir_action_vector_hash(edge->from, edge->to, &edge->actions);
    size_t slot = (size_t)hash & (owner->edge_index_capacity - 1);
    while (owner->edge_index[slot].used) {
	const OnibiGIREdgeIndexSlot *prior_slot = &owner->edge_index[slot];
	const OnibiGirEdgeEntry *prior =
	    prior_slot->start ? &view->start_edges->entries[prior_slot->index]
			      : &view->edges->entries[prior_slot->index];
	if (prior_slot->hash == hash && prior->from == edge->from &&
	    prior->to == edge->to &&
	    onibi_gir_action_vectors_equal(&prior->actions, &edge->actions))
	    onibi_gir_verification_error(start ? "start edge is duplicated"
					       : "ordered edge is duplicated");
	slot = (slot + 1) & (owner->edge_index_capacity - 1);
    }
    owner->edge_index[slot] =
	(OnibiGIREdgeIndexSlot){hash, index, start ? 1 : 0, 1};
}

static void
onibi_gir_verify_action(const OnibiGIRView *view, OnibiGIRVerifyOwner *owner,
			const OnibiGAction *action, int start_action,
			long edge_from, long edge_to)
{
    if ((unsigned int)action->code > ONIBI_GA_PROGRESS ||
	action->code == ONIBI_GA_END)
	onibi_gir_verification_error("action opcode is invalid");
    if (action->set > 1 || action->positive > 1 || action->has_slot > 1 ||
	action->has_assert_kind > 1 || action->has_arg32 > 1 ||
	action->has_subprogram > 1)
	onibi_gir_verification_error("action payload flag is invalid");
    if ((!action->has_slot && action->slot != 0) ||
	(!action->has_assert_kind && action->assert_kind != 0) ||
	(!action->has_arg32 && action->arg32 != 0) ||
	(!action->has_subprogram && action->subprogram_id != 0))
	onibi_gir_verification_error("action payload is not canonical");

    switch (action->code) {
    case ONIBI_GA_CAPTURE_OPEN:
    case ONIBI_GA_CAPTURE_CLOSE: {
	uint32_t capture_slots = (uint32_t)view->capture_count * 2U;
	if (!action->has_slot || action->has_assert_kind || action->has_arg32 ||
	    action->has_subprogram || action->positive)
	    onibi_gir_verification_error(
		action->code == ONIBI_GA_CAPTURE_CLOSE
		    ? "capture-close payload is invalid"
		    : "capture-open payload is invalid");
	if (action->set != 0)
	    onibi_gir_verification_error(
		action->code == ONIBI_GA_CAPTURE_CLOSE
		    ? "capture-close payload is invalid"
		    : "capture-open payload is invalid");
	if (action->slot >= capture_slots ||
	    ((action->slot & 1U) !=
	     (action->code == ONIBI_GA_CAPTURE_CLOSE ? 1U : 0U)))
	    onibi_gir_verification_error("capture slot is invalid");
	break;
    }
    case ONIBI_GA_MATCH_RESET:
	if (action->set || action->positive || action->has_slot ||
	    action->has_assert_kind || action->has_arg32 ||
	    action->has_subprogram)
	    onibi_gir_verification_error("match-reset payload is invalid");
	break;
    case ONIBI_GA_ASSERT_POSITION: {
	int lookaround = action->assert_kind == ONIBI_RAP_LOOKAHEAD ||
			 action->assert_kind == ONIBI_RAP_LOOKBEHIND;
	if (action->set || action->has_slot || !action->has_assert_kind ||
	    action->assert_kind < ONIBI_RAP_BEGIN_BUFFER ||
	    action->assert_kind > ONIBI_RAP_LOOKBEHIND)
	    onibi_gir_verification_error("assertion payload is invalid");
	if (lookaround) {
	    if (!action->has_arg32 || !action->has_subprogram ||
		action->subprogram_id < view->subprograms->count ||
		action->subprogram_id >= view->semantic_subprogram_count)
		onibi_gir_verification_error(
		    "lookaround subprogram is invalid");
	    owner->semantic_subprogram_references[action->subprogram_id] = 1;
	}
	else if (action->positive || action->has_arg32 ||
		 action->has_subprogram) {
	    onibi_gir_verification_error("assertion payload is invalid");
	}
	break;
    }
    case ONIBI_GA_TEST_CAPTURE:
	if (!action->has_slot ||
	    action->slot >= (uint32_t)view->capture_count || action->positive ||
	    action->has_assert_kind || action->has_arg32 ||
	    action->has_subprogram)
	    onibi_gir_verification_error(
		"semantic capture reference is invalid");
	break;
    case ONIBI_GA_COUNTER_INIT:
    case ONIBI_GA_TEST_COUNTER_LT:
    case ONIBI_GA_TEST_COUNTER_GE:
	if (action->set || action->positive || !action->has_slot ||
	    action->slot >= (uint32_t)view->counter_count ||
	    action->has_assert_kind || !action->has_arg32 ||
	    action->has_subprogram ||
	    owner->progress_slot_states[action->slot] != 0)
	    onibi_gir_verification_error("counter slot is invalid");
	break;
    case ONIBI_GA_COUNTER_INCREMENT:
	if (action->set || action->positive || !action->has_slot ||
	    action->slot >= (uint32_t)view->counter_count ||
	    action->has_assert_kind || action->has_arg32 ||
	    action->has_subprogram ||
	    owner->progress_slot_states[action->slot] != 0)
	    onibi_gir_verification_error("counter slot is invalid");
	break;
    case ONIBI_GA_PROGRESS:
	if (action->set || action->positive || !action->has_slot ||
	    action->slot >= (uint32_t)view->counter_count ||
	    action->has_assert_kind || action->has_arg32 ||
	    action->has_subprogram ||
	    owner->progress_slot_states[action->slot] == 0 || start_action ||
	    edge_to > edge_from)
	    onibi_gir_verification_error("repeat progress is invalid");
	owner->progress_slot_states[action->slot] = 2;
	break;
    default: onibi_gir_verification_error("action opcode is invalid");
    }
}

static void
onibi_gir_verify_action_vector(const OnibiGIRView *view,
			       OnibiGIRVerifyOwner *owner,
			       const OnibiGActionVector *actions,
			       int start_action, long edge_from, long edge_to)
{
    if (actions->count > actions->capacity ||
	(actions->count != 0 && actions->entries == NULL))
	onibi_gir_verification_error("action vector is invalid");
    for (size_t i = 0; i < actions->count; i++)
	onibi_gir_verify_action(view, owner, &actions->entries[i], start_action,
				edge_from, edge_to);
}

static void
onibi_gir_verify_owner_initialize(const OnibiGIRView *view,
				  OnibiGIRVerifyOwner *owner)
{
    size_t physical_count = view->subprograms->count;
    size_t semantic_count = view->semantic_subprogram_count;
    size_t counter_count = (size_t)view->counter_count;
    if (physical_count != 0) {
	owner->physical_subprogram_references =
	    onibi_owned_realloc(&owner->allocations, NULL, physical_count);
	memset(owner->physical_subprogram_references, 0, physical_count);
    }
    if (semantic_count != 0) {
	owner->semantic_subprogram_references =
	    onibi_owned_realloc(&owner->allocations, NULL, semantic_count);
	memset(owner->semantic_subprogram_references, 0, semantic_count);
    }
    if (counter_count != 0) {
	owner->progress_slot_states =
	    onibi_owned_realloc(&owner->allocations, NULL, counter_count);
	memset(owner->progress_slot_states, 0, counter_count);
    }
    size_t edge_count;
    if (view->edges->count > SIZE_MAX - view->start_edges->count)
	onibi_gir_verification_error("verification index is too large");
    edge_count = view->edges->count + view->start_edges->count;
    if (edge_count > SIZE_MAX / 2)
	onibi_gir_verification_error("verification index is too large");
    size_t capacity = 1;
    while (capacity < edge_count * 2) {
	if (capacity > SIZE_MAX / 2)
	    onibi_gir_verification_error("verification index is too large");
	capacity *= 2;
    }
    if (capacity > SIZE_MAX / sizeof(*owner->edge_index))
	onibi_gir_verification_error("verification index is too large");
    owner->edge_index = onibi_owned_realloc(
	&owner->allocations, NULL, capacity * sizeof(*owner->edge_index));
    memset(owner->edge_index, 0, capacity * sizeof(*owner->edge_index));
    owner->edge_index_capacity = capacity;
}

static VALUE
onibi_gir_verify_body(VALUE opaque)
{
    OnibiGIRVerifyCall *call = (OnibiGIRVerifyCall *)(uintptr_t)opaque;
    const OnibiGIRView *view = call->view;
    OnibiGIRVerifyOwner *owner = &call->owner;
    const uint32_t option_mask = ONIBI_OPT_IGNORECASE | ONIBI_OPT_EXTENDED |
				 ONIBI_OPT_MULTILINE | ONIBI_OPT_FIXEDENCODING |
				 ONIBI_OPT_NOENCODING;
    if (!view || !view->states || !view->edges || !view->start_edges ||
	!view->subprograms || !view->progress_slots)
	onibi_gir_verification_error("typed GIR input is incomplete");
    if (view->subprograms->count == 0 ||
	view->subprograms->count > view->subprograms->capacity ||
	view->subprograms->entries == NULL ||
	view->semantic_subprogram_count < view->subprograms->count ||
	view->semantic_subprogram_count > UINT32_MAX)
	onibi_gir_verification_error("subprogram table is invalid");
    if (view->progress_slots->count > view->progress_slots->capacity ||
	(view->progress_slots->count != 0 &&
	 view->progress_slots->entries == NULL))
	onibi_gir_verification_error("repeat progress table is invalid");
    if (view->edges->count > view->edges->capacity ||
	(view->edges->count != 0 && view->edges->entries == NULL))
	onibi_gir_verification_error("ordered edge vector is invalid");
    if (view->start_edges->count == 0 ||
	view->start_edges->count > view->start_edges->capacity ||
	view->start_edges->entries == NULL)
	onibi_gir_verification_error("start edges are invalid");
    if (view->capture_count < 0 ||
	(uint64_t)view->capture_count > ONIBI_GIR_MAX_CAPTURE_COUNT)
	onibi_gir_verification_error("capture count exceeds the operand limit");
    if (view->counter_count < 0 ||
	(uint64_t)view->counter_count > ONIBI_GIR_MAX_COUNTER_COUNT)
	onibi_gir_verification_error("counter count exceeds the operand limit");
    if ((view->options & ~option_mask) != 0)
	onibi_gir_verification_error("option environment is unresolved");
    if (view->states->count == 0 || view->states->count > UINT32_MAX ||
	view->states->count > view->states->capacity ||
	view->states->entries == NULL || view->next_id < 0 ||
	(size_t)view->next_id != view->states->count)
	onibi_gir_verification_error("state IDs are not contiguous");

    onibi_gir_verify_owner_initialize(view, owner);
    for (size_t i = 0; i < view->progress_slots->count; i++) {
	uint32_t slot = view->progress_slots->entries[i];
	if (slot >= (uint32_t)view->counter_count)
	    onibi_gir_verification_error("repeat progress is invalid");
	if (owner->progress_slot_states[slot] != 0)
	    onibi_gir_verification_error("repeat progress slot is duplicated");
	owner->progress_slot_states[slot] = 1;
    }

    for (size_t i = 0; i < view->states->count; i++) {
	const OnibiGirStateEntry *state = &view->states->entries[i];
	if (state->id != (long)i)
	    onibi_gir_verification_error("state IDs are not contiguous");
	if ((unsigned int)state->opcode > ONIBI_G_ABSENT ||
	    state->payload_index != 0)
	    onibi_gir_verification_error("state opcode payload is invalid");
	uint8_t allowed_flags = 0;
	if (state->opcode == ONIBI_G_CHAR || state->opcode == ONIBI_G_BACKREF)
	    allowed_flags = ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE;
	else if (state->opcode == ONIBI_G_CLASS || state->opcode == ONIBI_G_ANY)
	    allowed_flags = ONIBI_RSEQ_STATE_FLAG_NEGATED;
	if ((state->flags & ~allowed_flags) != 0)
	    onibi_gir_verification_error("option environment is unresolved");
	if (state->opcode == ONIBI_G_CHAR) {
	    if (state->literal_length == 0 ||
		state->literal_length > sizeof(state->literal) ||
		state->value != state->literal[0] ||
		!onibi_gir_zero_bytes(state->bitmap, sizeof(state->bitmap)))
		onibi_gir_verification_error("state opcode payload is invalid");
	}
	else if (state->opcode == ONIBI_G_CLASS) {
	    if (state->value != 0 || state->literal_length != 0 ||
		!onibi_gir_zero_bytes(state->literal, sizeof(state->literal)))
		onibi_gir_verification_error("state opcode payload is invalid");
	}
	else {
	    if (state->literal_length != 0 ||
		!onibi_gir_zero_bytes(state->literal, sizeof(state->literal)) ||
		!onibi_gir_zero_bytes(state->bitmap, sizeof(state->bitmap)))
		onibi_gir_verification_error("state opcode payload is invalid");
	    if ((state->opcode == ONIBI_G_ACCEPT ||
		 state->opcode == ONIBI_G_ANY ||
		 state->opcode == ONIBI_G_GRAPHEME) &&
		state->value != 0)
		onibi_gir_verification_error("state opcode payload is invalid");
	}
	if (state->opcode == ONIBI_G_BACKREF &&
	    state->value >= (uint32_t)view->capture_count)
	    onibi_gir_verification_error(
		"semantic capture reference is invalid");
	if (state->opcode == ONIBI_G_CALL || state->opcode == ONIBI_G_ATOMIC ||
	    state->opcode == ONIBI_G_ABSENT) {
	    if (state->value == 0 || state->value >= view->subprograms->count)
		onibi_gir_verification_error("subprogram reference is invalid");
	    uint32_t required_flags =
		state->opcode == ONIBI_G_ATOMIC	  ? ONIBI_SUBPROGRAM_ATOMIC
		: state->opcode == ONIBI_G_ABSENT ? ONIBI_SUBPROGRAM_ABSENT
						  : 0;
	    if (view->subprograms->entries[state->value].flags !=
		required_flags)
		onibi_gir_verification_error(
		    state->opcode == ONIBI_G_ATOMIC
			? "atomic subprogram is invalid"
		    : state->opcode == ONIBI_G_ABSENT
			? "absence subprogram is invalid"
			: "subprogram reference is invalid");
	    owner->physical_subprogram_references[state->value] = 1;
	}
    }

    long last_source = -1;
    for (size_t i = 0; i < view->edges->count; i++) {
	const OnibiGirEdgeEntry *edge = &view->edges->entries[i];
	if (edge->from < 0 || edge->to < 0 ||
	    (size_t)edge->from >= view->states->count ||
	    (size_t)edge->to >= view->states->count)
	    onibi_gir_verification_error("edge state is out of range");
	if (edge->from < last_source)
	    onibi_gir_verification_error("ordered edges are not preserved");
	last_source = edge->from;
	if (edge->action_offset != 0)
	    onibi_gir_verification_error("edge payload is not canonical");
	if (view->states->entries[edge->from].opcode == ONIBI_G_ACCEPT)
	    onibi_gir_verification_error("accept state has an outgoing edge");
	onibi_gir_verify_action_vector(view, owner, &edge->actions, 0,
				       edge->from, edge->to);
	onibi_gir_verify_edge_index_insert(view, owner, edge, i, 0);
    }

    int root_started = 0;
    for (size_t i = 0; i < view->start_edges->count; i++) {
	const OnibiGirEdgeEntry *edge = &view->start_edges->entries[i];
	if (edge->from != -1 || edge->to < 0 ||
	    (size_t)edge->to >= view->states->count || edge->action_offset != 0)
	    onibi_gir_verification_error("start edge is invalid");
	if (edge->to == view->root_entry) root_started = 1;
	onibi_gir_verify_action_vector(view, owner, &edge->actions, 1,
				       edge->from, edge->to);
	onibi_gir_verify_edge_index_insert(view, owner, edge, i, 1);
    }
    if (!root_started)
	onibi_gir_verification_error("root entry has no start edge");

    if (view->accept < 0 || view->root_entry < 0 ||
	(size_t)view->accept >= view->states->count ||
	(size_t)view->root_entry >= view->states->count ||
	view->states->entries[view->accept].opcode != ONIBI_G_ACCEPT)
	onibi_gir_verification_error("accept state is invalid");
    for (size_t i = 0; i < view->subprograms->count; i++) {
	const OnibiRSeqSubprogramEntry *subprogram =
	    &view->subprograms->entries[i];
	if (subprogram->entry >= view->states->count ||
	    subprogram->accept >= view->states->count ||
	    view->states->entries[subprogram->accept].opcode !=
		ONIBI_G_ACCEPT ||
	    (subprogram->flags != 0 &&
	     subprogram->flags != ONIBI_SUBPROGRAM_ATOMIC &&
	     subprogram->flags != ONIBI_SUBPROGRAM_ABSENT))
	    onibi_gir_verification_error("subprogram descriptor is invalid");
	if (i == 0 && (subprogram->entry != (OnibiStateId)view->root_entry ||
		       subprogram->accept != (OnibiStateId)view->accept ||
		       subprogram->flags != 0))
	    onibi_gir_verification_error("root subprogram is invalid");
	if (i != 0 && !owner->physical_subprogram_references[i])
	    onibi_gir_verification_error("subprogram reference is missing");
    }
    for (size_t i = view->subprograms->count;
	 i < view->semantic_subprogram_count; i++)
	if (!owner->semantic_subprogram_references[i])
	    onibi_gir_verification_error("lookaround subprogram is missing");

    for (size_t i = 0; i < view->progress_slots->count; i++) {
	uint32_t slot = view->progress_slots->entries[i];
	if (owner->progress_slot_states[slot] != 2)
	    onibi_gir_verification_error("repeat progress is invalid");
    }
    return Qnil;
}

static VALUE
onibi_gir_verify_ensure(VALUE opaque)
{
    OnibiGIRVerifyCall *call = (OnibiGIRVerifyCall *)(uintptr_t)opaque;
    onibi_allocation_owner_cleanup(&call->owner.allocations);
    return Qnil;
}

static void
onibi_gir_verify(const OnibiGIRView *view)
{
    OnibiGIRVerifyCall call;
    memset(&call, 0, sizeof(call));
    call.view = view;
    onibi_allocation_owner_init(&call.owner.allocations, NULL);
    onibi_allocation_owner_set_phase(&call.owner.allocations, 1);
    (void)rb_ensure(onibi_gir_verify_body, (VALUE)(uintptr_t)&call,
		    onibi_gir_verify_ensure, (VALUE)(uintptr_t)&call);
}

static uint8_t
onibi_rseq_physical_action_op(OnibiGActionOp code)
{
    return (
	uint8_t)(code == ONIBI_GA_CAPTURE_OPEN || code == ONIBI_GA_CAPTURE_CLOSE
		     ? ONIBI_RA_CAPTURE
		 : code == ONIBI_GA_MATCH_RESET	      ? ONIBI_RA_MATCH_RESET
		 : code == ONIBI_GA_ASSERT_POSITION   ? ONIBI_RA_ASSERT_POSITION
		 : code == ONIBI_GA_TEST_CAPTURE      ? ONIBI_RA_TEST_CAPTURE
		 : code == ONIBI_GA_COUNTER_INIT      ? ONIBI_RA_COUNTER_SET
		 : code == ONIBI_GA_COUNTER_INCREMENT ? ONIBI_RA_COUNTER_ADD
		 : code == ONIBI_GA_TEST_COUNTER_LT ||
			 code == ONIBI_GA_TEST_COUNTER_GE
		     ? ONIBI_RA_COUNTER_TEST
		 : code == ONIBI_GA_PROGRESS ? ONIBI_RA_PROGRESS
					     : ONIBI_RA_END);
}
static void
onibi_rseq_class_payload_vector_init(OnibiRSeqClassPayloadVector *vector)
{
    ONIBI_VECTOR_INIT(vector->entries, vector->count, vector->capacity);
    vector->allocation_owner = NULL;
}
static void
onibi_rseq_class_payload_vector_bind(OnibiRSeqClassPayloadVector *vector,
				     onibi_allocation_owner_t *owner)
{
    vector->allocation_owner = owner;
}
static void
onibi_rseq_class_payload_vector_push(OnibiRSeqClassPayloadVector *vector,
				     const OnibiGirStateEntry *state)
{
    OnibiRSeqClassPayloadEntry entry;
    memcpy(entry.bitmap, state->bitmap, sizeof(entry.bitmap));
    entry.negated = (state->flags & ONIBI_RSEQ_STATE_FLAG_NEGATED) != 0;
    ONIBI_OWNED_VECTOR_PUSH(vector, OnibiRSeqClassPayloadEntry, entry, 8,
			    "RSeq class payload vector is too large");
}
static void
onibi_rseq_class_payload_vector_free(OnibiRSeqClassPayloadVector *vector)
{
    ONIBI_OWNED_VECTOR_RELEASE(vector);
}
static void
onibi_rseq_literal_payload_vector_init(OnibiRSeqLiteralPayloadVector *vector)
{
    ONIBI_VECTOR_INIT(vector->entries, vector->count, vector->capacity);
    vector->allocation_owner = NULL;
}
static void
onibi_rseq_literal_payload_vector_bind(OnibiRSeqLiteralPayloadVector *vector,
				       onibi_allocation_owner_t *owner)
{
    vector->allocation_owner = owner;
}
static void
onibi_rseq_literal_payload_vector_push(OnibiRSeqLiteralPayloadVector *vector,
				       const OnibiGirStateEntry *state)
{
    OnibiRSeqLiteralPayloadEntry entry;
    memset(&entry, 0, sizeof(entry));
    entry.length = state->literal_length ? state->literal_length : 1;
    memcpy(entry.bytes, state->literal, state->literal_length);
    if (state->literal_length == 0)
	entry.bytes[0] = (unsigned char)state->value;
    entry.ignorecase = (state->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0;
    ONIBI_OWNED_VECTOR_PUSH(vector, OnibiRSeqLiteralPayloadEntry, entry, 8,
			    "RSeq literal payload vector is too large");
}
static void
onibi_rseq_literal_payload_vector_free(OnibiRSeqLiteralPayloadVector *vector)
{
    ONIBI_OWNED_VECTOR_RELEASE(vector);
}
ONIBI_VECTOR_DEFINE(onibi_rseq_subprogram_vector, OnibiRSeqSubprogramVector,
		    OnibiRSeqSubprogramEntry, 4,
		    "RSeq subprogram vector is too large")

static void
onibi_rseq_subprogram_vector_store(OnibiRSeqSubprogramVector *vector,
				   size_t index,
				   OnibiRSeqSubprogramEntry descriptor)
{
    if (index >= vector->count)
	rb_raise(rb_eArgError, "subprogram index is out of range");
    vector->entries[index] = descriptor;
}
typedef struct {
    unsigned char values[3];
    uint8_t count;
} OnibiCaseFoldExpansion;

static unsigned char
onibi_ascii_fold(unsigned char value)
{
    return (value >= 'A' && value <= 'Z') ? (unsigned char)(value + ('a' - 'A'))
					  : value;
}
static int
onibi_ascii_alpha(int c)
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}
static int
onibi_ascii_digit(int c)
{
    return c >= '0' && c <= '9';
}
static int
onibi_ascii_space(int c)
{
    return c == ' ' || (c >= '\t' && c <= '\r');
}
static int
onibi_ascii_xdigit(int c)
{
    return onibi_ascii_digit(c) || (c >= 'A' && c <= 'F') ||
	   (c >= 'a' && c <= 'f');
}
static int
onibi_ascii_alnum(int c)
{
    return onibi_ascii_alpha(c) || onibi_ascii_digit(c);
}

/* Small fold DAG node for ASCII-compatible patterns. */
static OnibiCaseFoldExpansion
onibi_casefold_expand(unsigned char value)
{
    OnibiCaseFoldExpansion expansion = {{value, 0, 0}, 1};
    unsigned char lower = onibi_ascii_fold(value);
    unsigned char upper = (value >= 'a' && value <= 'z')
			      ? (unsigned char)(value - ('a' - 'A'))
			      : value;
    if (lower != value && expansion.count < 3)
	expansion.values[expansion.count++] = lower;
    if (upper != value && upper != lower && expansion.count < 3)
	expansion.values[expansion.count++] = upper;
    return expansion;
}

static void
onibi_bitmap_set(unsigned char *bits, unsigned char value, int fold)
{
    OnibiCaseFoldExpansion expansion = onibi_casefold_expand(value);
    uint8_t count = fold ? expansion.count : 1;
    for (uint8_t i = 0; i < count; i++) {
	unsigned char folded = expansion.values[i];
	bits[folded >> 3] |= (unsigned char)(1U << (folded & 7));
    }
}

static OnibiAsciiProperty
onibi_ascii_property_kind_id(ID property)
{
    static ID ids[15];
    static int ready = 0;
    if (!ready) {
	const char *names[] = {
	    "ASCII",  "ASCII_Hex_Digit", "Digit", "Alpha", "Alnum",
	    "Lower",  "Upper",		 "Space", "Blank", "Word",
	    "XDigit", "Cntrl",		 "Print", "Graph", "Punct"};
	for (size_t i = 0; i < 15; i++)
	    ids[i] = rb_intern(names[i]);
	ready = 1;
    }
    for (int i = 0; i < 15; i++)
	if (property == ids[i]) return (OnibiAsciiProperty)i;
    return ONIBI_ASCII_PROP_UNKNOWN;
}

static int
onibi_ascii_property_hit_kind(OnibiAsciiProperty kind, int c)
{
    int ascii_alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
    int ascii_digit = c >= '0' && c <= '9';
    switch (kind) {
    case ONIBI_ASCII_PROP_ASCII: return c < 128;
    case ONIBI_ASCII_PROP_HEX:
    case ONIBI_ASCII_PROP_XDIGIT:
	return ascii_digit || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f');
    case ONIBI_ASCII_PROP_DIGIT: return ascii_digit;
    case ONIBI_ASCII_PROP_ALPHA: return ascii_alpha;
    case ONIBI_ASCII_PROP_ALNUM: return ascii_alpha || ascii_digit;
    case ONIBI_ASCII_PROP_LOWER: return c >= 'a' && c <= 'z';
    case ONIBI_ASCII_PROP_UPPER: return c >= 'A' && c <= 'Z';
    case ONIBI_ASCII_PROP_SPACE: return c == ' ' || (c >= '\t' && c <= '\r');
    case ONIBI_ASCII_PROP_BLANK: return c == ' ' || c == '\t';
    case ONIBI_ASCII_PROP_WORD: return ascii_alpha || ascii_digit || c == '_';
    case ONIBI_ASCII_PROP_CNTRL: return c < 32 || c == 127;
    case ONIBI_ASCII_PROP_PRINT: return c >= 32 && c < 127;
    case ONIBI_ASCII_PROP_GRAPH: return c > 32 && c < 127;
    case ONIBI_ASCII_PROP_PUNCT:
	return c >= 33 && c <= 126 && !ascii_alpha && !ascii_digit && c != '_';
    default: return -1;
    }
}

static int
onibi_ascii_property_name_p(ID name_id)
{
    return name_id != 0 &&
	   onibi_ascii_property_kind_id(name_id) != ONIBI_ASCII_PROP_UNKNOWN;
}

static unsigned char
onibi_ast_escape_byte(const OnibiAstArena *arena, const OnibiAstNode *node)
{
    if (node->name.present && node->name.length == 1)
	return arena->bytes[node->name.offset];
    return (unsigned char)node->byte;
}

static void
onibi_class_escape_bitmap(const OnibiAstArena *arena, const OnibiAstNode *node,
			  int fold, unsigned char bits[32])
{
    OnibiAsciiProperty property =
	node->name_id == 0 ? ONIBI_ASCII_PROP_UNKNOWN
			   : onibi_ascii_property_kind_id(node->name_id);
    if (property != ONIBI_ASCII_PROP_UNKNOWN) {
	for (int c = 0; c < 256; c++)
	    if (onibi_ascii_property_hit_kind(property, c) > 0)
		onibi_bitmap_set(bits, (unsigned char)c, fold);
	if (node->byte == 'P')
	    for (size_t i = 0; i < 32; i++)
		bits[i] = (unsigned char)~bits[i];
	return;
    }
    unsigned char raw = onibi_ast_escape_byte(arena, node);
    int code = onibi_ascii_fold(raw);
    if (code == 'r' || code == 'p' || code == 'x' || code == 'u')
	rb_raise(eRegexpError, "escape is not supported in RSeq class");
    int upper = raw >= 'A' && raw <= 'Z';
    for (int c = 0; c < 256; c++) {
	int hit =
	    code == 'd'
		? onibi_ascii_digit(c)
		: (code == 's'
		       ? onibi_ascii_space(c)
		       : (code == 'w'
			      ? (onibi_ascii_alnum(c) || c == '_')
			      : (code == 'h' ? onibi_ascii_xdigit(c) : 0)));
	if (upper ? !hit : hit) onibi_bitmap_set(bits, (unsigned char)c, fold);
    }
}

static void
onibi_class_bitmap_ast(const OnibiAstArena *arena, OnibiAstId id, int fold,
		       unsigned char bits[32])
{
    const OnibiAstNode *node = onibi_ast_node_const(arena, id);
    memset(bits, 0, 32);
    if (node->kind == ONIBI_AST_CLASS_INTERSECTION) {
	if (node->child_count < 2)
	    rb_raise(eRegexpError, "class intersection has no operands");
	onibi_class_bitmap_ast(arena, node->children[0], 0, bits);
	for (size_t i = 1; i < node->child_count; i++) {
	    unsigned char operand[32];
	    onibi_class_bitmap_ast(arena, node->children[i], 0, operand);
	    for (size_t byte = 0; byte < 32; byte++)
		bits[byte] &= operand[byte];
	}
	if (fold) {
	    unsigned char original[32];
	    memcpy(original, bits, sizeof(original));
	    for (int c = 0; c < 256; c++)
		if ((original[c >> 3] & (1U << (c & 7))) != 0)
		    onibi_bitmap_set(bits, (unsigned char)c, 1);
	}
	return;
    }
    if (node->kind == ONIBI_AST_ESCAPE)
	onibi_class_escape_bitmap(arena, node, fold, bits);
    for (size_t i = 0; i < node->range_count; i++) {
	const OnibiAstRange *range = &node->ranges[i];
	if (range->first_has_bytes || range->last_has_bytes) continue;
	for (unsigned int c = range->first_byte; c <= range->last_byte; c++) {
	    onibi_bitmap_set(bits, (unsigned char)c, fold);
	    if (c == range->last_byte) break;
	}
    }
    for (size_t i = 0; i < node->child_count; i++) {
	const OnibiAstNode *child =
	    onibi_ast_node_const(arena, node->children[i]);
	if (child->token_kind == ONIBI_TOKEN_LITERAL ||
	    child->kind == ONIBI_AST_LITERAL) {
	    onibi_bitmap_set(bits, (unsigned char)child->byte, fold);
	}
	else if (child->token_kind == ONIBI_TOKEN_ESCAPE ||
		 child->token_kind == ONIBI_TOKEN_META_ESCAPE ||
		 child->kind == ONIBI_AST_ESCAPE) {
	    onibi_class_escape_bitmap(arena, child, fold, bits);
	}
	else if (child->token_kind == ONIBI_TOKEN_POSIX_CLASS) {
	    OnibiPosixKind posix = onibi_posix_kind_id(child->name_id);
	    for (int c = 0; c < 256; c++) {
		int hit = posix == ONIBI_POSIX_ALPHA   ? onibi_ascii_alpha(c)
			  : posix == ONIBI_POSIX_DIGIT ? onibi_ascii_digit(c)
			  : posix == ONIBI_POSIX_ALNUM ? onibi_ascii_alnum(c)
			  : posix == ONIBI_POSIX_SPACE ? onibi_ascii_space(c)
			  : posix == ONIBI_POSIX_BLANK ? (c == ' ' || c == '\t')
			  : posix == ONIBI_POSIX_LOWER ? (c >= 'a' && c <= 'z')
			  : posix == ONIBI_POSIX_UPPER ? (c >= 'A' && c <= 'Z')
			  : posix == ONIBI_POSIX_WORD
			      ? (onibi_ascii_alnum(c) || c == '_')
			  : posix == ONIBI_POSIX_XDIGIT ? onibi_ascii_xdigit(c)
							: 0;
		if (hit) onibi_bitmap_set(bits, (unsigned char)c, fold);
	    }
	}
	else if (child->kind == ONIBI_AST_CHARACTER_CLASS ||
		 child->kind == ONIBI_AST_CLASS_INTERSECTION) {
	    unsigned char nested[32];
	    onibi_class_bitmap_ast(arena, node->children[i], fold, nested);
	    for (size_t byte = 0; byte < 32; byte++)
		bits[byte] |= nested[byte];
	}
    }
    if (node->flags & ONIBI_AST_NODE_NEGATED)
	for (size_t i = 0; i < 32; i++)
	    bits[i] = (unsigned char)~bits[i];
}

static OnibiPosixKind
onibi_posix_kind_id(ID property)
{
    static ID ids[9];
    static int ready = 0;
    if (!ready) {
	const char *names[] = {"alpha", "digit", "alnum", "space", "blank",
			       "lower", "upper", "word",  "xdigit"};
	for (size_t i = 0; i < 9; i++)
	    ids[i] = rb_intern(names[i]);
	ready = 1;
    }
    for (int i = 0; i < 9; i++)
	if (property == ids[i]) return (OnibiPosixKind)(i + 1);
    return ONIBI_POSIX_UNKNOWN;
}

static onibi_fragment_t
onibi_fragment_empty(onibi_gir_builder_t *builder)
{
    onibi_fragment_t fragment;
    onibi_id_vector_init(&fragment.starts);
    onibi_id_vector_bind(&fragment.starts, builder->allocation_owner);
    onibi_id_vector_init(&fragment.exits);
    onibi_id_vector_bind(&fragment.exits, builder->allocation_owner);
    onibi_g_action_vector_init(&fragment.start_actions);
    onibi_g_action_vector_bind(&fragment.start_actions,
			       builder->allocation_owner);
    onibi_g_action_vector_init(&fragment.pending_actions);
    onibi_g_action_vector_bind(&fragment.pending_actions,
			       builder->allocation_owner);
    fragment.nullable = 1;
    fragment.lazy = 0;
    return fragment;
}

static void
onibi_fragment_append_actions(OnibiGActionVector *destination,
			      const OnibiGActionVector *source)
{
    onibi_g_action_vector_append(destination, source);
}

static void
onibi_add_capture_guard_fragment(onibi_gir_builder_t *builder,
				 const OnibiIdVector *starts,
				 const OnibiGActionVector *guard)
{
    for (size_t i = 0; i < starts->count; i++) {
	onibi_guard_vector_add(&builder->capture_guards, starts->entries[i],
			       guard);
    }
}

static void
onibi_add_exit_guard_fragment(onibi_gir_builder_t *builder,
			      const OnibiIdVector *exits,
			      const OnibiGActionVector *actions)
{
    for (size_t i = 0; i < exits->count; i++) {
	onibi_guard_vector_add(&builder->exit_guards, exits->entries[i],
			       actions);
    }
}

static OnibiGAction
onibi_capture_test_action(long slot, int set)
{
    if (slot < 0 || (uint64_t)slot >= ONIBI_GIR_MAX_CAPTURE_COUNT)
	rb_raise(eRegexpError,
		 "capture reference exceeds the GIR operand limit");
    return (OnibiGAction){
	ONIBI_GA_TEST_CAPTURE, set ? 1 : 0, 0, 1, (uint16_t)slot, 0, 0, 0, 0};
}

static uint16_t
onibi_capture_boundary_slot(long capture_id, int close)
{
    if (capture_id < 0 || (uint64_t)capture_id >= ONIBI_GIR_MAX_CAPTURE_COUNT)
	rb_raise(eRegexpError, "capture slot exceeds the GIR operand limit");
    return (uint16_t)((uint32_t)capture_id * 2U + (close ? 1U : 0U));
}

static long
onibi_gir_allocate_counter_slot(onibi_gir_builder_t *builder, int progress)
{
    if (builder->counter_count < 0 ||
	(uint64_t)builder->counter_count >= ONIBI_GIR_MAX_COUNTER_COUNT)
	rb_raise(eRegexpError, "counter count exceeds the GIR operand limit");
    long slot = builder->counter_count++;
    if (progress)
	onibi_id_vector_push(&builder->progress_slots, (OnibiStateId)slot);
    return slot;
}

static OnibiGAction
onibi_counter_action(OnibiGActionOp code, long slot, int has_limit, long limit)
{
    if (slot < 0 || (uint64_t)slot >= ONIBI_GIR_MAX_COUNTER_COUNT)
	rb_raise(eRegexpError, "counter slot exceeds the GIR operand limit");
    if (has_limit && (limit < 0 || (uint64_t)limit > (uint64_t)UINT32_MAX))
	rb_raise(eRegexpError, "counter value exceeds the GIR operand limit");
    uint32_t value =
	code == ONIBI_GA_COUNTER_INIT ? 1U : (has_limit ? (uint32_t)limit : 0U);
    uint8_t has_arg32 = code == ONIBI_GA_COUNTER_INIT || has_limit;
    return (OnibiGAction){code, 0, 0,	      1,    (uint16_t)slot,
			  0,	0, has_arg32, value};
}

static int
onibi_c_ast_has_capture(const OnibiAstArena *arena, OnibiAstId id)
{
    const OnibiAstNode *node = onibi_ast_node_const(arena, id);
    if (node->kind == ONIBI_AST_CAPTURE) return 1;
    if (node->body != ONIBI_AST_NONE &&
	onibi_c_ast_has_capture(arena, node->body))
	return 1;
    if (node->atom != ONIBI_AST_NONE &&
	onibi_c_ast_has_capture(arena, node->atom))
	return 1;
    if (node->yes != ONIBI_AST_NONE &&
	onibi_c_ast_has_capture(arena, node->yes))
	return 1;
    if (node->no != ONIBI_AST_NONE && onibi_c_ast_has_capture(arena, node->no))
	return 1;
    for (size_t i = 0; i < node->child_count; i++)
	if (onibi_c_ast_has_capture(arena, node->children[i])) return 1;
    return 0;
}
