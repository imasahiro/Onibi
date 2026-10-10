#include "onibi_ast_internal.h"

/* Parser implementation: token ranges become typed AST node IDs. */
static OnibiAstId onibi_c_parse_range(const OnibiTokenVector *tokens,
				      OnibiAstArena *arena,
				      rb_encoding *encoding, long begin,
				      long end);

/* MRI rejects an empty name, a leading hyphen, and a leading decimal digit.
 * Other name bytes stay encoded source data. */
static int
onibi_capture_name_invalid(const unsigned char *name, size_t length,
			   rb_encoding *encoding)
{
    if (length == 0) return 1;

    const char *cursor = (const char *)name;
    const char *end = cursor + length;
    int character_width = 0;
    int first = rb_enc_ascget(cursor, end, &character_width, encoding);
    unsigned int codepoint;
    if (first >= 0) {
	if (character_width <= 0)
	    rb_raise(eRegexpError, "invalid multibyte character");
	codepoint = (unsigned int)first;
    }
    else {
	int encoded_length = rb_enc_precise_mbclen(cursor, end, encoding);
	if (!ONIGENC_MBCLEN_CHARFOUND_P(encoded_length))
	    rb_raise(eRegexpError, "invalid multibyte character");
	int width = ONIGENC_MBCLEN_CHARFOUND_LEN(encoded_length);
	if (width <= 0 || cursor + width > end)
	    rb_raise(eRegexpError, "invalid multibyte character");
	codepoint =
	    rb_enc_codepoint_len(cursor, end, &character_width, encoding);
	if (character_width != width)
	    rb_raise(eRegexpError, "invalid multibyte character");
    }
    return codepoint == (unsigned int)'-' ||
	   (codepoint >= (unsigned int)'0' && codepoint <= (unsigned int)'9') ||
	   rb_enc_isctype((OnigCodePoint)codepoint, ONIGENC_CTYPE_DIGIT,
			  encoding);
}

static long
onibi_c_repeat_close(const OnibiTokenVector *tokens, long open, long end)
{
    for (long i = open + 1; i < end; i++) {
	const OnibiTokenRecord *token = onibi_token_at(tokens, i);
	if (token->kind == ONIBI_TOKEN_QUANTIFIER && token->byte == '}')
	    return i;
    }
    return -1;
}

static int
onibi_c_repeat_shape_p(const OnibiTokenVector *tokens, long open, long close)
{
    if (close <= open + 1) return 0;

    const OnibiTokenRecord *previous = onibi_token_at(tokens, open);
    if (previous->end != previous->start + 1) return 0;
    long comma = -1;
    size_t lower_digits = 0;
    size_t upper_digits = 0;
    for (long i = open + 1; i < close; i++) {
	const OnibiTokenRecord *token = onibi_token_at(tokens, i);
	if (previous->end != token->start || token->end != token->start + 1 ||
	    token->kind != ONIBI_TOKEN_LITERAL)
	    return 0;
	if (token->byte == ',') {
	    if (comma >= 0) return 0;
	    comma = i;
	}
	else if (token->byte >= '0' && token->byte <= '9') {
	    if (comma < 0)
		lower_digits++;
	    else
		upper_digits++;
	}
	else {
	    return 0;
	}
	previous = token;
    }
    const OnibiTokenRecord *close_token = onibi_token_at(tokens, close);
    if (previous->end != close_token->start ||
	close_token->end != close_token->start + 1)
	return 0;

    if (comma < 0) return lower_digits > 0;
    return lower_digits > 0 || upper_digits > 0;
}

static int
onibi_c_repeat_interval_p(const OnibiTokenVector *tokens, long open, long end)
{
    long close = onibi_c_repeat_close(tokens, open, end);
    return close >= 0 && onibi_c_repeat_shape_p(tokens, open, close);
}

static OnibiAstId
onibi_c_parse_class_part(const OnibiTokenVector *tokens, OnibiAstArena *arena,
			 const OnibiTokenRecord *anchor, long begin, long end)
{
    long depth = 0;
    long intersection = -1;
    for (long i = begin; i + 1 < end; i++) {
	const OnibiTokenRecord *token = onibi_token_at(tokens, i);
	if (token->kind == ONIBI_TOKEN_CLASS_START) {
	    depth++;
	    continue;
	}
	if (token->kind == ONIBI_TOKEN_CLASS_END) {
	    if (depth > 0) depth--;
	    continue;
	}
	if (depth == 0 && token->kind == ONIBI_TOKEN_LITERAL &&
	    token->byte == '&' && !token->from_escape &&
	    onibi_token_at(tokens, i + 1)->kind == ONIBI_TOKEN_LITERAL &&
	    onibi_token_at(tokens, i + 1)->byte == '&' &&
	    !onibi_token_at(tokens, i + 1)->from_escape) {
	    intersection = i;
	    break;
	}
    }
    if (intersection >= 0) {
	OnibiAstId id =
	    onibi_ast_arena_add(arena, ONIBI_AST_CLASS_INTERSECTION, anchor);
	onibi_ast_add_child(arena, id,
			    onibi_c_parse_class_part(tokens, arena, anchor,
						     begin, intersection));
	onibi_ast_add_child(arena, id,
			    onibi_c_parse_class_part(tokens, arena, anchor,
						     intersection + 2, end));
	return id;
    }

    OnibiAstId id =
	onibi_ast_arena_add(arena, ONIBI_AST_CHARACTER_CLASS, anchor);
    for (long i = begin; i < end; i++) {
	const OnibiTokenRecord *token = onibi_token_at(tokens, i);
	if (token->kind == ONIBI_TOKEN_CLASS_NEGATE && i == begin) {
	    onibi_ast_node_at(arena, id)->flags |= ONIBI_AST_NODE_NEGATED;
	    continue;
	}
	if (token->kind == ONIBI_TOKEN_CLASS_START) {
	    long close = token->matching;
	    if (close < 0 || close >= end)
		rb_raise(eRegexpError, "unterminated nested character class");
	    OnibiAstId nested =
		onibi_c_parse_class_part(tokens, arena, token, i + 1, close);
	    onibi_ast_node_at(arena, nested)->end =
		onibi_token_at(tokens, close)->end;
	    onibi_ast_add_child(arena, id, nested);
	    i = close;
	    continue;
	}
	if (token->kind == ONIBI_TOKEN_CLASS_RANGE && i > begin &&
	    i + 1 < end) {
	    const OnibiTokenRecord *first = onibi_token_at(tokens, i - 1);
	    const OnibiTokenRecord *last = onibi_token_at(tokens, i + 1);
	    if (first->kind != ONIBI_TOKEN_LITERAL ||
		last->kind != ONIBI_TOKEN_LITERAL)
		rb_raise(eRegexpError,
			 "invalid range endpoint in character class");
	    OnibiTokenSlice first_slice = first->bytes;
	    OnibiTokenSlice last_slice = last->bytes;
	    if (first_slice.present != last_slice.present) {
		if (!first_slice.present)
		    first_slice =
			onibi_ast_arena_copy_bytes(arena, &first->byte, 1);
		if (!last_slice.present)
		    last_slice =
			onibi_ast_arena_copy_bytes(arena, &last->byte, 1);
	    }
	    if (first_slice.present && last_slice.present) {
		size_t common = first_slice.length < last_slice.length
				    ? first_slice.length
				    : last_slice.length;
		int order = memcmp(arena->bytes + first_slice.offset,
				   arena->bytes + last_slice.offset, common);
		if (order == 0)
		    order =
			first_slice.length < last_slice.length
			    ? -1
			    : (first_slice.length > last_slice.length ? 1 : 0);
		if (order > 0)
		    rb_raise(eRegexpError, "empty range in character class");
	    }
	    else if (first->byte > last->byte) {
		rb_raise(eRegexpError, "empty range in character class");
	    }
	    OnibiAstRange range = {first_slice,		last_slice,
				   first->byte,		last->byte,
				   first_slice.present, last_slice.present};
	    onibi_ast_add_range(arena, id, range);
	    i++;
	    continue;
	}
	if (token->kind == ONIBI_TOKEN_CLASS_END ||
	    token->kind == ONIBI_TOKEN_CLASS_RANGE)
	    continue;
	OnibiAstKind kind = token->kind == ONIBI_TOKEN_LITERAL
				? ONIBI_AST_LITERAL
				: ((token->kind == ONIBI_TOKEN_ESCAPE ||
				    token->kind == ONIBI_TOKEN_META_ESCAPE)
				       ? ONIBI_AST_ESCAPE
				       : ONIBI_AST_UNKNOWN);
	if (kind == ONIBI_AST_UNKNOWN && token->kind != ONIBI_TOKEN_POSIX_CLASS)
	    rb_raise(eRegexpError, "unsupported character class token");
	if (token->kind == ONIBI_TOKEN_POSIX_CLASS &&
	    onibi_posix_kind_id(token->name_id) == ONIBI_POSIX_UNKNOWN)
	    rb_raise(eRegexpError, "unknown POSIX character class");
	OnibiAstId child = onibi_ast_arena_add(arena, kind, token);
	onibi_ast_add_child(arena, id, child);
    }
    return id;
}

static OnibiAstId
onibi_c_parse_atom(const OnibiTokenVector *tokens, OnibiAstArena *arena,
		   rb_encoding *encoding, long *index, long end)
{
    const OnibiTokenRecord *token = onibi_token_at(tokens, *index);
    OnibiTokenKind token_kind = token->kind;
    if (token_kind == ONIBI_TOKEN_QUANTIFIER &&
	(token->byte == '}' ||
	 (token->byte == '{' &&
	  !onibi_c_repeat_interval_p(tokens, *index, end))))
	token_kind = ONIBI_TOKEN_LITERAL;
    OnibiAstKind group_kind = ONIBI_AST_UNKNOWN;
    if (token_kind == ONIBI_TOKEN_LOOKAHEAD_START)
	group_kind = ONIBI_AST_LOOKAHEAD;
    else if (token_kind == ONIBI_TOKEN_LOOKBEHIND_START)
	group_kind = ONIBI_AST_LOOKBEHIND;
    else if (token_kind == ONIBI_TOKEN_OPTION_SCOPE_START)
	group_kind = ONIBI_AST_OPTION_SCOPE;
    else if (token_kind == ONIBI_TOKEN_NONCAPTURE_START)
	group_kind = ONIBI_AST_GROUP;
    else if (token_kind == ONIBI_TOKEN_ATOMIC_START)
	group_kind = ONIBI_AST_ATOMIC;
    else if (token_kind == ONIBI_TOKEN_ABSENCE_START)
	group_kind = ONIBI_AST_ABSENCE;
    else if (token_kind == ONIBI_TOKEN_CONDITIONAL_START)
	group_kind = ONIBI_AST_CONDITIONAL;
    else if (token_kind == ONIBI_TOKEN_GROUP_START)
	group_kind = ONIBI_AST_CAPTURE;

    if (group_kind != ONIBI_AST_UNKNOWN) {
	long close = token->matching;
	if (close < 0 || close >= end)
	    rb_raise(eRegexpError, "unterminated regexp group");
	OnibiAstId id = onibi_ast_arena_add(arena, group_kind, token);
	OnibiAstNode *node = onibi_ast_node_at(arena, id);
	node->end = onibi_token_at(tokens, close)->end;
	if (group_kind == ONIBI_AST_CONDITIONAL) {
	    OnibiAstId body =
		onibi_c_parse_range(tokens, arena, encoding, *index + 1, close);
	    const OnibiAstNode *body_node = onibi_ast_node_const(arena, body);
	    if (body_node->kind == ONIBI_AST_ALTERNATIVE &&
		body_node->child_count == 2) {
		OnibiAstId yes = body_node->children[0];
		OnibiAstId no = body_node->children[1];
		node = onibi_ast_node_at(arena, id);
		node->yes = yes;
		node->no = no;
	    }
	    else {
		OnibiAstId no =
		    onibi_c_parse_range(tokens, arena, encoding, close, close);
		node = onibi_ast_node_at(arena, id);
		node->yes = body;
		node->no = no;
	    }
	}
	else {
	    OnibiAstId body =
		onibi_c_parse_range(tokens, arena, encoding, *index + 1, close);
	    node = onibi_ast_node_at(arena, id);
	    node->body = body;
	}
	if (group_kind == ONIBI_AST_LOOKAHEAD ||
	    group_kind == ONIBI_AST_LOOKBEHIND) {
	    if (token->byte == '=') node->flags |= ONIBI_AST_NODE_POSITIVE;
	}
	if (group_kind == ONIBI_AST_CAPTURE) {
	    node->flags |= ONIBI_AST_NODE_CAPTURING;
	    if (node->name.present) {
		const unsigned char *name = arena->bytes + node->name.offset;
		if (onibi_capture_name_invalid(name, node->name.length,
					       encoding))
		    rb_raise(eRegexpError, "invalid capture name");
	    }
	}
	if (group_kind == ONIBI_AST_OPTION_SCOPE && token->negative)
	    node->flags |= ONIBI_AST_NODE_NEGATIVE;
	*index = close + 1;
	return id;
    }

    if (token_kind == ONIBI_TOKEN_OPTION_GLOBAL) {
	OnibiAstId id =
	    onibi_ast_arena_add(arena, ONIBI_AST_OPTION_GLOBAL, token);
	if (token->negative)
	    onibi_ast_node_at(arena, id)->flags |= ONIBI_AST_NODE_NEGATIVE;
	(*index)++;
	return id;
    }
    if (token_kind == ONIBI_TOKEN_CLASS_START) {
	long close = token->matching;
	if (close < 0 || close >= end)
	    rb_raise(eRegexpError, "unterminated character class");
	OnibiAstId id =
	    onibi_c_parse_class_part(tokens, arena, token, *index + 1, close);
	onibi_ast_node_at(arena, id)->end = onibi_token_at(tokens, close)->end;
	*index = close + 1;
	return id;
    }

    OnibiAstKind kind =
	token_kind == ONIBI_TOKEN_WILDCARD
	    ? ONIBI_AST_ANY
	    : (token_kind == ONIBI_TOKEN_ANCHOR
		   ? ONIBI_AST_ANCHOR
		   : ((token_kind == ONIBI_TOKEN_ESCAPE ||
		       token_kind == ONIBI_TOKEN_META_ESCAPE)
			  ? ONIBI_AST_ESCAPE
			  : (token_kind == ONIBI_TOKEN_MATCH_RESET
				 ? ONIBI_AST_MATCH_RESET
				 : (token_kind == ONIBI_TOKEN_BACKREF
					? ONIBI_AST_BACKREF
					: (token_kind == ONIBI_TOKEN_SUBROUTINE
					       ? ONIBI_AST_SUBROUTINE
					       : (token_kind ==
							  ONIBI_TOKEN_LITERAL
						      ? ONIBI_AST_LITERAL
						      : ONIBI_AST_UNKNOWN))))));
    if (kind == ONIBI_AST_UNKNOWN)
	rb_raise(eRegexpError, "unexpected token in expression");
    OnibiAstId id = onibi_ast_arena_add(arena, kind, token);
    OnibiAstNode *node = onibi_ast_node_at(arena, id);
    /* Escape spelling is retained as a byte.  Do not intern source text. */
    if (kind == ONIBI_AST_ESCAPE && !node->name.present) node->name_id = 0;
    if (kind == ONIBI_AST_BACKREF && !node->name.present && !token->has_capture)
	node->capture = token->byte - '0';
    (*index)++;
    return id;
}

static OnibiAstId
onibi_c_parse_range(const OnibiTokenVector *tokens, OnibiAstArena *arena,
		    rb_encoding *encoding, long begin, long end)
{
    long part = begin;
    long depth = 0;
    OnibiAstId alternative = ONIBI_AST_NONE;
    for (long i = begin; i < end; i++) {
	OnibiTokenKind kind = onibi_token_at(tokens, i)->kind;
	if (kind == ONIBI_TOKEN_GROUP_START ||
	    kind == ONIBI_TOKEN_NONCAPTURE_START ||
	    kind == ONIBI_TOKEN_ATOMIC_START ||
	    kind == ONIBI_TOKEN_ABSENCE_START ||
	    kind == ONIBI_TOKEN_CONDITIONAL_START ||
	    kind == ONIBI_TOKEN_LOOKAHEAD_START ||
	    kind == ONIBI_TOKEN_LOOKBEHIND_START ||
	    kind == ONIBI_TOKEN_OPTION_SCOPE_START ||
	    kind == ONIBI_TOKEN_CLASS_START)
	    depth++;
	else if (kind == ONIBI_TOKEN_GROUP_END || kind == ONIBI_TOKEN_CLASS_END)
	    depth--;
	else if (kind == ONIBI_TOKEN_ALTERNATION && depth == 0) {
	    if (alternative == ONIBI_AST_NONE)
		alternative =
		    onibi_ast_arena_add(arena, ONIBI_AST_ALTERNATIVE, NULL);
	    onibi_ast_add_child(
		arena, alternative,
		onibi_c_parse_range(tokens, arena, encoding, part, i));
	    part = i + 1;
	}
    }
    if (alternative != ONIBI_AST_NONE) {
	onibi_ast_add_child(
	    arena, alternative,
	    onibi_c_parse_range(tokens, arena, encoding, part, end));
	return alternative;
    }

    OnibiAstId sequence = onibi_ast_arena_add(arena, ONIBI_AST_SEQUENCE, NULL);
    for (long i = begin; i < end;) {
	OnibiAstId atom = onibi_c_parse_atom(tokens, arena, encoding, &i, end);
    parse_atom_modifiers:
	if (i < end &&
	    onibi_token_at(tokens, i)->kind == ONIBI_TOKEN_QUANTIFIER) {
	    const OnibiTokenRecord *modifier = onibi_token_at(tokens, i);
	    long marker = modifier->byte;
	    long min = 0, max = 0;
	    int has_max = 0;
	    int fixed_interval = 0;
	    long close = i;
	    if (marker == '*' || marker == '+' || marker == '?') {
		min = marker == '+' ? 1 : 0;
		if (marker == '?') {
		    max = 1;
		    has_max = 1;
		}
		i++;
	    }
	    else if (marker == '{') {
		close = onibi_c_repeat_close(tokens, i, end);
		if (close < 0 || !onibi_c_repeat_shape_p(tokens, i, close)) {
		    onibi_ast_add_child(arena, sequence, atom);
		    atom =
			onibi_ast_arena_add(arena, ONIBI_AST_LITERAL, modifier);
		    i++;
		    goto parse_atom_modifiers;
		}
		char spec[128];
		size_t length = 0;
		for (long j = i + 1; j < close; j++) {
		    if (length + 1 >= sizeof(spec))
			rb_raise(eRegexpError, "quantifier is too large");
		    spec[length++] = (char)onibi_token_at(tokens, j)->byte;
		}
		spec[length] = '\0';
		char *comma = memchr(spec, ',', length);
		char *endptr = NULL;
		if (comma != NULL) {
		    if (comma == spec)
			min = 0;
		    else {
			min = onibi_parse_count(spec, &endptr);
			if (endptr != comma)
			    rb_raise(eRegexpError, "invalid repeat range");
		    }
		    if (comma + 1 < spec + length) {
			max = onibi_parse_count(comma + 1, &endptr);
			if (endptr != spec + length)
			    rb_raise(eRegexpError, "invalid repeat range");
			has_max = 1;
		    }
		}
		else {
		    min = onibi_parse_count(spec, &endptr);
		    if (endptr != spec + length)
			rb_raise(eRegexpError, "invalid repeat range");
		    max = min;
		    has_max = 1;
		    fixed_interval = 1;
		}
		if (has_max && max < min)
		    rb_raise(eRegexpError, "invalid quantifier range");
		i = close + 1;
	    }
	    else {
		onibi_ast_add_child(arena, sequence, atom);
		continue;
	    }
	    /* Onigmo parses a ? after {n} as a greedy optional exact repeat.
	     * It is not the lazy suffix used by {n,n}? and other ranges. */
	    if (marker == '{' && fixed_interval && i < end &&
		onibi_token_at(tokens, i)->kind == ONIBI_TOKEN_QUANTIFIER &&
		onibi_token_at(tokens, i)->byte == '?') {
		OnibiAstId fixed =
		    onibi_ast_arena_add(arena, ONIBI_AST_QUANTIFIER, modifier);
		OnibiAstNode *fixed_node = onibi_ast_node_at(arena, fixed);
		fixed_node->atom = atom;
		fixed_node->min = min;
		fixed_node->max = max;
		fixed_node->end = onibi_token_at(tokens, close)->end;
		fixed_node->flags |=
		    ONIBI_AST_NODE_GREEDY | ONIBI_AST_NODE_HAS_MAX;

		const OnibiTokenRecord *optional = onibi_token_at(tokens, i++);
		OnibiAstId quantifier =
		    onibi_ast_arena_add(arena, ONIBI_AST_QUANTIFIER, optional);
		OnibiAstNode *node = onibi_ast_node_at(arena, quantifier);
		node->atom = fixed;
		node->min = 0;
		node->max = 1;
		node->start = modifier->start;
		node->flags |= ONIBI_AST_NODE_GREEDY | ONIBI_AST_NODE_HAS_MAX;
		atom = quantifier;
		goto append_atom;
	    }
	    if (onibi_ast_node_const(arena, atom)->kind == ONIBI_AST_QUANTIFIER)
		rb_raise(eRegexpError, "nested quantifier");
	    OnibiAstId quantifier =
		onibi_ast_arena_add(arena, ONIBI_AST_QUANTIFIER, modifier);
	    OnibiAstNode *node = onibi_ast_node_at(arena, quantifier);
	    node->atom = atom;
	    node->min = min;
	    node->max = max;
	    node->flags |= ONIBI_AST_NODE_GREEDY;
	    if (has_max) node->flags |= ONIBI_AST_NODE_HAS_MAX;
	    if (i < end &&
		onibi_token_at(tokens, i)->kind == ONIBI_TOKEN_QUANTIFIER) {
		if (onibi_token_at(tokens, i)->byte == '?') {
		    node->flags &= ~ONIBI_AST_NODE_GREEDY;
		    i++;
		}
		else if (onibi_token_at(tokens, i)->byte == '+') {
		    node->flags |= ONIBI_AST_NODE_POSSESSIVE;
		    i++;
		}
	    }
	    atom = quantifier;
	}
    append_atom:
	onibi_ast_add_child(arena, sequence, atom);
    }
    return sequence;
}

static VALUE
onibi_parser_parse_internal(VALUE source, VALUE options,
			    const OnibiTokenVector *tokens)
{
    source = StringValue(source);
    if (tokens == NULL)
	rb_raise(rb_eArgError, "parser requires a token vector");
    OnibiParsed *parsed;
    VALUE result = TypedData_Make_Struct(rb_cObject, OnibiParsed,
					 &onibi_parsed_type, parsed);
    onibi_ast_arena_init(&parsed->arena, tokens);
    memset(&parsed->semantics, 0, sizeof(parsed->semantics));
    parsed->ast_flags = 0;
    parsed->encoding_index = rb_enc_get_index(source);
    parsed->options = onibi_option_mask(options);
    parsed->arena.root = onibi_c_parse_range(
	tokens, &parsed->arena, rb_enc_get(source), 0, (long)tokens->count);
    if (onibi_ast_safe_multibyte_class(&parsed->arena, parsed->arena.root))
	parsed->ast_flags |= ONIBI_AST_FLAG_SAFE_MULTIBYTE_CLASS;
    OnibiAstAnalysis analysis = {0};
    (void)onibi_ast_nullable_scan(&parsed->arena, parsed->arena.root,
				  &analysis);
    if (analysis.flags & ONIBI_AST_ANALYSIS_ANCHOR_REPEAT)
	parsed->ast_flags |= ONIBI_AST_FLAG_ANCHOR_REPEAT;
    if (analysis.flags & ONIBI_AST_ANALYSIS_NULLABLE_ABSENCE)
	parsed->ast_flags |= ONIBI_AST_FLAG_NULLABLE_ABSENCE;
    if (analysis.flags & ONIBI_AST_ANALYSIS_NULLABLE_CAPTURE)
	parsed->ast_flags |= ONIBI_AST_FLAG_NULLABLE_CAPTURE;
    return result;
}
