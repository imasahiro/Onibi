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
    unsigned char *data;
    uint16_t data_length;
    uint8_t kind;
    uint8_t flags;
    uint8_t casefolded;
    uint8_t incomplete_casefold;
} OnibiSemanticClass;
typedef ONIBI_VECTOR(OnibiSemanticClass) OnibiSemanticClassVector;
typedef struct {
    uint64_t hash;
    uint32_t index;
    uint8_t used;
} OnibiGIRClassHashSlot;
typedef struct {
    OnibiGIRClassHashSlot *slots;
    size_t count;
    size_t capacity;
} OnibiGIRClassHash;
typedef struct {
    unsigned char bytes[4];
    uint8_t length;
    int ignorecase;
} OnibiRSeqLiteralPayloadEntry;
typedef ONIBI_VECTOR(OnibiRSeqLiteralPayloadEntry)
    OnibiRSeqLiteralPayloadVector;
typedef OnibiSubprogramDesc OnibiRSeqSubprogramEntry;
typedef ONIBI_VECTOR(OnibiRSeqSubprogramEntry) OnibiRSeqSubprogramVector;
typedef ONIBI_VECTOR(OnibiBackrefDesc) OnibiBackrefDescVector;
typedef struct {
    OnibiSubprogramId semantic_id;
    OnibiSubprogramId physical_id;
    uint16_t scope_count;
    uint16_t scopes[256];
    uint8_t compiling;
} OnibiSubprogramVariant;
typedef ONIBI_VECTOR(OnibiSubprogramVariant) OnibiSubprogramVariantVector;
ONIBI_VECTOR_DEFINE(onibi_subprogram_variant_vector,
		    OnibiSubprogramVariantVector, OnibiSubprogramVariant, 4,
		    "subprogram variant vector is too large")
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
    OnibiBackrefDescVector backrefs;
    OnibiIdVector backref_capture_ids;
    OnibiGirEdgeVector subprogram_entries;
    OnibiIdVector lookbehind_widths;
    OnibiSemanticClassVector classes;
    OnibiGIRClassHash class_hash;
    OnibiLoweringWork lowering_work;
    OnibiIdVector progress_slots;
    OnibiAstArena *ast;
    const OnibiResolvedArena *semantics;
    unsigned char *subprogram_status;
    size_t resolved_subprogram_count;
    size_t semantic_subprogram_count;
    int encoding_index;
    int optional_seen;
    int casefold_repeat_depth;
    int ordered_choice_depth;
    uint16_t nullable_scopes[256];
    size_t nullable_scope_count;
    OnibiSubprogramVariantVector subprogram_variants;
    int capture_order_required;
    onibi_allocation_owner_t *allocation_owner;
    OnibiTaggedNfa *nfa;
} onibi_gir_builder_t;

/* This view is the complete verifier input.  It contains typed GIR only. */
typedef struct {
    const OnibiGirStateVector *states;
    const OnibiGirEdgeVector *edges;
    const OnibiGirEdgeVector *start_edges;
    const OnibiGirEdgeVector *subprogram_entries;
    const OnibiRSeqSubprogramVector *subprograms;
    const OnibiBackrefDescVector *backrefs;
    const OnibiIdVector *backref_capture_ids;
    const OnibiIdVector *lookbehind_widths;
    const OnibiSemanticClassVector *classes;
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

ONIBI_VECTOR_DEFINE(onibi_semantic_class_vector, OnibiSemanticClassVector,
		    OnibiSemanticClass, 8,
		    "GIR class descriptor vector is too large")

static uint64_t
onibi_gir_class_hash_bytes(uint64_t hash, const void *data, size_t length)
{
    const unsigned char *bytes = data;
    for (size_t i = 0; i < length; i++) {
	hash ^= bytes[i];
	hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static uint64_t
onibi_gir_class_hash(uint8_t kind, uint8_t flags, int casefolded,
		     int incomplete_casefold, const void *data,
		     size_t data_length)
{
    const unsigned char *bytes = data;
    uint64_t hash = UINT64_C(1469598103934665603);
    hash = onibi_gir_class_hash_bytes(hash, &kind, sizeof(kind));
    hash = onibi_gir_class_hash_bytes(hash, &flags, sizeof(flags));
    uint8_t folded = (uint8_t)casefolded;
    uint8_t incomplete = (uint8_t)incomplete_casefold;
    hash = onibi_gir_class_hash_bytes(hash, &folded, sizeof(folded));
    hash = onibi_gir_class_hash_bytes(hash, &incomplete, sizeof(incomplete));
    hash = onibi_gir_class_hash_bytes(hash, &data_length, sizeof(data_length));
    return onibi_gir_class_hash_bytes(hash, bytes, data_length);
}

static void
onibi_gir_class_hash_grow(onibi_gir_builder_t *builder)
{
    OnibiGIRClassHash *table = &builder->class_hash;
    size_t next_capacity = table->capacity == 0 ? 16 : table->capacity * 2U;
    if (next_capacity < table->capacity ||
	next_capacity > SIZE_MAX / sizeof(*table->slots))
	rb_raise(rb_eNoMemError, "GIR class hash table is too large");
    OnibiGIRClassHashSlot *next = onibi_owned_realloc(
	builder->allocation_owner, NULL, next_capacity * sizeof(*next));
    memset(next, 0, next_capacity * sizeof(*next));
    for (size_t i = 0; i < table->capacity; i++) {
	if (!table->slots[i].used) continue;
	size_t slot = (size_t)table->slots[i].hash & (next_capacity - 1U);
	while (next[slot].used)
	    slot = (slot + 1U) & (next_capacity - 1U);
	next[slot] = table->slots[i];
    }
    onibi_owned_free(builder->allocation_owner, table->slots);
    table->slots = next;
    table->capacity = next_capacity;
}

static uint32_t
onibi_semantic_class_add(onibi_gir_builder_t *builder, uint8_t kind,
			 uint8_t flags, int casefolded, int incomplete_casefold,
			 const void *data, size_t data_length)
{
    if (data_length == 0 || data_length > UINT16_MAX)
	rb_raise(eRegexpError, "class descriptor exceeds the v1 size limit");
    if (builder->classes.count >= UINT32_MAX)
	rb_raise(eRegexpError, "too many GIR class descriptors");
    OnibiGIRClassHash *table = &builder->class_hash;
    if (table->capacity == 0 ||
	(table->count + 1U) * 10U > table->capacity * 7U)
	onibi_gir_class_hash_grow(builder);
    uint64_t hash = onibi_gir_class_hash(
	kind, flags, casefolded, incomplete_casefold, data, data_length);
    size_t slot = (size_t)hash & (table->capacity - 1U);
    while (table->slots[slot].used) {
	builder->lowering_work.gir_class_probes++;
	const OnibiGIRClassHashSlot *prior_slot = &table->slots[slot];
	const OnibiSemanticClass *prior =
	    &builder->classes.entries[prior_slot->index];
	if (prior_slot->hash == hash && prior->kind == kind &&
	    prior->flags == flags && prior->casefolded == casefolded &&
	    prior->incomplete_casefold == incomplete_casefold &&
	    prior->data_length == data_length &&
	    memcmp(prior->data, data, data_length) == 0)
	    return prior_slot->index;
	slot = (slot + 1U) & (table->capacity - 1U);
    }
    unsigned char *copy =
	onibi_owned_realloc(builder->allocation_owner, NULL, data_length);
    memcpy(copy, data, data_length);
    OnibiSemanticClass entry = {
	copy,  (uint16_t)data_length, kind,
	flags, (uint8_t)casefolded,   (uint8_t)incomplete_casefold};
    onibi_semantic_class_vector_push(&builder->classes, entry);
    uint32_t index = (uint32_t)(builder->classes.count - 1U);
    table->slots[slot] = (OnibiGIRClassHashSlot){hash, index, 1};
    table->count++;
    return index;
}

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
    long from;
    long to;
    const OnibiGActionVector *actions;
    size_t next_outgoing;
    size_t next_incoming;
} OnibiGIRNullableEdgeIndex;

typedef struct {
    long to;
    const OnibiGActionVector *actions;
    uint32_t subprogram_id;
    uint8_t subprogram;
    size_t next;
} OnibiGIRNullableEntryIndex;

typedef struct {
    onibi_allocation_owner_t allocations;
    unsigned char *physical_subprogram_references;
    unsigned char *progress_slot_states;
    unsigned char *nullable_owner_bases;
    unsigned char *nullable_reserved_slots;
    uint32_t *nullable_owner_indices;
    uint64_t *nullable_state_in;
    uint64_t *nullable_mask;
    size_t nullable_word_count;
    size_t nullable_state_count;
    size_t nullable_owner_count;
    size_t *nullable_outgoing_heads;
    size_t *nullable_incoming_heads;
    size_t *nullable_entry_heads;
    OnibiGIRNullableEdgeIndex *nullable_edges;
    OnibiGIRNullableEntryIndex *nullable_entries;
    uint64_t *nullable_entry_inputs;
    unsigned char *nullable_entry_initialized;
    size_t nullable_entry_count;
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
onibi_gir_nullable_set(uint64_t *state, uint32_t owner_index)
{
    state[(size_t)owner_index / (sizeof(uint64_t) * CHAR_BIT)] |=
	UINT64_C(1) << (owner_index % (sizeof(uint64_t) * CHAR_BIT));
}

static void
onibi_gir_nullable_clear(uint64_t *state, uint32_t owner_index)
{
    state[(size_t)owner_index / (sizeof(uint64_t) * CHAR_BIT)] &=
	~(UINT64_C(1) << (owner_index % (sizeof(uint64_t) * CHAR_BIT)));
}

static void
onibi_gir_nullable_transfer(const OnibiGIRVerifyOwner *owner,
			    const OnibiGActionVector *actions,
			    const uint64_t *input, uint64_t *output,
			    size_t word_count)
{
    if (output != input) memcpy(output, input, word_count * sizeof(*output));
    for (size_t i = 0; i < actions->count; i++) {
	const OnibiGAction *action = &actions->entries[i];
	if (action->code == ONIBI_GA_NULL_ENTER)
	    onibi_gir_nullable_set(output,
				   owner->nullable_owner_indices[action->slot]);
	else if (action->code == ONIBI_GA_NULL_CONTINUE ||
		 action->code == ONIBI_GA_NULL_STOP)
	    onibi_gir_nullable_clear(
		output, owner->nullable_owner_indices[action->slot]);
    }
}

static void
onibi_gir_nullable_meet(uint64_t *destination, const uint64_t *source,
			size_t word_count)
{
    for (size_t i = 0; i < word_count; i++)
	destination[i] &= source[i];
}

static int
onibi_gir_nullable_bits_equal(const uint64_t *left, const uint64_t *right,
			      size_t word_count)
{
    return memcmp(left, right, word_count * sizeof(*left)) == 0;
}

static void
onibi_gir_nullable_collect_action(const OnibiGIRView *view,
				  OnibiGIRVerifyOwner *owner,
				  const OnibiGAction *action)
{
    if (action->code != ONIBI_GA_NULL_ENTER || !action->has_slot) return;
    if ((uint32_t)action->slot + 1U >= (uint32_t)view->counter_count)
	onibi_gir_verification_error("nullable owner range is invalid");
    uint32_t base = action->slot;
    if (owner->nullable_owner_bases[base]) return;
    if (owner->nullable_reserved_slots[base] ||
	owner->nullable_reserved_slots[base + 1U])
	onibi_gir_verification_error("nullable owner intervals overlap");
    owner->nullable_owner_bases[base] = 1;
    owner->nullable_reserved_slots[base] = 1;
    owner->nullable_reserved_slots[base + 1U] = 1;
    owner->nullable_owner_indices[base] = (uint32_t)owner->nullable_owner_count;
    owner->nullable_owner_count++;
}

static void
onibi_gir_nullable_collect_vector(const OnibiGIRView *view,
				  OnibiGIRVerifyOwner *owner,
				  const OnibiGActionVector *actions)
{
    if (!actions || actions->count > actions->capacity ||
	(actions->count != 0 && actions->entries == NULL))
	onibi_gir_verification_error("action vector is invalid");
    for (size_t i = 0; i < actions->count; i++)
	onibi_gir_nullable_collect_action(view, owner, &actions->entries[i]);
}

static void
onibi_gir_nullable_validate_action(const OnibiGIRVerifyOwner *owner,
				   const OnibiGAction *action, uint64_t *state)
{
    if (action->code == ONIBI_GA_NULL_ENTER) {
	onibi_gir_nullable_set(state,
			       owner->nullable_owner_indices[action->slot]);
	return;
    }
    if (action->code != ONIBI_GA_NULL_CAPTURE &&
	action->code != ONIBI_GA_NULL_CONTINUE &&
	action->code != ONIBI_GA_NULL_STOP) {
	return;
    }
    uint32_t owner_index = owner->nullable_owner_indices[action->slot];
    if (!(state[(size_t)owner_index / (sizeof(uint64_t) * CHAR_BIT)] &
	  (UINT64_C(1) << (owner_index % (sizeof(uint64_t) * CHAR_BIT)))))
	onibi_gir_verification_error("nullable owner is not initialized");
    if (action->code == ONIBI_GA_NULL_CONTINUE ||
	action->code == ONIBI_GA_NULL_STOP)
	onibi_gir_nullable_clear(state,
				 owner->nullable_owner_indices[action->slot]);
}

static void
onibi_gir_nullable_validate_vector(const OnibiGIRVerifyOwner *owner,
				   const OnibiGActionVector *actions,
				   const uint64_t *input, uint64_t *output,
				   size_t word_count)
{
    memcpy(output, input, word_count * sizeof(*output));
    for (size_t i = 0; i < actions->count; i++)
	onibi_gir_nullable_validate_action(owner, &actions->entries[i], output);
}

static void
onibi_gir_nullable_build_index(const OnibiGIRView *view,
			       OnibiGIRVerifyOwner *owner)
{
    size_t state_count = owner->nullable_state_count;
    if (state_count > SIZE_MAX / sizeof(*owner->nullable_outgoing_heads) ||
	view->edges->count > SIZE_MAX / sizeof(*owner->nullable_edges))
	onibi_gir_verification_error(
	    "nullable verification index is too large");
    owner->nullable_outgoing_heads = onibi_owned_realloc(
	&owner->allocations, NULL,
	state_count * sizeof(*owner->nullable_outgoing_heads));
    owner->nullable_incoming_heads = onibi_owned_realloc(
	&owner->allocations, NULL,
	state_count * sizeof(*owner->nullable_incoming_heads));
    owner->nullable_entry_heads =
	onibi_owned_realloc(&owner->allocations, NULL,
			    state_count * sizeof(*owner->nullable_entry_heads));
    for (size_t i = 0; i < state_count; i++) {
	owner->nullable_outgoing_heads[i] = SIZE_MAX;
	owner->nullable_incoming_heads[i] = SIZE_MAX;
	owner->nullable_entry_heads[i] = SIZE_MAX;
    }
    if (view->edges->count != 0) {
	owner->nullable_edges = onibi_owned_realloc(
	    &owner->allocations, NULL,
	    view->edges->count * sizeof(*owner->nullable_edges));
	for (size_t i = 0; i < view->edges->count; i++) {
	    const OnibiGirEdgeEntry *edge = &view->edges->entries[i];
	    owner->nullable_edges[i] = (OnibiGIRNullableEdgeIndex){
		edge->from, edge->to, &edge->actions,
		owner->nullable_outgoing_heads[edge->from],
		owner->nullable_incoming_heads[edge->to]};
	    owner->nullable_outgoing_heads[edge->from] = i;
	    owner->nullable_incoming_heads[edge->to] = i;
	}
    }
    if (view->start_edges->count > SIZE_MAX - view->subprogram_entries->count)
	onibi_gir_verification_error(
	    "nullable verification index is too large");
    owner->nullable_entry_count =
	view->start_edges->count + view->subprogram_entries->count;
    if (owner->nullable_entry_count >
	SIZE_MAX / sizeof(*owner->nullable_entries))
	onibi_gir_verification_error(
	    "nullable verification index is too large");
    if (owner->nullable_entry_count != 0) {
	owner->nullable_entries = onibi_owned_realloc(
	    &owner->allocations, NULL,
	    owner->nullable_entry_count * sizeof(*owner->nullable_entries));
	size_t entry = 0;
	for (size_t i = 0; i < view->start_edges->count; i++, entry++) {
	    const OnibiGirEdgeEntry *edge = &view->start_edges->entries[i];
	    owner->nullable_entries[entry] = (OnibiGIRNullableEntryIndex){
		edge->to, &edge->actions, 0, 0,
		owner->nullable_entry_heads[edge->to]};
	    owner->nullable_entry_heads[edge->to] = entry;
	}
	for (size_t i = 0; i < view->subprogram_entries->count; i++, entry++) {
	    const OnibiGirEdgeEntry *edge =
		&view->subprogram_entries->entries[i];
	    owner->nullable_entries[entry] = (OnibiGIRNullableEntryIndex){
		edge->to, &edge->actions, (uint32_t)edge->from, 1,
		owner->nullable_entry_heads[edge->to]};
	    owner->nullable_entry_heads[edge->to] = entry;
	}
	if (owner->nullable_entry_count >
	    SIZE_MAX / owner->nullable_word_count /
		sizeof(*owner->nullable_entry_inputs))
	    onibi_gir_verification_error(
		"nullable verification index is too large");
	owner->nullable_entry_inputs = onibi_owned_realloc(
	    &owner->allocations, NULL,
	    owner->nullable_entry_count * owner->nullable_word_count *
		sizeof(*owner->nullable_entry_inputs));
	owner->nullable_entry_initialized = onibi_owned_realloc(
	    &owner->allocations, NULL, owner->nullable_entry_count);
	memset(owner->nullable_entry_inputs, 0,
	       owner->nullable_entry_count * owner->nullable_word_count *
		   sizeof(*owner->nullable_entry_inputs));
	memset(owner->nullable_entry_initialized, 0,
	       owner->nullable_entry_count);
	for (size_t i = 0; i < view->start_edges->count; i++)
	    owner->nullable_entry_initialized[i] = 1;
    }
}

static void
onibi_gir_nullable_finalize_owners(OnibiGIRVerifyOwner *owner)
{
    if (owner->nullable_owner_count == 0) return;
    size_t bit_count = sizeof(uint64_t) * CHAR_BIT;
    owner->nullable_word_count =
	(owner->nullable_owner_count + bit_count - 1U) / bit_count;
    owner->nullable_mask = onibi_owned_realloc(
	&owner->allocations, NULL,
	owner->nullable_word_count * sizeof(*owner->nullable_mask));
    for (size_t i = 0; i < owner->nullable_word_count; i++)
	owner->nullable_mask[i] = UINT64_MAX;
}

static int
onibi_gir_nullable_update_state(const OnibiGIRVerifyOwner *owner,
				const unsigned char *reachable, size_t state,
				uint64_t *next, uint64_t *output)
{
    size_t word_count = owner->nullable_word_count;
    int has_incoming = 0;
    memcpy(next, owner->nullable_mask, word_count * sizeof(*next));
    for (size_t entry = owner->nullable_entry_heads[state]; entry != SIZE_MAX;
	 entry = owner->nullable_entries[entry].next) {
	const OnibiGIRNullableEntryIndex *incoming =
	    &owner->nullable_entries[entry];
	if (!owner->nullable_entry_initialized[entry]) continue;
	const uint64_t *input =
	    owner->nullable_entry_inputs + entry * word_count;
	onibi_gir_nullable_transfer(owner, incoming->actions, input, output,
				    word_count);
	if (!has_incoming) {
	    memcpy(next, output, word_count * sizeof(*next));
	    has_incoming = 1;
	}
	else {
	    onibi_gir_nullable_meet(next, output, word_count);
	}
    }
    for (size_t edge = owner->nullable_incoming_heads[state]; edge != SIZE_MAX;
	 edge = owner->nullable_edges[edge].next_incoming) {
	const OnibiGIRNullableEdgeIndex *incoming =
	    &owner->nullable_edges[edge];
	if (!reachable[incoming->from]) continue;
	const uint64_t *input =
	    owner->nullable_state_in + (size_t)incoming->from * word_count;
	onibi_gir_nullable_transfer(owner, incoming->actions, input, output,
				    word_count);
	if (!has_incoming) {
	    memcpy(next, output, word_count * sizeof(*next));
	    has_incoming = 1;
	}
	else {
	    onibi_gir_nullable_meet(next, output, word_count);
	}
    }
    if (!has_incoming) return 0;
    uint64_t *current = owner->nullable_state_in + state * word_count;
    if (onibi_gir_nullable_bits_equal(next, current, word_count)) return 0;
    memcpy(current, next, word_count * sizeof(*next));
    return 1;
}

static void
onibi_gir_nullable_transfer_prefix(const OnibiGIRVerifyOwner *owner,
				   const OnibiGActionVector *actions,
				   size_t length, const uint64_t *input,
				   uint64_t *output)
{
    if (output != input)
	memcpy(output, input, owner->nullable_word_count * sizeof(*output));
    for (size_t i = 0; i < length; i++) {
	const OnibiGAction *action = &actions->entries[i];
	if (action->code == ONIBI_GA_NULL_ENTER)
	    onibi_gir_nullable_set(output,
				   owner->nullable_owner_indices[action->slot]);
	else if (action->code == ONIBI_GA_NULL_CONTINUE ||
		 action->code == ONIBI_GA_NULL_STOP)
	    onibi_gir_nullable_clear(
		output, owner->nullable_owner_indices[action->slot]);
    }
}

static int
onibi_gir_nullable_seed_subprogram(const OnibiGIRView *view,
				   OnibiGIRVerifyOwner *owner,
				   uint32_t subprogram_id,
				   const uint64_t *input)
{
    int changed = 0;
    size_t word_count = owner->nullable_word_count;
    for (size_t i = view->start_edges->count; i < owner->nullable_entry_count;
	 i++) {
	OnibiGIRNullableEntryIndex *entry = &owner->nullable_entries[i];
	if (entry->subprogram_id != subprogram_id) continue;
	uint64_t *destination = owner->nullable_entry_inputs + i * word_count;
	if (!owner->nullable_entry_initialized[i]) {
	    memcpy(destination, input, word_count * sizeof(*destination));
	    owner->nullable_entry_initialized[i] = 1;
	    changed = 1;
	}
	else if (!onibi_gir_nullable_bits_equal(destination, input,
						word_count)) {
	    for (size_t word = 0; word < word_count; word++) {
		uint64_t value = destination[word] & input[word];
		if (value != destination[word]) changed = 1;
		destination[word] = value;
	    }
	}
    }
    return changed;
}

static int
onibi_gir_nullable_seed_assertion(const OnibiGIRView *view,
				  OnibiGIRVerifyOwner *owner,
				  const OnibiGActionVector *actions,
				  const uint64_t *input)
{
    int changed = 0;
    for (size_t i = 0; i < actions->count; i++) {
	const OnibiGAction *action = &actions->entries[i];
	if (action->code != ONIBI_GA_ASSERT_POSITION ||
	    !action->has_subprogram ||
	    (action->assert_kind != ONIBI_RAP_LOOKAHEAD &&
	     action->assert_kind != ONIBI_RAP_LOOKBEHIND))
	    continue;
	uint64_t *prefix =
	    onibi_owned_realloc(&owner->allocations, NULL,
				owner->nullable_word_count * sizeof(*prefix));
	onibi_gir_nullable_transfer_prefix(owner, actions, i, input, prefix);
	if (onibi_gir_nullable_seed_subprogram(view, owner,
					       action->subprogram_id, prefix))
	    changed = 1;
	onibi_owned_free(&owner->allocations, prefix);
    }
    return changed;
}

static int
onibi_gir_nullable_seed_entry_assertions(const OnibiGIRView *view,
					 OnibiGIRVerifyOwner *owner)
{
    int changed = 0;
    for (size_t i = 0; i < owner->nullable_entry_count; i++) {
	if (!owner->nullable_entry_initialized[i]) continue;
	const uint64_t *input =
	    owner->nullable_entry_inputs + i * owner->nullable_word_count;
	if (onibi_gir_nullable_seed_assertion(
		view, owner, owner->nullable_entries[i].actions, input))
	    changed = 1;
    }
    return changed;
}

static void
onibi_gir_nullable_enqueue_state(OnibiGIRVerifyOwner *owner,
				 unsigned char *reachable,
				 unsigned char *queued, size_t *worklist,
				 size_t *queue_tail, size_t *queue_count,
				 size_t state, const char *overflow_message)
{
    if (reachable[state]) {
	if (queued[state]) return;
    }
    else {
	reachable[state] = 1;
    }
    if (*queue_count == owner->nullable_state_count)
	onibi_gir_verification_error(overflow_message);
    worklist[(*queue_tail)++] = state;
    if (*queue_tail == owner->nullable_state_count) *queue_tail = 0;
    queued[state] = 1;
    (*queue_count)++;
}

static void
onibi_gir_nullable_enqueue_entries(const OnibiGIRVerifyOwner *owner,
				   unsigned char *reachable,
				   unsigned char *queued, size_t *worklist,
				   size_t *queue_tail, size_t *queue_count,
				   const char *overflow_message)
{
    for (size_t i = 0; i < owner->nullable_entry_count; i++) {
	const OnibiGIRNullableEntryIndex *entry = &owner->nullable_entries[i];
	if (!owner->nullable_entry_initialized[i]) continue;
	onibi_gir_nullable_enqueue_state(
	    (OnibiGIRVerifyOwner *)owner, reachable, queued, worklist,
	    queue_tail, queue_count, (size_t)entry->to, overflow_message);
    }
}

static void
onibi_gir_nullable_validate_all_paths(const OnibiGIRView *view,
				      OnibiGIRVerifyOwner *owner)
{
    if (owner->nullable_owner_count == 0) return;
    size_t word_count = owner->nullable_word_count;
    size_t state_count = owner->nullable_state_count;
    if (state_count > SIZE_MAX / word_count / sizeof(*owner->nullable_state_in))
	onibi_gir_verification_error(
	    "nullable verification index is too large");
    if (state_count > SIZE_MAX / sizeof(size_t))
	onibi_gir_verification_error(
	    "nullable verification index is too large");
    onibi_gir_nullable_build_index(view, owner);
    owner->nullable_state_in = onibi_owned_realloc(
	&owner->allocations, NULL,
	state_count * word_count * sizeof(*owner->nullable_state_in));
    uint64_t *next = onibi_owned_realloc(&owner->allocations, NULL,
					 word_count * sizeof(*next));
    uint64_t *output = onibi_owned_realloc(&owner->allocations, NULL,
					   word_count * sizeof(*output));
    unsigned char *reachable =
	onibi_owned_realloc(&owner->allocations, NULL, state_count);
    unsigned char *queued =
	onibi_owned_realloc(&owner->allocations, NULL, state_count);
    unsigned char *expanded =
	onibi_owned_realloc(&owner->allocations, NULL, state_count);
    size_t *worklist = onibi_owned_realloc(&owner->allocations, NULL,
					   state_count * sizeof(*worklist));
    for (size_t state = 0; state < state_count; state++)
	memcpy(owner->nullable_state_in + state * word_count,
	       owner->nullable_mask,
	       word_count * sizeof(*owner->nullable_mask));
    memset(reachable, 0, state_count);
    memset(queued, 0, state_count);
    memset(expanded, 0, state_count);
    size_t queue_head = 0, queue_tail = 0, queue_count = 0;
    const char *reachability_overflow =
	"nullable reachability queue is too large";
    const char *worklist_overflow = "nullable worklist is too large";

    /* Root entries are the only entries reachable before a call site runs. */
    for (size_t i = 0; i < view->start_edges->count; i++) {
	const OnibiGirEdgeEntry *entry = &view->start_edges->entries[i];
	onibi_gir_nullable_seed_assertion(view, owner, &entry->actions,
					  owner->nullable_entry_inputs +
					      i * word_count);
    }
    while (onibi_gir_nullable_seed_entry_assertions(view, owner))
	;
    onibi_gir_nullable_enqueue_entries(owner, reachable, queued, worklist,
				       &queue_tail, &queue_count,
				       reachability_overflow);
    while (queue_count != 0) {
	size_t state = worklist[queue_head++];
	queue_count--;
	queued[state] = 0;
	if (queue_head == state_count) queue_head = 0;
	int state_changed = onibi_gir_nullable_update_state(
	    owner, reachable, state, next, output);
	int first_visit = !expanded[state];
	expanded[state] = 1;
	const uint64_t *input = owner->nullable_state_in + state * word_count;
	const OnibiGirStateEntry *state_entry = &view->states->entries[state];
	int seed_changed = 0;
	if ((state_changed || first_visit) &&
	    (state_entry->opcode == ONIBI_G_CALL ||
	     state_entry->opcode == ONIBI_G_ATOMIC ||
	     state_entry->opcode == ONIBI_G_ABSENT))
	    seed_changed |= onibi_gir_nullable_seed_subprogram(
		view, owner, (uint32_t)state_entry->value, input);

	for (size_t edge = owner->nullable_outgoing_heads[state];
	     edge != SIZE_MAX;
	     edge = owner->nullable_edges[edge].next_outgoing) {
	    const OnibiGIRNullableEdgeIndex *indexed =
		&owner->nullable_edges[edge];
	    if (state_changed || first_visit) {
		seed_changed |= onibi_gir_nullable_seed_assertion(
		    view, owner, indexed->actions, input);
	    }
	    if (state_changed || first_visit) {
		onibi_gir_nullable_enqueue_state(
		    owner, reachable, queued, worklist, &queue_tail,
		    &queue_count, (size_t)indexed->to, worklist_overflow);
	    }
	}
	if (seed_changed) {
	    while (onibi_gir_nullable_seed_entry_assertions(view, owner))
		;
	    onibi_gir_nullable_enqueue_entries(owner, reachable, queued,
					       worklist, &queue_tail,
					       &queue_count, worklist_overflow);
	}
    }

    for (size_t i = 0; i < owner->nullable_entry_count; i++) {
	const OnibiGIRNullableEntryIndex *entry = &owner->nullable_entries[i];
	if (!owner->nullable_entry_initialized[i]) continue;
	const uint64_t *input = owner->nullable_entry_inputs + i * word_count;
	onibi_gir_nullable_validate_vector(owner, entry->actions, input, next,
					   word_count);
    }
    for (size_t i = 0; i < view->edges->count; i++) {
	const OnibiGirEdgeEntry *edge = &view->edges->entries[i];
	if (!reachable[edge->from]) continue;
	const uint64_t *input =
	    owner->nullable_state_in + (size_t)edge->from * word_count;
	onibi_gir_nullable_validate_vector(owner, &edge->actions, input, next,
					   word_count);
    }
}

static void
onibi_gir_verify_action(const OnibiGIRView *view, OnibiGIRVerifyOwner *owner,
			const OnibiGAction *action, int start_action,
			long edge_from, long edge_to)
{
    if ((unsigned int)action->code > ONIBI_GA_ORDER ||
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
    case ONIBI_GA_CAPTURE_CLOSE:
    case ONIBI_GA_CAPTURE_OPEN_UNSCOPED: {
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
	int close = action->code == ONIBI_GA_CAPTURE_CLOSE;
	if (action->slot >= capture_slots ||
	    ((action->slot & 1U) != (close ? 1U : 0U)))
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
	    if (action->has_arg32 || !action->has_subprogram ||
		action->subprogram_id == 0 ||
		action->subprogram_id >= view->subprograms->count)
		onibi_gir_verification_error(
		    "lookaround subprogram is invalid");
	    uint8_t required_kind = action->assert_kind == ONIBI_RAP_LOOKAHEAD
					? ONIBI_SUBPROGRAM_LOOKAHEAD
					: ONIBI_SUBPROGRAM_LOOKBEHIND;
	    const OnibiRSeqSubprogramEntry *subprogram =
		&view->subprograms->entries[action->subprogram_id];
	    if (subprogram->kind != required_kind ||
		((subprogram->effects & ONIBI_SUBPROGRAM_EFFECT_POSITIVE) !=
		 0) != (action->positive != 0))
		onibi_gir_verification_error(
		    "lookaround subprogram is invalid");
	    owner->physical_subprogram_references[action->subprogram_id] = 1;
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
	    owner->progress_slot_states[action->slot] != 0 ||
	    owner->nullable_reserved_slots[action->slot] != 0)
	    onibi_gir_verification_error("counter slot is invalid");
	break;
    case ONIBI_GA_COUNTER_INCREMENT:
	if (action->set || action->positive || !action->has_slot ||
	    action->slot >= (uint32_t)view->counter_count ||
	    action->has_assert_kind || action->has_arg32 ||
	    action->has_subprogram ||
	    owner->progress_slot_states[action->slot] != 0 ||
	    owner->nullable_reserved_slots[action->slot] != 0)
	    onibi_gir_verification_error("counter slot is invalid");
	break;
    case ONIBI_GA_PROGRESS:
	if (action->set || action->positive || !action->has_slot ||
	    action->slot >= (uint32_t)view->counter_count ||
	    action->has_assert_kind || action->has_arg32 ||
	    action->has_subprogram ||
	    owner->progress_slot_states[action->slot] == 0 || start_action ||
	    edge_to > edge_from ||
	    owner->nullable_reserved_slots[action->slot] != 0)
	    onibi_gir_verification_error("repeat progress is invalid");
	owner->progress_slot_states[action->slot] = 2;
	break;
    case ONIBI_GA_NULL_ENTER:
    case ONIBI_GA_NULL_CAPTURE:
    case ONIBI_GA_NULL_CONTINUE:
    case ONIBI_GA_NULL_STOP:
	if (!action->has_slot ||
	    (uint32_t)action->slot + 1U >= (uint32_t)view->counter_count ||
	    action->has_assert_kind || action->has_subprogram || action->set ||
	    action->positive ||
	    (action->code == ONIBI_GA_NULL_CAPTURE
		 ? !action->has_arg32 ||
		       action->arg32 >= (uint32_t)view->capture_count
		 : action->has_arg32))
	    onibi_gir_verification_error("nullable repeat action is invalid");
	if (!owner->nullable_owner_bases[action->slot])
	    onibi_gir_verification_error("nullable owner base is invalid");
	break;
    case ONIBI_GA_ORDER:
	if (action->has_slot || !action->has_arg32 || action->has_assert_kind ||
	    action->has_subprogram || action->set || action->positive)
	    onibi_gir_verification_error("ordered capture action is invalid");
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
    for (size_t i = 0; i < actions->count; i++) {
	onibi_gir_verify_action(view, owner, &actions->entries[i], start_action,
				edge_from, edge_to);
    }
}

static void
onibi_gir_verify_owner_initialize(const OnibiGIRView *view,
				  OnibiGIRVerifyOwner *owner)
{
    size_t physical_count = view->subprograms->count;
    size_t counter_count = (size_t)view->counter_count;
    if (physical_count != 0) {
	owner->physical_subprogram_references =
	    onibi_owned_realloc(&owner->allocations, NULL, physical_count);
	memset(owner->physical_subprogram_references, 0, physical_count);
    }
    if (counter_count != 0) {
	owner->progress_slot_states =
	    onibi_owned_realloc(&owner->allocations, NULL, counter_count);
	memset(owner->progress_slot_states, 0, counter_count);
	owner->nullable_owner_bases =
	    onibi_owned_realloc(&owner->allocations, NULL, counter_count);
	memset(owner->nullable_owner_bases, 0, counter_count);
	owner->nullable_reserved_slots =
	    onibi_owned_realloc(&owner->allocations, NULL, counter_count);
	memset(owner->nullable_reserved_slots, 0, counter_count);
	owner->nullable_owner_indices = onibi_owned_realloc(
	    &owner->allocations, NULL,
	    counter_count * sizeof(*owner->nullable_owner_indices));
	for (size_t i = 0; i < counter_count; i++)
	    owner->nullable_owner_indices[i] = UINT32_MAX;
    }
    owner->nullable_state_count = view->states->count;
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

static void
onibi_gir_verify_class(const OnibiSemanticClass *klass)
{
    if (!klass->data || klass->data_length == 0 ||
	klass->kind > ONIBI_CLASS_MIXED || klass->casefolded > 1 ||
	klass->incomplete_casefold > 1 ||
	(klass->incomplete_casefold && !klass->casefolded) ||
	(klass->flags & ~ONIBI_RSEQ_CLASS_FLAG_NEGATED) != 0)
	onibi_gir_verification_error("class descriptor is invalid");
    if (klass->kind == ONIBI_CLASS_ASCII_BITMAP) {
	if (klass->data_length != 32)
	    onibi_gir_verification_error("class bitmap is invalid");
	return;
    }
    if (klass->kind == ONIBI_CLASS_CODEPOINT_RANGES) {
	if (klass->data_length % sizeof(OnibiCodepointRange) != 0)
	    onibi_gir_verification_error("class range set is invalid");
	const OnibiCodepointRange *ranges =
	    (const OnibiCodepointRange *)klass->data;
	size_t count = klass->data_length / sizeof(*ranges);
	for (size_t i = 0; i < count; i++)
	    if (ranges[i].first > ranges[i].last ||
		(i > 0 && ranges[i - 1].last >= ranges[i].first))
		onibi_gir_verification_error("class range set is invalid");
	return;
    }
    if (klass->kind == ONIBI_CLASS_ENCODING_CTYPE) {
	if (klass->data_length != sizeof(uint32_t))
	    onibi_gir_verification_error("class character type is invalid");
	return;
    }
    if (klass->data_length % sizeof(OnibiClassExpr) != 0)
	onibi_gir_verification_error("mixed class program is invalid");
    const OnibiClassExpr *expr = (const OnibiClassExpr *)klass->data;
    size_t count = klass->data_length / sizeof(*expr);
    size_t depth = 0;
    for (size_t i = 0; i < count; i++) {
	if (expr[i].flags != 0 || expr[i].reserved != 0 ||
	    expr[i].op < ONIBI_CLASS_EXPR_RANGE ||
	    expr[i].op > ONIBI_CLASS_EXPR_NEGATE)
	    onibi_gir_verification_error("mixed class program is invalid");
	if (expr[i].op == ONIBI_CLASS_EXPR_RANGE ||
	    expr[i].op == ONIBI_CLASS_EXPR_CTYPE) {
	    if (expr[i].op == ONIBI_CLASS_EXPR_RANGE &&
		expr[i].arg0 > expr[i].arg1)
		onibi_gir_verification_error("mixed class range is invalid");
	    depth++;
	}
	else if (expr[i].op == ONIBI_CLASS_EXPR_NEGATE) {
	    if (depth < 1)
		onibi_gir_verification_error("mixed class stack is invalid");
	}
	else {
	    if (depth < 2)
		onibi_gir_verification_error("mixed class stack is invalid");
	    depth--;
	}
    }
    if (depth != 1)
	onibi_gir_verification_error("mixed class stack is invalid");
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
	!view->subprogram_entries || !view->subprograms ||
	!view->lookbehind_widths || !view->progress_slots)
	onibi_gir_verification_error("typed GIR input is incomplete");
    if (view->subprograms->count == 0 ||
	view->subprograms->count > view->subprograms->capacity ||
	view->subprograms->entries == NULL ||
	view->semantic_subprogram_count > view->subprograms->count ||
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
    if (view->subprogram_entries->count > view->subprogram_entries->capacity ||
	(view->subprogram_entries->count != 0 &&
	 view->subprogram_entries->entries == NULL))
	onibi_gir_verification_error("subprogram entries are invalid");
    if (view->lookbehind_widths->count > view->lookbehind_widths->capacity ||
	(view->lookbehind_widths->count != 0 &&
	 view->lookbehind_widths->entries == NULL))
	onibi_gir_verification_error("lookbehind width set is invalid");
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
    if (!view->classes || view->classes->count > UINT32_MAX ||
	view->classes->count > view->classes->capacity ||
	(view->classes->count != 0 && view->classes->entries == NULL))
	onibi_gir_verification_error("class descriptor vector is invalid");
    for (size_t i = 0; i < view->classes->count; i++)
	onibi_gir_verify_class(&view->classes->entries[i]);
    if (!view->backrefs || view->backrefs->count > UINT32_MAX ||
	view->backrefs->count > view->backrefs->capacity ||
	(view->backrefs->count != 0 && view->backrefs->entries == NULL) ||
	!view->backref_capture_ids ||
	view->backref_capture_ids->count > UINT32_MAX ||
	view->backref_capture_ids->count >
	    view->backref_capture_ids->capacity ||
	(view->backref_capture_ids->count != 0 &&
	 view->backref_capture_ids->entries == NULL))
	onibi_gir_verification_error(
	    "backreference descriptor vector is invalid");
    for (size_t i = 0; i < view->backrefs->count; i++) {
	const OnibiBackrefDesc *descriptor = &view->backrefs->entries[i];
	if (descriptor->capture_count == 0 ||
	    descriptor->capture_list_off > view->backref_capture_ids->count ||
	    descriptor->capture_count > view->backref_capture_ids->count -
					    descriptor->capture_list_off ||
	    (descriptor->flags &
	     ~(ONIBI_BACKREF_FLAG_IGNORE_CASE | ONIBI_BACKREF_FLAG_NAMED |
	       ONIBI_BACKREF_FLAG_RELATIVE | ONIBI_BACKREF_FLAG_WITH_LEVEL)) !=
		0 ||
	    (!(descriptor->flags & ONIBI_BACKREF_FLAG_WITH_LEVEL) &&
	     descriptor->recursion_level != 0))
	    onibi_gir_verification_error("backreference descriptor is invalid");
	for (uint16_t j = 0; j < descriptor->capture_count; j++)
	    if (view->backref_capture_ids
		    ->entries[descriptor->capture_list_off + j] >=
		(uint32_t)view->capture_count)
		onibi_gir_verification_error(
		    "backreference capture list is invalid");
    }

    onibi_gir_verify_owner_initialize(view, owner);
    for (size_t i = 0; i < view->edges->count; i++)
	onibi_gir_nullable_collect_vector(view, owner,
					  &view->edges->entries[i].actions);
    for (size_t i = 0; i < view->start_edges->count; i++)
	onibi_gir_nullable_collect_vector(
	    view, owner, &view->start_edges->entries[i].actions);
    for (size_t i = 0; i < view->subprogram_entries->count; i++)
	onibi_gir_nullable_collect_vector(
	    view, owner, &view->subprogram_entries->entries[i].actions);

    onibi_gir_nullable_finalize_owners(owner);
    for (size_t i = 0; i < view->progress_slots->count; i++) {
	uint32_t slot = view->progress_slots->entries[i];
	if (slot >= (uint32_t)view->counter_count)
	    onibi_gir_verification_error("repeat progress is invalid");
	if (owner->progress_slot_states[slot] != 0)
	    onibi_gir_verification_error("repeat progress slot is duplicated");
	if (owner->nullable_reserved_slots[slot] != 0)
	    onibi_gir_verification_error(
		"repeat progress aliases nullable owner");
	owner->progress_slot_states[slot] = 1;
    }

    for (size_t i = 0; i < view->states->count; i++) {
	const OnibiGirStateEntry *state = &view->states->entries[i];
	if (state->id != (long)i)
	    onibi_gir_verification_error("state IDs are not contiguous");
	if ((unsigned int)state->opcode > ONIBI_G_ABSENT ||
	    (state->payload_index != 0 && state->opcode != ONIBI_G_BACKREF))
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
	    if (state->value >= view->classes->count)
		onibi_gir_verification_error("class reference is invalid");
	    if (state->literal_length != 0 ||
		!onibi_gir_zero_bytes(state->literal, sizeof(state->literal)) ||
		!onibi_gir_zero_bytes(state->bitmap, sizeof(state->bitmap)))
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
	    state->value >= view->backrefs->count)
	    onibi_gir_verification_error(
		"backreference descriptor reference is invalid");
	if (state->opcode == ONIBI_G_BACKREF &&
	    (((state->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0) !=
	     ((view->backrefs->entries[state->value].flags &
	       ONIBI_BACKREF_FLAG_IGNORE_CASE) != 0)))
	    onibi_gir_verification_error(
		"backreference option and descriptor flags do not agree");
	if (state->opcode == ONIBI_G_CALL || state->opcode == ONIBI_G_ATOMIC ||
	    state->opcode == ONIBI_G_ABSENT) {
	    if (state->value == 0 || state->value >= view->subprograms->count)
		onibi_gir_verification_error("subprogram reference is invalid");
	    uint32_t required_flags =
		state->opcode == ONIBI_G_ATOMIC	  ? ONIBI_SUBPROGRAM_ATOMIC
		: state->opcode == ONIBI_G_ABSENT ? ONIBI_SUBPROGRAM_ABSENT
						  : 0;
	    uint8_t required_kind =
		state->opcode == ONIBI_G_ATOMIC ? ONIBI_SUBPROGRAM_ATOMIC_GROUP
		: state->opcode == ONIBI_G_ABSENT ? ONIBI_SUBPROGRAM_ABSENCE
						  : ONIBI_SUBPROGRAM_CALL;
	    if (view->subprograms->entries[state->value].flags !=
		    required_flags ||
		view->subprograms->entries[state->value].kind != required_kind)
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
	uint8_t expected_effects =
	    subprogram->kind == ONIBI_SUBPROGRAM_ATOMIC_GROUP
		? ONIBI_SUBPROGRAM_EFFECT_FIRST_SUCCESS
	    : ((subprogram->kind == ONIBI_SUBPROGRAM_LOOKAHEAD ||
		subprogram->kind == ONIBI_SUBPROGRAM_LOOKBEHIND) &&
	       (subprogram->effects & ONIBI_SUBPROGRAM_EFFECT_POSITIVE) != 0)
		? ONIBI_SUBPROGRAM_EFFECT_POSITIVE |
		      ONIBI_SUBPROGRAM_EFFECT_PUBLISH_CAPTURES
		: 0;
	if (subprogram->entry >= view->states->count ||
	    subprogram->accept >= view->states->count ||
	    view->states->entries[subprogram->accept].opcode !=
		ONIBI_G_ACCEPT ||
	    subprogram->kind > ONIBI_SUBPROGRAM_ABSENCE ||
	    subprogram->effects != expected_effects ||
	    subprogram->reserved != 0 ||
	    (subprogram->option_env.options & ~option_mask) != 0 ||
	    subprogram->option_env.encoding_index < 0 ||
	    (subprogram->flags != 0 &&
	     subprogram->flags != ONIBI_SUBPROGRAM_ATOMIC &&
	     subprogram->flags != ONIBI_SUBPROGRAM_ABSENT))
	    onibi_gir_verification_error("subprogram descriptor is invalid");
	if (i == 0 &&
	    (subprogram->entry != (OnibiStateId)view->root_entry ||
	     subprogram->accept != (OnibiStateId)view->accept ||
	     subprogram->flags != 0 ||
	     subprogram->kind != ONIBI_SUBPROGRAM_ROOT ||
	     subprogram->entry_edge_count != 0 || subprogram->width_count != 0))
	    onibi_gir_verification_error("root subprogram is invalid");
	if (i != 0) {
	    if (subprogram->entry_edge_count == 0 ||
		(uint64_t)subprogram->entry_edge_base +
			subprogram->entry_edge_count >
		    view->subprogram_entries->count ||
		subprogram->entry != (OnibiStateId)view->subprogram_entries
					 ->entries[subprogram->entry_edge_base]
					 .to)
		onibi_gir_verification_error("subprogram entry is invalid");
	    for (uint32_t j = 0; j < subprogram->entry_edge_count; j++) {
		const OnibiGirEdgeEntry *entry =
		    &view->subprogram_entries
			 ->entries[subprogram->entry_edge_base + j];
		if (entry->from != (long)i || entry->to < 0 ||
		    (size_t)entry->to >= view->states->count)
		    onibi_gir_verification_error("subprogram entry is invalid");
		onibi_gir_verify_action_vector(view, owner, &entry->actions, 1,
					       entry->from, entry->to);
	    }
	}
	if ((subprogram->kind == ONIBI_SUBPROGRAM_LOOKBEHIND) !=
	    (subprogram->width_count != 0))
	    onibi_gir_verification_error("lookbehind width set is invalid");
	if ((uint64_t)subprogram->width_base + subprogram->width_count >
	    view->lookbehind_widths->count)
	    onibi_gir_verification_error("lookbehind width set is invalid");
    }
    for (size_t i = 1; i < view->subprograms->count; i++)
	if (!owner->physical_subprogram_references[i])
	    onibi_gir_verification_error("subprogram reference is missing");

    for (size_t i = 0; i < view->progress_slots->count; i++) {
	uint32_t slot = view->progress_slots->entries[i];
	if (owner->progress_slot_states[slot] != 2)
	    onibi_gir_verification_error("repeat progress is invalid");
    }
    onibi_gir_nullable_validate_all_paths(view, owner);
    return Qnil;
}

static VALUE
onibi_gir_verify_ensure(VALUE opaque)
{
    OnibiGIRVerifyCall *call = (OnibiGIRVerifyCall *)(uintptr_t)opaque;
    onibi_allocation_owner_cleanup(&call->owner.allocations);
    return Qnil;
}

static size_t
onibi_gir_verify(const OnibiGIRView *view)
{
    OnibiGIRVerifyCall call;
    memset(&call, 0, sizeof(call));
    call.view = view;
    onibi_allocation_owner_init(&call.owner.allocations, NULL);
    onibi_allocation_owner_set_phase(&call.owner.allocations, 1);
    (void)rb_ensure(onibi_gir_verify_body, (VALUE)(uintptr_t)&call,
		    onibi_gir_verify_ensure, (VALUE)(uintptr_t)&call);
    return call.owner.nullable_word_count;
}

static uint8_t
onibi_rseq_physical_action_op(OnibiGActionOp code)
{
    return (uint8_t)(code == ONIBI_GA_CAPTURE_OPEN ||
			     code == ONIBI_GA_CAPTURE_CLOSE ||
			     code == ONIBI_GA_CAPTURE_OPEN_UNSCOPED
			 ? ONIBI_RA_CAPTURE
		     : code == ONIBI_GA_MATCH_RESET ? ONIBI_RA_MATCH_RESET
		     : code == ONIBI_GA_ASSERT_POSITION
			 ? ONIBI_RA_ASSERT_POSITION
		     : code == ONIBI_GA_TEST_CAPTURE ? ONIBI_RA_TEST_CAPTURE
		     : code == ONIBI_GA_COUNTER_INIT ? ONIBI_RA_COUNTER_SET
		     : code == ONIBI_GA_COUNTER_INCREMENT ? ONIBI_RA_COUNTER_ADD
		     : code == ONIBI_GA_TEST_COUNTER_LT ||
			     code == ONIBI_GA_TEST_COUNTER_GE
			 ? ONIBI_RA_COUNTER_TEST
		     : code == ONIBI_GA_PROGRESS      ? ONIBI_RA_PROGRESS
		     : code == ONIBI_GA_NULL_ENTER    ? ONIBI_RA_NULL_ENTER
		     : code == ONIBI_GA_NULL_CAPTURE  ? ONIBI_RA_NULL_CAPTURE
		     : code == ONIBI_GA_NULL_CONTINUE ? ONIBI_RA_NULL_CONTINUE
		     : code == ONIBI_GA_NULL_STOP     ? ONIBI_RA_NULL_STOP
		     : code == ONIBI_GA_ORDER	      ? ONIBI_RA_ORDER
						      : ONIBI_RA_END);
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
ONIBI_VECTOR_DEFINE(onibi_backref_desc_vector, OnibiBackrefDescVector,
		    OnibiBackrefDesc, 4,
		    "GIR backreference descriptor vector is too large")

static void
onibi_rseq_subprogram_vector_store(OnibiRSeqSubprogramVector *vector,
				   size_t index,
				   OnibiRSeqSubprogramEntry descriptor)
{
    if (index >= vector->count)
	rb_raise(rb_eArgError, "subprogram index is out of range");
    vector->entries[index] = descriptor;
}
static unsigned char
onibi_ascii_fold(unsigned char value)
{
    return (value >= 'A' && value <= 'Z') ? (unsigned char)(value + ('a' - 'A'))
					  : value;
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
onibi_ascii_property_name_p(ID name_id)
{
    return name_id != 0 &&
	   onibi_ascii_property_kind_id(name_id) != ONIBI_ASCII_PROP_UNKNOWN;
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
