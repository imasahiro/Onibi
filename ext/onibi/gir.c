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
typedef struct {
    OnibiGirStateVector states;
    OnibiGirEdgeVector edges;
    long next_id;
    long capture_count;
    long counter_count;
    OnibiGuardVector capture_guards;
    OnibiGuardVector exit_guards;
    OnibiRSeqSubprogramVector subprograms;
    OnibiAstArena *ast;
    const OnibiResolvedArena *semantics;
    unsigned char *subprogram_status;
    size_t resolved_subprogram_count;
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
		 : code == ONIBI_GA_PROGRESS ? ONIBI_RA_PROGRESS
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
    entry.negated = (state->flags & ONIBI_RSEQ_STATE_FLAG_NEGATED) != 0;
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
    OnibiRSeqLiteralPayloadEntry entry;
    memset(&entry, 0, sizeof(entry));
    entry.length = state->literal_length ? state->literal_length : 1;
    memcpy(entry.bytes, state->literal, state->literal_length);
    if (state->literal_length == 0)
	entry.bytes[0] = (unsigned char)state->value;
    entry.ignorecase = (state->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0;
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

static void
onibi_gir_state(onibi_gir_builder_t *builder, long id, OnibiGStateOp opcode,
		uint32_t value, uint8_t flags)
{
    OnibiGirStateEntry entry;
    memset(&entry, 0, sizeof(entry));
    entry.id = id;
    entry.opcode = opcode;
    entry.value = value;
    entry.flags = flags;
    onibi_gir_state_vector_push(&builder->states, entry);
}

/* Store one typed literal record in GIR. */
static void
onibi_gir_state_literal(onibi_gir_builder_t *builder, long id,
			const unsigned char *bytes, size_t length,
			int ignorecase)
{
    OnibiGirStateEntry entry;
    memset(&entry, 0, sizeof(entry));
    entry.id = id;
    entry.opcode = ONIBI_G_CHAR;
    if (length == 0 || length > sizeof(entry.literal))
	rb_raise(eRegexpError, "literal descriptor has invalid length");
    entry.literal_length = (uint8_t)length;
    memcpy(entry.literal, bytes, length);
    entry.value = bytes[0];
    if (ignorecase) entry.flags |= 1U;
    onibi_gir_state_vector_push(&builder->states, entry);
}

static void
onibi_gir_state_class(onibi_gir_builder_t *builder, long id,
		      const unsigned char bitmap[32], int negated)
{
    OnibiGirStateEntry entry;
    memset(&entry, 0, sizeof(entry));
    entry.id = id;
    entry.opcode = ONIBI_G_CLASS;
    memcpy(entry.bitmap, bitmap, sizeof(entry.bitmap));
    if (negated) entry.flags |= 1U;
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
    OnibiGActionVector composed =
	onibi_gir_compose_edge_actions(builder, from, to, actions);
    /* Action programs are part of edge identity.  Keep the first identical
     * edge for priority, but never merge different paths into one program. */
    for (size_t i = 0; i < builder->edges.count; i++) {
	const OnibiGirEdgeEntry *prior = &builder->edges.entries[i];
	if (prior->from == from && prior->to == to &&
	    prior->actions.count == composed.count &&
	    (composed.count == 0 ||
	     memcmp(prior->actions.entries, composed.entries,
		    composed.count * sizeof(*composed.entries)) == 0)) {
	    onibi_g_action_vector_free(&composed);
	    return;
	}
    }
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
onibi_counter_action(OnibiGActionOp code, long slot, int has_limit, long limit)
{
    uint32_t value =
	code == ONIBI_GA_COUNTER_INIT ? 1U : (has_limit ? (uint32_t)limit : 0U);
    return (OnibiGAction){code, 0, 0, 1, (uint16_t)slot, 0, 0, 1, value};
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
				OnibiTokenSlice name)
{
    const OnibiAstNode *node = onibi_ast_node_const(arena, id);
    if (node->kind == ONIBI_AST_SUBROUTINE && node->name.present &&
	name.present && node->name.length == name.length &&
	memcmp(arena->bytes + node->name.offset, arena->bytes + name.offset,
	       name.length) == 0)
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
