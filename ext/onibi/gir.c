/* GIR builder, fragment records, and mutable graph construction. */
typedef struct {
    OnibiIdVector starts;
    OnibiIdVector exits;
    VALUE start_actions;
    VALUE pending_actions;
    int nullable;
    int lazy;
} onibi_fragment_t;
typedef struct {
    OnibiStateId state;
    OnibiValueVector actions;
    uint32_t action_count;
} OnibiGuardEntry;
typedef struct {
    OnibiGuardEntry *entries;
    size_t count;
    size_t capacity;
} OnibiGuardVector;
typedef struct {
    VALUE key;
    VALUE value;
} OnibiValueEntry;
typedef struct {
    OnibiValueEntry *entries;
    size_t count;
    size_t capacity;
} OnibiValueMap;
typedef struct {
    long id;
    ID op;
    OnibiGStateOp opcode;
    VALUE payload;
    uint32_t payload_index;
} OnibiGirStateEntry;
typedef struct {
    OnibiGirStateEntry *entries;
    size_t count;
    size_t capacity;
} OnibiGirStateVector;
typedef struct {
    long from;
    long to;
    long action_offset;
    uint32_t action_count;
    VALUE actions;
} OnibiGirEdgeEntry;
typedef struct {
    OnibiGirEdgeEntry *entries;
    size_t count;
    size_t capacity;
} OnibiGirEdgeVector;
typedef struct {
    VALUE value;
    OnibiGActionOp code;
    uint8_t physical_op;
    uint8_t set;
    uint8_t positive;
    uint8_t has_slot;
    uint16_t slot;
    uint8_t has_assert_kind;
    uint16_t assert_kind;
    uint8_t has_arg32;
    uint32_t arg32;
} OnibiGAction;
typedef struct {
    OnibiGAction *entries;
    size_t count;
    size_t capacity;
} OnibiGActionVector;
typedef struct {
    VALUE payload;
    VALUE bitmap;
    int negated;
} OnibiRSeqClassPayloadEntry;
typedef struct {
    OnibiRSeqClassPayloadEntry *entries;
    size_t count;
    size_t capacity;
} OnibiRSeqClassPayloadVector;
typedef struct {
    VALUE payload;
    int byte;
    int ignorecase;
} OnibiRSeqLiteralPayloadEntry;
typedef struct {
    OnibiRSeqLiteralPayloadEntry *entries;
    size_t count;
    size_t capacity;
} OnibiRSeqLiteralPayloadVector;
typedef struct {
    VALUE descriptor;
    OnibiStateId entry;
    OnibiStateId accept;
    uint32_t flags;
} OnibiRSeqSubprogramEntry;
typedef struct {
    OnibiRSeqSubprogramEntry *entries;
    size_t count;
    size_t capacity;
} OnibiRSeqSubprogramVector;
typedef struct {
    OnibiGirStateVector states;
    OnibiGirEdgeVector edges;
    long next_id;
    long capture_count;
    long counter_count;
    OnibiValueMap capture_names;
    OnibiValueMap capture_bodies;
    OnibiValueMap capture_ids;
    OnibiGuardVector capture_guards;
    OnibiGuardVector exit_guards;
    OnibiValueMap active_subroutines;
    OnibiValueVector subprograms;
    OnibiValueMap subprogram_ids;
    VALUE map_roots;
    OnibiAstArena *ast;
    int ignorecase;
    int multiline;
    int optional_seen;
} onibi_gir_builder_t;
static void onibi_append_values(VALUE destination, VALUE values);

static void
onibi_id_vector_init(OnibiIdVector *vector)
{
    vector->items = NULL;
    vector->count = 0;
    vector->capacity = 0;
}

static void
onibi_id_vector_push(OnibiIdVector *vector, OnibiStateId value)
{
    if (vector->count == vector->capacity) {
	size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
	if (next > SIZE_MAX / sizeof(*vector->items))
	    rb_raise(rb_eNoMemError, "GIR state vector is too large");
	vector->items = REALLOC_N(vector->items, OnibiStateId, next);
	vector->capacity = next;
    }
    vector->items[vector->count++] = value;
}

static void
onibi_id_vector_free(OnibiIdVector *vector)
{
    xfree(vector->items);
    vector->items = NULL;
    vector->count = vector->capacity = 0;
}

static void
onibi_id_vector_move(OnibiIdVector *destination, OnibiIdVector *source)
{
    onibi_id_vector_free(destination);
    *destination = *source;
    onibi_id_vector_init(source);
}

static void
onibi_id_vector_append(OnibiIdVector *destination, const OnibiIdVector *source)
{
    for (size_t i = 0; i < source->count; i++)
	onibi_id_vector_push(destination, source->items[i]);
}

static void
onibi_id_vector_single(OnibiIdVector *vector, OnibiStateId value)
{
    onibi_id_vector_init(vector);
    onibi_id_vector_push(vector, value);
}

static void
onibi_value_vector_init(OnibiValueVector *vector)
{
    vector->items = NULL;
    vector->count = 0;
    vector->capacity = 0;
}

static void
onibi_value_vector_reserve(OnibiValueVector *vector, size_t additional)
{
    if (additional > SIZE_MAX - vector->count)
	rb_raise(rb_eNoMemError, "value vector is too large");
    size_t required = vector->count + additional;
    if (required <= vector->capacity) return;
    size_t next = vector->capacity == 0 ? 8 : vector->capacity;
    while (next < required) {
	if (next > SIZE_MAX / 2) {
	    next = required;
	    break;
	}
	next *= 2;
    }
    if (next > SIZE_MAX / sizeof(*vector->items))
	rb_raise(rb_eNoMemError, "value vector is too large");
    vector->items = REALLOC_N(vector->items, VALUE, next);
    vector->capacity = next;
}

static void
onibi_value_vector_push(OnibiValueVector *vector, VALUE value, VALUE roots)
{
    onibi_value_vector_reserve(vector, 1);
    vector->items[vector->count++] = value;
    rb_ary_push(roots, value);
}

static void
onibi_value_vector_store(OnibiValueVector *vector, size_t index, VALUE value,
			 VALUE roots)
{
    if (index >= vector->count)
	rb_raise(rb_eArgError, "value vector index is out of range");
    vector->items[index] = value;
    rb_ary_push(roots, value);
}

static void
onibi_value_vector_free(OnibiValueVector *vector)
{
    xfree(vector->items);
    vector->items = NULL;
    vector->count = vector->capacity = 0;
}

static void
onibi_value_vector_append_array(OnibiValueVector *destination, VALUE source,
				VALUE roots)
{
    long count = RARRAY_LEN(source);
    onibi_value_vector_reserve(destination, (size_t)count);
    for (long i = 0; i < count; i++)
	onibi_value_vector_push(destination, rb_ary_entry(source, i), roots);
}

static void
onibi_append_vector_values(VALUE destination, const OnibiValueVector *source)
{
    for (size_t i = 0; i < source->count; i++)
	rb_ary_push(destination, source->items[i]);
}

static void
onibi_guard_vector_init(OnibiGuardVector *vector)
{
    vector->entries = NULL;
    vector->count = 0;
    vector->capacity = 0;
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
		       VALUE actions, VALUE roots)
{
    long incoming = RARRAY_LEN(actions);
    if ((uint64_t)incoming > UINT32_MAX)
	rb_raise(rb_eArgError, "GIR guard action list is too large");
    for (size_t i = 0; i < vector->count; i++) {
	if (vector->entries[i].state == state) {
	    if (vector->entries[i].action_count >
		UINT32_MAX - (uint32_t)incoming)
		rb_raise(rb_eArgError, "GIR guard action list is too large");
	    onibi_value_vector_append_array(&vector->entries[i].actions,
					    actions, roots);
	    vector->entries[i].action_count =
		(uint32_t)vector->entries[i].actions.count;
	    return;
	}
    }
    if (vector->count == vector->capacity) {
	size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
	if (next > SIZE_MAX / sizeof(*vector->entries))
	    rb_raise(rb_eNoMemError, "GIR guard vector is too large");
	vector->entries = REALLOC_N(vector->entries, OnibiGuardEntry, next);
	vector->capacity = next;
    }
    vector->entries[vector->count].state = state;
    onibi_value_vector_init(&vector->entries[vector->count].actions);
    onibi_value_vector_append_array(&vector->entries[vector->count].actions,
				    actions, roots);
    vector->entries[vector->count].action_count =
	(uint32_t)vector->entries[vector->count].actions.count;
    vector->count++;
}

static void
onibi_guard_vector_add_values(OnibiGuardVector *vector, OnibiStateId state,
			      const OnibiValueVector *actions)
{
    if (actions->count > UINT32_MAX)
	rb_raise(rb_eArgError, "GIR guard action list is too large");
    for (size_t i = 0; i < vector->count; i++) {
	if (vector->entries[i].state == state) {
	    if (vector->entries[i].action_count >
		UINT32_MAX - (uint32_t)actions->count)
		rb_raise(rb_eArgError, "GIR guard action list is too large");
	    onibi_value_vector_reserve(&vector->entries[i].actions,
				       actions->count);
	    memcpy(vector->entries[i].actions.items +
		       vector->entries[i].actions.count,
		   actions->items, sizeof(VALUE) * actions->count);
	    vector->entries[i].actions.count += actions->count;
	    vector->entries[i].action_count =
		(uint32_t)vector->entries[i].actions.count;
	    return;
	}
    }
    if (vector->count == vector->capacity) {
	size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
	if (next > SIZE_MAX / sizeof(*vector->entries))
	    rb_raise(rb_eNoMemError, "GIR guard vector is too large");
	vector->entries = REALLOC_N(vector->entries, OnibiGuardEntry, next);
	vector->capacity = next;
    }
    OnibiGuardEntry *entry = &vector->entries[vector->count++];
    entry->state = state;
    onibi_value_vector_init(&entry->actions);
    onibi_value_vector_reserve(&entry->actions, actions->count);
    memcpy(entry->actions.items, actions->items,
	   sizeof(VALUE) * actions->count);
    entry->actions.count = actions->count;
    entry->action_count = (uint32_t)actions->count;
}

static void
onibi_guard_vector_free(OnibiGuardVector *vector)
{
    for (size_t i = 0; i < vector->count; i++)
	onibi_value_vector_free(&vector->entries[i].actions);
    xfree(vector->entries);
    vector->entries = NULL;
    vector->count = vector->capacity = 0;
}

static void
onibi_value_map_init(OnibiValueMap *map)
{
    map->entries = NULL;
    map->count = 0;
    map->capacity = 0;
}

static int
onibi_value_map_key_equal(VALUE left, VALUE right)
{
    return left == right || RTEST(rb_equal(left, right));
}

static VALUE
onibi_value_map_find(const OnibiValueMap *map, VALUE key)
{
    for (size_t i = 0; i < map->count; i++)
	if (onibi_value_map_key_equal(map->entries[i].key, key))
	    return map->entries[i].value;
    return Qnil;
}

static void
onibi_value_map_reserve(OnibiValueMap *map, size_t additional)
{
    if (additional > SIZE_MAX - map->count)
	rb_raise(rb_eNoMemError, "GIR value map is too large");
    size_t required = map->count + additional;
    if (required <= map->capacity) return;
    size_t next = map->capacity == 0 ? 8 : map->capacity;
    while (next < required) {
	if (next > SIZE_MAX / 2) {
	    next = required;
	    break;
	}
	next *= 2;
    }
    if (next > SIZE_MAX / sizeof(*map->entries))
	rb_raise(rb_eNoMemError, "GIR value map is too large");
    map->entries = REALLOC_N(map->entries, OnibiValueEntry, next);
    map->capacity = next;
}

static void
onibi_value_map_set(OnibiValueMap *map, VALUE key, VALUE value, VALUE roots)
{
    for (size_t i = 0; i < map->count; i++) {
	if (onibi_value_map_key_equal(map->entries[i].key, key)) {
	    map->entries[i].value = value;
	    rb_ary_push(roots, value);
	    return;
	}
    }
    onibi_value_map_reserve(map, 1);
    map->entries[map->count].key = key;
    map->entries[map->count].value = value;
    rb_ary_push(roots, key);
    rb_ary_push(roots, value);
    map->count++;
}

static void
onibi_value_map_delete(OnibiValueMap *map, VALUE key)
{
    for (size_t i = 0; i < map->count; i++) {
	if (onibi_value_map_key_equal(map->entries[i].key, key)) {
	    map->entries[i] = map->entries[--map->count];
	    return;
	}
    }
}

static void
onibi_value_map_free(OnibiValueMap *map)
{
    xfree(map->entries);
    map->entries = NULL;
    map->count = map->capacity = 0;
}

static void
onibi_gir_state_vector_init(OnibiGirStateVector *vector)
{
    vector->entries = NULL;
    vector->count = 0;
    vector->capacity = 0;
}

static void
onibi_gir_state_vector_push(OnibiGirStateVector *vector,
			    OnibiGirStateEntry entry, VALUE roots)
{
    if (vector->count == vector->capacity) {
	size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
	if (next > SIZE_MAX / sizeof(*vector->entries))
	    rb_raise(rb_eNoMemError, "GIR state vector is too large");
	vector->entries = REALLOC_N(vector->entries, OnibiGirStateEntry, next);
	vector->capacity = next;
    }
    vector->entries[vector->count++] = entry;
    rb_ary_push(roots, entry.payload);
}

static void
onibi_gir_edge_vector_init(OnibiGirEdgeVector *vector)
{
    vector->entries = NULL;
    vector->count = 0;
    vector->capacity = 0;
}

static void
onibi_gir_edge_vector_push(OnibiGirEdgeVector *vector, OnibiGirEdgeEntry entry,
			   VALUE roots)
{
    if (vector->count == vector->capacity) {
	size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
	if (next > SIZE_MAX / sizeof(*vector->entries))
	    rb_raise(rb_eNoMemError, "GIR edge vector is too large");
	vector->entries = REALLOC_N(vector->entries, OnibiGirEdgeEntry, next);
	vector->capacity = next;
    }
    vector->entries[vector->count++] = entry;
    rb_ary_push(roots, entry.actions);
}

static void
onibi_gir_edge_vector_insert(OnibiGirEdgeVector *vector, size_t index,
			     OnibiGirEdgeEntry entry, VALUE roots)
{
    if (index > vector->count) index = vector->count;
    if (vector->count == vector->capacity) {
	size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
	if (next > SIZE_MAX / sizeof(*vector->entries))
	    rb_raise(rb_eNoMemError, "GIR edge vector is too large");
	vector->entries = REALLOC_N(vector->entries, OnibiGirEdgeEntry, next);
	vector->capacity = next;
    }
    memmove(&vector->entries[index + 1], &vector->entries[index],
	    (vector->count - index) * sizeof(*vector->entries));
    vector->entries[index] = entry;
    vector->count++;
    rb_ary_push(roots, entry.actions);
}

static void
onibi_gir_edge_vector_group_by_from(OnibiGirEdgeVector *vector,
				    size_t state_count)
{
    if (vector->count < 2) return;
    for (size_t i = 0; i < vector->count; i++) {
	if (vector->entries[i].from < 0 ||
	    (size_t)vector->entries[i].from >= state_count)
	    rb_raise(rb_eArgError, "RSeq edge source is out of range");
    }
    if (state_count > SIZE_MAX / sizeof(size_t) ||
	vector->count > SIZE_MAX / sizeof(*vector->entries))
	rb_raise(rb_eNoMemError, "RSeq edge index is too large");
    size_t *counts = ALLOC_N(size_t, state_count);
    size_t *next = ALLOC_N(size_t, state_count);
    OnibiGirEdgeEntry *ordered = ALLOC_N(OnibiGirEdgeEntry, vector->count);
    memset(counts, 0, sizeof(*counts) * state_count);
    for (size_t i = 0; i < vector->count; i++)
	counts[vector->entries[i].from]++;
    size_t offset = 0;
    for (size_t i = 0; i < state_count; i++) {
	next[i] = offset;
	offset += counts[i];
    }
    for (size_t i = 0; i < vector->count; i++) {
	size_t from = (size_t)vector->entries[i].from;
	ordered[next[from]++] = vector->entries[i];
    }
    xfree(counts);
    xfree(next);
    xfree(vector->entries);
    vector->entries = ordered;
    vector->capacity = vector->count;
}

static void
onibi_gir_state_vector_free(OnibiGirStateVector *vector)
{
    xfree(vector->entries);
    vector->entries = NULL;
    vector->count = vector->capacity = 0;
}
static void
onibi_gir_edge_vector_free(OnibiGirEdgeVector *vector)
{
    xfree(vector->entries);
    vector->entries = NULL;
    vector->count = vector->capacity = 0;
}

static void
onibi_rseq_action_vector_init(OnibiGActionVector *vector)
{
    vector->entries = NULL;
    vector->count = vector->capacity = 0;
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
		     : ONIBI_RA_END);
}
static void
onibi_rseq_action_vector_push(OnibiGActionVector *vector, VALUE value)
{
    if (vector->count == vector->capacity) {
	size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
	if (next > SIZE_MAX / sizeof(*vector->entries))
	    rb_raise(rb_eNoMemError, "RSeq action vector is too large");
	vector->entries = REALLOC_N(vector->entries, OnibiGAction, next);
	vector->capacity = next;
    }
    VALUE slot = onibi_hash_value_id(value, id_key_slot);
    VALUE width = onibi_hash_value_id(value, id_key_width);
    VALUE limit = onibi_hash_value_id(value, id_key_limit);
    VALUE arg_value = onibi_hash_value_id(value, id_key_value);
    VALUE assert_kind = onibi_hash_value_id(value, id_key_assert_kind);
    VALUE arg32 = !NIL_P(width) ? width : (!NIL_P(limit) ? limit : arg_value);
    OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(
	onibi_hash_value_id(value, id_key_action_code));
    vector->entries[vector->count++] = (OnibiGAction){
	value,
	code,
	onibi_rseq_physical_action_op(code),
	RTEST(onibi_hash_value_id(value, id_key_set)) ? 1 : 0,
	RTEST(onibi_hash_value_id(value, id_key_positive)) ? 1 : 0,
	NIL_P(slot) ? 0 : 1,
	NIL_P(slot) ? 0 : (uint16_t)NUM2ULONG(slot),
	NIL_P(assert_kind) ? 0 : 1,
	NIL_P(assert_kind) ? 0 : (uint16_t)NUM2ULONG(assert_kind),
	NIL_P(arg32) ? 0 : 1,
	NIL_P(arg32) ? 0 : (uint32_t)NUM2ULONG(arg32)};
}
static void
onibi_rseq_action_vector_free(OnibiGActionVector *vector)
{
    xfree(vector->entries);
    vector->entries = NULL;
    vector->count = vector->capacity = 0;
}
static void
onibi_rseq_class_payload_vector_init(OnibiRSeqClassPayloadVector *vector)
{
    vector->entries = NULL;
    vector->count = vector->capacity = 0;
}
static void
onibi_rseq_class_payload_vector_push(OnibiRSeqClassPayloadVector *vector,
				     VALUE payload)
{
    if (vector->count == vector->capacity) {
	size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
	if (next > SIZE_MAX / sizeof(*vector->entries))
	    rb_raise(rb_eNoMemError, "RSeq class payload vector is too large");
	vector->entries =
	    REALLOC_N(vector->entries, OnibiRSeqClassPayloadEntry, next);
	vector->capacity = next;
    }
    vector->entries[vector->count++] = (OnibiRSeqClassPayloadEntry){
	payload, onibi_hash_value_id(payload, id_key_bitmap),
	RTEST(onibi_hash_value_id(payload, id_key_negated))};
}
static void
onibi_rseq_class_payload_vector_free(OnibiRSeqClassPayloadVector *vector)
{
    xfree(vector->entries);
    vector->entries = NULL;
    vector->count = vector->capacity = 0;
}
static void
onibi_rseq_literal_payload_vector_init(OnibiRSeqLiteralPayloadVector *vector)
{
    vector->entries = NULL;
    vector->count = vector->capacity = 0;
}
static void
onibi_rseq_literal_payload_vector_push(OnibiRSeqLiteralPayloadVector *vector,
				       VALUE payload)
{
    if (vector->count == vector->capacity) {
	size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
	if (next > SIZE_MAX / sizeof(*vector->entries))
	    rb_raise(rb_eNoMemError,
		     "RSeq literal payload vector is too large");
	vector->entries =
	    REALLOC_N(vector->entries, OnibiRSeqLiteralPayloadEntry, next);
	vector->capacity = next;
    }
    vector->entries[vector->count++] = (OnibiRSeqLiteralPayloadEntry){
	payload, NUM2INT(onibi_hash_value_id(payload, id_key_byte)),
	RTEST(onibi_hash_value_id(payload, id_key_ignorecase))};
}
static void
onibi_rseq_literal_payload_vector_free(OnibiRSeqLiteralPayloadVector *vector)
{
    xfree(vector->entries);
    vector->entries = NULL;
    vector->count = vector->capacity = 0;
}
static void
onibi_rseq_subprogram_vector_init(OnibiRSeqSubprogramVector *vector)
{
    vector->entries = NULL;
    vector->count = vector->capacity = 0;
}
static void
onibi_rseq_subprogram_vector_push(OnibiRSeqSubprogramVector *vector,
				  VALUE descriptor)
{
    if (vector->count == vector->capacity) {
	size_t next = vector->capacity == 0 ? 4 : vector->capacity * 2;
	if (next > SIZE_MAX / sizeof(*vector->entries))
	    rb_raise(rb_eNoMemError, "RSeq subprogram vector is too large");
	vector->entries =
	    REALLOC_N(vector->entries, OnibiRSeqSubprogramEntry, next);
	vector->capacity = next;
    }
    vector->entries[vector->count++] = (OnibiRSeqSubprogramEntry){
	descriptor,
	(OnibiStateId)NUM2ULONG(onibi_hash_value_id(descriptor, id_key_entry)),
	(OnibiStateId)NUM2ULONG(onibi_hash_value_id(descriptor, id_key_accept)),
	(uint32_t)NUM2ULONG(onibi_hash_value_id(descriptor, id_key_flags))};
}
static void
onibi_rseq_subprogram_vector_free(OnibiRSeqSubprogramVector *vector)
{
    xfree(vector->entries);
    vector->entries = NULL;
    vector->count = vector->capacity = 0;
}
static void
onibi_bitmap_set(unsigned char *bits, unsigned char value, int fold)
{
    bits[value >> 3] |= (unsigned char)(1U << (value & 7));
    if (fold) {
	unsigned char lower = (unsigned char)tolower(value);
	unsigned char upper = (unsigned char)toupper(value);
	bits[lower >> 3] |= (unsigned char)(1U << (lower & 7));
	bits[upper >> 3] |= (unsigned char)(1U << (upper & 7));
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

static VALUE
onibi_class_bitmap(VALUE payload, int fold)
{
    unsigned char bits[32];
    memset(bits, 0, sizeof(bits));
    if (onibi_ast_kind(payload) == ONIBI_AST_CLASS_INTERSECTION) {
	VALUE operands = onibi_hash_value_id(payload, id_key_operands);
	if (!RB_TYPE_P(operands, T_ARRAY) || RARRAY_LEN(operands) < 2)
	    rb_raise(eRegexpError, "class intersection has no operands");
	/* Set intersection is defined before case folding.  Folding each
	   operand first would turn [a-z&&A-Z] into [a-z]. */
	VALUE first = onibi_class_bitmap(rb_ary_entry(operands, 0), 0);
	memcpy(bits, RSTRING_PTR(first), sizeof(bits));
	for (long i = 1; i < RARRAY_LEN(operands); i++) {
	    VALUE next = onibi_class_bitmap(rb_ary_entry(operands, i), 0);
	    for (long byte = 0; byte < 32; byte++)
		bits[byte] &= (unsigned char)RSTRING_PTR(next)[byte];
	}
	if (fold) {
	    unsigned char original[32];
	    memcpy(original, bits, sizeof(original));
	    for (int c = 0; c < 256; c++) {
		if ((original[c >> 3] & (1U << (c & 7))) != 0)
		    onibi_bitmap_set(bits, (unsigned char)c, 1);
	    }
	}
	VALUE result = rb_str_new((const char *)bits, sizeof(bits));
	rb_obj_freeze(result);
	return result;
    }
    VALUE ranges = onibi_hash_value_id(payload, id_key_ranges);
    VALUE escape_name = onibi_hash_value_id(payload, id_key_name);
    ID escape_name_id = onibi_token_name_id(payload);
    if (!NIL_P(escape_name) && RSTRING_LEN(escape_name) == 1) {
	int upper = isupper((unsigned char)RSTRING_PTR(escape_name)[0]);
	int code = tolower((unsigned char)RSTRING_PTR(escape_name)[0]);
	for (int c = 0; c < 256; c++) {
	    int hit =
		code == 'd'
		    ? isdigit(c)
		    : (code == 's'
			   ? isspace(c)
			   : (code == 'w' ? (isalnum(c) || c == '_')
					  : (code == 'h' ? isxdigit(c) : 0)));
	    if (upper ? !hit : hit)
		onibi_bitmap_set(bits, (unsigned char)c, fold);
	}
    }
    else {
	OnibiAsciiProperty property_kind =
	    escape_name_id == 0 ? ONIBI_ASCII_PROP_UNKNOWN
				: onibi_ascii_property_kind_id(escape_name_id);
	if (property_kind == ONIBI_ASCII_PROP_UNKNOWN) goto class_children;
	for (int c = 0; c < 256; c++) {
	    int hit = onibi_ascii_property_hit_kind(property_kind, c);
	    if (hit > 0) onibi_bitmap_set(bits, (unsigned char)c, fold);
	}
	if (NUM2INT(onibi_hash_value_id(payload, id_key_byte)) == 'P')
	    for (long i = 0; i < 32; i++)
		bits[i] = (unsigned char)~bits[i];
    }
class_children:
    for (long i = 0; i < RARRAY_LEN(ranges); i++) {
	VALUE range = rb_ary_entry(ranges, i);
	if (RARRAY_LEN(range) != 2) continue;
	if (!RB_INTEGER_TYPE_P(rb_ary_entry(range, 0)) ||
	    !RB_INTEGER_TYPE_P(rb_ary_entry(range, 1)))
	    continue;
	int first = NUM2INT(rb_ary_entry(range, 0));
	int last = NUM2INT(rb_ary_entry(range, 1));
	if (first < 0) first = 0;
	if (last > 255) last = 255;
	for (int c = first; c <= last; c++)
	    onibi_bitmap_set(bits, (unsigned char)c, fold);
    }
    VALUE children = onibi_hash_value_id(payload, id_key_children);
    for (long i = 0; i < RARRAY_LEN(children); i++) {
	VALUE child = rb_ary_entry(children, i);
	OnibiTokenKind token_kind = onibi_token_kind_code(child);
	OnibiAstKind ast_kind = onibi_ast_kind(child);
	if (token_kind == ONIBI_TOKEN_LITERAL ||
	    ast_kind == ONIBI_AST_LITERAL) {
	    onibi_bitmap_set(
		bits,
		(unsigned char)NUM2INT(onibi_hash_value_id(child, id_key_byte)),
		fold);
	}
	else if (token_kind == ONIBI_TOKEN_ESCAPE ||
		 token_kind == ONIBI_TOKEN_META_ESCAPE ||
		 ast_kind == ONIBI_AST_ESCAPE) {
	    VALUE name = onibi_hash_value_id(child, id_key_name);
	    ID name_id = onibi_token_name_id(child);
	    VALUE child_byte_value = onibi_hash_value_id(child, id_key_byte);
	    OnibiAsciiProperty property_kind =
		name_id == 0 ? ONIBI_ASCII_PROP_UNKNOWN
			     : onibi_ascii_property_kind_id(name_id);
	    if (property_kind != ONIBI_ASCII_PROP_UNKNOWN) {
		for (int c = 0; c < 256; c++) {
		    int hit = onibi_ascii_property_hit_kind(property_kind, c);
		    if (hit > 0) onibi_bitmap_set(bits, (unsigned char)c, fold);
		}
		if (!NIL_P(child_byte_value) &&
		    NUM2INT(child_byte_value) == 'P')
		    for (long byte = 0; byte < 32; byte++)
			bits[byte] = (unsigned char)~bits[byte];
		continue;
	    }
	    int escape_code =
		NIL_P(name)
		    ? tolower((unsigned char)NUM2INT(child_byte_value))
		    : (RSTRING_LEN(name) == 1
			   ? tolower((unsigned char)RSTRING_PTR(name)[0])
			   : 0);
	    if (escape_code == 'r' || escape_code == 'p' ||
		escape_code == 'x' || escape_code == 'u')
		rb_raise(eRegexpError, "escape is not supported in RSeq class");
	    int upper = NIL_P(name)
			    ? isupper((unsigned char)NUM2INT(child_byte_value))
			    : (RSTRING_LEN(name) == 1 &&
			       isupper((unsigned char)RSTRING_PTR(name)[0]));
	    int code = escape_code;
	    for (int c = 0; c < 256; c++) {
		int hit = code == 'd'
			      ? isdigit(c)
			      : (code == 's'
				     ? isspace(c)
				     : (code == 'w'
					    ? (isalnum(c) || c == '_')
					    : (code == 'h' ? isxdigit(c) : 0)));
		if (upper ? !hit : hit)
		    onibi_bitmap_set(bits, (unsigned char)c, fold);
	    }
	}
	else if (token_kind == ONIBI_TOKEN_POSIX_CLASS) {
	    VALUE name_id = onibi_hash_value_id(child, id_key_name_id);
	    ID property = NIL_P(name_id) ? 0 : (ID)NUM2ULONG(name_id);
	    OnibiPosixKind posix = onibi_posix_kind_id(property);
	    for (int c = 0; c < 256; c++) {
		int hit = posix == ONIBI_POSIX_ALPHA   ? isalpha(c)
			  : posix == ONIBI_POSIX_DIGIT ? isdigit(c)
			  : posix == ONIBI_POSIX_ALNUM ? isalnum(c)
			  : posix == ONIBI_POSIX_SPACE ? isspace(c)
			  : posix == ONIBI_POSIX_BLANK ? (c == ' ' || c == '\t')
			  : posix == ONIBI_POSIX_LOWER ? islower(c)
			  : posix == ONIBI_POSIX_UPPER ? isupper(c)
			  : posix == ONIBI_POSIX_WORD ? (isalnum(c) || c == '_')
			  : posix == ONIBI_POSIX_XDIGIT ? isxdigit(c)
							: 0;
		if (hit) onibi_bitmap_set(bits, (unsigned char)c, fold);
	    }
	}
	else if (ast_kind == ONIBI_AST_CHARACTER_CLASS ||
		 ast_kind == ONIBI_AST_CLASS_INTERSECTION) {
	    VALUE nested = onibi_class_bitmap(child, fold);
	    for (long byte = 0; byte < 32; byte++)
		bits[byte] |= (unsigned char)RSTRING_PTR(nested)[byte];
	}
    }
    if (RTEST(onibi_hash_value_id(payload, id_key_negated)))
	for (long i = 0; i < 32; i++)
	    bits[i] = (unsigned char)~bits[i];
    VALUE bitmap = rb_str_new((const char *)bits, sizeof(bits));
    rb_obj_freeze(bitmap);
    return bitmap;
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

static void
onibi_gir_state(onibi_gir_builder_t *builder, long id, ID op, VALUE payload)
{
    OnibiGStateOp opcode = op == id_g_accept	 ? ONIBI_G_ACCEPT
			   : op == id_g_char	 ? ONIBI_G_CHAR
			   : op == id_g_class	 ? ONIBI_G_CLASS
			   : op == id_g_any	 ? ONIBI_G_ANY
			   : op == id_g_grapheme ? ONIBI_G_GRAPHEME
			   : op == id_g_backref	 ? ONIBI_G_BACKREF
			   : op == id_g_call	 ? ONIBI_G_CALL
			   : op == id_g_atomic	 ? ONIBI_G_ATOMIC
			   : op == id_g_absent	 ? ONIBI_G_ABSENT
						 : (OnibiGStateOp)-1;
    onibi_gir_state_vector_push(
	&builder->states, (OnibiGirStateEntry){id, op, opcode, payload, 0},
	builder->map_roots);
}

static VALUE
onibi_gir_compose_edge_actions(onibi_gir_builder_t *builder, long from, long to,
			       VALUE explicit_actions)
{
    const OnibiGuardEntry *capture_guard = onibi_guard_vector_find_entry(
	&builder->capture_guards, (OnibiStateId)to);
    const OnibiGuardEntry *exit_guard = onibi_guard_vector_find_entry(
	&builder->exit_guards, (OnibiStateId)from);
    uint32_t capture_count = capture_guard ? capture_guard->action_count : 0;
    uint32_t exit_count = exit_guard ? exit_guard->action_count : 0;
    uint64_t action_count = (uint64_t)exit_count +
			    (uint64_t)RARRAY_LEN(explicit_actions) +
			    (uint64_t)capture_count;
    if (action_count > LONG_MAX)
	rb_raise(rb_eArgError, "GIR edge action list is too large");
    if (action_count == 0) return onibi_empty_actions;
    VALUE actions = rb_ary_new_capa((long)action_count);
    if (exit_guard) onibi_append_vector_values(actions, &exit_guard->actions);
    onibi_append_values(actions, explicit_actions);
    if (capture_guard)
	onibi_append_vector_values(actions, &capture_guard->actions);
    return actions;
}

static void
onibi_gir_edge(onibi_gir_builder_t *builder, long from, long to)
{
    VALUE actions =
	onibi_gir_compose_edge_actions(builder, from, to, onibi_empty_actions);
    onibi_gir_edge_vector_push(
	&builder->edges,
	(OnibiGirEdgeEntry){from, to, 0, (uint32_t)RARRAY_LEN(actions),
			    actions},
	builder->map_roots);
}

static void
onibi_gir_edge_actions(onibi_gir_builder_t *builder, long from, long to,
		       VALUE actions)
{
    const OnibiGuardEntry *capture_guard = onibi_guard_vector_find_entry(
	&builder->capture_guards, (OnibiStateId)to);
    const OnibiGuardEntry *exit_guard = onibi_guard_vector_find_entry(
	&builder->exit_guards, (OnibiStateId)from);
    uint32_t capture_count = capture_guard ? capture_guard->action_count : 0;
    uint32_t exit_count = exit_guard ? exit_guard->action_count : 0;
    for (size_t i = 0; i < builder->edges.count; i++) {
	OnibiGirEdgeEntry *prior = &builder->edges.entries[i];
	if (prior->from == from && prior->to == to) {
	    VALUE prior_actions = prior->actions;
	    uint64_t guard_count =
		(uint64_t)exit_count + (uint64_t)capture_count;
	    if ((uint64_t)prior->action_count < guard_count)
		rb_raise(rb_eArgError, "GIR edge guard layout is invalid");
	    long prior_explicit_count =
		(long)((uint64_t)prior->action_count - guard_count);
	    uint64_t explicit_count =
		(uint64_t)RARRAY_LEN(actions) + (uint64_t)prior_explicit_count;
	    if (explicit_count > LONG_MAX)
		rb_raise(rb_eArgError, "GIR edge action list is too large");
	    VALUE explicit_actions =
		explicit_count == 0 ? onibi_empty_actions
				    : rb_ary_new_capa((long)explicit_count);
	    onibi_append_values(explicit_actions, actions);
	    for (long j = 0; j < prior_explicit_count; j++)
		rb_ary_push(explicit_actions,
			    rb_ary_entry(prior_actions, (long)exit_count + j));
	    VALUE merged_actions = onibi_gir_compose_edge_actions(
		builder, from, to, explicit_actions);
	    prior->actions = merged_actions;
	    prior->action_count = (uint32_t)RARRAY_LEN(merged_actions);
	    rb_ary_push(builder->map_roots, merged_actions);
	    return;
	}
    }
    actions = onibi_gir_compose_edge_actions(builder, from, to, actions);
    onibi_gir_edge_vector_push(
	&builder->edges,
	(OnibiGirEdgeEntry){from, to, 0, (uint32_t)RARRAY_LEN(actions),
			    actions},
	builder->map_roots);
}

static onibi_fragment_t
onibi_fragment_empty(void)
{
    onibi_fragment_t fragment;
    onibi_id_vector_init(&fragment.starts);
    onibi_id_vector_init(&fragment.exits);
    fragment.start_actions = onibi_empty_actions;
    fragment.pending_actions = onibi_empty_actions;
    fragment.nullable = 1;
    fragment.lazy = 0;
    return fragment;
}

static VALUE
onibi_fragment_actions_mutable(VALUE *actions)
{
    if (*actions == onibi_empty_actions) *actions = rb_ary_new();
    return *actions;
}

static void
onibi_fragment_append_actions(VALUE *destination, VALUE source)
{
    if (RARRAY_LEN(source) == 0) return;
    onibi_append_values(onibi_fragment_actions_mutable(destination), source);
}

/* Fragment composition still stores Ruby arrays, but all numeric exit
 * traversal goes through the C vector boundary. */
static void
onibi_connect_fragment_actions(onibi_gir_builder_t *builder,
			       const OnibiIdVector *exits,
			       const OnibiIdVector *starts, VALUE actions,
			       int prepend)
{
    for (size_t i = 0; i < exits->count; i++) {
	long from = (long)exits->items[i];
	for (size_t j = 0; j < starts->count; j++) {
	    long to = (long)starts->items[j];
	    if (prepend) {
		size_t insert_at = builder->edges.count;
		for (size_t k = 0; k < builder->edges.count; k++) {
		    if (builder->edges.entries[k].from == from) {
			insert_at = k;
			break;
		    }
		}
		VALUE edge_actions =
		    onibi_gir_compose_edge_actions(builder, from, to, actions);
		onibi_gir_edge_vector_insert(
		    &builder->edges, insert_at,
		    (OnibiGirEdgeEntry){from, to, 0,
					(uint32_t)RARRAY_LEN(edge_actions),
					edge_actions},
		    builder->map_roots);
	    }
	    else {
		onibi_gir_edge_actions(builder, from, to, actions);
	    }
	}
    }
}

static void
onibi_connect_fragment(onibi_gir_builder_t *builder, const OnibiIdVector *exits,
		       const OnibiIdVector *starts)
{
    for (size_t i = 0; i < exits->count; i++)
	for (size_t j = 0; j < starts->count; j++)
	    onibi_gir_edge(builder, (long)exits->items[i],
			   (long)starts->items[j]);
}

static void
onibi_append_values(VALUE destination, VALUE values)
{
    VALUE *items = RARRAY_PTR(values);
    long count = RARRAY_LEN(values);
    for (long i = 0; i < count; i++)
	rb_ary_push(destination, items[i]);
}

static VALUE
onibi_concat_action_values(VALUE first, VALUE second)
{
    long first_count = RARRAY_LEN(first);
    long second_count = RARRAY_LEN(second);
    if (first_count == 0) return second;
    if (second_count == 0) return first;
    VALUE result = rb_ary_new_capa(first_count + second_count);
    onibi_append_values(result, first);
    onibi_append_values(result, second);
    return result;
}

static void
onibi_add_capture_guard_fragment(onibi_gir_builder_t *builder,
				 const OnibiIdVector *starts, VALUE guard)
{
    for (size_t i = 0; i < starts->count; i++) {
	onibi_guard_vector_add(&builder->capture_guards, starts->items[i],
			       guard, builder->map_roots);
    }
}

static void
onibi_add_exit_guard_fragment(onibi_gir_builder_t *builder,
			      const OnibiIdVector *exits, VALUE actions)
{
    for (size_t i = 0; i < exits->count; i++) {
	onibi_guard_vector_add(&builder->exit_guards, exits->items[i], actions,
			       builder->map_roots);
    }
}

static VALUE
onibi_capture_test_action(long slot, int set)
{
    VALUE action = rb_hash_new();
    rb_hash_aset(action, ID2SYM(id_key_op), ID2SYM(id_a_test_capture));
    onibi_set_gir_action_opcode(action, id_a_test_capture);
    rb_hash_aset(action, ID2SYM(id_key_slot), LONG2NUM(slot));
    rb_hash_aset(action, ID2SYM(id_key_set), set ? Qtrue : Qfalse);
    return action;
}

static VALUE
onibi_counter_action(ID op, long slot, VALUE limit)
{
    VALUE action = rb_hash_new();
    rb_hash_aset(action, ID2SYM(id_key_op), ID2SYM(op));
    onibi_set_gir_action_opcode(action, op);
    rb_hash_aset(action, ID2SYM(id_key_slot), LONG2NUM(slot));
    if (!NIL_P(limit)) rb_hash_aset(action, ID2SYM(id_key_limit), limit);
    if (op == id_a_counter_init)
	rb_hash_aset(action, ID2SYM(id_key_value), INT2NUM(1));
    return action;
}

static void
onibi_materialize_gir(onibi_gir_builder_t *builder, VALUE *states_out,
		      VALUE *edges_out)
{
    VALUE states = rb_ary_new_capa((long)builder->states.count);
    for (size_t i = 0; i < builder->states.count; i++) {
	OnibiGirStateEntry *entry = &builder->states.entries[i];
	VALUE state = rb_hash_new();
	rb_hash_aset(state, ID2SYM(id_key_id), LONG2NUM(entry->id));
	rb_hash_aset(state, ID2SYM(id_key_op), ID2SYM(entry->op));
	if (entry->opcode >= ONIBI_G_ACCEPT)
	    rb_hash_aset(state, ID2SYM(id_key_opcode), UINT2NUM(entry->opcode));
	rb_hash_aset(state, ID2SYM(id_key_payload), entry->payload);
	rb_obj_freeze(state);
	rb_ary_push(states, state);
    }
    VALUE edges = rb_ary_new_capa((long)builder->edges.count);
    for (size_t i = 0; i < builder->edges.count; i++) {
	OnibiGirEdgeEntry *entry = &builder->edges.entries[i];
	VALUE edge = rb_hash_new();
	rb_hash_aset(edge, ID2SYM(id_key_from), LONG2NUM(entry->from));
	rb_hash_aset(edge, ID2SYM(id_key_to), LONG2NUM(entry->to));
	rb_obj_freeze(entry->actions);
	rb_hash_aset(edge, ID2SYM(id_key_actions), entry->actions);
	rb_obj_freeze(edge);
	rb_ary_push(edges, edge);
    }
    rb_obj_freeze(states);
    rb_obj_freeze(edges);
    *states_out = states;
    *edges_out = edges;
}

static VALUE
onibi_gir_payload_from_ast_terminal(const OnibiAstArena *arena, OnibiAstId id,
				    int semantic_class)
{
    const OnibiAstNode *node = onibi_ast_node_const(arena, id);
    if (node->kind != ONIBI_AST_LITERAL && node->kind != ONIBI_AST_ESCAPE &&
	node->kind != ONIBI_AST_ANY && node->kind != ONIBI_AST_BACKREF &&
	node->kind != ONIBI_AST_CHARACTER_CLASS &&
	node->kind != ONIBI_AST_CLASS_INTERSECTION &&
	!(node->kind == ONIBI_AST_UNKNOWN &&
	  node->token_kind == ONIBI_TOKEN_POSIX_CLASS))
	rb_raise(rb_eArgError, "GIR payload requires a terminal AST node");
    VALUE value = rb_hash_new();
    rb_hash_aset(value, ID2SYM(id_key_type_code), UINT2NUM(node->kind));
    if (node->token_kind >= ONIBI_TOKEN_LITERAL)
	rb_hash_aset(value, ID2SYM(id_key_kind_code),
		     UINT2NUM(node->token_kind));
    if (node->start >= 0)
	rb_hash_aset(value, ID2SYM(id_key_start), LONG2NUM(node->start));
    if (node->end >= 0)
	rb_hash_aset(value, ID2SYM(id_key_end), LONG2NUM(node->end));
    rb_hash_aset(value, ID2SYM(id_key_byte), LONG2NUM(node->byte));
    if (node->name_id != 0)
	rb_hash_aset(value, ID2SYM(id_key_name_id), ULONG2NUM(node->name_id));
    VALUE name = onibi_ast_slice_string(arena, node->name);
    if (NIL_P(name) && node->kind == ONIBI_AST_ESCAPE)
	name = rb_str_new((const char[]){(char)node->byte}, 1);
    if (!NIL_P(name)) rb_hash_aset(value, ID2SYM(id_key_name), name);
    VALUE bytes = onibi_ast_slice_string(arena, node->bytes);
    if (!NIL_P(bytes)) rb_hash_aset(value, ID2SYM(id_key_bytes), bytes);

    if (node->kind == ONIBI_AST_CHARACTER_CLASS) {
	VALUE children = rb_ary_new_capa((long)node->child_count);
	for (size_t i = 0; i < node->child_count; i++) {
	    VALUE child = semantic_class ? onibi_gir_payload_from_ast_terminal(
					       arena, node->children[i], 1)
					 : UINT2NUM(node->children[i]);
	    rb_ary_push(children, child);
	}
	VALUE ranges = rb_ary_new_capa((long)node->range_count);
	for (size_t i = 0; i < node->range_count; i++) {
	    const OnibiAstRange *range = &node->ranges[i];
	    VALUE first = range->first_has_bytes
			      ? onibi_ast_slice_string(arena, range->first)
			      : INT2NUM(range->first_byte);
	    VALUE last = range->last_has_bytes
			     ? onibi_ast_slice_string(arena, range->last)
			     : INT2NUM(range->last_byte);
	    rb_ary_push(ranges, rb_ary_new_from_args(2, first, last));
	}
	rb_hash_aset(value, ID2SYM(id_key_children), children);
	rb_hash_aset(value, ID2SYM(id_key_ranges), ranges);
    }
    if (node->kind == ONIBI_AST_CLASS_INTERSECTION && semantic_class) {
	VALUE operands = rb_ary_new_capa((long)node->child_count);
	for (size_t i = 0; i < node->child_count; i++)
	    rb_ary_push(operands, onibi_gir_payload_from_ast_terminal(
				      arena, node->children[i], 1));
	rb_hash_aset(value, ID2SYM(id_key_operands), operands);
    }
    if (node->flags & ONIBI_AST_NODE_NEGATED)
	rb_hash_aset(value, ID2SYM(id_key_negated), Qtrue);
    else if (node->kind == ONIBI_AST_CHARACTER_CLASS)
	rb_hash_aset(value, ID2SYM(id_key_negated), Qfalse);
    if (node->kind == ONIBI_AST_BACKREF) {
	if (NIL_P(name))
	    rb_hash_aset(value, ID2SYM(id_key_capture),
			 LONG2NUM(node->capture));
    }
    return value;
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

static int
onibi_c_ast_has_subroutine_name(const OnibiAstArena *arena, OnibiAstId id,
				VALUE name)
{
    const OnibiAstNode *node = onibi_ast_node_const(arena, id);
    if (node->kind == ONIBI_AST_SUBROUTINE && node->name.present &&
	node->name.length == (size_t)RSTRING_LEN(name) &&
	memcmp(arena->bytes + node->name.offset, RSTRING_PTR(name),
	       node->name.length) == 0)
	return 1;
    if (node->body != ONIBI_AST_NONE &&
	onibi_c_ast_has_subroutine_name(arena, node->body, name))
	return 1;
    if (node->atom != ONIBI_AST_NONE &&
	onibi_c_ast_has_subroutine_name(arena, node->atom, name))
	return 1;
    if (node->yes != ONIBI_AST_NONE &&
	onibi_c_ast_has_subroutine_name(arena, node->yes, name))
	return 1;
    if (node->no != ONIBI_AST_NONE &&
	onibi_c_ast_has_subroutine_name(arena, node->no, name))
	return 1;
    for (size_t i = 0; i < node->child_count; i++)
	if (onibi_c_ast_has_subroutine_name(arena, node->children[i], name))
	    return 1;
    return 0;
}
