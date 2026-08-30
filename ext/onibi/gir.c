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
    VALUE key;
    VALUE value;
} OnibiValueEntry;
typedef ONIBI_VECTOR(OnibiValueEntry) OnibiValueMap;
typedef struct {
    long id;
    OnibiGStateOp opcode;
    uint32_t payload_index;
    uint32_t value;
    uint8_t flags;
    unsigned char bitmap[32];
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
    int byte;
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
    OnibiRSeqSubprogramVector subprograms;
    OnibiValueMap subprogram_ids;
    VALUE map_roots;
    OnibiAstArena *ast;
    int ignorecase;
    int multiline;
    int optional_seen;
} onibi_gir_builder_t;
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
onibi_id_vector_single(OnibiIdVector *vector, OnibiStateId value)
{
    onibi_id_vector_init(vector);
    onibi_id_vector_push(vector, value);
}

ONIBI_VECTOR_DEFINE(onibi_g_action_vector, OnibiGActionVector, OnibiGAction, 8,
		    "GIR action vector is too large")

static OnibiGActionVector
onibi_g_action_vector_concat(const OnibiGActionVector *first,
			     const OnibiGActionVector *second)
{
    OnibiGActionVector result;
    onibi_g_action_vector_init(&result);
    onibi_g_action_vector_append(&result, first);
    onibi_g_action_vector_append(&result, second);
    return result;
}

static OnibiGActionVector
onibi_g_action_vector_copy(const OnibiGActionVector *source)
{
    OnibiGActionVector result;
    onibi_g_action_vector_init(&result);
    onibi_g_action_vector_append(&result, source);
    return result;
}

static void
onibi_guard_vector_init(OnibiGuardVector *vector)
{
    ONIBI_VECTOR_INIT(vector->entries, vector->count, vector->capacity);
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
    OnibiGuardEntry entry = {state, onibi_g_action_vector_copy(actions)};
    ONIBI_VECTOR_PUSH(vector->entries, vector->count, vector->capacity,
		      OnibiGuardEntry, entry, 8,
		      "GIR guard vector is too large");
}

static void
onibi_guard_vector_free(OnibiGuardVector *vector)
{
    for (size_t i = 0; i < vector->count; i++)
	onibi_g_action_vector_free(&vector->entries[i].actions);
    ONIBI_VECTOR_RELEASE(vector->entries, vector->count, vector->capacity);
}

static void
onibi_value_map_init(OnibiValueMap *map)
{
    ONIBI_VECTOR_INIT(map->entries, map->count, map->capacity);
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
    ONIBI_VECTOR_RESERVE(map->entries, map->count, map->capacity,
			 OnibiValueEntry, additional, 8,
			 "GIR value map is too large");
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
    ONIBI_VECTOR_RELEASE(map->entries, map->count, map->capacity);
}

ONIBI_VECTOR_DEFINE(onibi_gir_state_vector, OnibiGirStateVector,
		    OnibiGirStateEntry, 8, "GIR state vector is too large")

static void
onibi_gir_edge_vector_init(OnibiGirEdgeVector *vector)
{
    ONIBI_VECTOR_INIT(vector->entries, vector->count, vector->capacity);
}

static void
onibi_gir_edge_vector_push(OnibiGirEdgeVector *vector, OnibiGirEdgeEntry entry)
{
    ONIBI_VECTOR_PUSH(vector->entries, vector->count, vector->capacity,
		      OnibiGirEdgeEntry, entry, 8,
		      "GIR edge vector is too large");
}

static void
onibi_gir_edge_vector_insert(OnibiGirEdgeVector *vector, size_t index,
			     OnibiGirEdgeEntry entry)
{
    ONIBI_VECTOR_INSERT(vector->entries, vector->count, vector->capacity,
			OnibiGirEdgeEntry, index, entry, 8,
			"GIR edge vector is too large");
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
onibi_gir_edge_vector_free(OnibiGirEdgeVector *vector)
{
    for (size_t i = 0; i < vector->count; i++)
	onibi_g_action_vector_free(&vector->entries[i].actions);
    ONIBI_VECTOR_RELEASE(vector->entries, vector->count, vector->capacity);
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
onibi_rseq_class_payload_vector_init(OnibiRSeqClassPayloadVector *vector)
{
    ONIBI_VECTOR_INIT(vector->entries, vector->count, vector->capacity);
}
static void
onibi_rseq_class_payload_vector_push(OnibiRSeqClassPayloadVector *vector,
				     const OnibiGirStateEntry *state)
{
    OnibiRSeqClassPayloadEntry entry;
    memcpy(entry.bitmap, state->bitmap, sizeof(entry.bitmap));
    entry.negated = (state->flags & 1U) != 0;
    ONIBI_VECTOR_PUSH(vector->entries, vector->count, vector->capacity,
		      OnibiRSeqClassPayloadEntry, entry, 8,
		      "RSeq class payload vector is too large");
}
static void
onibi_rseq_class_payload_vector_free(OnibiRSeqClassPayloadVector *vector)
{
    ONIBI_VECTOR_RELEASE(vector->entries, vector->count, vector->capacity);
}
static void
onibi_rseq_literal_payload_vector_init(OnibiRSeqLiteralPayloadVector *vector)
{
    ONIBI_VECTOR_INIT(vector->entries, vector->count, vector->capacity);
}
static void
onibi_rseq_literal_payload_vector_push(OnibiRSeqLiteralPayloadVector *vector,
				       const OnibiGirStateEntry *state)
{
    OnibiRSeqLiteralPayloadEntry entry = {(int)state->value,
					  (state->flags & 1U) != 0};
    ONIBI_VECTOR_PUSH(vector->entries, vector->count, vector->capacity,
		      OnibiRSeqLiteralPayloadEntry, entry, 8,
		      "RSeq literal payload vector is too large");
}
static void
onibi_rseq_literal_payload_vector_free(OnibiRSeqLiteralPayloadVector *vector)
{
    ONIBI_VECTOR_RELEASE(vector->entries, vector->count, vector->capacity);
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
onibi_gir_state(onibi_gir_builder_t *builder, long id, OnibiGStateOp opcode,
		VALUE payload)
{
    OnibiGirStateEntry entry;
    memset(&entry, 0, sizeof(entry));
    entry.id = id;
    entry.opcode = opcode;
    if (opcode == ONIBI_G_CHAR) {
	entry.value =
	    (uint32_t)NUM2UINT(onibi_hash_value_id(payload, id_key_byte));
	if (RTEST(onibi_hash_value_id(payload, id_key_ignorecase)))
	    entry.flags |= 1U;
    }
    else if (opcode == ONIBI_G_CLASS) {
	VALUE bitmap = onibi_hash_value_id(payload, id_key_bitmap);
	if (!RB_TYPE_P(bitmap, T_STRING) || RSTRING_LEN(bitmap) != 32)
	    rb_raise(eRegexpError, "GIR class requires a 256-bit bitmap");
	memcpy(entry.bitmap, RSTRING_PTR(bitmap), sizeof(entry.bitmap));
	if (RTEST(onibi_hash_value_id(payload, id_key_negated)))
	    entry.flags |= 1U;
    }
    else if (opcode == ONIBI_G_BACKREF) {
	VALUE capture = onibi_hash_value_id(payload, id_key_capture);
	if (NIL_P(capture) || NUM2LONG(capture) <= 0)
	    rb_raise(eRegexpError, "invalid GIR backreference capture");
	entry.value = (uint32_t)(NUM2ULONG(capture) - 1U);
	if (RTEST(onibi_hash_value_id(payload, id_key_ignorecase)))
	    entry.flags |= 1U;
    }
    else if (opcode == ONIBI_G_CALL || opcode == ONIBI_G_ATOMIC ||
	     opcode == ONIBI_G_ABSENT) {
	VALUE subprogram = onibi_hash_value_id(payload, id_key_subprogram);
	if (NIL_P(subprogram))
	    rb_raise(eRegexpError, "GIR state requires a subprogram");
	entry.value = (uint32_t)NUM2ULONG(subprogram);
    }
    else if (opcode == ONIBI_G_ANY &&
	     RTEST(onibi_hash_value_id(payload, id_key_multiline))) {
	entry.flags |= 1U;
    }
    onibi_gir_state_vector_push(&builder->states, entry);
}

static OnibiGActionVector
onibi_gir_compose_edge_actions(onibi_gir_builder_t *builder, long from, long to,
			       const OnibiGActionVector *explicit_actions)
{
    const OnibiGuardEntry *capture_guard = onibi_guard_vector_find_entry(
	&builder->capture_guards, (OnibiStateId)to);
    const OnibiGuardEntry *exit_guard = onibi_guard_vector_find_entry(
	&builder->exit_guards, (OnibiStateId)from);
    OnibiGActionVector actions;
    onibi_g_action_vector_init(&actions);
    if (exit_guard)
	onibi_g_action_vector_append(&actions, &exit_guard->actions);
    onibi_g_action_vector_append(&actions, explicit_actions);
    if (capture_guard)
	onibi_g_action_vector_append(&actions, &capture_guard->actions);
    return actions;
}

static void
onibi_gir_edge(onibi_gir_builder_t *builder, long from, long to)
{
    OnibiGActionVector empty;
    onibi_g_action_vector_init(&empty);
    OnibiGActionVector actions =
	onibi_gir_compose_edge_actions(builder, from, to, &empty);
    onibi_gir_edge_vector_push(&builder->edges,
			       (OnibiGirEdgeEntry){from, to, 0, actions});
}

static void
onibi_gir_edge_actions(onibi_gir_builder_t *builder, long from, long to,
		       const OnibiGActionVector *actions)
{
    const OnibiGuardEntry *capture_guard = onibi_guard_vector_find_entry(
	&builder->capture_guards, (OnibiStateId)to);
    const OnibiGuardEntry *exit_guard = onibi_guard_vector_find_entry(
	&builder->exit_guards, (OnibiStateId)from);
    size_t capture_count = capture_guard ? capture_guard->actions.count : 0;
    size_t exit_count = exit_guard ? exit_guard->actions.count : 0;
    for (size_t i = 0; i < builder->edges.count; i++) {
	OnibiGirEdgeEntry *prior = &builder->edges.entries[i];
	if (prior->from == from && prior->to == to) {
	    size_t guard_count = exit_count + capture_count;
	    if (prior->actions.count < guard_count)
		rb_raise(rb_eArgError, "GIR edge guard layout is invalid");
	    size_t prior_explicit_count = prior->actions.count - guard_count;
	    OnibiGActionVector explicit_actions;
	    onibi_g_action_vector_init(&explicit_actions);
	    onibi_g_action_vector_append(&explicit_actions, actions);
	    onibi_g_action_vector_reserve(&explicit_actions,
					  prior_explicit_count);
	    memcpy(explicit_actions.entries + explicit_actions.count,
		   prior->actions.entries + exit_count,
		   prior_explicit_count * sizeof(*prior->actions.entries));
	    explicit_actions.count += prior_explicit_count;
	    OnibiGActionVector merged_actions = onibi_gir_compose_edge_actions(
		builder, from, to, &explicit_actions);
	    onibi_g_action_vector_free(&explicit_actions);
	    onibi_g_action_vector_free(&prior->actions);
	    prior->actions = merged_actions;
	    return;
	}
    }
    OnibiGActionVector composed =
	onibi_gir_compose_edge_actions(builder, from, to, actions);
    onibi_gir_edge_vector_push(&builder->edges,
			       (OnibiGirEdgeEntry){from, to, 0, composed});
}

static onibi_fragment_t
onibi_fragment_empty(void)
{
    onibi_fragment_t fragment;
    onibi_id_vector_init(&fragment.starts);
    onibi_id_vector_init(&fragment.exits);
    onibi_g_action_vector_init(&fragment.start_actions);
    onibi_g_action_vector_init(&fragment.pending_actions);
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

/* Fragment composition still stores Ruby arrays, but all numeric exit
 * traversal goes through the C vector boundary. */
static void
onibi_connect_fragment_actions(onibi_gir_builder_t *builder,
			       const OnibiIdVector *exits,
			       const OnibiIdVector *starts,
			       const OnibiGActionVector *actions, int prepend)
{
    for (size_t i = 0; i < exits->count; i++) {
	long from = (long)exits->entries[i];
	for (size_t j = 0; j < starts->count; j++) {
	    long to = (long)starts->entries[j];
	    if (prepend) {
		size_t insert_at = builder->edges.count;
		for (size_t k = 0; k < builder->edges.count; k++) {
		    if (builder->edges.entries[k].from == from) {
			insert_at = k;
			break;
		    }
		}
		OnibiGActionVector edge_actions =
		    onibi_gir_compose_edge_actions(builder, from, to, actions);
		onibi_gir_edge_vector_insert(
		    &builder->edges, insert_at,
		    (OnibiGirEdgeEntry){from, to, 0, edge_actions});
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
	    onibi_gir_edge(builder, (long)exits->entries[i],
			   (long)starts->entries[j]);
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
    return (OnibiGAction){
	ONIBI_GA_TEST_CAPTURE, set ? 1 : 0, 0, 1, (uint16_t)slot, 0, 0, 0, 0};
}

static OnibiGAction
onibi_counter_action(OnibiGActionOp code, long slot, VALUE limit)
{
    uint32_t value = code == ONIBI_GA_COUNTER_INIT
			 ? 1U
			 : (NIL_P(limit) ? 0U : (uint32_t)NUM2ULONG(limit));
    return (OnibiGAction){code, 0, 0, 1, (uint16_t)slot, 0, 0, 1, value};
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
