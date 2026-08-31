/* Parser implementation: token ranges become typed AST node IDs. */
static OnibiAstId onibi_c_parse_range(const OnibiTokenVector *tokens,
				      OnibiAstArena *arena, long begin,
				      long end);

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
	    token->byte == '&' &&
	    onibi_token_at(tokens, i + 1)->kind == ONIBI_TOKEN_LITERAL &&
	    onibi_token_at(tokens, i + 1)->byte == '&') {
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
	    long close = onibi_c_find_close(
		tokens, i, end, ONIBI_TOKEN_CLASS_START, ONIBI_TOKEN_CLASS_END);
	    if (close < 0)
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
		   long *index, long end)
{
    const OnibiTokenRecord *token = onibi_token_at(tokens, *index);
    OnibiTokenKind token_kind = token->kind;
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
	long close = onibi_c_find_close(tokens, *index, end, token_kind,
					ONIBI_TOKEN_GROUP_END);
	if (close < 0) rb_raise(eRegexpError, "unterminated regexp group");
	OnibiAstId id = onibi_ast_arena_add(arena, group_kind, token);
	OnibiAstNode *node = onibi_ast_node_at(arena, id);
	node->end = onibi_token_at(tokens, close)->end;
	if (group_kind == ONIBI_AST_CONDITIONAL) {
	    OnibiAstId body =
		onibi_c_parse_range(tokens, arena, *index + 1, close);
	    const OnibiAstNode *body_node = onibi_ast_node_const(arena, body);
	    if (body_node->kind == ONIBI_AST_ALTERNATIVE &&
		body_node->child_count == 2) {
		node = onibi_ast_node_at(arena, id);
		node->yes = body_node->children[0];
		node->no = body_node->children[1];
	    }
	    else {
		node = onibi_ast_node_at(arena, id);
		node->yes = body;
		node->no = onibi_c_parse_range(tokens, arena, close, close);
	    }
	}
	else {
	    node->body = onibi_c_parse_range(tokens, arena, *index + 1, close);
	    node = onibi_ast_node_at(arena, id);
	}
	if (group_kind == ONIBI_AST_LOOKAHEAD ||
	    group_kind == ONIBI_AST_LOOKBEHIND) {
	    if (token->byte == '=') node->flags |= ONIBI_AST_NODE_POSITIVE;
	}
	if (group_kind == ONIBI_AST_CAPTURE) {
	    node->flags |= ONIBI_AST_NODE_CAPTURING;
	    if (node->name.present) {
		const unsigned char *name = arena->bytes + node->name.offset;
		if (node->name.length == 0 ||
		    !((name[0] >= 'A' && name[0] <= 'Z') ||
		      (name[0] >= 'a' && name[0] <= 'z')))
		    rb_raise(eRegexpError, "invalid capture name");
		for (size_t i = 1; i < node->name.length; i++)
		    if (!((name[i] >= 'A' && name[i] <= 'Z') ||
			  (name[i] >= 'a' && name[i] <= 'z') ||
			  (name[i] >= '0' && name[i] <= '9') || name[i] == '_'))
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
	long close =
	    onibi_c_find_close(tokens, *index, end, ONIBI_TOKEN_CLASS_START,
			       ONIBI_TOKEN_CLASS_END);
	if (close < 0) rb_raise(eRegexpError, "unterminated character class");
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
    if (kind == ONIBI_AST_ESCAPE && !node->name.present)
	node->name_id = rb_intern2((const char *)&token->byte, 1);
    if (kind == ONIBI_AST_BACKREF && !node->name.present && !token->has_capture)
	node->capture = token->byte - '0';
    (*index)++;
    return id;
}

static OnibiAstId
onibi_c_parse_range(const OnibiTokenVector *tokens, OnibiAstArena *arena,
		    long begin, long end)
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
	    onibi_ast_add_child(arena, alternative,
				onibi_c_parse_range(tokens, arena, part, i));
	    part = i + 1;
	}
    }
    if (alternative != ONIBI_AST_NONE) {
	onibi_ast_add_child(arena, alternative,
			    onibi_c_parse_range(tokens, arena, part, end));
	return alternative;
    }

    OnibiAstId sequence = onibi_ast_arena_add(arena, ONIBI_AST_SEQUENCE, NULL);
    for (long i = begin; i < end;) {
	OnibiAstId atom = onibi_c_parse_atom(tokens, arena, &i, end);
	if (i < end &&
	    onibi_token_at(tokens, i)->kind == ONIBI_TOKEN_QUANTIFIER) {
	    const OnibiTokenRecord *modifier = onibi_token_at(tokens, i);
	    long marker = modifier->byte;
	    long min = 0, max = 0;
	    int has_max = 0;
	    int valid = 1;
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
		close = i + 1;
		while (close < end &&
		       onibi_token_at(tokens, close)->byte != '}')
		    close++;
		if (close >= end)
		    rb_raise(eRegexpError, "unterminated quantifier");
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
		if (length == 0 ||
		    (comma != NULL &&
		     memchr(comma + 1, ',',
			    length - (size_t)(comma + 1 - spec)) != NULL))
		    valid = 0;
		if (valid && comma != NULL) {
		    if (comma == spec)
			min = 0;
		    else {
			min = onibi_parse_count(spec, &endptr);
			if (endptr != comma) valid = 0;
		    }
		    if (comma + 1 < spec + length) {
			max = onibi_parse_count(comma + 1, &endptr);
			if (endptr != spec + length) valid = 0;
			has_max = 1;
		    }
		}
		else if (valid) {
		    min = onibi_parse_count(spec, &endptr);
		    if (endptr != spec + length) valid = 0;
		    max = min;
		    has_max = 1;
		}
		if (valid && has_max && max < min)
		    rb_raise(eRegexpError, "invalid quantifier range");
		if (!valid) {
		    onibi_ast_add_child(arena, sequence, atom);
		    for (long j = i; j <= close; j++) {
			OnibiAstId literal =
			    onibi_ast_arena_add(arena, ONIBI_AST_LITERAL,
						onibi_token_at(tokens, j));
			onibi_ast_add_child(arena, sequence, literal);
		    }
		    i = close + 1;
		    continue;
		}
		i = close + 1;
	    }
	    else {
		onibi_ast_add_child(arena, sequence, atom);
		continue;
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
    parsed->ast_flags = 0;
    parsed->encoding_index = rb_enc_get_index(source);
    parsed->options = onibi_option_mask(options);
    parsed->arena.root =
	onibi_c_parse_range(tokens, &parsed->arena, 0, (long)tokens->count);
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
