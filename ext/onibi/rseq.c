#include "onibi_ast_internal.h"
#include "onibi_compiler_internal.h"
#include "onibi_gir_internal.h"
#include "onibi_rseq_internal.h"
#include "onibi_ruby_api_internal.h"

static uint8_t
onibi_g_action_flags(const OnibiGAction *action)
{
    if (action->code == ONIBI_GA_CAPTURE_CLOSE) return ONIBI_RA_CAPTURE_CLOSE;
    if (action->code == ONIBI_GA_CAPTURE_OPEN_UNSCOPED)
	return ONIBI_RA_CAPTURE_OPEN_UNSCOPED;
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
    physical_action->op =
	action->code == ONIBI_GA_ASSERT_POSITION && action->has_subprogram
	    ? ONIBI_RA_ASSERT_SUBPROGRAM
	    : onibi_rseq_physical_action_op(action->code);
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
    if (action->has_subprogram)
	physical_action->arg32 = action->subprogram_id;
    else if (action->has_arg32)
	physical_action->arg32 = action->arg32;
}

/* These records exist only while lowering.  They keep semantic GIR action
 * storage immutable and put physical action offsets in the RSeq records. */
typedef struct {
    long from;
    long to;
    uint32_t action_offset;
    uint32_t action_count;
} OnibiRSeqEdgeEntry;
typedef ONIBI_VECTOR(OnibiRSeqEdgeEntry) OnibiRSeqEdgeVector;
typedef struct {
    const OnibiSemanticClass *semantic;
} OnibiRSeqClassPayloadEntry;
typedef ONIBI_VECTOR(OnibiRSeqClassPayloadEntry) OnibiRSeqClassPayloadVector;
typedef struct {
    const OnibiGAction *actions;
    uint32_t action_count;
    uint32_t action_offset;
} OnibiRSeqActionProgramEntry;
typedef ONIBI_VECTOR(OnibiRSeqActionProgramEntry) OnibiRSeqActionProgramVector;

ONIBI_VECTOR_DEFINE(onibi_rseq_edge_vector, OnibiRSeqEdgeVector,
		    OnibiRSeqEdgeEntry, 8, "RSeq edge vector is too large")
ONIBI_VECTOR_DEFINE(onibi_rseq_class_payload_vector,
		    OnibiRSeqClassPayloadVector, OnibiRSeqClassPayloadEntry, 8,
		    "RSeq class payload vector is too large")
ONIBI_VECTOR_DEFINE(onibi_rseq_action_program_vector,
		    OnibiRSeqActionProgramVector, OnibiRSeqActionProgramEntry,
		    8, "RSeq action program vector is too large")

/* Hash slots use a one-based payload index.  The table has no semantic
 * ownership: the typed vectors own all keys and preserve first insertion. */
typedef struct {
    uint32_t *slots;
    uint64_t *hashes;
    size_t count;
    size_t capacity;
    onibi_allocation_owner_t *allocation_owner;
} OnibiRSeqHashTable;

static void
onibi_rseq_hash_table_init(OnibiRSeqHashTable *table,
			   onibi_allocation_owner_t *owner)
{
    memset(table, 0, sizeof(*table));
    table->allocation_owner = owner;
}

static void
onibi_rseq_hash_table_free(OnibiRSeqHashTable *table)
{
    onibi_owned_free(table->allocation_owner, table->slots);
    onibi_owned_free(table->allocation_owner, table->hashes);
    memset(table, 0, sizeof(*table));
}

static uint64_t
onibi_rseq_hash_bytes(uint64_t hash, const unsigned char *bytes, size_t count)
{
    for (size_t i = 0; i < count; i++) {
	hash ^= bytes[i];
	hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static uint64_t
onibi_rseq_hash_u32(uint64_t hash, uint32_t value)
{
    unsigned char bytes[4] = {(unsigned char)value, (unsigned char)(value >> 8),
			      (unsigned char)(value >> 16),
			      (unsigned char)(value >> 24)};
    return onibi_rseq_hash_bytes(hash, bytes, sizeof(bytes));
}

static uint64_t
onibi_rseq_hash_u8(uint64_t hash, uint8_t value)
{
    return onibi_rseq_hash_bytes(hash, &value, 1);
}

static void
onibi_rseq_hash_table_grow(OnibiRSeqHashTable *table)
{
    size_t next_capacity = table->capacity == 0 ? 16 : table->capacity * 2;
    if (next_capacity < table->capacity ||
	next_capacity > SIZE_MAX / sizeof(uint64_t) ||
	next_capacity > SIZE_MAX / sizeof(uint32_t))
	rb_raise(rb_eNoMemError, "RSeq hash table is too large");
    uint32_t *next_slots = onibi_owned_realloc(
	table->allocation_owner, NULL, next_capacity * sizeof(*next_slots));
    uint64_t *next_hashes = onibi_owned_realloc(
	table->allocation_owner, NULL, next_capacity * sizeof(*next_hashes));
    memset(next_slots, 0, next_capacity * sizeof(*next_slots));
    for (size_t i = 0; i < table->capacity; i++) {
	if (table->slots[i] == 0) continue;
	size_t slot = (size_t)table->hashes[i] & (next_capacity - 1U);
	while (next_slots[slot] != 0)
	    slot = (slot + 1U) & (next_capacity - 1U);
	next_slots[slot] = table->slots[i];
	next_hashes[slot] = table->hashes[i];
    }
    onibi_owned_free(table->allocation_owner, table->slots);
    onibi_owned_free(table->allocation_owner, table->hashes);
    table->slots = next_slots;
    table->hashes = next_hashes;
    table->capacity = next_capacity;
}

static void
onibi_rseq_hash_table_reserve_one(OnibiRSeqHashTable *table)
{
    if (table->capacity == 0 ||
	(table->count + 1U) * 10U > table->capacity * 7U)
	onibi_rseq_hash_table_grow(table);
}

static size_t
onibi_rseq_hash_table_slot(const OnibiRSeqHashTable *table, uint64_t hash)
{
    size_t slot = (size_t)hash & (table->capacity - 1U);
    while (table->slots[slot] != 0 && table->hashes[slot] != hash)
	slot = (slot + 1U) & (table->capacity - 1U);
    return slot;
}

static int
onibi_rseq_actions_equal(const OnibiGAction *first, const OnibiGAction *second,
			 size_t count)
{
    for (size_t i = 0; i < count; i++) {
	OnibiRAction left, right;
	onibi_rseq_serialize_action(&first[i], &left);
	onibi_rseq_serialize_action(&second[i], &right);
	if (left.op != right.op || left.flags != right.flags ||
	    left.arg16 != right.arg16 || left.arg32 != right.arg32)
	    return 0;
    }
    return 1;
}

static uint64_t
onibi_rseq_hash_actions(const OnibiGActionVector *actions)
{
    uint64_t hash = onibi_rseq_hash_u32(UINT64_C(1469598103934665603),
					(uint32_t)actions->count);
    for (size_t i = 0; i < actions->count; i++) {
	const OnibiGAction *action = &actions->entries[i];
	OnibiRAction physical;
	onibi_rseq_serialize_action(action, &physical);
	hash = onibi_rseq_hash_u8(hash, physical.op);
	hash = onibi_rseq_hash_u8(hash, physical.flags);
	hash = onibi_rseq_hash_u32(hash, physical.arg16);
	hash = onibi_rseq_hash_u32(hash, physical.arg32);
    }
    return hash;
}

static uint64_t
onibi_rseq_hash_literal(const OnibiGirStateEntry *state)
{
    size_t length = state->literal_length ? state->literal_length : 1;
    unsigned char byte = (unsigned char)state->value;
    const unsigned char *bytes = state->literal_length ? state->literal : &byte;
    uint64_t hash =
	onibi_rseq_hash_u32(UINT64_C(1469598103934665603), (uint32_t)length);
    hash = onibi_rseq_hash_bytes(hash, bytes, length);
    return onibi_rseq_hash_u8(
	hash, (state->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0);
}

static uint64_t
onibi_rseq_hash_class(const OnibiSemanticClass *entry)
{
    uint64_t hash =
	onibi_rseq_hash_u8(UINT64_C(1469598103934665603), entry->kind);
    uint8_t flags =
	entry->flags |
	(entry->incomplete_casefold ? ONIBI_RSEQ_CLASS_FLAG_INCOMPLETE_CASEFOLD
				    : 0);
    hash = onibi_rseq_hash_u8(hash, flags);
    hash = onibi_rseq_hash_u32(hash, entry->data_length);
    return onibi_rseq_hash_bytes(hash, entry->data, entry->data_length);
}

static uint32_t
onibi_rseq_intern_literal(OnibiRSeqLiteralPayloadVector *payloads,
			  OnibiRSeqHashTable *table, OnibiLoweringWork *work,
			  const OnibiGirStateEntry *state)
{
    uint64_t hash = onibi_rseq_hash_literal(state);
    onibi_rseq_hash_table_reserve_one(table);
    size_t slot = onibi_rseq_hash_table_slot(table, hash);
    size_t length = state->literal_length ? state->literal_length : 1;
    unsigned char byte = (unsigned char)state->value;
    const unsigned char *bytes = state->literal_length ? state->literal : &byte;
    while (table->slots[slot] != 0) {
	work->literal_probes++;
	OnibiRSeqLiteralPayloadEntry *prior =
	    &payloads->entries[table->slots[slot] - 1U];
	if (table->hashes[slot] == hash && prior->length == length &&
	    prior->ignorecase ==
		((state->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0) &&
	    memcmp(prior->bytes, bytes, length) == 0)
	    return table->slots[slot] - 1U;
	slot = (slot + 1U) & (table->capacity - 1U);
    }
    if (payloads->count >= UINT32_MAX)
	rb_raise(eRegexpError, "RSeq has too many literal descriptors");
    onibi_rseq_literal_payload_vector_push(payloads, state);
    table->slots[slot] = (uint32_t)payloads->count;
    table->hashes[slot] = hash;
    table->count++;
    return (uint32_t)(payloads->count - 1U);
}

static uint32_t
onibi_rseq_intern_class(OnibiRSeqClassPayloadVector *payloads,
			OnibiRSeqHashTable *table, OnibiLoweringWork *work,
			const OnibiSemanticClass *entry)
{
    uint64_t hash = onibi_rseq_hash_class(entry);
    onibi_rseq_hash_table_reserve_one(table);
    size_t slot = onibi_rseq_hash_table_slot(table, hash);
    while (table->slots[slot] != 0) {
	work->rseq_class_probes++;
	const OnibiSemanticClass *prior =
	    payloads->entries[table->slots[slot] - 1U].semantic;
	if (table->hashes[slot] == hash && prior->kind == entry->kind &&
	    (prior->flags | (prior->incomplete_casefold
				 ? ONIBI_RSEQ_CLASS_FLAG_INCOMPLETE_CASEFOLD
				 : 0)) ==
		(entry->flags | (entry->incomplete_casefold
				     ? ONIBI_RSEQ_CLASS_FLAG_INCOMPLETE_CASEFOLD
				     : 0)) &&
	    prior->data_length == entry->data_length &&
	    memcmp(prior->data, entry->data, entry->data_length) == 0)
	    return table->slots[slot] - 1U;
	slot = (slot + 1U) & (table->capacity - 1U);
    }
    if (payloads->count >= UINT32_MAX)
	rb_raise(eRegexpError, "RSeq has too many class descriptors");
    onibi_rseq_class_payload_vector_push(payloads,
					 (OnibiRSeqClassPayloadEntry){entry});
    table->slots[slot] = (uint32_t)payloads->count;
    table->hashes[slot] = hash;
    table->count++;
    return (uint32_t)(payloads->count - 1U);
}

static uint32_t
onibi_rseq_intern_actions(OnibiRSeqActionProgramVector *programs,
			  OnibiRSeqHashTable *table,
			  OnibiGActionVector *physical, OnibiLoweringWork *work,
			  const OnibiGActionVector *actions)
{
    if (actions->count == 0) return 0;
    if (actions->count > UINT32_MAX || physical->count > UINT32_MAX)
	rb_raise(eRegexpError, "RSeq action program exceeds the size limit");
    uint64_t hash = onibi_rseq_hash_actions(actions);
    onibi_rseq_hash_table_reserve_one(table);
    size_t slot = onibi_rseq_hash_table_slot(table, hash);
    while (table->slots[slot] != 0) {
	work->action_probes++;
	OnibiRSeqActionProgramEntry *prior =
	    &programs->entries[table->slots[slot] - 1U];
	if (table->hashes[slot] == hash &&
	    prior->action_count == actions->count &&
	    onibi_rseq_actions_equal(prior->actions, actions->entries,
				     actions->count))
	    return prior->action_offset;
	slot = (slot + 1U) & (table->capacity - 1U);
    }
    if (programs->count >= UINT32_MAX ||
	physical->count > UINT32_MAX - actions->count - 1U)
	rb_raise(eRegexpError, "RSeq has too many action programs");
    uint32_t offset = (uint32_t)physical->count;
    onibi_g_action_vector_append(physical, actions);
    onibi_g_action_vector_push(
	physical, (OnibiGAction){ONIBI_GA_END, 0, 0, 0, 0, 0, 0, 0, 0});
    onibi_rseq_action_program_vector_push(
	programs, (OnibiRSeqActionProgramEntry){
		      actions->entries, (uint32_t)actions->count, offset});
    table->slots[slot] = (uint32_t)programs->count;
    table->hashes[slot] = hash;
    table->count++;
    return offset;
}

typedef struct {
    OnibiRSeqEdgeVector *vector;
    size_t state_count;
    size_t *counts;
    size_t *next;
    OnibiRSeqEdgeEntry *ordered;
} OnibiRSeqEdgeGroupOwner;

static void
onibi_rseq_edge_group_cleanup(OnibiRSeqEdgeGroupOwner *owner)
{
    onibi_owned_free(owner->vector->allocation_owner, owner->counts);
    onibi_owned_free(owner->vector->allocation_owner, owner->next);
    onibi_owned_free(owner->vector->allocation_owner, owner->ordered);
}

static VALUE
onibi_rseq_edge_group_body(VALUE opaque)
{
    OnibiRSeqEdgeGroupOwner *owner =
	(OnibiRSeqEdgeGroupOwner *)(uintptr_t)opaque;
    OnibiRSeqEdgeVector *vector = owner->vector;
    if (vector->count < 2) return Qnil;
    if (owner->state_count > SIZE_MAX / sizeof(size_t) ||
	vector->count > SIZE_MAX / sizeof(*vector->entries))
	rb_raise(rb_eNoMemError, "RSeq edge index is too large");
    owner->counts =
	onibi_owned_realloc(vector->allocation_owner, NULL,
			    owner->state_count * sizeof(*owner->counts));
    owner->next =
	onibi_owned_realloc(vector->allocation_owner, NULL,
			    owner->state_count * sizeof(*owner->next));
    owner->ordered =
	onibi_owned_realloc(vector->allocation_owner, NULL,
			    vector->count * sizeof(*owner->ordered));
    memset(owner->counts, 0, owner->state_count * sizeof(*owner->counts));
    for (size_t i = 0; i < vector->count; i++) {
	if (vector->entries[i].from < 0 ||
	    (size_t)vector->entries[i].from >= owner->state_count)
	    rb_raise(rb_eArgError, "RSeq edge source is out of range");
	owner->counts[vector->entries[i].from]++;
    }
    size_t offset = 0;
    for (size_t i = 0; i < owner->state_count; i++) {
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

static VALUE
onibi_rseq_edge_group_ensure(VALUE opaque)
{
    onibi_rseq_edge_group_cleanup((OnibiRSeqEdgeGroupOwner *)(uintptr_t)opaque);
    return Qnil;
}

static void
onibi_rseq_edge_vector_group_by_from(OnibiRSeqEdgeVector *vector,
				     size_t state_count)
{
    if (vector->count < 2) return;
    OnibiRSeqEdgeGroupOwner owner;
    memset(&owner, 0, sizeof(owner));
    owner.vector = vector;
    owner.state_count = state_count;
    (void)rb_ensure(onibi_rseq_edge_group_body, (VALUE)(uintptr_t)&owner,
		    onibi_rseq_edge_group_ensure, (VALUE)(uintptr_t)&owner);
}

/* RSeq lowering uses one scoped owner for all mutable lowering records.  The
 * owner remains active until the protected body publishes or discards them. */
typedef struct {
    onibi_allocation_owner_t allocations;
    OnibiGirStateVector states;
    OnibiRSeqSubprogramVector subprograms;
    OnibiRSeqEdgeVector subprogram_entries;
    OnibiIdVector lookbehind_widths;
    OnibiRSeqClassPayloadVector class_payloads;
    OnibiRSeqLiteralPayloadVector literal_payloads;
    OnibiGActionVector actions;
    OnibiRSeqActionProgramVector action_programs;
    OnibiRSeqEdgeVector edges;
    OnibiRSeqEdgeVector start_edges;
    OnibiRSeqHashTable class_hash;
    OnibiRSeqHashTable literal_hash;
    OnibiRSeqHashTable action_hash;
    OnibiLoweringWork lowering_work;
    OnibiLoweringWork *result_work;
    int failure_phase;
    int *failure_fired;
    OnibiCompileOutcome *compile_outcome;
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
onibi_rseq_mark_unsupported(OnibiRSeqLowerOwner *owner,
			    OnibiUnsupportedReason reason)
{
    if (owner && owner->compile_outcome)
	onibi_compile_outcome_unsupported(owner->compile_outcome, reason);
}

static void
onibi_rseq_lower_owner_cleanup(OnibiRSeqLowerOwner *owner)
{
    onibi_rseq_hash_table_free(&owner->class_hash);
    onibi_rseq_hash_table_free(&owner->literal_hash);
    onibi_rseq_hash_table_free(&owner->action_hash);
    onibi_rseq_class_payload_vector_free(&owner->class_payloads);
    onibi_rseq_literal_payload_vector_free(&owner->literal_payloads);
    onibi_g_action_vector_free(&owner->actions);
    onibi_rseq_action_program_vector_free(&owner->action_programs);
    onibi_rseq_edge_vector_free(&owner->edges);
    onibi_rseq_edge_vector_free(&owner->start_edges);
    onibi_gir_state_vector_free(&owner->states);
    onibi_rseq_subprogram_vector_free(&owner->subprograms);
    onibi_rseq_edge_vector_free(&owner->subprogram_entries);
    onibi_id_vector_free(&owner->lookbehind_widths);
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
#define subprogram_entry_records (owner->subprogram_entries)
#define lookbehind_width_records (owner->lookbehind_widths)
#define class_payloads (owner->class_payloads)
#define literal_payloads (owner->literal_payloads)
#define action_records (owner->actions)
#define action_programs (owner->action_programs)
#define r_edge_records (owner->edges)
#define r_start_edge_records (owner->start_edges)
    OnibiCompiled *compiled_data = onibi_compiled_get(compiled);
    owner->lowering_work = compiled_data->lowering_work;
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
    onibi_rseq_edge_vector_init(&subprogram_entry_records);
    onibi_rseq_edge_vector_bind(&subprogram_entry_records, &owner->allocations);
    onibi_id_vector_init(&lookbehind_width_records);
    onibi_id_vector_bind(&lookbehind_width_records, &owner->allocations);
    onibi_id_vector_append(&lookbehind_width_records,
			   &compiled_data->lookbehind_widths);
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
    onibi_rseq_hash_table_init(&owner->class_hash, &owner->allocations);
    for (size_t i = 0; i < state_records.count; i++) {
	OnibiGirStateEntry *state = &state_records.entries[i];
	if (state->opcode != ONIBI_G_CLASS) continue;
	if (state->value >= compiled_data->classes.count)
	    rb_raise(rb_eArgError, "RSeq class index is out of range");
	state->payload_index = onibi_rseq_intern_class(
	    &class_payloads, &owner->class_hash, &owner->lowering_work,
	    &compiled_data->classes.entries[state->value]);
    }
    onibi_rseq_lower_fail_if(owner, 3);
    uint32_t class_count = (uint32_t)class_payloads.count;
    onibi_allocation_owner_set_phase(&owner->allocations, 4);
    onibi_g_action_vector_init(&action_records);
    onibi_g_action_vector_bind(&action_records, &owner->allocations);
    onibi_rseq_action_program_vector_init(&action_programs);
    onibi_rseq_action_program_vector_bind(&action_programs,
					  &owner->allocations);
    onibi_rseq_hash_table_init(&owner->action_hash, &owner->allocations);
    onibi_rseq_edge_vector_init(&r_edge_records);
    onibi_rseq_edge_vector_bind(&r_edge_records, &owner->allocations);
    for (size_t i = 0; i < compiled_data->edges.count; i++) {
	const OnibiGirEdgeEntry *edge = &compiled_data->edges.entries[i];
	const OnibiGActionVector *edge_actions = &edge->actions;
	uint32_t action_offset = onibi_rseq_intern_actions(
	    &action_programs, &owner->action_hash, &action_records,
	    &owner->lowering_work, edge_actions);
	onibi_rseq_edge_vector_push(
	    &r_edge_records,
	    (OnibiRSeqEdgeEntry){edge->from, edge->to, action_offset,
				 (uint32_t)edge_actions->count});
    }
    for (size_t i = 0; i < compiled_data->subprogram_entries.count; i++) {
	const OnibiGirEdgeEntry *entry =
	    &compiled_data->subprogram_entries.entries[i];
	const OnibiGActionVector *entry_actions = &entry->actions;
	uint32_t action_offset = onibi_rseq_intern_actions(
	    &action_programs, &owner->action_hash, &action_records,
	    &owner->lowering_work, entry_actions);
	onibi_rseq_edge_vector_push(
	    &subprogram_entry_records,
	    (OnibiRSeqEdgeEntry){entry->from, entry->to, action_offset,
				 (uint32_t)entry_actions->count});
    }
    onibi_rseq_edge_vector_group_by_from(&r_edge_records, state_count);
    onibi_rseq_lower_fail_if(owner, 4);
    onibi_allocation_owner_set_phase(&owner->allocations, 5);
    onibi_rseq_edge_vector_init(&r_start_edge_records);
    onibi_rseq_edge_vector_bind(&r_start_edge_records, &owner->allocations);
    for (size_t i = 0; i < compiled_data->start_edges.count; i++) {
	const OnibiGirEdgeEntry *edge = &compiled_data->start_edges.entries[i];
	const OnibiGActionVector *edge_actions = &edge->actions;
	uint32_t action_offset = onibi_rseq_intern_actions(
	    &action_programs, &owner->action_hash, &action_records,
	    &owner->lowering_work, edge_actions);
	onibi_rseq_edge_vector_push(
	    &r_start_edge_records,
	    (OnibiRSeqEdgeEntry){-1, edge->to, action_offset,
				 (uint32_t)edge_actions->count});
    }
    onibi_rseq_lower_fail_if(owner, 5);
    int options = compiled_data->options;
    int ignorecase = (options & ONIBI_OPT_IGNORECASE) != 0;
    int multiline = (options & ONIBI_OPT_MULTILINE) != 0;
    uint64_t physical_edge_count = (uint64_t)r_edge_records.count +
				   (uint64_t)r_start_edge_records.count +
				   (uint64_t)subprogram_entry_records.count;
    onibi_allocation_owner_set_phase(&owner->allocations, 6);
    onibi_rseq_literal_payload_vector_init(&literal_payloads);
    onibi_rseq_literal_payload_vector_bind(&literal_payloads,
					   &owner->allocations);
    onibi_rseq_hash_table_init(&owner->literal_hash, &owner->allocations);
    for (size_t i = 0; i < state_records.count; i++) {
	unsigned int opcode = state_records.entries[i].opcode;
	if (opcode != ONIBI_G_CHAR) continue;
	OnibiGirStateEntry *state = &state_records.entries[i];
	state_records.entries[i].payload_index =
	    onibi_rseq_intern_literal(&literal_payloads, &owner->literal_hash,
				      &owner->lowering_work, state);
    }
    onibi_rseq_lower_fail_if(owner, 6);
    for (size_t i = 0; i < state_records.count; i++) {
	OnibiGirStateEntry *state = &state_records.entries[i];
	if (state->opcode != ONIBI_G_BACKREF) continue;
	state->payload_index = state->value;
    }
    uint32_t literal_count = (uint32_t)literal_payloads.count;
    uint32_t backref_count = (uint32_t)compiled_data->backrefs.count;
    uint32_t backref_list_count =
	(uint32_t)compiled_data->backref_capture_ids.count;
    uint64_t class_section_size =
	(uint64_t)class_count * sizeof(OnibiClassDesc);

    for (size_t i = 0; i < class_payloads.count; i++) {
	if (UINT64_MAX - class_section_size <
	    class_payloads.entries[i].semantic->data_length)
	    rb_raise(eRegexpError, "RSeq class section exceeds the size limit");
	class_section_size += class_payloads.entries[i].semantic->data_length;
    }
    uint64_t literal_desc_size =
	(uint64_t)literal_count * sizeof(OnibiLiteralDesc);
    uint64_t backref_desc_size =
	(uint64_t)backref_count * sizeof(OnibiBackrefDesc);
    uint64_t backref_list_size =
	(uint64_t)backref_list_count * sizeof(uint32_t);
    uint64_t literal_data_size = 0;
    for (size_t i = 0; i < literal_payloads.count; i++)
	literal_data_size += literal_payloads.entries[i].length;
    literal_data_size = (literal_data_size + 3U) & ~UINT64_C(3);
    uint64_t subprogram_section_size =
	(uint64_t)subprogram_records.count * sizeof(OnibiSubprogramDesc);
    uint64_t lookbehind_width_section_size =
	(uint64_t)lookbehind_width_records.count * sizeof(uint32_t);
    uint64_t physical_size =
	sizeof(OnibiRSeqHeader) +
	(uint64_t)sizeof(OnibiRState) * (uint64_t)state_records.count +
	(uint64_t)sizeof(OnibiREdge) * physical_edge_count +
	(uint64_t)sizeof(OnibiRAction) * (uint64_t)action_records.count +
	class_section_size + literal_desc_size + literal_data_size +
	backref_desc_size + backref_list_size + subprogram_section_size +
	lookbehind_width_section_size;
    if (state_records.count > UINT32_MAX || physical_edge_count > UINT32_MAX ||
	action_records.count > UINT32_MAX ||
	compiled_data->backrefs.count > UINT32_MAX ||
	compiled_data->backref_capture_ids.count > UINT32_MAX ||
	subprogram_records.count > UINT32_MAX ||
	lookbehind_width_records.count > UINT32_MAX ||
	physical_size > UINT32_MAX) {
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
    physical.lookbehind_width_count = (uint32_t)lookbehind_width_records.count;
    physical.capture_count = capture_count;
    physical.semantic_capture_count = analysis.semantic_capture_count;
    physical.counter_count = counter_count;
    physical.exec_kind = (uint8_t)analysis.execution_kind;
    physical.start_edge_base = (uint32_t)r_edge_records.count;
    physical.state_count = (uint32_t)state_records.count;
    physical.edge_count = (uint32_t)physical_edge_count;
    physical.action_count = (uint32_t)action_records.count;
    physical.start_edge_count = (uint32_t)r_start_edge_records.count;
    physical.backref_count = backref_count;
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
    physical.backrefs_offset = (uint32_t)offset;
    offset += backref_desc_size;
    physical.backref_lists_offset = (uint32_t)offset;
    offset += backref_list_size;
    physical.subprograms_offset = (uint32_t)offset;
    offset += subprogram_section_size;
    physical.lookbehind_widths_offset = (uint32_t)offset;
    offset += lookbehind_width_section_size;
    physical.blob_size = (uint32_t)offset;
    int bitmap_valid = 1;
    int bitmap_have = 0;
    memset(physical.first_bitmap, 0, sizeof(physical.first_bitmap));
    for (size_t i = 0; i < r_start_edge_records.count; i++) {
	OnibiRSeqEdgeEntry *edge = &r_start_edge_records.entries[i];
	if (edge->to < 0 || (size_t)edge->to >= state_records.count) {
	    bitmap_valid = 0;
	    continue;
	}
	OnibiGirStateEntry *state = &state_records.entries[edge->to];
	if (edge->action_count != 0 || state->opcode == ONIBI_G_ACCEPT ||
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
    if ((physical.features & ONIBI_RSEQ_FEATURE_FIRST_BITMAP) == 0)
	memset(physical.first_bitmap, 0, sizeof(physical.first_bitmap));
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
	physical_states[i].flags = state->flags;
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
    OnibiRSeqHeader *physical_header = (OnibiRSeqHeader *)RSTRING_PTR(blob);
    if (!ignorecase && r_start_edge_records.count == 1 &&
	r_start_edge_records.entries[0].action_count == 0) {
	long current = r_start_edge_records.entries[0].to;
	while (current >= 0 && (size_t)current < state_records.count &&
	       physical_header->prefix_length <
		   sizeof(physical_header->prefix)) {
	    OnibiGirStateEntry *state = &state_records.entries[current];
	    if (state->opcode != ONIBI_G_CHAR ||
		(state->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0 ||
		state->literal_length == 0 ||
		state->literal_length > sizeof(physical_header->prefix) -
					    physical_header->prefix_length)
		break;
	    memcpy(physical_header->prefix + physical_header->prefix_length,
		   state->literal, state->literal_length);
	    physical_header->prefix_length += state->literal_length;
	    OnibiRState *physical_state = &physical_states[current];
	    if (physical_state->edge_count != 1) break;
	    OnibiRSeqEdgeEntry *next =
		&r_edge_records.entries[physical_state->edge_base];
	    owner->lowering_work.prefix_edges++;
	    if (next->action_count != 0 || next->to < 0 ||
		(size_t)next->to >= state_records.count)
		break;
	    current = next->to;
	}
    }
    OnibiREdge *physical_edges =
	(OnibiREdge *)(RSTRING_PTR(blob) + physical.edges_offset);
    for (size_t i = 0; i < r_edge_records.count; i++) {
	OnibiRSeqEdgeEntry *record = &r_edge_records.entries[i];
	uint32_t destination = (uint32_t)record->to;
	if (destination == (uint32_t)(state_records.count - 1))
	    destination = ONIBI_ACCEPT_STATE;
	physical_edges[i].destination = destination;
	physical_edges[i].action_offset =
	    record->action_count == 0
		? 0
		: (uint32_t)(sizeof(OnibiRAction) *
			     (record->action_offset + 1U));
    }
    for (size_t i = 0; i < subprogram_entry_records.count; i++) {
	OnibiRSeqEdgeEntry *record = &subprogram_entry_records.entries[i];
	size_t index = r_edge_records.count + r_start_edge_records.count + i;
	physical_edges[index].destination = (uint32_t)record->to;
	physical_edges[index].action_offset =
	    record->action_count == 0
		? 0
		: (uint32_t)(sizeof(OnibiRAction) *
			     (record->action_offset + 1U));
    }
    for (size_t i = 0; i < r_start_edge_records.count; i++) {
	OnibiRSeqEdgeEntry *record = &r_start_edge_records.entries[i];
	size_t index = r_edge_records.count + i;
	physical_edges[index].destination = (uint32_t)record->to;
	physical_edges[index].action_offset =
	    record->action_count == 0
		? 0
		: (uint32_t)(sizeof(OnibiRAction) *
			     (record->action_offset + 1U));
    }
    OnibiRAction *physical_actions =
	(OnibiRAction *)(RSTRING_PTR(blob) + physical.actions_offset);
    for (size_t i = 0; i < action_records.count; i++)
	onibi_rseq_serialize_action(&action_records.entries[i],
				    &physical_actions[i]);
    OnibiClassDesc *class_descs =
	(OnibiClassDesc *)(RSTRING_PTR(blob) + physical.classes_offset);
    uint32_t class_data_offset =
	physical.classes_offset + class_count * sizeof(OnibiClassDesc);
    class_index = 0;
    for (size_t i = 0; i < class_payloads.count; i++) {
	const OnibiSemanticClass *entry = class_payloads.entries[i].semantic;
	class_descs[class_index].data_offset = class_data_offset;
	class_descs[class_index].data_length = entry->data_length;
	class_descs[class_index].kind = entry->kind;
	class_descs[class_index].flags =
	    entry->flags | (entry->incomplete_casefold
				? ONIBI_RSEQ_CLASS_FLAG_INCOMPLETE_CASEFOLD
				: 0);
	memcpy(RSTRING_PTR(blob) + class_data_offset, entry->data,
	       entry->data_length);
	class_data_offset += entry->data_length;
	class_index++;
    }
    unsigned char *literal_data =
	(unsigned char *)(RSTRING_PTR(blob) + physical.literals_offset);
    OnibiLiteralDesc *literal_descs =
	(OnibiLiteralDesc *)(RSTRING_PTR(blob) + physical.descriptors_offset);
    literal_index = 0;
    uint32_t literal_data_offset = physical.literals_offset;
    for (size_t i = 0; i < literal_payloads.count; i++) {
	OnibiRSeqLiteralPayloadEntry *entry = &literal_payloads.entries[i];
	literal_descs[literal_index].data_offset = literal_data_offset;
	literal_descs[literal_index].data_length = entry->length;
	literal_descs[literal_index].flags = entry->ignorecase ? 1 : 0;
	memcpy(literal_data + literal_descs[literal_index].data_offset -
		   physical.literals_offset,
	       entry->bytes, entry->length);
	literal_data_offset += entry->length;
	literal_index++;
    }
    OnibiBackrefDesc *physical_backrefs =
	(OnibiBackrefDesc *)(RSTRING_PTR(blob) + physical.backrefs_offset);
    for (size_t i = 0; i < compiled_data->backrefs.count; i++) {
	const OnibiBackrefDesc *source = &compiled_data->backrefs.entries[i];
	physical_backrefs[i] = *source;
	uint64_t list_offset =
	    (uint64_t)physical.backref_lists_offset +
	    (uint64_t)source->capture_list_off * sizeof(uint32_t);
	if (list_offset > UINT32_MAX)
	    rb_raise(eRegexpError,
		     "RSeq backreference list exceeds the size limit");
	physical_backrefs[i].capture_list_off = (uint32_t)list_offset;
    }
    uint32_t *physical_backref_lists =
	(uint32_t *)(RSTRING_PTR(blob) + physical.backref_lists_offset);
    for (size_t i = 0; i < compiled_data->backref_capture_ids.count; i++)
	physical_backref_lists[i] =
	    compiled_data->backref_capture_ids.entries[i];
    OnibiSubprogramDesc *physical_subprograms =
	(OnibiSubprogramDesc *)(RSTRING_PTR(blob) +
				physical.subprograms_offset);
    for (size_t i = 0; i < subprogram_records.count; i++) {
	OnibiRSeqSubprogramEntry *record = &subprogram_records.entries[i];
	physical_subprograms[i].entry = record->entry;
	physical_subprograms[i].accept = record->accept;
	physical_subprograms[i].flags = record->flags;
	physical_subprograms[i].option_env = record->option_env;
	physical_subprograms[i].entry_edge_base =
	    record->entry_edge_count == 0
		? 0
		: (uint32_t)(r_edge_records.count + r_start_edge_records.count +
			     record->entry_edge_base);
	physical_subprograms[i].width_base = record->width_base;
	physical_subprograms[i].entry_edge_count = record->entry_edge_count;
	physical_subprograms[i].width_count = record->width_count;
	physical_subprograms[i].kind = record->kind;
	physical_subprograms[i].effects = record->effects;
	physical_subprograms[i].reserved = 0;
    }
    uint32_t *physical_widths =
	(uint32_t *)(RSTRING_PTR(blob) + physical.lookbehind_widths_offset);
    for (size_t i = 0; i < lookbehind_width_records.count; i++)
	physical_widths[i] = lookbehind_width_records.entries[i];
    rb_obj_freeze(blob);
    /* Validate once. Publish only the relocatable blob. The typed GIR vectors
	 remain compiler-owned and are released after lowering. */
    onibi_rseq_blob_validate(blob);
    onibi_rseq_lower_fail_if(owner, 7);
    if (owner->result_work) *owner->result_work = owner->lowering_work;
    onibi_rseq_hash_table_free(&owner->class_hash);
    onibi_rseq_hash_table_free(&owner->literal_hash);
    onibi_rseq_hash_table_free(&owner->action_hash);
    onibi_rseq_class_payload_vector_free(&class_payloads);
    onibi_rseq_literal_payload_vector_free(&literal_payloads);
    onibi_g_action_vector_free(&action_records);
    onibi_rseq_action_program_vector_free(&action_programs);
    onibi_rseq_edge_vector_free(&r_edge_records);
    onibi_rseq_edge_vector_free(&r_start_edge_records);
    onibi_gir_state_vector_free(&state_records);
    onibi_rseq_subprogram_vector_free(&subprogram_records);
    onibi_rseq_edge_vector_free(&subprogram_entry_records);
    onibi_id_vector_free(&lookbehind_width_records);
#undef state_records
#undef subprogram_records
#undef subprogram_entry_records
#undef lookbehind_width_records
#undef class_payloads
#undef literal_payloads
#undef action_records
#undef action_programs
#undef r_edge_records
#undef r_start_edge_records
    return blob;
}

static VALUE
onibi_rseq_lower_with_work(VALUE compiled, int failure_phase,
			   int *failure_fired,
			   OnibiAllocationAccounting *accounting,
			   OnibiLoweringWork *result_work,
			   OnibiCompileOutcome *compile_outcome)
{
    OnibiRSeqLowerOwner owner;
    memset(&owner, 0, sizeof(owner));
    onibi_allocation_owner_init(&owner.allocations, accounting);
    owner.failure_phase = failure_phase;
    owner.failure_fired = failure_fired;
    owner.compile_outcome = compile_outcome;
    owner.result_work = result_work;
    owner.allocations.failure_phase = failure_phase;
    owner.allocations.failure_fired = failure_fired;
    OnibiRSeqLowerCall call = {&owner, compiled};
    return rb_ensure(onibi_rseq_lower_body, (VALUE)(uintptr_t)&call,
		     onibi_rseq_lower_owner_ensure, (VALUE)(uintptr_t)&owner);
}

static VALUE
onibi_rseq_lower_with_failure(VALUE compiled, int failure_phase,
			      int *failure_fired,
			      OnibiAllocationAccounting *accounting)
{
    return onibi_rseq_lower_with_work(compiled, failure_phase, failure_fired,
				      accounting, NULL, NULL);
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
    OnibiLoweringWork *lowering_work;
    OnibiCompileOutcome *compile_outcome;
} OnibiProgramArgs;

static int
onibi_tokens_have_unsupported_posix(const OnibiTokenVector *tokens)
{
    for (size_t i = 0; i < tokens->count; i++) {
	const OnibiTokenRecord *token = onibi_token_at(tokens, (long)i);
	if (token->kind == ONIBI_TOKEN_POSIX_CLASS &&
	    onibi_posix_kind_id(token->name_id) == ONIBI_POSIX_UNKNOWN)
	    return 1;
    }
    return 0;
}

static int
onibi_tokens_have_nested_possessive(const OnibiTokenVector *tokens)
{
    for (size_t i = 1; i < tokens->count; i++) {
	const OnibiTokenRecord *previous = &tokens->items[i - 1];
	const OnibiTokenRecord *current = &tokens->items[i];
	if (previous->kind == ONIBI_TOKEN_QUANTIFIER &&
	    current->kind == ONIBI_TOKEN_QUANTIFIER &&
	    (current->byte == '+' || current->byte == '*'))
	    return 1;
    }
    return 0;
}

/* Apply the one compatibility decision used by initialization. A protected
 * failure can select MRI only when the compiler marked it unsupported. */
static int
onibi_compile_outcome_select_fallback(onibi_regexp_t *obj,
				      const OnibiCompileOutcome *outcome,
				      int program_state)
{
    if (outcome->error_kind != ONIBI_COMPILE_UNSUPPORTED) return 0;
    if (program_state) rb_set_errinfo(Qnil);
    obj->compile_error_kind = outcome->error_kind;
    obj->unsupported_reason = outcome->unsupported_reason;
    obj->fallback_reason = outcome->unsupported_reason;
    return 1;
}

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
    if (onibi_tokens_have_unsupported_posix(tokens)) {
	onibi_compile_outcome_unsupported(args->compile_outcome,
					  ONIBI_UNSUPPORTED_CLASS);
	rb_raise(eRegexpError, "unknown POSIX character class");
    }
    VALUE parsed = onibi_parser_parse_internal(source, options, tokens);
    VALUE compiled =
	onibi_compiler_compile_with_outcome(parsed, args->compile_outcome);
    VALUE rseq = onibi_rseq_lower_with_work(
	compiled, 0, NULL, NULL, args->lowering_work, args->compile_outcome);
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
    VALUE parsed = onibi_parser_parse_internal(source, options, tokens);
    onibi_compile_outcome_unsupported(args->compile_outcome,
				      ONIBI_UNSUPPORTED_META_ESCAPE);
    return parsed;
}

static VALUE
onibi_make_mri_regexp(VALUE argument)
{
    OnibiProgramArgs *args = (OnibiProgramArgs *)(uintptr_t)argument;
    VALUE source = args->source;
    VALUE options = args->options;
    return rb_funcall(rb_cRegexp, id_new, 2, source, options);
}

/* Compute token diagnostics and initialization metadata in one pass over the
   immutable token stream.  These bits never select an execution class. */
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
	}
	else if (kind_code == ONIBI_TOKEN_BACKREF ||
		 kind_code == ONIBI_TOKEN_ATOMIC_START ||
		 kind_code == ONIBI_TOKEN_ABSENCE_START) {
	    if (kind_code == ONIBI_TOKEN_BACKREF)
		obj->feature_flags |= ONIBI_FEATURE_BACKREF;
	    if (kind_code == ONIBI_TOKEN_ATOMIC_START)
		obj->feature_flags |= ONIBI_FEATURE_ATOMIC;
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
		}
	    }
	    if (token->byte == 'u')
		obj->feature_flags |= ONIBI_FEATURE_UNICODE_ESCAPE;
	}
	else if (kind_code == ONIBI_TOKEN_META_ESCAPE) {
	    obj->feature_flags |= ONIBI_FEATURE_META_ESCAPE;
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
    OnibiProgramArgs regexp_args = {regexp_source, INT2NUM(opts), NULL, NULL,
				    NULL};
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
    VALUE compilation_source = rb_str_dup(source);
    rb_enc_associate(compilation_source, rb_enc_get(obj->regexp));
    memset(&obj->lowering_work, 0, sizeof(obj->lowering_work));
    OnibiCompileOutcome compile_outcome = {ONIBI_COMPILE_OK,
					   ONIBI_UNSUPPORTED_NONE};
    OnibiProgramArgs program_args = {compilation_source, INT2NUM(opts), &tokens,
				     &obj->lowering_work, &compile_outcome};
    int program_state = 0;
    VALUE parsed = Qnil;
    int parse_only = (obj->feature_flags & ONIBI_FEATURE_META_ESCAPE) != 0;
    VALUE program;
    if (onibi_tokens_have_nested_possessive(&tokens)) {
	onibi_compile_outcome_unsupported(&compile_outcome,
					  ONIBI_UNSUPPORTED_POSSESSIVE);
	program_state = 1;
	program = Qnil;
    }
    else {
	program =
	    parse_only
		? rb_protect(onibi_parse_program,
			     (VALUE)(uintptr_t)&program_args, &program_state)
		: rb_protect(onibi_build_program,
			     (VALUE)(uintptr_t)&program_args, &program_state);
    }
    if (!program_state) {
	parsed = parse_only ? program : rb_ary_entry(program, 0);
	obj->rseq = parse_only ? Qnil : rb_ary_entry(program, 1);
	if (!NIL_P(parsed)) {
	    OnibiParsed *parsed_data = onibi_parsed_get(parsed);
	    obj->ast_flags = parsed_data->ast_flags;
	    /* The AST is an initialization artifact.  The published RSeq/GIR
	       objects carry all runtime data. */
	    if (parsed_data->arena.root != ONIBI_AST_NONE)
		onibi_ast_arena_free(&parsed_data->arena);
	}
	if (opts & ONIBI_OPT_NOENCODING) {
	    parsed = obj->rseq = Qnil;
	}
	if (!NIL_P(obj->rseq)) {
	    obj->rseq_blob = obj->rseq;
	    obj->rseq_view_valid =
		onibi_rseq_view_init(obj->rseq_blob, &obj->rseq_view) ? 1 : 0;
	    if (obj->rseq_view_valid) {
		onibi_rseq_view_prepare(&obj->rseq_view);
		/* The physical verifier accepted this header before
		   publication. Copy its class. Token metadata is not an
		   execution input. */
		obj->execution_kind =
		    (OnibiExecutionKind)obj->rseq_view.header->exec_kind;
	    }
	}
    }
    if (!onibi_compile_outcome_select_fallback(obj, &compile_outcome,
					       program_state) &&
	program_state) {
	onibi_token_vector_free(&tokens);
	rb_jump_tag(program_state);
    }
    onibi_token_vector_free(&tokens);
    rb_obj_freeze(self);
    return self;
}

/* Ruby's public regexp position is a character index.  The VM receives only
 * byte offsets.  Keep both values while crossing this API boundary so that a
 * byte offset never reaches an MRI character-index argument. */
typedef struct {
    long character;
    OnibiBytePos byte;
    int valid;
} OnibiRubyPosition;

static OnibiRubyPosition
onibi_ruby_position(VALUE str, VALUE position, int clamp_to_end)
{
    long character_length = rb_str_strlen(str);
    long character = NUM2LONG(position);
    OnibiRubyPosition result = {0, 0, 1};

    if (character < 0) {
	if (character < -character_length) {
	    result.valid = 0;
	    return result;
	}
	character += character_length;
    }
    else if (character > character_length) {
	if (!clamp_to_end) {
	    result.valid = 0;
	    return result;
	}
	character = character_length;
    }
    result.character = character;
    result.byte = rb_str_offset(str, character);
    return result;
}

static long
onibi_ruby_character_position(VALUE str, OnibiBytePos byte_position)
{
    return rb_str_sublen(str, byte_position);
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
    OnibiRubyPosition origin = {0, 0, 1};
    if (!NIL_P(pos)) {
	origin = onibi_ruby_position(str, pos, 1);
	if (!origin.valid) {
	    rb_backref_set(Qnil);
	    return Qnil;
	}
    }
    OnibiRawMatch raw_match = {.begin_byte = -1, .end_byte = -1};
    OnibiExecStatus search_status =
	onibi_vm_search(self, str, origin.byte, &raw_match);
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
					  LONG2NUM(origin.character));
    if (NIL_P(match)) return Qnil;
    return rb_block_given_p() ? rb_yield(match) : match;
}

static VALUE
onibi_match_p(int argc, VALUE *argv, VALUE self)
{
    VALUE str, pos = Qnil;
    rb_scan_args(argc, argv, "11", &str, &pos);
    if (argc == 2 && NIL_P(pos))
	rb_raise(rb_eTypeError, "no implicit conversion from nil to integer");
    if (argc == 2 && RB_TYPE_P(pos, T_STRING))
	rb_raise(rb_eTypeError,
		 "no implicit conversion of String into Integer");
    if (SYMBOL_P(str)) str = rb_sym2str(str);
    if (NIL_P(str)) {
	if (argc == 1) return Qfalse;
	(void)NUM2LONG(pos);
	return Qfalse;
    }
    if (!RB_TYPE_P(str, T_STRING)) StringValue(str);
    {
	OnibiRubyPosition origin = {0, 0, 1};
	if (!NIL_P(pos)) {
	    origin = onibi_ruby_position(str, pos, 0);
	    if (!origin.valid) return Qfalse;
	}
	OnibiRawMatch raw_match = {.begin_byte = -1, .end_byte = -1};
	OnibiExecStatus result =
	    onibi_vm_search(self, str, origin.byte, &raw_match);
	if (result == ONIBI_EXEC_STATUS_MATCH ||
	    result == ONIBI_EXEC_STATUS_NO_MATCH)
	    return result == ONIBI_EXEC_STATUS_MATCH ? Qtrue : Qfalse;
	if (result == ONIBI_EXEC_STATUS_INTERNAL_ERROR)
	    rb_raise(eRegexpError, "Onibi execution failed");
	if (result == ONIBI_EXEC_STATUS_FALLBACK) {
	    onibi_regexp_t *obj;
	    TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
	    ID id_match_question = rb_intern_const("match?");
	    return NIL_P(pos)
		       ? rb_funcall(obj->regexp, id_match_question, 1, str)
		       : rb_funcall(obj->regexp, id_match_question, 2, str,
				    LONG2NUM(origin.character));
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
    if (!NIL_P(obj->rseq) && obj->rseq_view_valid)
	return obj->execution_kind == ONIBI_EXEC_DYNAMIC ? Qfalse : Qtrue;

    /* Unsupported compilation stays at the MRI compatibility boundary.  The
     * native Regexp class owns linear_time? semantics for that path. */
    return rb_funcall(rb_cRegexp, rb_intern_const("linear_time?"), 1,
		      obj->regexp);
}
