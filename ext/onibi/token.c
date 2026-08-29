/* These sets are lexer grammar, not user data.  Keep them as direct
 * predicates so tokenization does not call a string-search routine for each
 * source byte. */
static int
onibi_option_char_p(unsigned char c)
{
    return c == 'i' || c == 'm' || c == 'x';
}

static int
onibi_anchor_escape_p(unsigned char c)
{
    switch (c) {
    case 'A':
    case 'z':
    case 'Z':
    case 'G':
    case 'b':
    case 'B': return 1;
    default: return 0;
    }
}

static int
onibi_class_escape_p(unsigned char c)
{
    switch (c) {
    case 'd':
    case 'D':
    case 's':
    case 'S':
    case 'w':
    case 'W':
    case 'h':
    case 'H':
    case 'R':
    case 'X':
    case 'p':
    case 'P':
    case 'u': return 1;
    default: return 0;
    }
}

static int
onibi_simple_escape_p(unsigned char c)
{
    return c == 'd' || c == 'D' || c == 's' || c == 'S' || c == 'w' ||
	   c == 'W' || c == 'h' || c == 'H';
}

static int
onibi_quantifier_byte_p(unsigned char c)
{
    return c == '*' || c == '+' || c == '?' || c == '{' || c == '}';
}

typedef struct {
    VALUE *items;
    size_t count;
    size_t capacity;
} OnibiValueVector;
static void onibi_value_vector_init(OnibiValueVector *vector);
static void onibi_value_vector_push(OnibiValueVector *vector, VALUE value,
				    VALUE roots);
static void onibi_value_vector_free(OnibiValueVector *vector);

typedef struct {
    OnibiTokenKind kind;
    unsigned char byte;
    long start;
    long end;
    OnibiTokenSlice name;
    OnibiTokenSlice negative_name;
    OnibiTokenSlice bytes;
    long capture;
    ID name_id;
    OnibiAsciiProperty property_kind;
    unsigned char has_capture;
    unsigned char inline_ignorecase;
    unsigned char negative;
} OnibiTokenRecord;

typedef struct {
    OnibiTokenRecord *items;
    size_t count;
    size_t capacity;
    unsigned char *bytes;
    size_t bytes_count;
    size_t bytes_capacity;
} OnibiTokenVector;

static void
onibi_token_vector_init(OnibiTokenVector *vector)
{
    memset(vector, 0, sizeof(*vector));
}

static void
onibi_token_vector_free(OnibiTokenVector *vector)
{
    xfree(vector->items);
    xfree(vector->bytes);
    memset(vector, 0, sizeof(*vector));
}

static OnibiTokenSlice
onibi_token_vector_copy(OnibiTokenVector *vector, const char *bytes,
			size_t length)
{
    OnibiTokenSlice slice = {0, 0, 1};
    if (length == 0) return slice;
    if (vector->bytes_count > SIZE_MAX - length)
	rb_raise(rb_eNoMemError, "token byte storage is too large");
    size_t required = vector->bytes_count + length;
    if (required > vector->bytes_capacity) {
	size_t next = vector->bytes_capacity == 0 ? 64 : vector->bytes_capacity;
	while (next < required) {
	    if (next > SIZE_MAX / 2) {
		next = required;
		break;
	    }
	    next *= 2;
	}
	vector->bytes = REALLOC_N(vector->bytes, unsigned char, next);
	vector->bytes_capacity = next;
    }
    slice.offset = vector->bytes_count;
    slice.length = length;
    memcpy(vector->bytes + vector->bytes_count, bytes, length);
    vector->bytes_count = required;
    return slice;
}

static inline const OnibiTokenRecord *
onibi_token_at(const OnibiTokenVector *vector, long index)
{
    if (index < 0 || (size_t)index >= vector->count)
	rb_raise(rb_eIndexError, "token index is outside the token vector");
    return &vector->items[index];
}

static void
onibi_ast_arena_init(OnibiAstArena *arena, const OnibiTokenVector *tokens)
{
    memset(arena, 0, sizeof(*arena));
    arena->root = ONIBI_AST_NONE;
    if (tokens->bytes_count == 0) return;
    arena->bytes = ALLOC_N(unsigned char, tokens->bytes_count);
    memcpy(arena->bytes, tokens->bytes, tokens->bytes_count);
    arena->bytes_count = arena->bytes_capacity = tokens->bytes_count;
}

static void
onibi_ast_arena_free(OnibiAstArena *arena)
{
    for (size_t i = 0; i < arena->count; i++) {
	xfree(arena->nodes[i].children);
	xfree(arena->nodes[i].ranges);
    }
    xfree(arena->nodes);
    xfree(arena->bytes);
    memset(arena, 0, sizeof(*arena));
    arena->root = ONIBI_AST_NONE;
}

static OnibiAstId
onibi_ast_arena_add(OnibiAstArena *arena, OnibiAstKind kind,
		    const OnibiTokenRecord *token)
{
    if (arena->count == arena->capacity) {
	size_t next = arena->capacity == 0 ? 32 : arena->capacity * 2;
	if (next < arena->capacity || next > UINT32_MAX ||
	    next > SIZE_MAX / sizeof(*arena->nodes))
	    rb_raise(rb_eNoMemError, "AST node arena is too large");
	arena->nodes = REALLOC_N(arena->nodes, OnibiAstNode, next);
	arena->capacity = next;
    }
    OnibiAstId id = (OnibiAstId)arena->count++;
    OnibiAstNode *node = &arena->nodes[id];
    memset(node, 0, sizeof(*node));
    node->kind = kind;
    node->token_kind = token == NULL ? (OnibiTokenKind)-1 : token->kind;
    node->start = token == NULL ? -1 : token->start;
    node->end = token == NULL ? -1 : token->end;
    node->byte = token == NULL ? 0 : token->byte;
    node->capture = token != NULL && token->has_capture ? token->capture : -1;
    node->name_id = token == NULL ? 0 : token->name_id;
    node->name = token == NULL ? (OnibiTokenSlice){0, 0, 0} : token->name;
    node->negative_options =
	token == NULL ? (OnibiTokenSlice){0, 0, 0} : token->negative_name;
    node->bytes = token == NULL ? (OnibiTokenSlice){0, 0, 0} : token->bytes;
    node->body = node->atom = node->yes = node->no = ONIBI_AST_NONE;
    return id;
}

static OnibiAstNode *
onibi_ast_node_at(OnibiAstArena *arena, OnibiAstId id)
{
    if (id == ONIBI_AST_NONE || (size_t)id >= arena->count)
	rb_raise(rb_eIndexError, "AST node ID is outside the arena");
    return &arena->nodes[id];
}

static const OnibiAstNode *
onibi_ast_node_const(const OnibiAstArena *arena, OnibiAstId id)
{
    if (id == ONIBI_AST_NONE || (size_t)id >= arena->count)
	rb_raise(rb_eIndexError, "AST node ID is outside the arena");
    return &arena->nodes[id];
}

static void
onibi_ast_add_child(OnibiAstArena *arena, OnibiAstId parent, OnibiAstId child)
{
    OnibiAstNode *node = onibi_ast_node_at(arena, parent);
    if (node->child_count == node->child_capacity) {
	size_t next = node->child_capacity == 0 ? 4 : node->child_capacity * 2;
	if (next < node->child_capacity ||
	    next > SIZE_MAX / sizeof(*node->children))
	    rb_raise(rb_eNoMemError, "AST child vector is too large");
	node->children = REALLOC_N(node->children, OnibiAstId, next);
	node->child_capacity = next;
    }
    node->children[node->child_count++] = child;
}

static void
onibi_ast_add_range(OnibiAstArena *arena, OnibiAstId parent,
		    OnibiAstRange range)
{
    OnibiAstNode *node = onibi_ast_node_at(arena, parent);
    if (node->range_count == node->range_capacity) {
	size_t next = node->range_capacity == 0 ? 4 : node->range_capacity * 2;
	if (next < node->range_capacity ||
	    next > SIZE_MAX / sizeof(*node->ranges))
	    rb_raise(rb_eNoMemError, "AST range vector is too large");
	node->ranges = REALLOC_N(node->ranges, OnibiAstRange, next);
	node->range_capacity = next;
    }
    node->ranges[node->range_count++] = range;
}

static VALUE
onibi_ast_slice_string(const OnibiAstArena *arena, OnibiTokenSlice slice)
{
    if (!slice.present) return Qnil;
    return rb_str_new((const char *)arena->bytes + slice.offset,
		      (long)slice.length);
}

static OnibiTokenSlice
onibi_ast_arena_copy_bytes(OnibiAstArena *arena, const unsigned char *bytes,
			   size_t length)
{
    if (arena->bytes_count > SIZE_MAX - length)
	rb_raise(rb_eNoMemError, "AST byte arena is too large");
    size_t required = arena->bytes_count + length;
    if (required > arena->bytes_capacity) {
	size_t next = arena->bytes_capacity == 0 ? 64 : arena->bytes_capacity;
	while (next < required) {
	    if (next > SIZE_MAX / 2) {
		next = required;
		break;
	    }
	    next *= 2;
	}
	arena->bytes = REALLOC_N(arena->bytes, unsigned char, next);
	arena->bytes_capacity = next;
    }
    OnibiTokenSlice slice = {arena->bytes_count, length, 1};
    memcpy(arena->bytes + arena->bytes_count, bytes, length);
    arena->bytes_count = required;
    return slice;
}

static void
onibi_token_record_push(OnibiTokenVector *vector, OnibiTokenRecord record)
{
    if (vector->count == vector->capacity) {
	size_t next = vector->capacity == 0 ? 16 : vector->capacity * 2;
	if (next < vector->capacity || next > SIZE_MAX / sizeof(*vector->items))
	    rb_raise(rb_eNoMemError, "token vector is too large");
	vector->items = REALLOC_N(vector->items, OnibiTokenRecord, next);
	vector->capacity = next;
    }
    vector->items[vector->count++] = record;
}

static void
onibi_tokenize_internal(VALUE src, int extended, OnibiTokenVector *tokens)
{
    onibi_token_vector_init(tokens);
    /* One escape is one semantic token.  Do not let an escaped metacharacter
       enter the AST as syntax. */
    int in_class = 0;
    long class_depth = 0;
    long class_body_start = -1;
    long class_body_starts[256];
    int extended_stack[256];
    long extended_depth = 0;
    for (long i = 0; i < RSTRING_LEN(src); i++) {
	long start = i;
	OnibiTokenKind kind = ONIBI_TOKEN_LITERAL;
	unsigned char byte = (unsigned char)RSTRING_PTR(src)[i];
	if (extended && !in_class && byte == '#') {
	    while (i + 1 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] != '\n')
		i++;
	    continue;
	}
	if (extended && !in_class &&
	    (byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n'))
	    continue;
	long name_start = -1;
	long name_length = 0;
	long capture_number = 0;
	int has_capture_number = 0;
	OnibiTokenSlice literal_slice = {0, 0, 0};
	long negative_name_start = -1;
	long negative_name_length = 0;
	int option_negative = 0;
	int option_scope_x = -1;
	if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) &&
	    RSTRING_PTR(src)[i + 1] == '?' &&
	    (RSTRING_PTR(src)[i + 2] == '=' ||
	     RSTRING_PTR(src)[i + 2] == '!')) {
	    kind = ONIBI_TOKEN_LOOKAHEAD_START;
	    byte = (unsigned char)RSTRING_PTR(src)[i + 2];
	    i += 2;
	}
	else if (!in_class && byte == '(' && i + 3 < RSTRING_LEN(src) &&
		 RSTRING_PTR(src)[i + 1] == '?' &&
		 RSTRING_PTR(src)[i + 2] == '<' &&
		 (RSTRING_PTR(src)[i + 3] == '=' ||
		  RSTRING_PTR(src)[i + 3] == '!')) {
	    kind = ONIBI_TOKEN_LOOKBEHIND_START;
	    byte = (unsigned char)RSTRING_PTR(src)[i + 3];
	    i += 3;
	}
	else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) &&
		 RSTRING_PTR(src)[i + 1] == '?' &&
		 (RSTRING_PTR(src)[i + 2] == '-' ||
		  onibi_option_char_p(
		      (unsigned char)RSTRING_PTR(src)[i + 2]))) {
	    long option_end = i + 2;
	    int valid = 1;
	    if (RSTRING_PTR(src)[option_end] == '-') {
		option_negative = 1;
		option_end++;
	    }
	    long option_count = option_end;
	    while (option_end < RSTRING_LEN(src) &&
		   onibi_option_char_p(
		       (unsigned char)RSTRING_PTR(src)[option_end]))
		option_end++;
	    long positive_end = option_end;
	    long negative_start = -1;
	    if (!option_negative && option_end < RSTRING_LEN(src) &&
		RSTRING_PTR(src)[option_end] == '-') {
		negative_start = ++option_end;
		while (option_end < RSTRING_LEN(src) &&
		       onibi_option_char_p(
			   (unsigned char)RSTRING_PTR(src)[option_end]))
		    option_end++;
		if (option_end == negative_start) valid = 0;
	    }
	    int global_modifier = 0;
	    if (option_end == option_count || option_end >= RSTRING_LEN(src))
		valid = 0;
	    else if (RSTRING_PTR(src)[option_end] == ')')
		global_modifier = 1;
	    else if (RSTRING_PTR(src)[option_end] != ':')
		valid = 0;
	    if (valid) {
		kind = global_modifier ? ONIBI_TOKEN_OPTION_GLOBAL
				       : ONIBI_TOKEN_OPTION_SCOPE_START;
		byte = global_modifier ? ')' : ':';
		i = option_end;
		long name_end = negative_start >= 0 ? positive_end : option_end;
		name_start = option_count;
		name_length = name_end - option_count;
		if (option_negative)
		    option_scope_x = 0;
		else
		    option_scope_x =
			memchr(RSTRING_PTR(src) + option_count, 'x',
			       (size_t)(negative_start >= 0
					    ? negative_start - option_count
					    : option_end - option_count)) !=
			NULL;
		if (negative_start >= 0) {
		    negative_name_start = negative_start;
		    negative_name_length = option_end - negative_start;
		}
	    }
	}
	else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) &&
		 RSTRING_PTR(src)[i + 1] == '?' &&
		 RSTRING_PTR(src)[i + 2] == ':') {
	    kind = ONIBI_TOKEN_NONCAPTURE_START;
	    byte = ':';
	    i += 2;
	}
	else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) &&
		 RSTRING_PTR(src)[i + 1] == '?' &&
		 RSTRING_PTR(src)[i + 2] == '>') {
	    kind = ONIBI_TOKEN_ATOMIC_START;
	    byte = '>';
	    i += 2;
	}
	else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) &&
		 RSTRING_PTR(src)[i + 1] == '?' &&
		 RSTRING_PTR(src)[i + 2] == '~') {
	    kind = ONIBI_TOKEN_ABSENCE_START;
	    byte = '~';
	    i += 2;
	}
	else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) &&
		 RSTRING_PTR(src)[i + 1] == '?' &&
		 RSTRING_PTR(src)[i + 2] == '(') {
	    long close = i + 3;
	    while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != ')')
		close++;
	    if (close < RSTRING_LEN(src)) {
		kind = ONIBI_TOKEN_CONDITIONAL_START;
		byte = '(';
		name_start = i + 3;
		name_length = close - (i + 3);
		i = close;
	    }
	}
	else if (!in_class && byte == '(' && i + 3 < RSTRING_LEN(src) &&
		 RSTRING_PTR(src)[i + 1] == '?' &&
		 RSTRING_PTR(src)[i + 2] == '<') {
	    long close = i + 3;
	    while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != '>')
		close++;
	    if (close < RSTRING_LEN(src)) {
		kind = ONIBI_TOKEN_GROUP_START;
		name_start = i + 3;
		name_length = close - (i + 3);
		i = close;
	    }
	}
	if (in_class && byte == '[' && i + 2 < RSTRING_LEN(src) &&
	    RSTRING_PTR(src)[i + 1] == ':') {
	    long close = i + 2;
	    while (close + 1 < RSTRING_LEN(src) &&
		   !(RSTRING_PTR(src)[close] == ':' &&
		     RSTRING_PTR(src)[close + 1] == ']'))
		close++;
	    if (close + 1 < RSTRING_LEN(src)) {
		kind = ONIBI_TOKEN_POSIX_CLASS;
		name_start = i + 2;
		name_length = close - (i + 2);
		i = close + 1;
	    }
	}
	if (!in_class && byte == '\\' && i + 3 < RSTRING_LEN(src) &&
	    RSTRING_PTR(src)[i + 1] == 'k' && RSTRING_PTR(src)[i + 2] == '<') {
	    long close = i + 3;
	    while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != '>')
		close++;
	    if (close < RSTRING_LEN(src)) {
		kind = ONIBI_TOKEN_BACKREF;
		byte = 'k';
		name_start = i + 3;
		name_length = close - (i + 3);
		i = close;
	    }
	}
	if (kind == ONIBI_TOKEN_LITERAL && !in_class && byte == '\\' &&
	    i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == 'g' &&
	    RSTRING_PTR(src)[i + 2] == '<') {
	    long close = i + 3;
	    while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != '>')
		close++;
	    if (close < RSTRING_LEN(src)) {
		kind = ONIBI_TOKEN_SUBROUTINE;
		byte = 'g';
		name_start = i + 3;
		name_length = close - (i + 3);
		i = close;
	    }
	}
	if (kind == ONIBI_TOKEN_LITERAL && byte == '\\' &&
	    i + 2 < RSTRING_LEN(src) &&
	    (RSTRING_PTR(src)[i + 1] == 'M' ||
	     RSTRING_PTR(src)[i + 1] == 'C') &&
	    RSTRING_PTR(src)[i + 2] == '-') {
	    if (RSTRING_PTR(src)[i + 1] == 'C' && i + 3 < RSTRING_LEN(src)) {
		kind = ONIBI_TOKEN_LITERAL;
		byte = (unsigned char)RSTRING_PTR(src)[i + 3] & 0x1f;
		i += 3;
	    }
	    else {
		kind = ONIBI_TOKEN_META_ESCAPE;
		byte = (unsigned char)RSTRING_PTR(src)[i + 1];
		i += 2;
	    }
	}
	if (kind == ONIBI_TOKEN_LITERAL && byte == '\\' &&
	    i + 1 < RSTRING_LEN(src)) {
	    unsigned char escaped = (unsigned char)RSTRING_PTR(src)[i + 1];
	    int hex_literal = 0;
	    int octal_literal = 0;
	    byte = escaped;
	    if (escaped == 'c' && i + 2 < RSTRING_LEN(src)) {
		byte = (unsigned char)RSTRING_PTR(src)[i + 2] & 0x1f;
		i += 2;
	    }
	    if (escaped == 'x' && i + 3 < RSTRING_LEN(src)) {
		int hi =
		    onibi_hex_digit((unsigned char)RSTRING_PTR(src)[i + 2]);
		int lo =
		    onibi_hex_digit((unsigned char)RSTRING_PTR(src)[i + 3]);
		if (hi >= 0 && lo >= 0) {
		    unsigned char decoded_byte =
			(unsigned char)((hi << 4) | lo);
		    size_t decoded_offset = tokens->bytes_count;
		    size_t decoded_length = 1;
		    (void)onibi_token_vector_copy(
			tokens, (const char *)&decoded_byte, 1);
		    byte = decoded_byte;
		    i += 3;
		    hex_literal = 1;
		    while (i + 4 < RSTRING_LEN(src) &&
			   RSTRING_PTR(src)[i + 1] == '\\' &&
			   RSTRING_PTR(src)[i + 2] == 'x') {
			int next_hi = onibi_hex_digit(
			    (unsigned char)RSTRING_PTR(src)[i + 3]);
			int next_lo = onibi_hex_digit(
			    (unsigned char)RSTRING_PTR(src)[i + 4]);
			if (next_hi < 0 || next_lo < 0) break;
			unsigned char next_byte =
			    (unsigned char)((next_hi << 4) | next_lo);
			(void)onibi_token_vector_copy(
			    tokens, (const char *)&next_byte, 1);
			decoded_length++;
			i += 4;
		    }
		    if (decoded_length > 1)
			literal_slice = (OnibiTokenSlice){decoded_offset,
							  decoded_length, 1};
		}
	    }
	    if (escaped >= '1' && escaped <= '9' && i + 1 < RSTRING_LEN(src) &&
		RSTRING_PTR(src)[i + 1] >= '0' &&
		RSTRING_PTR(src)[i + 1] <= '9') {
		long number = escaped - '0';
		while (i + 1 < RSTRING_LEN(src) &&
		       RSTRING_PTR(src)[i + 1] >= '0' &&
		       RSTRING_PTR(src)[i + 1] <= '9') {
		    number = number * 10 + (RSTRING_PTR(src)[++i] - '0');
		}
		kind = ONIBI_TOKEN_BACKREF;
		capture_number = number;
		has_capture_number = 1;
	    }
	    if (!has_capture_number && escaped >= '1' && escaped <= '7' &&
		i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 2] >= '0' &&
		RSTRING_PTR(src)[i + 2] <= '7') {
		size_t decoded_offset = tokens->bytes_count;
		size_t decoded_length = 0;
		int value = 0;
		int digits = 0;
		while (digits < 3 && i + 1 < RSTRING_LEN(src) &&
		       RSTRING_PTR(src)[i + 1] >= '0' &&
		       RSTRING_PTR(src)[i + 1] <= '7') {
		    value = (value << 3) | (RSTRING_PTR(src)[i + 1] - '0');
		    i++;
		    digits++;
		}
		unsigned char first_byte = (unsigned char)value;
		(void)onibi_token_vector_copy(tokens, (const char *)&first_byte,
					      1);
		decoded_length++;
		while (i + 2 < RSTRING_LEN(src) &&
		       RSTRING_PTR(src)[i + 1] == '\\' &&
		       RSTRING_PTR(src)[i + 2] >= '0' &&
		       RSTRING_PTR(src)[i + 2] <= '7') {
		    long cursor = i + 2;
		    int next_value = 0;
		    int next_digits = 0;
		    while (next_digits < 3 && cursor < RSTRING_LEN(src) &&
			   RSTRING_PTR(src)[cursor] >= '0' &&
			   RSTRING_PTR(src)[cursor] <= '7') {
			next_value = (next_value << 3) |
				     (RSTRING_PTR(src)[cursor] - '0');
			cursor++;
			next_digits++;
		    }
		    unsigned char next_byte = (unsigned char)next_value;
		    (void)onibi_token_vector_copy(tokens,
						  (const char *)&next_byte, 1);
		    decoded_length++;
		    i = cursor - 1;
		}
		byte = first_byte;
		octal_literal = 1;
		if (decoded_length > 1)
		    literal_slice =
			(OnibiTokenSlice){decoded_offset, decoded_length, 1};
	    }
	    if (escaped == '0') {
		int value = 0, digits = 0;
		while (digits < 3 && i + 1 < RSTRING_LEN(src) &&
		       RSTRING_PTR(src)[i + 1] >= '0' &&
		       RSTRING_PTR(src)[i + 1] <= '7') {
		    value = (value << 3) | (RSTRING_PTR(src)[i + 1] - '0');
		    i++;
		    digits++;
		}
		byte = (unsigned char)value;
		octal_literal = 1;
	    }
	    if (escaped == 'n')
		byte = '\n';
	    else if (escaped == 'r')
		byte = '\r';
	    else if (escaped == 't')
		byte = '\t';
	    else if (escaped == 'f')
		byte = '\f';
	    else if (escaped == 'v')
		byte = '\v';
	    else if (escaped == 'a')
		byte = '\a';
	    else if (escaped == 'e')
		byte = 0x1b;
	    if (hex_literal || octal_literal)
		kind = ONIBI_TOKEN_LITERAL;
	    else if (!in_class && onibi_anchor_escape_p(escaped))
		kind = ONIBI_TOKEN_ANCHOR;
	    else if (!in_class && escaped == 'K')
		kind = ONIBI_TOKEN_MATCH_RESET;
	    else if (!in_class && escaped >= '1' && escaped <= '9')
		kind = ONIBI_TOKEN_BACKREF;
	    else if (onibi_class_escape_p(escaped))
		kind = ONIBI_TOKEN_ESCAPE;
	    i++;
	    if ((escaped == 'p' || escaped == 'P') &&
		i + 1 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '{') {
		long close = i + 2;
		while (close < RSTRING_LEN(src) &&
		       RSTRING_PTR(src)[close] != '}')
		    close++;
		if (close < RSTRING_LEN(src)) {
		    name_start = i + 2;
		    name_length = close - (i + 2);
		    i = close;
		}
	    }
	}
	else if (byte == '[' && !in_class) {
	    kind = ONIBI_TOKEN_CLASS_START;
	    in_class = 1;
	    class_depth = 1;
	    class_body_start = i + 1;
	}
	else if (kind == ONIBI_TOKEN_LITERAL && byte == '[' && in_class) {
	    kind = ONIBI_TOKEN_CLASS_START;
	    if (class_depth >= (long)(sizeof(class_body_starts) /
				      sizeof(class_body_starts[0])))
		rb_raise(eRegexpError,
			 "regexp character class nesting is too deep");
	    class_body_starts[class_depth - 1] = class_body_start;
	    class_depth++;
	    class_body_start = i + 1;
	}
	else if (byte == ']' && in_class && class_depth > 1) {
	    kind = ONIBI_TOKEN_CLASS_END;
	    class_depth--;
	    class_body_start = class_body_starts[class_depth - 1];
	}
	else if (byte == ']' && in_class) {
	    kind = ONIBI_TOKEN_CLASS_END;
	    in_class = 0;
	    class_depth = 0;
	}
	else if (in_class) {
	    if (byte == '-' && i > class_body_start)
		kind = ONIBI_TOKEN_CLASS_RANGE;
	    else if (byte == '^' && i == class_body_start)
		kind = ONIBI_TOKEN_CLASS_NEGATE;
	}
	else if (byte == '|')
	    kind = ONIBI_TOKEN_ALTERNATION;
	else if (kind == ONIBI_TOKEN_LITERAL && byte == '(')
	    kind = ONIBI_TOKEN_GROUP_START;
	else if (kind == ONIBI_TOKEN_LITERAL && byte == ')')
	    kind = ONIBI_TOKEN_GROUP_END;
	else if (kind == ONIBI_TOKEN_LITERAL && onibi_quantifier_byte_p(byte))
	    kind = ONIBI_TOKEN_QUANTIFIER;
	else if (kind == ONIBI_TOKEN_LITERAL && byte == '.')
	    kind = ONIBI_TOKEN_WILDCARD;
	else if (kind == ONIBI_TOKEN_LITERAL && (byte == '^' || byte == '$'))
	    kind = ONIBI_TOKEN_ANCHOR;
	if (kind == ONIBI_TOKEN_LITERAL && byte >= 0x80) {
	    int char_len = rb_enc_mbclen(RSTRING_PTR(src) + start,
					 RSTRING_PTR(src) + RSTRING_LEN(src),
					 rb_enc_get(src));
	    if (char_len > 1 && start + char_len <= RSTRING_LEN(src)) {
		/* rb_str_substr uses character offsets.  `start` and `char_len`
		   are byte offsets from the encoding callback, so copy bytes
		   directly and keep the complete encoded character only. */
		literal_slice = onibi_token_vector_copy(
		    tokens, RSTRING_PTR(src) + start, (size_t)char_len);
		i += char_len - 1;
		byte = (unsigned char)RSTRING_PTR(src)[start];
	    }
	}
	if (kind == ONIBI_TOKEN_GROUP_START ||
	    kind == ONIBI_TOKEN_NONCAPTURE_START ||
	    kind == ONIBI_TOKEN_ATOMIC_START ||
	    kind == ONIBI_TOKEN_ABSENCE_START ||
	    kind == ONIBI_TOKEN_CONDITIONAL_START ||
	    kind == ONIBI_TOKEN_LOOKAHEAD_START ||
	    kind == ONIBI_TOKEN_LOOKBEHIND_START ||
	    kind == ONIBI_TOKEN_OPTION_SCOPE_START) {
	    if (extended_depth >=
		(long)(sizeof(extended_stack) / sizeof(extended_stack[0])))
		rb_raise(eRegexpError, "regexp nesting is too deep");
	    extended_stack[extended_depth++] = -1;
	    if (kind == ONIBI_TOKEN_OPTION_SCOPE_START) {
		extended_stack[extended_depth - 1] = extended;
		if (option_scope_x >= 0) extended = option_negative ? 0 : 1;
	    }
	}
	if (kind == ONIBI_TOKEN_OPTION_GLOBAL && option_scope_x >= 0)
	    extended = option_scope_x;
	OnibiTokenSlice name_slice =
	    name_start < 0
		? (OnibiTokenSlice){0, 0, 0}
		: onibi_token_vector_copy(tokens, RSTRING_PTR(src) + name_start,
					  (size_t)name_length);
	OnibiTokenSlice negative_name_slice =
	    negative_name_start < 0
		? (OnibiTokenSlice){0, 0, 0}
		: onibi_token_vector_copy(
		      tokens, RSTRING_PTR(src) + negative_name_start,
		      (size_t)negative_name_length);
	ID name_id = name_start < 0 ? 0
				    : rb_intern2(RSTRING_PTR(src) + name_start,
						 name_length);
	OnibiTokenRecord record = {
	    kind,
	    byte,
	    start,
	    i + 1,
	    name_slice,
	    negative_name_slice,
	    literal_slice,
	    capture_number,
	    name_id,
	    name_id == 0 ? ONIBI_ASCII_PROP_UNKNOWN
			 : onibi_ascii_property_kind_id(name_id),
	    (unsigned char)has_capture_number,
	    (unsigned char)(name_start >= 0 &&
			    memchr(RSTRING_PTR(src) + name_start, 'i',
				   (size_t)name_length) != NULL),
	    (unsigned char)(option_negative ? 1 : 0)};
	onibi_token_record_push(tokens, record);
	if (kind == ONIBI_TOKEN_GROUP_END && extended_depth > 0) {
	    int prior_extended = extended_stack[--extended_depth];
	    if (prior_extended >= 0) extended = prior_extended;
	}
    }
}


