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

/* Append one decimal digit without ever evaluating a signed overflowing
 * multiply.  Numeric backreferences use this helper for every digit. */
static long
onibi_checked_decimal_append(long value, unsigned char digit)
{
    if (digit > 9 || value > (LONG_MAX - (long)digit) / 10)
	rb_raise(eRegexpError, "numeric backreference is too large");
    return value * 10 + (long)digit;
}

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
    ONIBI_VECTOR_RELEASE(vector->items, vector->count, vector->capacity);
    ONIBI_VECTOR_RELEASE(vector->bytes, vector->bytes_count,
			 vector->bytes_capacity);
}

static OnibiTokenSlice
onibi_token_vector_copy(OnibiTokenVector *vector, const char *bytes,
			size_t length)
{
    OnibiTokenSlice slice = {0, 0, 1};
    if (length == 0) return slice;
    ONIBI_VECTOR_RESERVE(vector->bytes, vector->bytes_count,
			 vector->bytes_capacity, unsigned char, length, 64,
			 "token byte storage is too large");
    size_t required = vector->bytes_count + length;
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
    ONIBI_VECTOR_RELEASE(arena->nodes, arena->count, arena->capacity);
    ONIBI_VECTOR_RELEASE(arena->bytes, arena->bytes_count,
			 arena->bytes_capacity);
    arena->root = ONIBI_AST_NONE;
}

static OnibiAstId
onibi_ast_arena_add(OnibiAstArena *arena, OnibiAstKind kind,
		    const OnibiTokenRecord *token)
{
    if (arena->count >= UINT32_MAX ||
	(arena->count == arena->capacity && arena->capacity > UINT32_MAX / 2U))
	rb_raise(rb_eNoMemError, "AST node arena is too large");
    ONIBI_VECTOR_RESERVE(arena->nodes, arena->count, arena->capacity,
			 OnibiAstNode, 1, 32, "AST node arena is too large");
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
    ONIBI_VECTOR_PUSH(node->children, node->child_count, node->child_capacity,
		      OnibiAstId, child, 4, "AST child vector is too large");
}

static void
onibi_ast_add_range(OnibiAstArena *arena, OnibiAstId parent,
		    OnibiAstRange range)
{
    OnibiAstNode *node = onibi_ast_node_at(arena, parent);
    ONIBI_VECTOR_PUSH(node->ranges, node->range_count, node->range_capacity,
		      OnibiAstRange, range, 4, "AST range vector is too large");
}

static OnibiTokenSlice
onibi_ast_arena_copy_bytes(OnibiAstArena *arena, const unsigned char *bytes,
			   size_t length)
{
    ONIBI_VECTOR_RESERVE(arena->bytes, arena->bytes_count,
			 arena->bytes_capacity, unsigned char, length, 64,
			 "AST byte arena is too large");
    size_t required = arena->bytes_count + length;
    OnibiTokenSlice slice = {arena->bytes_count, length, 1};
    memcpy(arena->bytes + arena->bytes_count, bytes, length);
    arena->bytes_count = required;
    return slice;
}

static void
onibi_token_record_push(OnibiTokenVector *vector, OnibiTokenRecord record)
{
    ONIBI_VECTOR_PUSH(vector->items, vector->count, vector->capacity,
		      OnibiTokenRecord, record, 16,
		      "token vector is too large");
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
	    /* Three octal digits form one byte.  Resolve this form before the
	       numeric backreference rule.  The parser must not receive \101 as
	       capture number 101. */
	    int three_digit_octal =
		escaped >= '1' && escaped <= '7' && i + 2 < RSTRING_LEN(src) &&
		RSTRING_PTR(src)[i + 2] >= '0' &&
		RSTRING_PTR(src)[i + 2] <= '7' && i + 3 < RSTRING_LEN(src) &&
		RSTRING_PTR(src)[i + 3] >= '0' &&
		RSTRING_PTR(src)[i + 3] <= '7';
	    if (!three_digit_octal && escaped >= '1' && escaped <= '9' &&
		i + 1 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] >= '0' &&
		RSTRING_PTR(src)[i + 1] <= '9') {
		long number = escaped - '0';
		i++;
		while (i + 1 < RSTRING_LEN(src) &&
		       RSTRING_PTR(src)[i + 1] >= '0' &&
		       RSTRING_PTR(src)[i + 1] <= '9') {
		    number = onibi_checked_decimal_append(
			number, (unsigned char)(RSTRING_PTR(src)[++i] - '0'));
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
