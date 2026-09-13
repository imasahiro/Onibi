static onibi_fragment_t onibi_compile_node(OnibiAstId node_id,
					   onibi_gir_builder_t *builder);

#define ONIBI_FRAGMENT_EXIT_LAZY 1
#define ONIBI_FRAGMENT_NULLABLE_LAZY 2
#define ONIBI_FRAGMENT_LAZY_BOTH                                               \
    (ONIBI_FRAGMENT_EXIT_LAZY | ONIBI_FRAGMENT_NULLABLE_LAZY)

typedef struct {
    uint32_t rseq_features;
    uint32_t capture_count;
    uint32_t semantic_capture_count;
    uint32_t counter_count;
    OnibiExecutionKind execution_kind;
} VerifiedGIRAnalysis;

typedef struct {
    OnibiRSeqSubprogramVector subprograms;
    OnibiBackrefDescVector backrefs;
    OnibiIdVector backref_capture_ids;
    OnibiGirEdgeVector subprogram_entries;
    OnibiIdVector lookbehind_widths;
    OnibiSemanticClassVector classes;
    OnibiGirStateVector states;
    OnibiGirEdgeVector edges;
    OnibiGirEdgeVector start_edges;
    long accept;
    long capture_count;
    long counter_count;
    int options;
    VerifiedGIRAnalysis analysis;
    OnibiLoweringWork lowering_work;
} OnibiCompiled;

/* A compile owner contains every mutable allocation that can outlive one
 * pass.  The owner is stack scoped and is released by rb_ensure. */
typedef struct {
    onibi_allocation_owner_t allocations;
    onibi_gir_builder_t builder;
    OnibiGirEdgeVector start_edges;
    OnibiTaggedNfa nfa;
    onibi_fragment_t root_fragment;
    OnibiIdVector accept_starts;
    OnibiGActionVector pending_actions;
    int nfa_active;
    int root_fragment_active;
    int gir_transferred;
    int failure_phase;
    int *failure_fired;
    OnibiCompileOutcome *compile_outcome;
} OnibiCompilerOwner;
typedef struct {
    OnibiCompilerOwner *owner;
    VALUE parsed;
    int nfa_diagnostics;
} OnibiCompilerCall;

static void
onibi_compiler_mark_unsupported(const onibi_gir_builder_t *builder,
				OnibiUnsupportedReason reason)
{
    if (builder && builder->allocation_owner)
	onibi_compile_outcome_unsupported(
	    builder->allocation_owner->compile_outcome, reason);
}

static void
onibi_compiler_fail_if(OnibiCompilerOwner *owner, int phase)
{
    if (owner->failure_phase == phase) {
	if (owner->failure_fired) *owner->failure_fired = 1;
	rb_raise(eRegexpError, "injected compiler failure at pass %d", phase);
    }
}

/* Compiler pass contracts.  These records make ownership and pass order
 * explicit, even while several early analyses still share the C AST. */
typedef struct {
    OnibiParsed *parsed;
    int options;
} OnibiParseOutput;
typedef struct {
    OnibiParsed *parsed;
    const OnibiResolvedArena *semantics;
} OnibiResolveOutput;
typedef struct {
    OnibiParsed *parsed;
    const OnibiResolvedArena *semantics;
} OnibiNormalizeOutput;
typedef struct {
    OnibiParsed *parsed;
    const OnibiResolvedArena *semantics;
    onibi_gir_builder_t *builder;
    long capture_count;
    int nullable;
    long min_width;
    long max_width;
} OnibiAnalyzeOutput;
typedef struct {
    onibi_gir_builder_t *builder;
    OnibiGirEdgeVector *start_edges;
    long accept;
    long root_entry;
} OnibiLowerNfaOutput;
typedef struct {
    onibi_gir_builder_t *builder;
} OnibiGirOutput;
typedef struct {
    VALUE rseq;
} OnibiRseqOutput;
typedef struct {
    VALUE rseq;
} OnibiSearchMetadataOutput;
typedef ONIBI_VECTOR(OnibiClassExpr) OnibiClassExprVector;
ONIBI_VECTOR_DEFINE(onibi_class_expr_vector, OnibiClassExprVector,
		    OnibiClassExpr, 16,
		    "class expression exceeds the v1 size limit")
typedef ONIBI_VECTOR(OnigCodePoint) OnibiCodepointVector;
ONIBI_VECTOR_DEFINE(onibi_codepoint_vector, OnibiCodepointVector, OnigCodePoint,
		    16, "class case-fold closure exceeds the v1 size limit")

static void
onibi_class_expr_push(OnibiClassExprVector *expr, OnibiClassExprOp op,
		      uint32_t arg0, uint32_t arg1)
{
    if (expr->count >= UINT16_MAX / sizeof(OnibiClassExpr))
	onibi_compile_outcome_unsupported(
	    expr->allocation_owner->compile_outcome, ONIBI_UNSUPPORTED_LIMIT);
    if (expr->count >= UINT16_MAX / sizeof(OnibiClassExpr))
	rb_raise(eRegexpError, "class descriptor exceeds the v1 size limit");
    OnibiClassExpr item = {arg0, arg1, (uint8_t)op, 0, 0};
    onibi_class_expr_vector_push(expr, item);
}

static uint32_t
onibi_class_decode(const onibi_gir_builder_t *builder,
		   const unsigned char *bytes, size_t length)
{
    rb_encoding *encoding = rb_enc_from_index(builder->encoding_index);
    const char *begin = (const char *)bytes;
    const char *end = begin + length;
    int width = rb_enc_precise_mbclen(begin, end, encoding);
    if (!MBCLEN_CHARFOUND_P(width) ||
	(size_t)MBCLEN_CHARFOUND_LEN(width) != length)
	rb_raise(eRegexpError, "class character has an invalid encoding");
    return (uint32_t)rb_enc_mbc_to_codepoint(begin, end, encoding);
}

static void
onibi_class_expr_combine(OnibiClassExprVector *expr, size_t *operand_count,
			 OnibiClassExprOp op)
{
    if (*operand_count > 0) onibi_class_expr_push(expr, op, 0, 0);
    (*operand_count)++;
}

static uint32_t
onibi_class_property_ctype(const onibi_gir_builder_t *builder,
			   const OnibiAstNode *node, int *negated)
{
    const unsigned char *name = builder->ast->bytes + node->name.offset;
    size_t length = node->name.length;
    if (length > 0 && name[0] == '^') {
	name++;
	length--;
	*negated = !*negated;
    }
    rb_encoding *encoding = rb_enc_from_index(builder->encoding_index);
    int ctype = ONIGENC_PROPERTY_NAME_TO_CTYPE(
	encoding, (const OnigUChar *)name, (const OnigUChar *)name + length);
    if (ctype < 0) rb_raise(eRegexpError, "invalid character property name");
    return (uint32_t)ctype;
}

static uint32_t
onibi_class_named_ctype(const onibi_gir_builder_t *builder, const char *name)
{
    rb_encoding *encoding = rb_enc_from_index(builder->encoding_index);
    const OnigUChar *begin = (const OnigUChar *)name;
    int ctype =
	ONIGENC_PROPERTY_NAME_TO_CTYPE(encoding, begin, begin + strlen(name));
    if (ctype < 0) rb_raise(eRegexpError, "invalid character property name");
    return (uint32_t)ctype;
}

static void
onibi_class_expr_word(onibi_gir_builder_t *builder, OnibiClassExprVector *expr)
{
    rb_encoding *encoding = rb_enc_from_index(builder->encoding_index);
    if (!ONIGENC_IS_UNICODE(encoding)) {
	onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_CTYPE, ONIGENC_CTYPE_WORD,
			      0);
	return;
    }
    const char *const names[] = {"Alpha", "M", "Nd", "Pc", "Join_Control"};
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
	onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_CTYPE,
			      onibi_class_named_ctype(builder, names[i]), 0);
	if (i > 0) onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_UNION, 0, 0);
    }
}

static void
onibi_class_expr_ascii_escape(OnibiClassExprVector *expr, unsigned char code)
{
    const OnibiCodepointRange *ranges;
    size_t count;
    static const OnibiCodepointRange digit[] = {{'0', '9'}};
    static const OnibiCodepointRange space[] = {{'\t', '\r'}, {' ', ' '}};
    static const OnibiCodepointRange word[] = {
	{'0', '9'}, {'A', 'Z'}, {'_', '_'}, {'a', 'z'}};
    static const OnibiCodepointRange hex[] = {
	{'0', '9'}, {'A', 'F'}, {'a', 'f'}};
    if (code == 'd') {
	ranges = digit;
	count = sizeof(digit) / sizeof(digit[0]);
    }
    else if (code == 's') {
	ranges = space;
	count = sizeof(space) / sizeof(space[0]);
    }
    else if (code == 'w') {
	ranges = word;
	count = sizeof(word) / sizeof(word[0]);
    }
    else {
	ranges = hex;
	count = sizeof(hex) / sizeof(hex[0]);
    }
    for (size_t i = 0; i < count; i++) {
	onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_RANGE, ranges[i].first,
			      ranges[i].last);
	if (i > 0) onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_UNION, 0, 0);
    }
}

static void onibi_class_expr_ast(onibi_gir_builder_t *builder, OnibiAstId id,
				 OnibiClassExprVector *expr);

static void
onibi_class_expr_escape(onibi_gir_builder_t *builder, const OnibiAstNode *node,
			OnibiClassExprVector *expr)
{
    int negated = node->byte == 'P';
    uint32_t ctype;
    if (node->name.present) {
	const unsigned char *name = builder->ast->bytes + node->name.offset;
	size_t length = node->name.length;
	size_t first = length > 0 && name[0] == '^' ? 1 : 0;
	if (length - first == 4 && (memcmp(name + first, "Word", 4) == 0 ||
				    memcmp(name + first, "word", 4) == 0)) {
	    if (first != 0) negated = !negated;
	    onibi_class_expr_word(builder, expr);
	    if (negated)
		onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_NEGATE, 0, 0);
	    return;
	}
	ctype = onibi_class_property_ctype(builder, node, &negated);
    }
    else {
	unsigned char raw = (unsigned char)node->byte;
	unsigned char code = onibi_ascii_fold(raw);
	if (code != 'd' && code != 's' && code != 'w' && code != 'h') {
	    onibi_compiler_mark_unsupported(builder, ONIBI_UNSUPPORTED_CLASS);
	    rb_raise(eRegexpError, "escape is not supported in RSeq class");
	}
	onibi_class_expr_ascii_escape(expr, code);
	if (raw >= 'A' && raw <= 'Z') negated = !negated;
	if (negated) onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_NEGATE, 0, 0);
	return;
    }
    onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_CTYPE, ctype, 0);
    if (negated) onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_NEGATE, 0, 0);
}

static void
onibi_class_expr_ast(onibi_gir_builder_t *builder, OnibiAstId id,
		     OnibiClassExprVector *expr)
{
    const OnibiAstNode *node = onibi_ast_node_const(builder->ast, id);
    if (node->kind == ONIBI_AST_ESCAPE) {
	onibi_class_expr_escape(builder, node, expr);
	return;
    }
    if (node->kind == ONIBI_AST_CLASS_INTERSECTION) {
	if (node->child_count < 2)
	    rb_raise(eRegexpError, "class intersection has no operands");
	onibi_class_expr_ast(builder, node->children[0], expr);
	for (size_t i = 1; i < node->child_count; i++) {
	    onibi_class_expr_ast(builder, node->children[i], expr);
	    onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_INTERSECTION, 0, 0);
	}
	if (node->flags & ONIBI_AST_NODE_NEGATED)
	    onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_NEGATE, 0, 0);
	return;
    }
    size_t operands = 0;
    for (size_t i = 0; i < node->range_count; i++) {
	const OnibiAstRange *range = &node->ranges[i];
	const unsigned char *first =
	    range->first_has_bytes ? builder->ast->bytes + range->first.offset
				   : &range->first_byte;
	const unsigned char *last =
	    range->last_has_bytes ? builder->ast->bytes + range->last.offset
				  : &range->last_byte;
	size_t first_length = range->first_has_bytes ? range->first.length : 1;
	size_t last_length = range->last_has_bytes ? range->last.length : 1;
	uint32_t first_code = onibi_class_decode(builder, first, first_length);
	uint32_t last_code = onibi_class_decode(builder, last, last_length);
	if (first_code > last_code)
	    rb_raise(eRegexpError, "empty range in character class");
	onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_RANGE, first_code,
			      last_code);
	onibi_class_expr_combine(expr, &operands, ONIBI_CLASS_EXPR_UNION);
    }
    for (size_t i = 0; i < node->child_count; i++) {
	const OnibiAstNode *child =
	    onibi_ast_node_const(builder->ast, node->children[i]);
	if (child->token_kind == ONIBI_TOKEN_LITERAL ||
	    child->kind == ONIBI_AST_LITERAL) {
	    unsigned char single = (unsigned char)child->byte;
	    const unsigned char *bytes =
		child->bytes.present ? builder->ast->bytes + child->bytes.offset
				     : &single;
	    size_t length = child->bytes.present ? child->bytes.length : 1;
	    uint32_t codepoint = onibi_class_decode(builder, bytes, length);
	    onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_RANGE, codepoint,
				  codepoint);
	}
	else if (child->token_kind == ONIBI_TOKEN_ESCAPE ||
		 child->token_kind == ONIBI_TOKEN_META_ESCAPE ||
		 child->kind == ONIBI_AST_ESCAPE) {
	    onibi_class_expr_escape(builder, child, expr);
	}
	else if (child->token_kind == ONIBI_TOKEN_POSIX_CLASS) {
	    int ctype = onibi_unicode_ctype_id(child->name_id);
	    if (ctype < 0)
		rb_raise(eRegexpError, "unknown POSIX character class");
	    if (onibi_posix_kind_id(child->name_id) == ONIBI_POSIX_WORD)
		onibi_class_expr_word(builder, expr);
	    else
		onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_CTYPE,
				      (uint32_t)ctype, 0);
	}
	else if (child->kind == ONIBI_AST_CHARACTER_CLASS ||
		 child->kind == ONIBI_AST_CLASS_INTERSECTION) {
	    onibi_class_expr_ast(builder, node->children[i], expr);
	}
	else {
	    onibi_compiler_mark_unsupported(builder, ONIBI_UNSUPPORTED_CLASS);
	    rb_raise(eRegexpError, "unsupported character class token");
	}
	onibi_class_expr_combine(expr, &operands, ONIBI_CLASS_EXPR_UNION);
    }
    if (operands == 0)
	rb_raise(eRegexpError, "empty character class descriptor");
    if (node->flags & ONIBI_AST_NODE_NEGATED)
	onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_NEGATE, 0, 0);
}

static int
onibi_codepoint_range_compare(const void *left, const void *right)
{
    const OnibiCodepointRange *a = left;
    const OnibiCodepointRange *b = right;
    return a->first < b->first ? -1 : a->first > b->first ? 1 : 0;
}

static int
onibi_class_expr_hit(const OnibiClassExpr *expr, size_t count,
		     OnigCodePoint codepoint, rb_encoding *encoding,
		     unsigned char *stack)
{
    size_t depth = 0;
    for (size_t i = 0; i < count; i++) {
	if (expr[i].op == ONIBI_CLASS_EXPR_RANGE) {
	    stack[depth++] =
		codepoint >= expr[i].arg0 && codepoint <= expr[i].arg1;
	}
	else if (expr[i].op == ONIBI_CLASS_EXPR_CTYPE) {
	    stack[depth++] =
		ONIGENC_IS_CODE_CTYPE(encoding, codepoint,
				      (OnigCtype)expr[i].arg0) != 0;
	}
	else if (expr[i].op == ONIBI_CLASS_EXPR_NEGATE) {
	    stack[depth - 1U] = !stack[depth - 1U];
	}
	else {
	    unsigned char right = stack[--depth];
	    if (expr[i].op == ONIBI_CLASS_EXPR_UNION)
		stack[depth - 1U] = stack[depth - 1U] || right;
	    else
		stack[depth - 1U] = stack[depth - 1U] && right;
	}
    }
    return stack[0] != 0;
}

typedef struct {
    const OnibiClassExpr *expr;
    size_t expr_count;
    rb_encoding *encoding;
    unsigned char *stack;
    OnibiCodepointVector *additions;
    int repeated;
    int changed;
    int incomplete;
} OnibiClassFoldClosure;

static int
onibi_class_fold_member(OnibiClassFoldClosure *closure, OnigCodePoint codepoint)
{
    if (onibi_class_expr_hit(closure->expr, closure->expr_count, codepoint,
			     closure->encoding, closure->stack))
	return 1;
    for (size_t i = 0; i < closure->additions->count; i++)
	if (closure->additions->entries[i] == codepoint) return 1;
    return 0;
}

static void
onibi_class_fold_add(OnibiClassFoldClosure *closure, OnigCodePoint codepoint)
{
    if (onibi_class_fold_member(closure, codepoint)) return;
    size_t limit = UINT16_MAX / sizeof(OnibiClassExpr);
    if (closure->expr_count >= limit ||
	closure->additions->count >= (limit - closure->expr_count) / 2U)
	rb_raise(eRegexpError,
		 "class case-fold closure exceeds the v1 size limit");
    onibi_codepoint_vector_push(closure->additions, codepoint);
    closure->changed = 1;
}

static int
onibi_class_fold_callback(OnigCodePoint from, OnigCodePoint *to, int to_len,
			  void *opaque)
{
    OnibiClassFoldClosure *closure = opaque;
    if (to_len != 1) {
	if (onibi_class_fold_member(closure, from)) {
	    closure->incomplete = 1;
	    return 0;
	}
	if (closure->repeated && to_len > 1) {
	    int all_members = 1;
	    for (int i = 0; i < to_len; i++)
		if (!onibi_class_fold_member(closure, to[i])) {
		    all_members = 0;
		    break;
		}
	    if (all_members) closure->incomplete = 1;
	}
	return 0;
    }
    int from_member = onibi_class_fold_member(closure, from);
    int to_member = onibi_class_fold_member(closure, to[0]);
    if (from_member && !to_member) onibi_class_fold_add(closure, to[0]);
    if (to_member && !from_member) onibi_class_fold_add(closure, from);
    return 0;
}

static void
onibi_class_expr_apply_casefold(onibi_gir_builder_t *builder,
				OnibiClassExprVector *expr, int *incomplete)
{
    if (expr->count == 1 && expr->entries[0].op == ONIBI_CLASS_EXPR_CTYPE &&
	expr->entries[0].arg0 == ONIGENC_CTYPE_ASCII)
	return;
    OnibiCodepointVector additions;
    onibi_codepoint_vector_init(&additions);
    onibi_codepoint_vector_bind(&additions, builder->allocation_owner);
    unsigned char *stack =
	onibi_owned_realloc(builder->allocation_owner, NULL, expr->count);
    rb_encoding *fold_encoding = rb_enc_from_index(builder->encoding_index);
    if (builder->encoding_index == rb_usascii_encindex())
	fold_encoding = rb_utf8_encoding();
    OnibiClassFoldClosure closure = {expr->entries,
				     expr->count,
				     fold_encoding,
				     stack,
				     &additions,
				     builder->casefold_repeat_depth > 0,
				     0,
				     0};
    do {
	closure.changed = 0;
	int status = ONIGENC_APPLY_ALL_CASE_FOLD(
	    closure.encoding, ONIGENC_CASE_FOLD_DEFAULT,
	    onibi_class_fold_callback, &closure);
	if (status != 0)
	    rb_raise(eRegexpError, "class case-fold closure failed");
    } while (closure.changed);
    *incomplete = closure.incomplete;
    onibi_owned_free(builder->allocation_owner, stack);
    for (size_t i = 0; i < additions.count; i++) {
	onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_RANGE,
			      additions.entries[i], additions.entries[i]);
	onibi_class_expr_push(expr, ONIBI_CLASS_EXPR_UNION, 0, 0);
    }
    onibi_codepoint_vector_free(&additions);
}

static uint32_t
onibi_compiler_normalize_class(onibi_gir_builder_t *builder, OnibiAstId id,
			       int fold)
{
    OnibiClassExprVector expr;
    onibi_class_expr_vector_init(&expr);
    onibi_class_expr_vector_bind(&expr, builder->allocation_owner);
    onibi_class_expr_ast(builder, id, &expr);
    uint8_t flags = 0;
    const OnibiAstNode *node = onibi_ast_node_const(builder->ast, id);
    int whole_negated = node->kind == ONIBI_AST_ESCAPE ||
			(node->flags & ONIBI_AST_NODE_NEGATED) != 0;
    if (whole_negated && expr.count > 1 &&
	expr.entries[expr.count - 1].op == ONIBI_CLASS_EXPR_NEGATE) {
	flags |= ONIBI_RSEQ_CLASS_FLAG_NEGATED;
	expr.count--;
    }
    int incomplete_casefold = 0;
    if (fold)
	onibi_class_expr_apply_casefold(builder, &expr, &incomplete_casefold);
    uint32_t result;
    if (expr.count == 1 && expr.entries[0].op == ONIBI_CLASS_EXPR_CTYPE) {
	uint32_t ctype = expr.entries[0].arg0;
	result = onibi_semantic_class_add(builder, ONIBI_CLASS_ENCODING_CTYPE,
					  flags, fold, incomplete_casefold,
					  &ctype, sizeof(ctype));
    }
    else {
	int ranges_only = expr.count > 0;
	size_t range_count = 0;
	for (size_t i = 0; i < expr.count; i++) {
	    if (expr.entries[i].op == ONIBI_CLASS_EXPR_RANGE)
		range_count++;
	    else if (expr.entries[i].op != ONIBI_CLASS_EXPR_UNION)
		ranges_only = 0;
	}
	if (ranges_only && range_count > 0) {
	    OnibiCodepointRange *ranges =
		onibi_owned_realloc(builder->allocation_owner, NULL,
				    range_count * sizeof(OnibiCodepointRange));
	    size_t at = 0;
	    for (size_t i = 0; i < expr.count; i++)
		if (expr.entries[i].op == ONIBI_CLASS_EXPR_RANGE)
		    ranges[at++] = (OnibiCodepointRange){expr.entries[i].arg0,
							 expr.entries[i].arg1};
	    qsort(ranges, range_count, sizeof(*ranges),
		  onibi_codepoint_range_compare);
	    size_t merged = 0;
	    for (size_t i = 0; i < range_count; i++) {
		if (merged > 0 && (ranges[merged - 1].last == UINT32_MAX ||
				   ranges[i].first <=
				       ranges[merged - 1].last + UINT32_C(1))) {
		    if (ranges[i].last > ranges[merged - 1].last)
			ranges[merged - 1].last = ranges[i].last;
		}
		else
		    ranges[merged++] = ranges[i];
	    }
	    int ascii = ranges[merged - 1].last <= 255;
	    if (ascii) {
		unsigned char bitmap[32] = {0};
		for (size_t i = 0; i < merged; i++)
		    for (uint32_t cp = ranges[i].first; cp <= ranges[i].last;
			 cp++) {
			bitmap[cp >> 3] |= (unsigned char)(1U << (cp & 7));
			if (cp == ranges[i].last) break;
		    }
		result = onibi_semantic_class_add(
		    builder, ONIBI_CLASS_ASCII_BITMAP, flags, fold,
		    incomplete_casefold, bitmap, sizeof(bitmap));
	    }
	    else {
		result = onibi_semantic_class_add(
		    builder, ONIBI_CLASS_CODEPOINT_RANGES, flags, fold,
		    incomplete_casefold, ranges, merged * sizeof(*ranges));
	    }
	    onibi_owned_free(builder->allocation_owner, ranges);
	}
	else {
	    result = onibi_semantic_class_add(
		builder, ONIBI_CLASS_MIXED, flags, fold, incomplete_casefold,
		expr.entries, expr.count * sizeof(*expr.entries));
	}
    }
    onibi_class_expr_vector_free(&expr);
    return result;
}
static void
onibi_compiled_mark(void *ptr)
{
    (void)ptr;
}

static void
onibi_compiler_owner_cleanup(OnibiCompilerOwner *owner)
{
    if (owner->nfa_active) {
	onibi_nfa_free(&owner->nfa);
	owner->nfa_active = 0;
    }
    onibi_id_vector_free(&owner->accept_starts);
    onibi_g_action_vector_free(&owner->pending_actions);
    if (owner->root_fragment_active) {
	onibi_id_vector_free(&owner->root_fragment.starts);
	onibi_id_vector_free(&owner->root_fragment.exits);
	onibi_g_action_vector_free(&owner->root_fragment.start_actions);
	onibi_g_action_vector_free(&owner->root_fragment.pending_actions);
	owner->root_fragment_active = 0;
    }
    /* Publication reinitializes every transferred vector.  Keep the flag
     * explicit so a later publication path cannot free published storage. */
    onibi_guard_vector_free(&owner->builder.capture_guards);
    onibi_guard_vector_free(&owner->builder.exit_guards);
    onibi_id_vector_free(&owner->builder.progress_slots);
    onibi_subprogram_variant_vector_free(&owner->builder.subprogram_variants);
    if (!owner->gir_transferred) {
	onibi_gir_edge_vector_free(&owner->start_edges);
	onibi_rseq_subprogram_vector_free(&owner->builder.subprograms);
	onibi_backref_desc_vector_free(&owner->builder.backrefs);
	onibi_id_vector_free(&owner->builder.backref_capture_ids);
	onibi_gir_edge_vector_free(&owner->builder.subprogram_entries);
	onibi_id_vector_free(&owner->builder.lookbehind_widths);
	onibi_semantic_class_vector_free(&owner->builder.classes);
	onibi_gir_state_vector_free(&owner->builder.states);
	onibi_gir_edge_vector_free(&owner->builder.edges);
    }
    onibi_owned_free(&owner->allocations, owner->builder.subprogram_status);
    owner->builder.subprogram_status = NULL;
    onibi_allocation_owner_cleanup(&owner->allocations);
}

static VALUE
onibi_compiler_owner_ensure(VALUE opaque)
{
    onibi_compiler_owner_cleanup((OnibiCompilerOwner *)(uintptr_t)opaque);
    return Qnil;
}

static size_t
onibi_compiled_edge_vector_memsize(const OnibiGirEdgeVector *vector)
{
    size_t size = vector->capacity * sizeof(*vector->entries);
    for (size_t i = 0; i < vector->count; i++)
	size += vector->entries[i].actions.capacity *
		sizeof(*vector->entries[i].actions.entries);
    return size;
}

static void
onibi_compiled_free(void *ptr)
{
    OnibiCompiled *compiled = (OnibiCompiled *)ptr;
    if (!compiled) return;
    onibi_gir_state_vector_free(&compiled->states);
    /* This vector helper releases every nested action vector first. */
    onibi_gir_edge_vector_free(&compiled->edges);
    onibi_gir_edge_vector_free(&compiled->start_edges);
    onibi_rseq_subprogram_vector_free(&compiled->subprograms);
    onibi_backref_desc_vector_free(&compiled->backrefs);
    onibi_id_vector_free(&compiled->backref_capture_ids);
    onibi_gir_edge_vector_free(&compiled->subprogram_entries);
    onibi_id_vector_free(&compiled->lookbehind_widths);
    for (size_t i = 0; i < compiled->classes.count; i++)
	ruby_xfree(compiled->classes.entries[i].data);
    onibi_semantic_class_vector_free(&compiled->classes);
    xfree(ptr);
}
static size_t
onibi_compiled_memsize(const void *ptr)
{
    const OnibiCompiled *compiled = (const OnibiCompiled *)ptr;
    if (!compiled) return 0;
    size_t size =
	sizeof(*compiled) +
	compiled->states.capacity * sizeof(*compiled->states.entries) +
	onibi_compiled_edge_vector_memsize(&compiled->edges) +
	onibi_compiled_edge_vector_memsize(&compiled->start_edges) +
	compiled->subprograms.capacity *
	    sizeof(*compiled->subprograms.entries) +
	compiled->backrefs.capacity * sizeof(*compiled->backrefs.entries) +
	compiled->backref_capture_ids.capacity *
	    sizeof(*compiled->backref_capture_ids.entries) +
	onibi_compiled_edge_vector_memsize(&compiled->subprogram_entries) +
	compiled->lookbehind_widths.capacity *
	    sizeof(*compiled->lookbehind_widths.entries) +
	compiled->classes.capacity * sizeof(*compiled->classes.entries);
    for (size_t i = 0; i < compiled->classes.count; i++)
	size += compiled->classes.entries[i].data_length;
    return size;
}
static const rb_data_type_t onibi_compiled_type = {"Onibi::Compiled",
						   {onibi_compiled_mark,
						    onibi_compiled_free,
						    onibi_compiled_memsize,
						    NULL,
						    {NULL}},
						   0,
						   0,
						   RUBY_TYPED_FREE_IMMEDIATELY};
static inline OnibiCompiled *
onibi_compiled_get(VALUE value)
{
    OnibiCompiled *compiled;
    TypedData_Get_Struct(value, OnibiCompiled, &onibi_compiled_type, compiled);
    return compiled;
}

static int
onibi_ast_slice_equal(const OnibiAstArena *arena, OnibiTokenSlice first,
		      OnibiTokenSlice second)
{
    return first.present && second.present && first.length == second.length &&
	   memcmp(arena->bytes + first.offset, arena->bytes + second.offset,
		  first.length) == 0;
}

static uint64_t
onibi_name_hash(const OnibiAstArena *arena, OnibiTokenSlice name)
{
    uint64_t h = UINT64_C(1469598103934665603);
    for (size_t i = 0; i < name.length; i++) {
	h ^= arena->bytes[name.offset + i];
	h *= UINT64_C(1099511628211);
    }
    return h;
}

static OnibiNameIndexEntry *
onibi_name_index_find(OnibiResolvedArena *semantics, const OnibiAstArena *arena,
		      OnibiTokenSlice name)
{
    if (semantics->name_index_capacity == 0) return NULL;
    size_t mask = semantics->name_index_capacity - 1;
    size_t slot = (size_t)onibi_name_hash(arena, name) & mask;
    for (;;) {
	OnibiNameIndexEntry *entry = &semantics->name_entries[slot];
	if (!entry->used) return entry;
	if (onibi_ast_slice_equal(arena, entry->name, name)) return entry;
	slot = (slot + 1) & mask;
    }
}

static void
onibi_name_index_build(OnibiParsed *parsed)
{
    OnibiResolvedArena *semantics = &parsed->semantics;
    size_t needed = semantics->capture_count * 2 + 1;
    size_t capacity = 1;
    while (capacity < needed)
	capacity <<= 1;
    semantics->name_entries = ALLOC_N(OnibiNameIndexEntry, capacity);
    memset(semantics->name_entries, 0,
	   capacity * sizeof(*semantics->name_entries));
    semantics->name_index_capacity = capacity;
    for (size_t i = 0; i < semantics->count; i++) {
	const OnibiAstNode *node =
	    onibi_ast_node_const(&parsed->arena, (OnibiAstId)i);
	if (node->kind != ONIBI_AST_CAPTURE || !node->name.present) continue;
	OnibiNameIndexEntry *entry =
	    onibi_name_index_find(semantics, &parsed->arena, node->name);
	if (!entry->used) {
	    entry->used = 1;
	    entry->name = node->name;
	    entry->subprogram_id = UINT32_MAX;
	    semantics->name_entry_count++;
	}
	if (entry->definition_count == entry->definition_capacity) {
	    size_t cap =
		entry->definition_capacity ? entry->definition_capacity * 2 : 2;
	    REALLOC_N(entry->definitions, OnibiAstId, cap);
	    entry->definition_capacity = cap;
	}
	entry->definitions[entry->definition_count++] = (OnibiAstId)i;
    }
}

static int
onibi_ast_slice_number(const OnibiAstArena *arena, OnibiTokenSlice slice,
		       long *number)
{
    if (!slice.present || slice.length == 0) return 0;
    long value = 0;
    for (size_t i = 0; i < slice.length; i++) {
	unsigned char byte = arena->bytes[slice.offset + i];
	if (byte < '0' || byte > '9') return 0;
	if (value > (LONG_MAX - (byte - '0')) / 10)
	    rb_raise(eRegexpError, "capture number is too large");
	value = value * 10 + (byte - '0');
    }
    *number = value;
    return 1;
}

static OnibiAstId
onibi_resolved_named_capture(const OnibiAstArena *arena,
			     const OnibiResolvedArena *semantics,
			     OnibiTokenSlice name)
{
    OnibiNameIndexEntry *entry =
	onibi_name_index_find((OnibiResolvedArena *)semantics, arena, name);
    if (entry != NULL && entry->used && entry->definition_count != 0)
	return entry->definitions[0];
    return ONIBI_AST_NONE;
}

static OnibiSubprogramId
onibi_resolved_named_subprogram(const OnibiAstArena *arena,
				const OnibiResolvedArena *semantics,
				OnibiTokenSlice name)
{
    OnibiNameIndexEntry *entry =
	onibi_name_index_find((OnibiResolvedArena *)semantics, arena, name);
    return entry != NULL && entry->used ? entry->subprogram_id : UINT32_MAX;
}

static OnibiAstId
onibi_resolved_numbered_capture(const OnibiResolvedArena *semantics,
				long number)
{
    if (number <= 0) return ONIBI_AST_NONE;
    if ((size_t)(number - 1) < semantics->capture_by_number_count)
	return semantics->capture_by_number[number - 1];
    return ONIBI_AST_NONE;
}

/* Build the immutable capture list used by one backreference.  Ruby resolves
 * duplicate names in reverse source order and tests each currently set
 * capture. */
static uint32_t
onibi_compile_backref_descriptor(const OnibiAstNode *node,
				 const OnibiResolvedNode *resolved,
				 onibi_gir_builder_t *builder)
{
    OnibiBackrefDesc descriptor;
    memset(&descriptor, 0, sizeof(descriptor));
    descriptor.capture_list_off = (uint32_t)builder->backref_capture_ids.count;
    if (node->name.present) descriptor.flags |= ONIBI_BACKREF_FLAG_NAMED;
    if ((resolved->lexical_options & ONIBI_OPT_IGNORECASE) != 0)
	descriptor.flags |= ONIBI_BACKREF_FLAG_IGNORE_CASE;

    if (node->name.present) {
	OnibiNameIndexEntry *entry = onibi_name_index_find(
	    (OnibiResolvedArena *)builder->semantics, builder->ast, node->name);
	if (entry == NULL || !entry->used || entry->definition_count == 0 ||
	    entry->definition_count > UINT16_MAX)
	    rb_raise(eRegexpError, "invalid GIR backreference capture list");
	for (size_t i = entry->definition_count; i > 0; i--) {
	    OnibiAstId definition = entry->definitions[i - 1];
	    int32_t capture_id =
		builder->semantics->nodes[definition].capture_id;
	    if (capture_id < 0 ||
		(uint64_t)capture_id >= (uint64_t)builder->capture_count)
		rb_raise(eRegexpError, "invalid GIR backreference capture");
	    onibi_id_vector_push(&builder->backref_capture_ids,
				 (OnibiStateId)capture_id);
	}
    }
    else {
	if (resolved->capture_id < 0 ||
	    (uint64_t)resolved->capture_id >= (uint64_t)builder->capture_count)
	    rb_raise(eRegexpError, "invalid GIR backreference capture");
	onibi_id_vector_push(&builder->backref_capture_ids,
			     (OnibiStateId)resolved->capture_id);
    }
    size_t count = builder->backref_capture_ids.count -
		   (size_t)descriptor.capture_list_off;
    if (count == 0 || count > UINT16_MAX ||
	descriptor.capture_list_off > UINT32_MAX ||
	builder->backrefs.count >= UINT32_MAX)
	rb_raise(eRegexpError, "GIR backreference descriptor is too large");
    descriptor.capture_count = (uint16_t)count;
    uint32_t id = (uint32_t)builder->backrefs.count;
    onibi_backref_desc_vector_push(&builder->backrefs, descriptor);
    return id;
}

static void
onibi_resolve_capture_numbers(OnibiParsed *parsed, OnibiAstId id,
			      long *next_capture)
{
    const OnibiAstNode *node = onibi_ast_node_const(&parsed->arena, id);
    OnibiResolvedNode *semantic = &parsed->semantics.nodes[id];
    if (node->kind == ONIBI_AST_CAPTURE) {
	semantic->capture_id = (int32_t)(*next_capture)++;
    }
    if (node->body != ONIBI_AST_NONE)
	onibi_resolve_capture_numbers(parsed, node->body, next_capture);
    if (node->atom != ONIBI_AST_NONE)
	onibi_resolve_capture_numbers(parsed, node->atom, next_capture);
    if (node->yes != ONIBI_AST_NONE)
	onibi_resolve_capture_numbers(parsed, node->yes, next_capture);
    if (node->no != ONIBI_AST_NONE)
	onibi_resolve_capture_numbers(parsed, node->no, next_capture);
    for (size_t i = 0; i < node->child_count; i++)
	onibi_resolve_capture_numbers(parsed, node->children[i], next_capture);
}

static uint32_t
onibi_resolve_option_slice(const OnibiAstArena *arena, OnibiTokenSlice slice,
			   uint32_t options, int enabled)
{
    if (!slice.present) return options;
    for (size_t i = 0; i < slice.length; i++) {
	uint32_t bit;
	switch (arena->bytes[slice.offset + i]) {
	case 'i': bit = ONIBI_OPT_IGNORECASE; break;
	case 'm': bit = ONIBI_OPT_MULTILINE; break;
	case 'x': bit = ONIBI_OPT_EXTENDED; break;
	default: rb_raise(eRegexpError, "unknown inline option flag");
	}
	if (enabled)
	    options |= bit;
	else
	    options &= ~bit;
    }
    return options;
}

static uint32_t
onibi_resolve_option_node(const OnibiAstArena *arena, const OnibiAstNode *node,
			  uint32_t options)
{
    int enabled = (node->flags & ONIBI_AST_NODE_NEGATIVE) == 0;
    options = onibi_resolve_option_slice(arena, node->name, options, enabled);
    return onibi_resolve_option_slice(arena, node->negative_options, options,
				      0);
}

static uint32_t
onibi_resolve_semantic_node(OnibiParsed *parsed, OnibiAstId id,
			    uint32_t options, uint32_t *next_subprogram)
{
    const OnibiAstArena *arena = &parsed->arena;
    const OnibiAstNode *node = onibi_ast_node_const(arena, id);
    OnibiResolvedNode *semantic = &parsed->semantics.nodes[id];
    semantic->lexical_options = options;
    semantic->encoding_index = parsed->encoding_index;
    semantic->flags |= ONIBI_SEMANTIC_RESOLVED;

    if (node->kind == ONIBI_AST_BACKREF) {
	OnibiAstId target = ONIBI_AST_NONE;
	if (node->name.present)
	    target = onibi_resolved_named_capture(arena, &parsed->semantics,
						  node->name);
	else
	    target = onibi_resolved_numbered_capture(&parsed->semantics,
						     node->capture);
	if (target == ONIBI_AST_NONE)
	    rb_raise(eRegexpError, "undefined backreference");
	semantic->reference_target = target;
	semantic->capture_id = parsed->semantics.nodes[target].capture_id;
    }
    else if (node->kind == ONIBI_AST_SUBROUTINE) {
	long number = 0;
	OnibiAstId target =
	    onibi_ast_slice_number(arena, node->name, &number)
		? onibi_resolved_numbered_capture(&parsed->semantics, number)
		: onibi_resolved_named_capture(arena, &parsed->semantics,
					       node->name);
	if (target == ONIBI_AST_NONE)
	    rb_raise(eRegexpError, "undefined subroutine call");
	semantic->reference_target = target;
	semantic->capture_id = parsed->semantics.nodes[target].capture_id;
	if (number == 0) {
	    OnibiSubprogramId indexed = onibi_resolved_named_subprogram(
		arena, &parsed->semantics, node->name);
	    if (indexed != UINT32_MAX) semantic->subprogram_id = indexed;
	}
	if (semantic->subprogram_id == UINT32_MAX) {
	    if (parsed->semantics.nodes[target].subprogram_id == UINT32_MAX)
		parsed->semantics.nodes[target].subprogram_id =
		    (*next_subprogram)++;
	    semantic->subprogram_id =
		parsed->semantics.nodes[target].subprogram_id;
	    if (number == 0) {
		OnibiNameIndexEntry *entry = onibi_name_index_find(
		    &parsed->semantics, arena, node->name);
		if (entry != NULL)
		    entry->subprogram_id = semantic->subprogram_id;
	    }
	}
    }
    else if (node->kind == ONIBI_AST_ATOMIC ||
	     node->kind == ONIBI_AST_ABSENCE) {
	semantic->subprogram_id = (*next_subprogram)++;
    }
    else if (node->kind == ONIBI_AST_CONDITIONAL) {
	OnibiTokenSlice condition = node->name;
	if (condition.present && condition.length >= 2 &&
	    arena->bytes[condition.offset] == '<' &&
	    arena->bytes[condition.offset + condition.length - 1] == '>') {
	    condition.offset++;
	    condition.length -= 2;
	}
	long number = 0;
	OnibiAstId target =
	    onibi_ast_slice_number(arena, condition, &number)
		? onibi_resolved_numbered_capture(&parsed->semantics, number)
		: onibi_resolved_named_capture(arena, &parsed->semantics,
					       condition);
	if (target == ONIBI_AST_NONE)
	    rb_raise(eRegexpError, "conditional capture is undefined");
	semantic->reference_target = target;
	semantic->capture_id = parsed->semantics.nodes[target].capture_id;
    }

    if (node->kind == ONIBI_AST_SEQUENCE) {
	uint32_t current = options;
	for (size_t i = 0; i < node->child_count; i++) {
	    OnibiAstId child_id = node->children[i];
	    current = onibi_resolve_semantic_node(parsed, child_id, current,
						  next_subprogram);
	}
	return current;
    }
    if (node->kind == ONIBI_AST_ALTERNATIVE) {
	uint32_t current = options;
	for (size_t i = 0; i < node->child_count; i++)
	    current = onibi_resolve_semantic_node(parsed, node->children[i],
						  current, next_subprogram);
	return current;
    }
    if (node->kind == ONIBI_AST_OPTION_GLOBAL) {
	return onibi_resolve_option_node(arena, node, options);
    }
    if (node->kind == ONIBI_AST_OPTION_SCOPE) {
	uint32_t scoped = onibi_resolve_option_node(arena, node, options);
	if (node->body != ONIBI_AST_NONE)
	    (void)onibi_resolve_semantic_node(parsed, node->body, scoped,
					      next_subprogram);
	return options;
    }
    if (node->body != ONIBI_AST_NONE)
	(void)onibi_resolve_semantic_node(parsed, node->body, options,
					  next_subprogram);
    if (node->atom != ONIBI_AST_NONE)
	(void)onibi_resolve_semantic_node(parsed, node->atom, options,
					  next_subprogram);
    if (node->yes != ONIBI_AST_NONE)
	(void)onibi_resolve_semantic_node(parsed, node->yes, options,
					  next_subprogram);
    if (node->no != ONIBI_AST_NONE)
	(void)onibi_resolve_semantic_node(parsed, node->no, options,
					  next_subprogram);
    for (size_t i = 0; i < node->child_count; i++)
	(void)onibi_resolve_semantic_node(parsed, node->children[i], options,
					  next_subprogram);
    return options;
}

static void
onibi_assign_lookaround_subprograms(OnibiParsed *parsed,
				    uint32_t *next_subprogram)
{
    for (size_t i = 0; i < parsed->semantics.count; i++) {
	OnibiResolvedNode *node = &parsed->semantics.nodes[i];
	if (!(node->flags & ONIBI_SEMANTIC_RESOLVED)) continue;
	if (node->kind == ONIBI_AST_LOOKAHEAD ||
	    node->kind == ONIBI_AST_LOOKBEHIND)
	    node->subprogram_id = (*next_subprogram)++;
    }
}

static OnibiResolveOutput
onibi_compiler_pass_resolve(OnibiParseOutput parse, OnibiCompilerOwner *owner)
{
    OnibiParsed *parsed = parse.parsed;
    onibi_resolved_indexes_free(&parsed->semantics);
    xfree(parsed->semantics.nodes);
    parsed->semantics.nodes = NULL;
    parsed->semantics.count = parsed->arena.count;
    parsed->semantics.nodes =
	ALLOC_N(OnibiResolvedNode, parsed->semantics.count);
    for (size_t i = 0; i < parsed->semantics.count; i++) {
	const OnibiAstNode *source =
	    onibi_ast_node_const(&parsed->arena, (OnibiAstId)i);
	OnibiResolvedNode *node = &parsed->semantics.nodes[i];
	memset(node, 0, sizeof(*node));
	node->kind = source->kind;
	node->source_id = (OnibiAstId)i;
	node->reference_target = ONIBI_AST_NONE;
	node->subprogram_id = UINT32_MAX;
	node->capture_id = -1;
	node->assertion_kind = 0;
	node->repeat_max = -1;
	node->max_width = -1;
	node->source_start = source->start;
	node->source_end = source->end;
    }
    long captures = 0;
    onibi_resolve_capture_numbers(parsed, parsed->arena.root, &captures);
    if ((uint64_t)captures > ONIBI_GIR_MAX_CAPTURE_COUNT)
	rb_raise(eRegexpError,
		 "capture count exceeds the GIR action operand limit");
    parsed->semantics.capture_count = (uint32_t)captures;
    parsed->semantics.capture_by_number_count = (size_t)captures;
    if (captures != 0)
	parsed->semantics.capture_by_number =
	    ALLOC_N(OnibiAstId, (size_t)captures);
    for (size_t i = 0; i < (size_t)captures; i++)
	parsed->semantics.capture_by_number[i] = ONIBI_AST_NONE;
    for (size_t i = 0; i < parsed->semantics.count; i++) {
	if (parsed->semantics.nodes[i].capture_id >= 0)
	    parsed->semantics
		.capture_by_number[parsed->semantics.nodes[i].capture_id] =
		(OnibiAstId)i;
    }
    onibi_name_index_build(parsed);
    uint32_t subprograms = 1;
    (void)onibi_resolve_semantic_node(parsed, parsed->arena.root,
				      (uint32_t)parse.options, &subprograms);
    for (size_t i = 0; i < parsed->semantics.name_index_capacity; i++) {
	OnibiNameIndexEntry *entry = &parsed->semantics.name_entries[i];
	if (entry->used && entry->definition_count != 0)
	    entry->subprogram_id =
		parsed->semantics.nodes[entry->definitions[0]].subprogram_id;
    }
    parsed->semantics.lowered_subprogram_count = subprograms;
    onibi_assign_lookaround_subprograms(parsed, &subprograms);
    parsed->semantics.subprogram_count = subprograms;
    onibi_compiler_fail_if(owner, 1);
    return (OnibiResolveOutput){parsed, &parsed->semantics};
}

static int32_t
onibi_normalized_assertion(const OnibiAstNode *node)
{
    if (node->kind == ONIBI_AST_LOOKAHEAD) return ONIBI_RAP_LOOKAHEAD;
    if (node->kind == ONIBI_AST_LOOKBEHIND) return ONIBI_RAP_LOOKBEHIND;
    if (node->kind != ONIBI_AST_ANCHOR) return 0;
    switch (node->byte) {
    case '^': return ONIBI_RAP_BEGIN_LINE;
    case '$': return ONIBI_RAP_END_LINE;
    case 'b': return ONIBI_RAP_WORD_BOUNDARY;
    case 'B': return ONIBI_RAP_NONWORD_BOUNDARY;
    case 'A': return ONIBI_RAP_BEGIN_BUFFER;
    case 'G': return ONIBI_RAP_SEARCH_ORIGIN;
    case 'Z': return ONIBI_RAP_SEMI_END_BUFFER;
    default: return ONIBI_RAP_END_BUFFER;
    }
}

static OnibiNormalizeOutput
onibi_compiler_pass_normalize(OnibiResolveOutput resolve,
			      OnibiCompilerOwner *owner)
{
    OnibiParsed *parsed = resolve.parsed;
    for (size_t i = 0; i < resolve.semantics->count; i++) {
	const OnibiAstNode *source =
	    onibi_ast_node_const(&parsed->arena, (OnibiAstId)i);
	OnibiResolvedNode *node = &parsed->semantics.nodes[i];
	if (!(node->flags & ONIBI_SEMANTIC_RESOLVED)) continue;
	if (node->kind != source->kind || node->encoding_index < 0)
	    rb_raise(eRegexpError, "semantic resolve invariant failed");
	node->assertion_kind = onibi_normalized_assertion(source);
	if (source->kind == ONIBI_AST_QUANTIFIER) {
	    if (source->min < 0 || ((source->flags & ONIBI_AST_NODE_HAS_MAX) &&
				    source->max < source->min))
		rb_raise(eRegexpError, "invalid normalized repeat");
	    node->repeat_min = source->min;
	    node->repeat_max =
		(source->flags & ONIBI_AST_NODE_HAS_MAX) ? source->max : -1;
	    if (source->flags & ONIBI_AST_NODE_HAS_MAX)
		node->flags |= ONIBI_SEMANTIC_REPEAT_HAS_MAX;
	    if (source->flags & ONIBI_AST_NODE_GREEDY)
		node->flags |= ONIBI_SEMANTIC_REPEAT_GREEDY;
	    if (source->flags & ONIBI_AST_NODE_POSSESSIVE)
		node->flags |= ONIBI_SEMANTIC_REPEAT_POSSESSIVE;
	}
	node->flags |= ONIBI_SEMANTIC_NORMALIZED;
    }
    onibi_compiler_fail_if(owner, 2);
    return (OnibiNormalizeOutput){parsed, resolve.semantics};
}

static long
onibi_width_add(long first, long second)
{
    if (first < 0 || second < 0) return -1;
    if (first > LONG_MAX - second) return -1;
    return first + second;
}

static long
onibi_width_multiply(long width, long count)
{
    if (width < 0 || count < 0) return -1;
    if (count != 0 && width > LONG_MAX / count) return -1;
    return width * count;
}

static void
onibi_analyze_semantic_node(OnibiParsed *parsed, OnibiAstId id)
{
    OnibiResolvedNode *semantic = &parsed->semantics.nodes[id];
    const OnibiAstNode *node = onibi_ast_node_const(&parsed->arena, id);
    if (semantic->flags & ONIBI_SEMANTIC_ANALYZED) return;
    if (semantic->flags & ONIBI_SEMANTIC_ANALYZING) {
	semantic->min_width = 0;
	semantic->max_width = -1;
	semantic->flags |= ONIBI_SEMANTIC_ANALYZED | ONIBI_SEMANTIC_NULLABLE;
	return;
    }
    semantic->flags |= ONIBI_SEMANTIC_ANALYZING;
    long min = 0;
    long max = 0;
    int nullable = 1;
    switch (node->kind) {
    case ONIBI_AST_LITERAL:
    case ONIBI_AST_ESCAPE:
    case ONIBI_AST_ANY:
    case ONIBI_AST_CHARACTER_CLASS:
    case ONIBI_AST_CLASS_INTERSECTION:
	for (size_t i = 0; i < node->child_count; i++)
	    onibi_analyze_semantic_node(parsed, node->children[i]);
	min = max = 1;
	nullable = 0;
	break;
    case ONIBI_AST_BACKREF:
	min = 0;
	max = -1;
	nullable = 1;
	break;
    case ONIBI_AST_SEQUENCE:
	for (size_t i = 0; i < node->child_count; i++) {
	    onibi_analyze_semantic_node(parsed, node->children[i]);
	    OnibiResolvedNode *child =
		&parsed->semantics.nodes[node->children[i]];
	    min = onibi_width_add(min, child->min_width);
	    max = onibi_width_add(max, child->max_width);
	    nullable =
		nullable && ((child->flags & ONIBI_SEMANTIC_NULLABLE) != 0);
	}
	break;
    case ONIBI_AST_ALTERNATIVE:
	min = LONG_MAX;
	max = 0;
	nullable = 0;
	for (size_t i = 0; i < node->child_count; i++) {
	    onibi_analyze_semantic_node(parsed, node->children[i]);
	    OnibiResolvedNode *child =
		&parsed->semantics.nodes[node->children[i]];
	    if (child->min_width < min) min = child->min_width;
	    if (child->max_width < 0 || max < 0)
		max = -1;
	    else if (child->max_width > max)
		max = child->max_width;
	    nullable =
		nullable || ((child->flags & ONIBI_SEMANTIC_NULLABLE) != 0);
	}
	if (min == LONG_MAX) min = 0;
	break;
    case ONIBI_AST_QUANTIFIER: {
	onibi_analyze_semantic_node(parsed, node->atom);
	OnibiResolvedNode *atom = &parsed->semantics.nodes[node->atom];
	min = onibi_width_multiply(atom->min_width, semantic->repeat_min);
	max = semantic->repeat_max < 0
		  ? -1
		  : onibi_width_multiply(atom->max_width, semantic->repeat_max);
	nullable = semantic->repeat_min == 0 ||
		   ((atom->flags & ONIBI_SEMANTIC_NULLABLE) != 0);
	break;
    }
    case ONIBI_AST_CAPTURE:
    case ONIBI_AST_GROUP:
    case ONIBI_AST_ATOMIC:
    case ONIBI_AST_OPTION_SCOPE:
	onibi_analyze_semantic_node(parsed, node->body);
	min = parsed->semantics.nodes[node->body].min_width;
	max = parsed->semantics.nodes[node->body].max_width;
	nullable = (parsed->semantics.nodes[node->body].flags &
		    ONIBI_SEMANTIC_NULLABLE) != 0;
	break;
    case ONIBI_AST_SUBROUTINE: {
	OnibiAstId target = semantic->reference_target;
	const OnibiAstNode *capture =
	    onibi_ast_node_const(&parsed->arena, target);
	onibi_analyze_semantic_node(parsed, capture->body);
	min = parsed->semantics.nodes[capture->body].min_width;
	max = parsed->semantics.nodes[capture->body].max_width;
	nullable = (parsed->semantics.nodes[capture->body].flags &
		    ONIBI_SEMANTIC_NULLABLE) != 0;
	break;
    }
    case ONIBI_AST_CONDITIONAL:
	onibi_analyze_semantic_node(parsed, node->yes);
	onibi_analyze_semantic_node(parsed, node->no);
	min = parsed->semantics.nodes[node->yes].min_width <
		      parsed->semantics.nodes[node->no].min_width
		  ? parsed->semantics.nodes[node->yes].min_width
		  : parsed->semantics.nodes[node->no].min_width;
	max = parsed->semantics.nodes[node->yes].max_width;
	if (max >= 0 && (parsed->semantics.nodes[node->no].max_width < 0 ||
			 parsed->semantics.nodes[node->no].max_width > max))
	    max = parsed->semantics.nodes[node->no].max_width;
	nullable = ((parsed->semantics.nodes[node->yes].flags |
		     parsed->semantics.nodes[node->no].flags) &
		    ONIBI_SEMANTIC_NULLABLE) != 0;
	break;
    case ONIBI_AST_ABSENCE:
	onibi_analyze_semantic_node(parsed, node->body);
	min = 0;
	max = -1;
	/* The absence operator can succeed without consuming bytes.  Mark it
	 * nullable so a repeat receives the same progress owner as MRI. */
	nullable = 1;
	break;
    case ONIBI_AST_LOOKAHEAD:
    case ONIBI_AST_LOOKBEHIND:
	onibi_analyze_semantic_node(parsed, node->body);
	min = max = 0;
	nullable = 1;
	break;
    default:
	min = max = 0;
	nullable = 1;
	break;
    }
    semantic->min_width = min;
    semantic->max_width = max;
    semantic->flags &= ~ONIBI_SEMANTIC_ANALYZING;
    semantic->flags |= ONIBI_SEMANTIC_ANALYZED;
    if (nullable) semantic->flags |= ONIBI_SEMANTIC_NULLABLE;
}

static void
onibi_subprogram_entry_push(onibi_gir_builder_t *builder,
			    OnibiSubprogramId subprogram_id,
			    OnibiStateId destination,
			    const OnibiGActionVector *actions)
{
    OnibiGActionVector composed =
	onibi_nfa_compose_edge_actions(builder, -1, (long)destination, actions);
    onibi_gir_edge_vector_push(&builder->subprogram_entries,
			       (OnibiGirEdgeEntry){(long)subprogram_id,
						   (long)destination, 0,
						   composed});
}

static long
onibi_store_subprogram_fragment(onibi_fragment_t *fragment,
				OnibiSubprogramId subprogram_id,
				onibi_gir_builder_t *builder, uint32_t flags,
				OnibiSubprogramKind kind, uint8_t effects,
				OnibiOptionEnv option_env, uint32_t width_base,
				uint16_t width_count)
{
    long accept = builder->next_id++;
    onibi_nfa_state(builder, accept, ONIBI_G_ACCEPT, 0, 0);
    OnibiIdVector accept_starts;
    onibi_id_vector_single(&accept_starts, (OnibiStateId)accept,
			   builder->allocation_owner);
    onibi_connect_fragment_actions(builder, &fragment->exits, &accept_starts,
				   &fragment->pending_actions, 0);
    size_t entry_base = builder->subprogram_entries.count;
    OnibiGActionVector nullable_actions = onibi_g_action_vector_concat(
	&fragment->start_actions, &fragment->pending_actions,
	builder->allocation_owner);
    if (fragment->nullable &&
	(fragment->lazy & ONIBI_FRAGMENT_NULLABLE_LAZY) != 0)
	onibi_subprogram_entry_push(builder, subprogram_id,
				    (OnibiStateId)accept, &nullable_actions);
    for (size_t i = 0; i < fragment->starts.count; i++)
	onibi_subprogram_entry_push(builder, subprogram_id,
				    fragment->starts.entries[i],
				    &fragment->start_actions);
    if (fragment->nullable &&
	(fragment->lazy & ONIBI_FRAGMENT_NULLABLE_LAZY) == 0)
	onibi_subprogram_entry_push(builder, subprogram_id,
				    (OnibiStateId)accept, &nullable_actions);
    onibi_g_action_vector_free(&nullable_actions);
    size_t entry_count = builder->subprogram_entries.count - entry_base;
    if (entry_count == 0 || entry_count > UINT16_MAX || entry_base > UINT32_MAX)
	onibi_compiler_mark_unsupported(builder, ONIBI_UNSUPPORTED_LIMIT);
    if (entry_count == 0 || entry_count > UINT16_MAX || entry_base > UINT32_MAX)
	rb_raise(eRegexpError, "subprogram entry set exceeds the RSeq limit");
    OnibiRSeqSubprogramEntry descriptor;
    memset(&descriptor, 0, sizeof(descriptor));
    descriptor.entry =
	(OnibiStateId)builder->subprogram_entries.entries[entry_base].to;
    descriptor.accept = (OnibiStateId)accept;
    descriptor.flags = flags;
    descriptor.option_env = option_env;
    descriptor.entry_edge_base = (uint32_t)entry_base;
    descriptor.entry_edge_count = (uint16_t)entry_count;
    descriptor.width_base = width_base;
    descriptor.width_count = width_count;
    descriptor.kind = (uint8_t)kind;
    descriptor.effects = effects;
    onibi_rseq_subprogram_vector_store(&builder->subprograms,
				       (size_t)subprogram_id, descriptor);
    onibi_id_vector_free(&fragment->starts);
    onibi_id_vector_free(&fragment->exits);
    onibi_id_vector_free(&accept_starts);
    onibi_g_action_vector_free(&fragment->start_actions);
    onibi_g_action_vector_free(&fragment->pending_actions);
    return (long)subprogram_id;
}

static OnibiSubprogramId
onibi_subprogram_variant_find(const onibi_gir_builder_t *builder,
			      OnibiSubprogramId semantic_id)
{
    for (size_t i = 0; i < builder->subprogram_variants.count; i++) {
	const OnibiSubprogramVariant *variant =
	    &builder->subprogram_variants.entries[i];
	if (variant->semantic_id != semantic_id ||
	    variant->scope_count != builder->nullable_scope_count)
	    continue;
	if (variant->scope_count == 0 ||
	    memcmp(variant->scopes, builder->nullable_scopes,
		   variant->scope_count * sizeof(*variant->scopes)) == 0)
	    return variant->physical_id;
    }
    return UINT32_MAX;
}

static OnibiSubprogramId
onibi_subprogram_variant_find_active(const onibi_gir_builder_t *builder,
				     OnibiSubprogramId semantic_id)
{
    for (size_t i = 0; i < builder->subprogram_variants.count; i++) {
	const OnibiSubprogramVariant *variant =
	    &builder->subprogram_variants.entries[i];
	if (variant->semantic_id == semantic_id && variant->compiling)
	    return variant->physical_id;
    }
    return UINT32_MAX;
}

static OnibiSubprogramId
onibi_subprogram_variant_start(onibi_gir_builder_t *builder,
			       OnibiSubprogramId semantic_id, int *compile)
{
    OnibiSubprogramId existing =
	onibi_subprogram_variant_find(builder, semantic_id);
    if (existing != UINT32_MAX) {
	*compile = 0;
	return existing;
    }
    OnibiSubprogramId active =
	onibi_subprogram_variant_find_active(builder, semantic_id);
    if (active != UINT32_MAX) {
	*compile = 0;
	return active;
    }
    if (builder->nullable_scope_count > 256) {
	onibi_compiler_mark_unsupported(builder, ONIBI_UNSUPPORTED_LIMIT);
	rb_raise(eRegexpError, "nullable repeat nesting is too deep");
    }
    OnibiSubprogramId physical_id;
    if (builder->subprogram_status[semantic_id] == 0)
	physical_id = semantic_id;
    else {
	if (builder->subprograms.count >= UINT32_MAX) {
	    onibi_compiler_mark_unsupported(builder, ONIBI_UNSUPPORTED_LIMIT);
	    rb_raise(eRegexpError, "subprogram table exceeds the RSeq limit");
	}
	physical_id = (OnibiSubprogramId)builder->subprograms.count;
	onibi_rseq_subprogram_vector_push(&builder->subprograms,
					  (OnibiRSeqSubprogramEntry){0});
    }
    OnibiSubprogramVariant variant;
    memset(&variant, 0, sizeof(variant));
    variant.semantic_id = semantic_id;
    variant.physical_id = physical_id;
    variant.scope_count = (uint16_t)builder->nullable_scope_count;
    variant.compiling = 1;
    memcpy(variant.scopes, builder->nullable_scopes,
	   variant.scope_count * sizeof(*variant.scopes));
    onibi_subprogram_variant_vector_push(&builder->subprogram_variants,
					 variant);
    builder->subprogram_status[semantic_id] = 1;
    *compile = 1;
    return physical_id;
}

static void
onibi_subprogram_variant_finish(onibi_gir_builder_t *builder,
				OnibiSubprogramId physical_id)
{
    for (size_t i = 0; i < builder->subprogram_variants.count; i++) {
	OnibiSubprogramVariant *variant =
	    &builder->subprogram_variants.entries[i];
	if (variant->physical_id != physical_id) continue;
	variant->compiling = 0;
	builder->subprogram_status[variant->semantic_id] = 2;
	return;
    }
    rb_raise(eRegexpError, "subprogram variant is not active");
}

static long
onibi_compile_resolved_body_subprogram(
    OnibiAstId body, OnibiSubprogramId subprogram_id,
    onibi_gir_builder_t *builder, uint32_t flags, OnibiSubprogramKind kind,
    uint8_t effects, OnibiOptionEnv option_env, uint32_t width_base,
    uint16_t width_count)
{
    if (subprogram_id == 0 ||
	(size_t)subprogram_id >= builder->resolved_subprogram_count) {
	rb_raise(eRegexpError, "resolved subprogram ID is invalid");
    }
    int compile;
    OnibiSubprogramId physical_id =
	onibi_subprogram_variant_start(builder, subprogram_id, &compile);
    if (!compile) return (long)physical_id;
    onibi_fragment_t fragment = onibi_compile_node(body, builder);
    long result = onibi_store_subprogram_fragment(
	&fragment, physical_id, builder, flags, kind, effects, option_env,
	width_base, width_count);
    onibi_subprogram_variant_finish(builder, physical_id);
    return result;
}

static long
onibi_compile_resolved_subprogram(OnibiAstId capture_id,
				  OnibiSubprogramId subprogram_id,
				  onibi_gir_builder_t *builder)
{
    if (subprogram_id == 0 ||
	(size_t)subprogram_id >= builder->resolved_subprogram_count) {
	rb_raise(eRegexpError, "resolved subprogram ID is invalid");
    }
    int compile;
    OnibiSubprogramId physical_id =
	onibi_subprogram_variant_start(builder, subprogram_id, &compile);
    if (!compile) return (long)physical_id;
    const OnibiAstNode *capture =
	onibi_ast_node_const(builder->ast, capture_id);
    const OnibiResolvedNode *capture_semantic =
	&builder->semantics->nodes[capture_id];
    onibi_fragment_t fragment = onibi_compile_node(capture->body, builder);
    long capture_slot = capture_semantic->capture_id;
    if (capture_slot >= 0) {
	OnibiGAction open = {ONIBI_GA_CAPTURE_OPEN,
			     0,
			     0,
			     1,
			     onibi_capture_boundary_slot(capture_slot, 0),
			     0,
			     0,
			     0,
			     0};
	OnibiGAction close = {ONIBI_GA_CAPTURE_CLOSE,
			      0,
			      0,
			      1,
			      onibi_capture_boundary_slot(capture_slot, 1),
			      0,
			      0,
			      0,
			      0};
	OnibiGActionVector starts;
	onibi_g_action_vector_init(&starts);
	onibi_g_action_vector_bind(&starts, builder->allocation_owner);
	onibi_g_action_vector_push(&starts, open);
	onibi_g_action_vector_append(&starts, &fragment.start_actions);
	onibi_g_action_vector_free(&fragment.start_actions);
	fragment.start_actions = starts;
	OnibiGActionVector exits;
	onibi_g_action_vector_init(&exits);
	onibi_g_action_vector_bind(&exits, builder->allocation_owner);
	onibi_g_action_vector_push(&exits, close);
	onibi_g_action_vector_append(&exits, &fragment.pending_actions);
	onibi_g_action_vector_free(&fragment.pending_actions);
	fragment.pending_actions = exits;
    }
    OnibiOptionEnv option_env = {capture_semantic->lexical_options,
				 capture_semantic->encoding_index};
    long result = onibi_store_subprogram_fragment(
	&fragment, physical_id, builder, 0, ONIBI_SUBPROGRAM_CALL, 0,
	option_env, 0, 0);
    onibi_subprogram_variant_finish(builder, physical_id);
    return result;
}

/* Give each fragment one explicit NFA entry and exit. In particular, an
 * empty alternative keeps its actions and its place in the choice order. */
static onibi_fragment_t
onibi_fragment_explicit(onibi_fragment_t part, onibi_gir_builder_t *builder)
{
    long entry = onibi_nfa_epsilon_state(builder);
    long exit = onibi_nfa_epsilon_state(builder);
    OnibiGActionVector empty = onibi_g_action_vector_concat(
	&part.start_actions, &part.pending_actions, builder->allocation_owner);
    if (part.nullable && (part.lazy & ONIBI_FRAGMENT_NULLABLE_LAZY))
	onibi_nfa_add_connection(builder, entry, exit, &empty, 0);
    for (size_t i = 0; i < part.starts.count; i++)
	onibi_nfa_add_connection(builder, entry, part.starts.entries[i],
				 &part.start_actions, 0);
    for (size_t i = 0; i < part.exits.count; i++)
	onibi_nfa_add_connection(builder, part.exits.entries[i], exit,
				 &part.pending_actions, 0);
    if (part.nullable && !(part.lazy & ONIBI_FRAGMENT_NULLABLE_LAZY))
	onibi_nfa_add_connection(builder, entry, exit, &empty, 0);
    onibi_g_action_vector_free(&empty);
    onibi_id_vector_free(&part.starts);
    onibi_id_vector_free(&part.exits);
    onibi_g_action_vector_free(&part.start_actions);
    onibi_g_action_vector_free(&part.pending_actions);
    part = onibi_fragment_empty(builder);
    onibi_id_vector_single(&part.starts, (OnibiStateId)entry,
			   builder->allocation_owner);
    onibi_id_vector_single(&part.exits, (OnibiStateId)exit,
			   builder->allocation_owner);
    part.nullable = 0;
    return part;
}

static void
onibi_fragment_join(onibi_fragment_t *left, onibi_fragment_t right,
		    onibi_gir_builder_t *builder)
{
    onibi_nfa_add_connection(builder, left->exits.entries[0],
			     right.starts.entries[0], &(OnibiGActionVector){0},
			     0);
    onibi_id_vector_free(&left->exits);
    left->exits = right.exits;
    onibi_id_vector_free(&right.starts);
    onibi_g_action_vector_free(&right.start_actions);
    onibi_g_action_vector_free(&right.pending_actions);
}

static onibi_fragment_t
onibi_compile_sequence(const OnibiAstNode *sequence,
		       onibi_gir_builder_t *builder)
{
    onibi_fragment_t result =
	onibi_fragment_explicit(onibi_fragment_empty(builder), builder);
    for (size_t i = 0; i < sequence->child_count; i++) {
	onibi_fragment_t part =
	    onibi_compile_node(sequence->children[i], builder);
	part = onibi_fragment_explicit(part, builder);
	onibi_fragment_join(&result, part, builder);
    }
    return result;
}

static onibi_fragment_t
onibi_compile_literal_bytes(const unsigned char *bytes, size_t length,
			    int ignorecase, onibi_gir_builder_t *builder)
{
    long id = builder->next_id++;
    onibi_nfa_state_literal(builder, id, bytes, length, ignorecase);
    onibi_fragment_t result = onibi_fragment_empty(builder);
    onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			   builder->allocation_owner);
    onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			   builder->allocation_owner);
    result.nullable = 0;
    return result;
}

static onibi_fragment_t
onibi_compile_character_class(OnibiAstId node_id, int ignorecase,
			      onibi_gir_builder_t *builder)
{
    long id = builder->next_id++;
    uint32_t class_index =
	onibi_compiler_normalize_class(builder, node_id, ignorecase);
    onibi_nfa_state_class(builder, id, class_index);
    onibi_fragment_t result = onibi_fragment_empty(builder);
    onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			   builder->allocation_owner);
    onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			   builder->allocation_owner);
    result.nullable = 0;
    return result;
}

static onibi_fragment_t
onibi_compile_repeat_atom(OnibiAstId atom, onibi_gir_builder_t *builder,
			  int can_repeat, int choice_scope)
{
    if (choice_scope) builder->ordered_choice_depth++;
    if (can_repeat) builder->casefold_repeat_depth++;
    onibi_fragment_t result = onibi_compile_node(atom, builder);
    if (can_repeat) builder->casefold_repeat_depth--;
    if (choice_scope) builder->ordered_choice_depth--;
    return result;
}

/* MRI 4.0.6 selects the finite greedy expansion from the compiled target
 * length.  This is an opcode-size reference calculation, not a character
 * width rule.  Keep all values saturated because only the 50-byte decision
 * boundary is observable here. */
#define ONIBI_MRI_REPEAT_EXPAND_LIMIT 50L
#define ONIBI_MRI_SIZE_OPCODE 1L
#define ONIBI_MRI_SIZE_RELADDR ((long)sizeof(int32_t))
#define ONIBI_MRI_SIZE_MEMNUM ((long)sizeof(int16_t))
#define ONIBI_MRI_SIZE_LENGTH ((long)sizeof(int32_t))
#define ONIBI_MRI_SIZE_PUSH (ONIBI_MRI_SIZE_OPCODE + ONIBI_MRI_SIZE_RELADDR)
#define ONIBI_MRI_SIZE_JUMP (ONIBI_MRI_SIZE_OPCODE + ONIBI_MRI_SIZE_RELADDR)
#define ONIBI_MRI_SIZE_REPEAT_INC                                              \
    (ONIBI_MRI_SIZE_OPCODE + ONIBI_MRI_SIZE_MEMNUM)
#define ONIBI_MRI_SIZE_NULL_CHECK                                              \
    (ONIBI_MRI_SIZE_OPCODE + ONIBI_MRI_SIZE_MEMNUM)
#define ONIBI_MRI_SIZE_MEMORY_START                                            \
    (ONIBI_MRI_SIZE_OPCODE + ONIBI_MRI_SIZE_MEMNUM)
#define ONIBI_MRI_SIZE_MEMORY_END                                              \
    (ONIBI_MRI_SIZE_OPCODE + ONIBI_MRI_SIZE_MEMNUM)

static long
onibi_repeat_reference_add(long first, long second)
{
    if (first > ONIBI_MRI_REPEAT_EXPAND_LIMIT ||
	second > ONIBI_MRI_REPEAT_EXPAND_LIMIT ||
	first > ONIBI_MRI_REPEAT_EXPAND_LIMIT - second)
	return ONIBI_MRI_REPEAT_EXPAND_LIMIT + 1L;
    return first + second;
}

static long
onibi_repeat_reference_multiply(long first, long second)
{
    if (first == 0 || second == 0) return 0;
    if (first > ONIBI_MRI_REPEAT_EXPAND_LIMIT ||
	second > ONIBI_MRI_REPEAT_EXPAND_LIMIT ||
	first > ONIBI_MRI_REPEAT_EXPAND_LIMIT / second)
	return ONIBI_MRI_REPEAT_EXPAND_LIMIT + 1L;
    return first * second;
}

static long
onibi_repeat_reference_string_size(long mb_len, long byte_len, int ignore_case)
{
    long characters =
	mb_len > 0 ? byte_len / mb_len + (byte_len % mb_len != 0) : 0;
    long size = ONIBI_MRI_SIZE_OPCODE + byte_len;

    if (ignore_case) {
	if (characters > 1)
	    size = onibi_repeat_reference_add(size, ONIBI_MRI_SIZE_LENGTH);
    }
    else if (mb_len >= 4)
	size = onibi_repeat_reference_add(
	    onibi_repeat_reference_add(size, ONIBI_MRI_SIZE_LENGTH),
	    ONIBI_MRI_SIZE_LENGTH);
    else if (mb_len == 3 || (mb_len == 2 && characters > 3) ||
	     (mb_len == 1 && byte_len > 5))
	size = onibi_repeat_reference_add(size, ONIBI_MRI_SIZE_LENGTH);
    return size > ONIBI_MRI_REPEAT_EXPAND_LIMIT
	       ? ONIBI_MRI_REPEAT_EXPAND_LIMIT + 1L
	       : size;
}

static long
onibi_repeat_reference_literal_size(OnibiAstId id,
				    const onibi_gir_builder_t *builder)
{
    /* Mirror MRI's compile_length_string_node: the encoded run chooses an
     * opcode form, and the result is the target program length. */
    const OnibiAstNode *node = onibi_ast_node_const(builder->ast, id);
    const OnibiResolvedNode *semantic = &builder->semantics->nodes[id];
    rb_encoding *encoding = rb_enc_from_index(builder->encoding_index);
    const unsigned char *bytes =
	node->bytes.present ? builder->ast->bytes + node->bytes.offset : NULL;
    size_t length = node->bytes.present ? node->bytes.length : 1U;
    int ignore_case = (semantic->lexical_options & ONIBI_OPT_IGNORECASE) != 0;
    if (bytes == NULL) {
	return onibi_repeat_reference_string_size(1, 1, ignore_case);
    }

    long size = 0;
    size_t offset = 0;
    while (offset < length) {
	const char *begin = (const char *)bytes + offset;
	const char *end = (const char *)bytes + length;
	int width = rb_enc_precise_mbclen(begin, end, encoding);
	if (!MBCLEN_CHARFOUND_P(width) || MBCLEN_CHARFOUND_LEN(width) <= 0)
	    return ONIBI_MRI_REPEAT_EXPAND_LIMIT + 1L;
	size_t character_width = (size_t)MBCLEN_CHARFOUND_LEN(width);
	size_t run = character_width;
	offset += character_width;
	while (offset < length) {
	    const char *next = (const char *)bytes + offset;
	    int next_width = rb_enc_precise_mbclen(next, end, encoding);
	    if (!MBCLEN_CHARFOUND_P(next_width) ||
		(!ignore_case &&
		 (size_t)MBCLEN_CHARFOUND_LEN(next_width) != character_width))
		break;
	    run += (size_t)MBCLEN_CHARFOUND_LEN(next_width);
	    offset += (size_t)MBCLEN_CHARFOUND_LEN(next_width);
	}
	long part = onibi_repeat_reference_string_size((long)character_width,
						       (long)run, ignore_case);
	size = onibi_repeat_reference_add(size, part);
	if (size > ONIBI_MRI_REPEAT_EXPAND_LIMIT) return size;
    }
    return size;
}

static long
onibi_repeat_reference_size(OnibiAstId id, const onibi_gir_builder_t *builder)
{
    const OnibiAstNode *node = onibi_ast_node_const(builder->ast, id);
    const OnibiResolvedNode *sem = &builder->semantics->nodes[id];
    long size = 0;
    switch (node->kind) {
    case ONIBI_AST_SEQUENCE:
	for (size_t i = 0; i < node->child_count; i++)
	    size = onibi_repeat_reference_add(
		size, onibi_repeat_reference_size(node->children[i], builder));
	break;
    case ONIBI_AST_ALTERNATIVE:
	for (size_t i = 0; i < node->child_count; i++) {
	    size = onibi_repeat_reference_add(
		size, onibi_repeat_reference_size(node->children[i], builder));
	    if (i != 0)
		size = onibi_repeat_reference_add(
		    size, ONIBI_MRI_SIZE_PUSH + ONIBI_MRI_SIZE_JUMP);
	}
	break;
    case ONIBI_AST_LITERAL:
	size = onibi_repeat_reference_literal_size(id, builder);
	break;
    case ONIBI_AST_ESCAPE:
    case ONIBI_AST_ANY:
    case ONIBI_AST_ANCHOR: size = ONIBI_MRI_SIZE_OPCODE; break;
    case ONIBI_AST_CHARACTER_CLASS:
    case ONIBI_AST_CLASS_INTERSECTION:
	size = ONIBI_MRI_REPEAT_EXPAND_LIMIT + 1L;
	break;
    case ONIBI_AST_CAPTURE:
	size = onibi_repeat_reference_add(
	    ONIBI_MRI_SIZE_MEMORY_START,
	    onibi_repeat_reference_size(node->body, builder));
	size = onibi_repeat_reference_add(size, ONIBI_MRI_SIZE_MEMORY_END);
	break;
    case ONIBI_AST_GROUP:
    case ONIBI_AST_OPTION_SCOPE:
	size = onibi_repeat_reference_size(node->body, builder);
	break;
    case ONIBI_AST_QUANTIFIER: {
	long body = onibi_repeat_reference_size(node->atom, builder);
	long min = sem->repeat_min;
	long max = sem->repeat_max;
	int greedy = (sem->flags & ONIBI_SEMANTIC_REPEAT_GREEDY) != 0;
	int nullable = (builder->semantics->nodes[node->atom].flags &
			ONIBI_SEMANTIC_NULLABLE) != 0;
	long modified = nullable ? onibi_repeat_reference_add(
				       body, 2L * ONIBI_MRI_SIZE_NULL_CHECK)
				 : body;
	int infinite = max < 0;
	if (max == 0)
	    size = 0;
	else if (infinite &&
		 (min <= 1 || onibi_repeat_reference_multiply(body, min) <=
				  ONIBI_MRI_REPEAT_EXPAND_LIMIT)) {
	    if (min == 1 && body > ONIBI_MRI_REPEAT_EXPAND_LIMIT)
		size = ONIBI_MRI_SIZE_JUMP;
	    else
		size = onibi_repeat_reference_multiply(body, min);
	    if (greedy) {
		size = onibi_repeat_reference_add(size, ONIBI_MRI_SIZE_PUSH);
		size = onibi_repeat_reference_add(size, modified);
		size = onibi_repeat_reference_add(size, ONIBI_MRI_SIZE_JUMP);
	    }
	    else {
		size = onibi_repeat_reference_add(size, ONIBI_MRI_SIZE_JUMP);
		size = onibi_repeat_reference_add(size, modified);
		size = onibi_repeat_reference_add(size, ONIBI_MRI_SIZE_PUSH);
	    }
	}
	else if (!infinite && greedy &&
		 (max == 1 ||
		  onibi_repeat_reference_multiply(
		      onibi_repeat_reference_add(body, ONIBI_MRI_SIZE_PUSH),
		      max) <= ONIBI_MRI_REPEAT_EXPAND_LIMIT)) {
	    size = onibi_repeat_reference_add(
		onibi_repeat_reference_multiply(body, min),
		onibi_repeat_reference_multiply(
		    onibi_repeat_reference_add(body, ONIBI_MRI_SIZE_PUSH),
		    max - min));
	}
	else if (!infinite && !greedy && max == 1 && min == 0) {
	    size = onibi_repeat_reference_add(
		ONIBI_MRI_SIZE_PUSH + ONIBI_MRI_SIZE_JUMP, body);
	}
	else {
	    size =
		onibi_repeat_reference_add(ONIBI_MRI_SIZE_REPEAT_INC, modified);
	    size = onibi_repeat_reference_add(size, ONIBI_MRI_SIZE_OPCODE +
							ONIBI_MRI_SIZE_RELADDR +
							ONIBI_MRI_SIZE_MEMNUM);
	}
	break;
    }
    default: size = ONIBI_MRI_REPEAT_EXPAND_LIMIT + 1L; break;
    }
    return size > ONIBI_MRI_REPEAT_EXPAND_LIMIT
	       ? ONIBI_MRI_REPEAT_EXPAND_LIMIT + 1L
	       : size;
}

static size_t
onibi_repeat_capture_count_visit(OnibiAstId id,
				 const onibi_gir_builder_t *builder,
				 OnibiIdVector *visited)
{
    for (size_t i = 0; i < visited->count; i++)
	if (visited->entries[i] == id) return 0;
    onibi_id_vector_push(visited, (OnibiStateId)id);
    const OnibiAstNode *node = onibi_ast_node_const(builder->ast, id);
    size_t count = node->kind == ONIBI_AST_CAPTURE ? 1U : 0U;
    if (node->kind == ONIBI_AST_SUBROUTINE) {
	const OnibiResolvedNode *resolved = &builder->semantics->nodes[id];
	if (resolved->reference_target != ONIBI_AST_NONE)
	    count += onibi_repeat_capture_count_visit(
		resolved->reference_target, builder, visited);
    }
    if (node->body != ONIBI_AST_NONE)
	count += onibi_repeat_capture_count_visit(node->body, builder, visited);
    if (node->atom != ONIBI_AST_NONE)
	count += onibi_repeat_capture_count_visit(node->atom, builder, visited);
    if (node->yes != ONIBI_AST_NONE)
	count += onibi_repeat_capture_count_visit(node->yes, builder, visited);
    if (node->no != ONIBI_AST_NONE)
	count += onibi_repeat_capture_count_visit(node->no, builder, visited);
    for (size_t i = 0; i < node->child_count; i++)
	count += onibi_repeat_capture_count_visit(node->children[i], builder,
						  visited);
    return count;
}

static size_t
onibi_repeat_capture_count(OnibiAstId id, const onibi_gir_builder_t *builder)
{
    OnibiIdVector visited = {0};
    onibi_id_vector_bind(&visited, builder->allocation_owner);
    size_t count = onibi_repeat_capture_count_visit(id, builder, &visited);
    onibi_id_vector_free(&visited);
    return count;
}

static void
onibi_repeat_link(onibi_gir_builder_t *builder, long from, long to,
		  OnibiGAction action)
{
    OnibiGActionVector actions = {0};
    onibi_g_action_vector_bind(&actions, builder->allocation_owner);
    onibi_g_action_vector_push(&actions, action);
    onibi_nfa_add_connection(builder, from, to, &actions, 0);
    onibi_g_action_vector_free(&actions);
}

static void
onibi_repeat_choice(onibi_gir_builder_t *builder, long choice, long body,
		    long exit, long counter, long min, long max, int greedy)
{
    if (!greedy)
	onibi_repeat_link(
	    builder, choice, exit,
	    onibi_counter_action(ONIBI_GA_TEST_COUNTER_GE, counter, 1, min));
    onibi_repeat_link(
	builder, choice, body,
	onibi_counter_action(ONIBI_GA_TEST_COUNTER_LT, counter, 1, max));
    if (greedy)
	onibi_repeat_link(
	    builder, choice, exit,
	    onibi_counter_action(ONIBI_GA_TEST_COUNTER_GE, counter, 1, min));
}

/* An empty iteration either stops or converts a previous capture into an
 * empty capture at this position. At most capture_count such conversions
 * can occur before another character is consumed. Clone only the epsilon
 * projection. All copies share the original consuming states. */
static onibi_fragment_t
onibi_compile_compact_repeat(OnibiAstId atom, long min, long max, int greedy,
			     int nullable, onibi_gir_builder_t *builder)
{
    long counter = onibi_gir_allocate_counter_slot(builder, 0);
    long guard = nullable ? onibi_gir_allocate_counter_slot(builder, 0) : -1;
    if (nullable) {
	(void)onibi_gir_allocate_counter_slot(builder, 0);
	if (builder->nullable_scope_count == 256) {
	    onibi_compiler_mark_unsupported(builder, ONIBI_UNSUPPORTED_LIMIT);
	    rb_raise(eRegexpError, "nullable repeat nesting is too deep");
	}
	builder->nullable_scopes[builder->nullable_scope_count++] =
	    (uint16_t)guard;
    }
    size_t state_base = builder->nfa->states.count;
    size_t edge_base = builder->nfa->edges.count;
    onibi_fragment_t body =
	onibi_compile_repeat_atom(atom, builder, 1, min != max);
    body = onibi_fragment_explicit(body, builder);
    if (nullable) builder->nullable_scope_count--;
    size_t state_end = builder->nfa->states.count;
    size_t edge_end = builder->nfa->edges.count;
    long body_entry = body.starts.entries[0], body_exit = body.exits.entries[0];
    long entry = onibi_nfa_epsilon_state(builder);
    long exit = onibi_nfa_epsilon_state(builder);
    size_t phases =
	nullable ? onibi_repeat_capture_count(atom, builder) + 1U : 1U;
    OnibiIdVector choices = {0};
    onibi_id_vector_bind(&choices, builder->allocation_owner);
    for (size_t phase = 0; phase < phases; phase++)
	onibi_id_vector_push(&choices,
			     (OnibiStateId)onibi_nfa_epsilon_state(builder));
    OnibiGAction initialize =
	onibi_counter_action(ONIBI_GA_COUNTER_INIT, counter, 0, 0);
    initialize.arg32 = 0;
    onibi_repeat_link(builder, entry, choices.entries[0], initialize);
    if (nullable) {
	/* The shared consuming path must complete the nullable owner's
	 * decision before it restarts the repeat.  Without this guard, a
	 * dynamic body can bypass NULL_CONTINUE/NULL_STOP after it consumes
	 * through a shared RSeq state. */
	long increment = onibi_nfa_epsilon_state(builder);
	onibi_repeat_link(
	    builder, body_exit, increment,
	    onibi_counter_action(ONIBI_GA_NULL_CONTINUE, guard, 0, 0));
	onibi_repeat_link(
	    builder, increment, choices.entries[0],
	    onibi_counter_action(ONIBI_GA_COUNTER_INCREMENT, counter, 0, 0));
	onibi_repeat_link(
	    builder, body_exit, exit,
	    onibi_counter_action(ONIBI_GA_NULL_STOP, guard, 0, 0));
	/* The phase projections below provide additional ordered empty paths.
	 */
    }
    else {
	onibi_repeat_link(
	    builder, body_exit, choices.entries[0],
	    onibi_counter_action(ONIBI_GA_COUNTER_INCREMENT, counter, 0, 0));
    }
    for (size_t phase = 0; phase < phases; phase++) {
	long projected_entry = body_entry, projected_exit = body_exit;
	{
	    OnibiIdVector map = {0};
	    onibi_id_vector_bind(&map, builder->allocation_owner);
	    for (size_t i = state_base; i < state_end; i++) {
		long target = (long)i;
		if (builder->nfa->states.entries[i].kind ==
		    ONIBI_NFA_STATE_EPSILON)
		    target = onibi_nfa_epsilon_state(builder);
		onibi_id_vector_push(&map, (OnibiStateId)target);
	    }
	    for (size_t i = edge_base; i < edge_end; i++) {
		OnibiNfaEdge edge = builder->nfa->edges.entries[i];
		if (edge.from < (long)state_base ||
		    edge.from >= (long)state_end ||
		    edge.to < (long)state_base || edge.to >= (long)state_end ||
		    builder->nfa->states.entries[edge.from].kind !=
			ONIBI_NFA_STATE_EPSILON)
		    continue;
		onibi_nfa_add_connection(
		    builder, map.entries[edge.from - (long)state_base],
		    map.entries[edge.to - (long)state_base], &edge.actions, 0);
	    }
	    projected_entry = map.entries[body_entry - (long)state_base];
	    projected_exit = map.entries[body_exit - (long)state_base];
	    onibi_id_vector_free(&map);
	}
	if (nullable) {
	    long enter_guard = onibi_nfa_epsilon_state(builder);
	    onibi_repeat_link(
		builder, enter_guard, projected_entry,
		onibi_counter_action(ONIBI_GA_NULL_ENTER, guard, 0, 0));
	    projected_entry = enter_guard;
	    if (phase + 1U < phases) {
		long increment = onibi_nfa_epsilon_state(builder);
		onibi_repeat_link(
		    builder, projected_exit, increment,
		    onibi_counter_action(ONIBI_GA_NULL_CONTINUE, guard, 0, 0));
		onibi_repeat_link(
		    builder, increment, choices.entries[phase + 1U],
		    onibi_counter_action(ONIBI_GA_COUNTER_INCREMENT, counter, 0,
					 0));
	    }
	    onibi_repeat_link(
		builder, projected_exit, exit,
		onibi_counter_action(ONIBI_GA_NULL_STOP, guard, 0, 0));
	}
	onibi_repeat_choice(builder, choices.entries[phase], projected_entry,
			    exit, counter, min, max, greedy);
    }
    onibi_id_vector_free(&choices);
    onibi_id_vector_free(&body.starts);
    onibi_id_vector_free(&body.exits);
    onibi_g_action_vector_free(&body.start_actions);
    onibi_g_action_vector_free(&body.pending_actions);
    onibi_fragment_t result = onibi_fragment_empty(builder);
    onibi_id_vector_single(&result.starts, (OnibiStateId)entry,
			   builder->allocation_owner);
    onibi_id_vector_single(&result.exits, (OnibiStateId)exit,
			   builder->allocation_owner);
    result.nullable = 0;
    return result;
}

static uint16_t
onibi_store_lookbehind_widths(OnibiAstId body, onibi_gir_builder_t *builder,
			      uint32_t *width_base)
{
    const OnibiAstNode *node = onibi_ast_node_const(builder->ast, body);
    if (node->kind == ONIBI_AST_SEQUENCE && node->child_count == 1) {
	const OnibiAstNode *child =
	    onibi_ast_node_const(builder->ast, node->children[0]);
	if (child->kind == ONIBI_AST_ALTERNATIVE) {
	    body = node->children[0];
	    node = child;
	}
    }
    if (builder->lookbehind_widths.count > UINT32_MAX) {
	onibi_compiler_mark_unsupported(builder, ONIBI_UNSUPPORTED_LIMIT);
	rb_raise(eRegexpError, "lookbehind width set exceeds the RSeq limit");
    }
    *width_base = (uint32_t)builder->lookbehind_widths.count;
    size_t count = node->kind == ONIBI_AST_ALTERNATIVE ? node->child_count : 1;
    if (count == 0 || count > UINT16_MAX) {
	onibi_compiler_mark_unsupported(builder, ONIBI_UNSUPPORTED_LIMIT);
	rb_raise(eRegexpError, "lookbehind width set exceeds the RSeq limit");
    }
    for (size_t i = 0; i < count; i++) {
	OnibiAstId branch =
	    node->kind == ONIBI_AST_ALTERNATIVE ? node->children[i] : body;
	const OnibiResolvedNode *semantic = &builder->semantics->nodes[branch];
	if (semantic->min_width < 0 ||
	    semantic->min_width != semantic->max_width ||
	    (uint64_t)semantic->min_width > UINT32_MAX)
	    rb_raise(eRegexpError,
		     "lookbehind body does not have a fixed character width");
	onibi_id_vector_push(&builder->lookbehind_widths,
			     (OnibiStateId)semantic->min_width);
    }
    return (uint16_t)count;
}

static onibi_fragment_t
onibi_compile_node(OnibiAstId node_id, onibi_gir_builder_t *builder)
{
    const OnibiAstNode *c_node = onibi_ast_node_const(builder->ast, node_id);
    const OnibiResolvedNode *resolved_node =
	&builder->semantics->nodes[node_id];
    OnibiAstKind type_code = c_node->kind;
    int ignorecase =
	(resolved_node->lexical_options & ONIBI_OPT_IGNORECASE) != 0;
    int multiline = (resolved_node->lexical_options & ONIBI_OPT_MULTILINE) != 0;
    if (type_code == ONIBI_AST_CHARACTER_CLASS ||
	type_code == ONIBI_AST_CLASS_INTERSECTION)
	return onibi_compile_character_class(node_id, ignorecase, builder);
    if (type_code == ONIBI_AST_SEQUENCE)
	return onibi_compile_sequence(c_node, builder);
    if (type_code == ONIBI_AST_ALTERNATIVE) {
	long entry = onibi_nfa_epsilon_state(builder),
	     exit = onibi_nfa_epsilon_state(builder);
	for (size_t i = 0; i < c_node->child_count; i++) {
	    builder->ordered_choice_depth++;
	    onibi_fragment_t branch = onibi_fragment_explicit(
		onibi_compile_node(c_node->children[i], builder), builder);
	    builder->ordered_choice_depth--;
	    onibi_nfa_add_connection(builder, entry, branch.starts.entries[0],
				     &(OnibiGActionVector){0}, 0);
	    onibi_nfa_add_connection(builder, branch.exits.entries[0], exit,
				     &(OnibiGActionVector){0}, 0);
	    onibi_id_vector_free(&branch.starts);
	    onibi_id_vector_free(&branch.exits);
	    onibi_g_action_vector_free(&branch.start_actions);
	    onibi_g_action_vector_free(&branch.pending_actions);
	}
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)entry,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)exit,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_LITERAL) {
	const unsigned char *bytes =
	    c_node->bytes.present ? builder->ast->bytes + c_node->bytes.offset
				  : (const unsigned char *)&c_node->byte;
	size_t length = c_node->bytes.present ? c_node->bytes.length : 1;
	return onibi_compile_literal_bytes(bytes, length, ignorecase, builder);
    }
    if (type_code == ONIBI_AST_ESCAPE) {
	size_t name_length = c_node->name.present ? c_node->name.length : 1;
	unsigned char name_byte = c_node->name.present
				      ? builder->ast->bytes[c_node->name.offset]
				      : (unsigned char)c_node->byte;
	int class_escape = onibi_simple_escape_p(name_byte) ||
			   onibi_ascii_property_name_p(c_node->name_id);
	int code = name_length == 1 ? onibi_ascii_fold(name_byte) : 0;
	if (!class_escape && name_length <= 1 &&
	    (code == 'r' || code == 'p' || code == 'u')) {
	    onibi_compiler_mark_unsupported(builder, ONIBI_UNSUPPORTED_ESCAPE);
	    rb_raise(eRegexpError, "escape is not supported in RSeq");
	}
	if (code == 'x') {
	    onibi_compiler_mark_unsupported(builder,
					    ONIBI_UNSUPPORTED_GRAPHEME);
	    rb_raise(eRegexpError,
		     "grapheme matching is not available in this PoC");
	}
	long id = builder->next_id++;
	uint32_t class_index =
	    onibi_compiler_normalize_class(builder, node_id, ignorecase);
	onibi_nfa_state_class(builder, id, class_index);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_ANY) {
	if (multiline) {
	    onibi_compiler_mark_unsupported(builder,
					    ONIBI_UNSUPPORTED_MULTILINE_ANY);
	    rb_raise(eRegexpError,
		     "multiline wildcard is not supported in RSeq");
	}
	long id = builder->next_id++;
	onibi_nfa_state(builder, id, ONIBI_G_ANY, 0, 0);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_BACKREF) {
	if (resolved_node->capture_id < 0)
	    rb_raise(eRegexpError, "invalid GIR backreference capture");
	uint32_t descriptor =
	    onibi_compile_backref_descriptor(c_node, resolved_node, builder);
	long id = builder->next_id++;
	onibi_nfa_state(builder, id, ONIBI_G_BACKREF, descriptor,
			ignorecase ? ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE : 0);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_SUBROUTINE) {
	if (resolved_node == NULL ||
	    resolved_node->reference_target == ONIBI_AST_NONE ||
	    resolved_node->subprogram_id == UINT32_MAX)
	    rb_raise(eRegexpError, "unresolved subroutine call");
	long subprogram_id = onibi_compile_resolved_subprogram(
	    resolved_node->reference_target, resolved_node->subprogram_id,
	    builder);
	long id = builder->next_id++;
	onibi_nfa_state(builder, id, ONIBI_G_CALL, (uint32_t)subprogram_id, 0);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	for (size_t i = 0; i < builder->nullable_scope_count; i++)
	    onibi_g_action_vector_push(
		&result.start_actions,
		onibi_counter_action(ONIBI_GA_NULL_CAPTURE,
				     builder->nullable_scopes[i], 1,
				     (uint32_t)resolved_node->capture_id));
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_OPTION_GLOBAL) {
	/* Resolve applies this option to later semantic nodes. */
	return onibi_fragment_empty(builder);
    }
    if (type_code == ONIBI_AST_OPTION_SCOPE) {
	return onibi_compile_node(c_node->body, builder);
    }
    if (type_code == ONIBI_AST_ANCHOR) {
	onibi_fragment_t result = onibi_fragment_empty(builder);
	if (resolved_node == NULL || resolved_node->assertion_kind == 0)
	    rb_raise(eRegexpError, "unnormalized assertion");
	OnibiGAction action = {
	    ONIBI_GA_ASSERT_POSITION,
	    0,
	    0,
	    0,
	    0,
	    1,
	    onibi_assertion_kind_operand(resolved_node->assertion_kind),
	    0,
	    0};
	onibi_g_action_vector_push(&result.pending_actions, action);
	return result;
    }
    if (type_code == ONIBI_AST_MATCH_RESET) {
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_g_action_vector_push(
	    &result.pending_actions,
	    (OnibiGAction){ONIBI_GA_MATCH_RESET, 0, 0, 0, 0, 0, 0, 0, 0});
	return result;
    }
    if (type_code == ONIBI_AST_CONDITIONAL) {
	if (resolved_node == NULL || resolved_node->capture_id < 0)
	    rb_raise(eRegexpError, "unresolved conditional capture");
	long capture_id = resolved_node->capture_id;
	onibi_fragment_t yes = onibi_compile_node(c_node->yes, builder);
	onibi_fragment_t no = onibi_compile_node(c_node->no, builder);
	OnibiGActionVector yes_guard;
	onibi_g_action_vector_init(&yes_guard);
	onibi_g_action_vector_bind(&yes_guard, builder->allocation_owner);
	onibi_g_action_vector_push(&yes_guard,
				   onibi_capture_test_action(capture_id, 1));
	onibi_g_action_vector_append(&yes_guard, &yes.start_actions);
	OnibiGActionVector no_guard;
	onibi_g_action_vector_init(&no_guard);
	onibi_g_action_vector_bind(&no_guard, builder->allocation_owner);
	onibi_g_action_vector_push(&no_guard,
				   onibi_capture_test_action(capture_id, 0));
	onibi_g_action_vector_append(&no_guard, &no.start_actions);
	for (size_t i = 0; i < yes.starts.count; i++)
	    onibi_guard_vector_add(&builder->capture_guards,
				   yes.starts.entries[i], &yes_guard);
	for (size_t i = 0; i < no.starts.count; i++)
	    onibi_guard_vector_add(&builder->capture_guards,
				   no.starts.entries[i], &no_guard);
	onibi_g_action_vector_free(&yes_guard);
	onibi_g_action_vector_free(&no_guard);
	onibi_add_exit_guard_fragment(builder, &yes.exits,
				      &yes.pending_actions);
	onibi_add_exit_guard_fragment(builder, &no.exits, &no.pending_actions);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_append(&result.starts, &yes.starts);
	onibi_id_vector_append(&result.starts, &no.starts);
	onibi_id_vector_append(&result.exits, &yes.exits);
	onibi_id_vector_append(&result.exits, &no.exits);
	onibi_id_vector_free(&yes.starts);
	onibi_id_vector_free(&yes.exits);
	onibi_id_vector_free(&no.starts);
	onibi_id_vector_free(&no.exits);
	onibi_g_action_vector_free(&yes.start_actions);
	onibi_g_action_vector_free(&yes.pending_actions);
	onibi_g_action_vector_free(&no.start_actions);
	onibi_g_action_vector_free(&no.pending_actions);
	result.nullable = yes.nullable || no.nullable;
	result.lazy = yes.lazy;
	return result;
    }
    if (type_code == ONIBI_AST_ATOMIC) {
	if (resolved_node == NULL || resolved_node->subprogram_id == UINT32_MAX)
	    rb_raise(eRegexpError, "unresolved atomic subprogram");
	long subprogram_id = onibi_compile_resolved_body_subprogram(
	    c_node->body, resolved_node->subprogram_id, builder,
	    ONIBI_SUBPROGRAM_ATOMIC, ONIBI_SUBPROGRAM_ATOMIC_GROUP,
	    ONIBI_SUBPROGRAM_EFFECT_FIRST_SUCCESS,
	    (OnibiOptionEnv){resolved_node->lexical_options,
			     resolved_node->encoding_index},
	    0, 0);
	long id = builder->next_id++;
	onibi_nfa_state(builder, id, ONIBI_G_ATOMIC, (uint32_t)subprogram_id,
			0);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_ABSENCE) {
	if (resolved_node == NULL || resolved_node->subprogram_id == UINT32_MAX)
	    rb_raise(eRegexpError, "unresolved absence subprogram");
	long subprogram_id = onibi_compile_resolved_body_subprogram(
	    c_node->body, resolved_node->subprogram_id, builder,
	    ONIBI_SUBPROGRAM_ABSENT, ONIBI_SUBPROGRAM_ABSENCE, 0,
	    (OnibiOptionEnv){resolved_node->lexical_options,
			     resolved_node->encoding_index},
	    0, 0);
	long id = builder->next_id++;
	onibi_nfa_state(builder, id, ONIBI_G_ABSENT, (uint32_t)subprogram_id,
			0);
	onibi_fragment_t result = onibi_fragment_empty(builder);
	onibi_id_vector_single(&result.starts, (OnibiStateId)id,
			       builder->allocation_owner);
	onibi_id_vector_single(&result.exits, (OnibiStateId)id,
			       builder->allocation_owner);
	result.nullable = 0;
	return result;
    }
    if (type_code == ONIBI_AST_LOOKAHEAD || type_code == ONIBI_AST_LOOKBEHIND) {
	if (resolved_node == NULL ||
	    resolved_node->subprogram_id == UINT32_MAX ||
	    resolved_node->subprogram_id <
		builder->semantics->lowered_subprogram_count)
	    rb_raise(eRegexpError, "unresolved lookaround subprogram");
	if (c_node->body == ONIBI_AST_NONE)
	    rb_raise(eRegexpError, "lookaround body is missing");
	if (resolved_node == NULL || resolved_node->assertion_kind == 0)
	    rb_raise(eRegexpError, "unnormalized lookaround assertion");
	uint32_t width_base = 0;
	uint16_t width_count = 0;
	if (type_code == ONIBI_AST_LOOKBEHIND)
	    width_count = onibi_store_lookbehind_widths(c_node->body, builder,
							&width_base);
	uint8_t effects = (c_node->flags & ONIBI_AST_NODE_POSITIVE)
			      ? ONIBI_SUBPROGRAM_EFFECT_POSITIVE |
				    ONIBI_SUBPROGRAM_EFFECT_PUBLISH_CAPTURES
			      : 0;
	long subprogram_id = onibi_compile_resolved_body_subprogram(
	    c_node->body, resolved_node->subprogram_id, builder, 0,
	    type_code == ONIBI_AST_LOOKAHEAD ? ONIBI_SUBPROGRAM_LOOKAHEAD
					     : ONIBI_SUBPROGRAM_LOOKBEHIND,
	    effects,
	    (OnibiOptionEnv){resolved_node->lexical_options,
			     resolved_node->encoding_index},
	    width_base, width_count);
	OnibiGAction action = {
	    ONIBI_GA_ASSERT_POSITION,
	    0,
	    (c_node->flags & ONIBI_AST_NODE_POSITIVE) ? 1 : 0,
	    0,
	    0,
	    1,
	    onibi_assertion_kind_operand(resolved_node->assertion_kind),
	    0,
	    0,
	    1,
	    (OnibiSubprogramId)subprogram_id};
	onibi_fragment_t result = onibi_fragment_empty(builder);
	result.nullable = 1;
	onibi_g_action_vector_push(&result.start_actions, action);
	return result;
    }
    if (type_code == ONIBI_AST_CAPTURE) {
	long capture_id = resolved_node->capture_id;
	onibi_fragment_t result = onibi_fragment_explicit(
	    onibi_compile_node(c_node->body, builder), builder);
	if (builder->ordered_choice_depth != 0) {
	    for (size_t i = 0; i < builder->nullable_scope_count; i++) {
		OnibiGAction test = onibi_counter_action(
		    ONIBI_GA_NULL_CAPTURE, builder->nullable_scopes[i], 1,
		    capture_id);
		onibi_g_action_vector_push(&result.start_actions, test);
	    }
	}
	OnibiGAction open = {0}, close = {0};
	open.code = ONIBI_GA_CAPTURE_OPEN;
	if (builder->ordered_choice_depth == 0 &&
	    builder->casefold_repeat_depth > 0) {
	    open.code = ONIBI_GA_CAPTURE_OPEN_UNSCOPED;
	    builder->capture_order_required = 1;
	}
	open.has_slot = 1;
	open.slot = onibi_capture_boundary_slot(capture_id, 0);
	close.code = ONIBI_GA_CAPTURE_CLOSE;
	close.has_slot = 1;
	close.slot = onibi_capture_boundary_slot(capture_id, 1);
	onibi_g_action_vector_push(&result.start_actions, open);
	onibi_g_action_vector_push(&result.pending_actions, close);
	return result;
    }
    if (type_code == ONIBI_AST_GROUP)
	return onibi_compile_node(c_node->body, builder);
    if (type_code == ONIBI_AST_QUANTIFIER) {
	long min = resolved_node->repeat_min, max = resolved_node->repeat_max;
	int greedy = (resolved_node->flags & ONIBI_SEMANTIC_REPEAT_GREEDY) != 0;
	OnibiAstId atom = c_node->atom;
	int nullable = (builder->semantics->nodes[atom].flags &
			ONIBI_SEMANTIC_NULLABLE) != 0;
	long reference_size = onibi_repeat_reference_size(atom, builder);
	const OnibiAstNode *atom_node =
	    onibi_ast_node_const(builder->ast, atom);
	if (nullable &&
	    (reference_size == 0 || atom_node->kind == ONIBI_AST_LOOKAHEAD ||
	     atom_node->kind == ONIBI_AST_LOOKBEHIND)) {
	    onibi_compiler_mark_unsupported(
		builder, ONIBI_UNSUPPORTED_ZERO_WIDTH_REPEAT);
	    rb_raise(eRegexpError,
		     "zero-width repeat is not supported in RSeq");
	}
	if (min == 0) builder->optional_seen = 1;
	if ((resolved_node->flags & ONIBI_SEMANTIC_REPEAT_POSSESSIVE) &&
	    max != min) {
	    onibi_compiler_mark_unsupported(builder,
					    ONIBI_UNSUPPORTED_POSSESSIVE);
	    rb_raise(eRegexpError,
		     "variable possessive quantifier is not supported in RSeq");
	}
	int expanded =
	    max >= 0 && greedy &&
	    (max <= 1 || onibi_repeat_reference_multiply(
			     onibi_repeat_reference_add(reference_size,
							ONIBI_MRI_SIZE_PUSH),
			     max) <= ONIBI_MRI_REPEAT_EXPAND_LIMIT);
	if (max > ONIBI_RSEQ_REPEAT_UNROLL_LIMIT ||
	    (nullable && !expanded && max != 1))
	    return onibi_compile_compact_repeat(atom, min,
						max < 0 ? UINT32_MAX : max,
						greedy, nullable, builder);
	onibi_fragment_t result =
	    onibi_fragment_explicit(onibi_fragment_empty(builder), builder);
	for (long i = 0; i < min; i++) {
	    onibi_fragment_t part = onibi_fragment_explicit(
		onibi_compile_repeat_atom(atom, builder, max < 0 || max > 1,
					  min != max),
		builder);
	    onibi_fragment_join(&result, part, builder);
	}
	if (max < 0) {
	    onibi_fragment_t part = onibi_fragment_explicit(
		onibi_compile_repeat_atom(atom, builder, 1, 1), builder);
	    long choice = result.exits.entries[0],
		 exit = onibi_nfa_epsilon_state(builder);
	    if (!greedy)
		onibi_nfa_add_connection(builder, choice, exit,
					 &(OnibiGActionVector){0}, 0);
	    onibi_nfa_add_connection(builder, choice, part.starts.entries[0],
				     &(OnibiGActionVector){0}, 0);
	    if (greedy)
		onibi_nfa_add_connection(builder, choice, exit,
					 &(OnibiGActionVector){0}, 0);
	    onibi_nfa_add_connection(builder, part.exits.entries[0], choice,
				     &(OnibiGActionVector){0}, 0);
	    result.exits.entries[0] = (OnibiStateId)exit;
	    onibi_id_vector_free(&part.starts);
	    onibi_id_vector_free(&part.exits);
	    onibi_g_action_vector_free(&part.start_actions);
	    onibi_g_action_vector_free(&part.pending_actions);
	}
	else if (max > min) {
	    long exit = onibi_nfa_epsilon_state(builder);
	    for (long i = min; i < max; i++) {
		onibi_fragment_t part = onibi_fragment_explicit(
		    onibi_compile_repeat_atom(atom, builder, max > 1, 1),
		    builder);
		long choice = result.exits.entries[0];
		if (!greedy)
		    onibi_nfa_add_connection(builder, choice, exit,
					     &(OnibiGActionVector){0}, 0);
		onibi_fragment_join(&result, part, builder);
		if (greedy)
		    onibi_nfa_add_connection(builder, choice, exit,
					     &(OnibiGActionVector){0}, 0);
	    }
	    onibi_nfa_add_connection(builder, result.exits.entries[0], exit,
				     &(OnibiGActionVector){0}, 0);
	    result.exits.entries[0] = (OnibiStateId)exit;
	}
	return result;
    }
    rb_raise(eRegexpError, "unsupported AST node");
    return onibi_fragment_empty(builder);
}

/* Initialize pass: create one owner for all mutable compiler state. */
static void
onibi_compiler_pass_init_builder(onibi_gir_builder_t *builder,
				 OnibiParsed *parsed,
				 const OnibiResolvedArena *semantics,
				 onibi_allocation_owner_t *allocation_owner)
{
    memset(builder, 0, sizeof(*builder));
    builder->ast = &parsed->arena;
    builder->semantics = semantics;
    builder->encoding_index = parsed->encoding_index;
    builder->allocation_owner = allocation_owner;
    onibi_gir_state_vector_init(&builder->states);
    onibi_gir_state_vector_bind(&builder->states, allocation_owner);
    onibi_gir_edge_vector_init(&builder->edges);
    onibi_gir_edge_vector_bind(&builder->edges, builder->allocation_owner);
    onibi_rseq_subprogram_vector_init(&builder->subprograms);
    onibi_rseq_subprogram_vector_bind(&builder->subprograms,
				      builder->allocation_owner);
    onibi_backref_desc_vector_init(&builder->backrefs);
    onibi_backref_desc_vector_bind(&builder->backrefs,
				   builder->allocation_owner);
    onibi_id_vector_init(&builder->backref_capture_ids);
    onibi_id_vector_bind(&builder->backref_capture_ids,
			 builder->allocation_owner);
    onibi_rseq_subprogram_vector_push(&builder->subprograms,
				      (OnibiRSeqSubprogramEntry){0, 0, 0});
    onibi_gir_edge_vector_init(&builder->subprogram_entries);
    onibi_gir_edge_vector_bind(&builder->subprogram_entries,
			       builder->allocation_owner);
    onibi_id_vector_init(&builder->lookbehind_widths);
    onibi_id_vector_bind(&builder->lookbehind_widths,
			 builder->allocation_owner);
    onibi_semantic_class_vector_init(&builder->classes);
    onibi_semantic_class_vector_bind(&builder->classes, allocation_owner);
    for (size_t i = 1; i < semantics->subprogram_count; i++)
	onibi_rseq_subprogram_vector_push(&builder->subprograms,
					  (OnibiRSeqSubprogramEntry){0, 0, 0});
    builder->resolved_subprogram_count = semantics->subprogram_count;
    builder->semantic_subprogram_count = semantics->subprogram_count;
    builder->subprogram_status = onibi_owned_realloc(
	builder->allocation_owner, NULL, builder->resolved_subprogram_count);
    memset(builder->subprogram_status, 0,
	   builder->resolved_subprogram_count * sizeof(unsigned char));
    onibi_guard_vector_init(&builder->capture_guards);
    onibi_guard_vector_bind(&builder->capture_guards,
			    builder->allocation_owner);
    onibi_guard_vector_init(&builder->exit_guards);
    onibi_guard_vector_bind(&builder->exit_guards, builder->allocation_owner);
    onibi_id_vector_init(&builder->progress_slots);
    onibi_id_vector_bind(&builder->progress_slots, builder->allocation_owner);
    onibi_subprogram_variant_vector_init(&builder->subprogram_variants);
    onibi_subprogram_variant_vector_bind(&builder->subprogram_variants,
					 builder->allocation_owner);
}

/* Lower NFA pass, followed by the explicit epsilon-elimination boundary. */
static void
onibi_compiler_pass_lower(OnibiParsed *parsed, OnibiCompilerOwner *owner,
			  OnibiGirEdgeVector *start_edges, long *accept_out,
			  long *root_entry_out, VALUE *nfa_diagnostics_out)
{
    onibi_gir_builder_t *builder = &owner->builder;
    OnibiTaggedNfa *nfa = &owner->nfa;
    onibi_nfa_init(nfa, builder->allocation_owner);
    owner->nfa_active = 1;
    builder->nfa = nfa;
    owner->root_fragment = onibi_compile_node(parsed->arena.root, builder);
    nfa->capture_order_required = builder->capture_order_required;
    owner->root_fragment_active = 1;
    onibi_fragment_t *fragment = &owner->root_fragment;
    long accept = builder->next_id++;
    onibi_nfa_state(builder, accept, ONIBI_G_ACCEPT, 0, 0);
    onibi_id_vector_single(&owner->accept_starts, (OnibiStateId)accept,
			   builder->allocation_owner);
    OnibiIdVector exit_ids = fragment->exits;
    onibi_connect_fragment_actions(
	builder, &exit_ids, &owner->accept_starts, &fragment->pending_actions,
	(fragment->lazy & ONIBI_FRAGMENT_EXIT_LAZY) != 0);
    onibi_id_vector_free(&owner->accept_starts);
    onibi_id_vector_init(&fragment->exits);
    long root_entry =
	fragment->starts.count > 0 ? (long)fragment->starts.entries[0] : accept;
    if (fragment->nullable &&
	(fragment->lazy & ONIBI_FRAGMENT_NULLABLE_LAZY) != 0) {
	owner->pending_actions = onibi_g_action_vector_concat(
	    &fragment->start_actions, &fragment->pending_actions,
	    builder->allocation_owner);
	onibi_nfa_add_start(builder, accept, &owner->pending_actions);
	onibi_g_action_vector_free(&owner->pending_actions);
	onibi_g_action_vector_init(&owner->pending_actions);
    }
    OnibiIdVector start_ids = fragment->starts;
    for (size_t i = 0; i < start_ids.count; i++) {
	long destination = (long)start_ids.entries[i];
	owner->pending_actions = onibi_g_action_vector_copy(
	    &fragment->start_actions, builder->allocation_owner);
	onibi_nfa_add_start(builder, destination, &owner->pending_actions);
	onibi_g_action_vector_free(&owner->pending_actions);
	onibi_g_action_vector_init(&owner->pending_actions);
    }
    onibi_id_vector_free(&start_ids);
    onibi_id_vector_free(&exit_ids);
    onibi_id_vector_init(&fragment->starts);
    if (fragment->nullable &&
	(fragment->lazy & ONIBI_FRAGMENT_NULLABLE_LAZY) == 0) {
	owner->pending_actions = onibi_g_action_vector_concat(
	    &fragment->start_actions, &fragment->pending_actions,
	    builder->allocation_owner);
	onibi_nfa_add_start(builder, accept, &owner->pending_actions);
	onibi_g_action_vector_free(&owner->pending_actions);
	onibi_g_action_vector_init(&owner->pending_actions);
    }
    onibi_g_action_vector_free(&fragment->start_actions);
    onibi_g_action_vector_free(&fragment->pending_actions);
    onibi_fragment_t empty_fragment;
    memset(&empty_fragment, 0, sizeof(empty_fragment));
    *fragment = empty_fragment;
    owner->root_fragment_active = 0;
    nfa->accept = accept;
    if (nfa_diagnostics_out) *nfa_diagnostics_out = onibi_nfa_diagnostics(nfa);
    onibi_epsilon_eliminate(nfa, builder, start_edges, &accept, &root_entry);
    if (nfa_diagnostics_out)
	onibi_nfa_add_elimination_diagnostics(*nfa_diagnostics_out, builder,
					      start_edges);
    onibi_nfa_free(nfa);
    owner->nfa_active = 0;
    builder->nfa = NULL;
    *accept_out = accept;
    *root_entry_out = root_entry;
}

static void
onibi_compiler_pass_verify_gir(const onibi_gir_builder_t *builder,
			       const OnibiGirEdgeVector *start_edges,
			       long accept, long root_entry, int options,
			       OnibiCompilerOwner *owner)
{
    OnibiGIRView view = {&builder->states,
			 &builder->edges,
			 start_edges,
			 &builder->subprogram_entries,
			 &builder->subprograms,
			 &builder->backrefs,
			 &builder->backref_capture_ids,
			 &builder->lookbehind_widths,
			 &builder->classes,
			 &builder->progress_slots,
			 builder->next_id,
			 builder->capture_count,
			 builder->counter_count,
			 accept,
			 root_entry,
			 builder->semantic_subprogram_count,
			 (uint32_t)options};
    onibi_gir_verify(&view);
    onibi_compiler_fail_if(owner, 5);
}

static VerifiedGIRAnalysis
onibi_compiler_pass_classify(const onibi_gir_builder_t *builder,
			     const OnibiGirEdgeVector *start_edges,
			     OnibiCompilerOwner *owner)
{
    VerifiedGIRAnalysis result = {0, (uint32_t)builder->capture_count, 0, 0,
				  ONIBI_EXEC_REGULAR};
    uint32_t execution_requirements = 0;
    unsigned char *semantic = NULL;
    if (builder->capture_count > 0) {
	semantic = onibi_owned_realloc(builder->allocation_owner, NULL,
				       (size_t)builder->capture_count);
	memset(semantic, 0, (size_t)builder->capture_count);
    }
#define MARK_SEMANTIC_CAPTURE(slot)                                            \
    do {                                                                       \
	uint32_t _slot = (uint32_t)(slot);                                     \
	if (semantic && _slot < result.capture_count && !semantic[_slot]) {    \
	    semantic[_slot] = 1;                                               \
	    result.semantic_capture_count++;                                   \
	}                                                                      \
    } while (0)
    if (result.capture_count > 0)
	result.rseq_features |= ONIBI_RSEQ_FEATURE_CAPTURE;
    for (size_t i = 0; i < builder->states.count; i++) {
	const OnibiGirStateEntry *state = &builder->states.entries[i];
	if (state->opcode == ONIBI_G_CHAR &&
	    (state->flags & ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE) != 0)
	    result.rseq_features |= ONIBI_RSEQ_FEATURE_LITERAL_CASEFOLD;
	if (state->opcode == ONIBI_G_BACKREF &&
	    state->value < builder->backrefs.count &&
	    (builder->backrefs.entries[state->value].flags &
	     ONIBI_BACKREF_FLAG_IGNORE_CASE) != 0)
	    result.rseq_features |= ONIBI_RSEQ_FEATURE_INCOMPLETE_CASEFOLD;
	if (state->opcode == ONIBI_G_CLASS &&
	    state->value < builder->classes.count &&
	    builder->classes.entries[state->value].incomplete_casefold)
	    result.rseq_features |= ONIBI_RSEQ_FEATURE_INCOMPLETE_CASEFOLD;
	if (state->opcode == ONIBI_G_GRAPHEME ||
	    state->opcode == ONIBI_G_BACKREF || state->opcode == ONIBI_G_CALL ||
	    state->opcode == ONIBI_G_ATOMIC || state->opcode == ONIBI_G_ABSENT)
	    execution_requirements |= ONIBI_EXEC_REQUIRE_DYNAMIC;
	if (state->opcode == ONIBI_G_BACKREF &&
	    state->value < builder->backrefs.count) {
	    const OnibiBackrefDesc *descriptor =
		&builder->backrefs.entries[state->value];
	    for (uint16_t j = 0; j < descriptor->capture_count; j++)
		MARK_SEMANTIC_CAPTURE(
		    builder->backref_capture_ids
			.entries[descriptor->capture_list_off + j]);
	}
	if (state->opcode == ONIBI_G_BACKREF)
	    result.rseq_features |= ONIBI_RSEQ_FEATURE_BACKREF;
    }
#define CLASSIFY_ACTION_VECTOR(vector_pointer)                                 \
    do {                                                                       \
	const OnibiGActionVector *_actions = (vector_pointer);                 \
	for (size_t _j = 0; _j < _actions->count; _j++) {                      \
	    const OnibiGAction *_action = &_actions->entries[_j];              \
	    switch (_action->code) {                                           \
	    case ONIBI_GA_TEST_CAPTURE:                                        \
		MARK_SEMANTIC_CAPTURE(_action->slot);                          \
		execution_requirements |= ONIBI_EXEC_REQUIRE_DYNAMIC;          \
		break;                                                         \
	    case ONIBI_GA_ASSERT_POSITION:                                     \
		result.rseq_features |= ONIBI_RSEQ_FEATURE_ASSERTION;          \
		if (_action->assert_kind == ONIBI_RAP_LOOKAHEAD ||             \
		    _action->assert_kind == ONIBI_RAP_LOOKBEHIND)              \
		    result.rseq_features |= ONIBI_RSEQ_FEATURE_LOOKAROUND;     \
		execution_requirements |= ONIBI_EXEC_REQUIRE_TAGGED;           \
		break;                                                         \
	    case ONIBI_GA_MATCH_RESET:                                         \
		result.rseq_features |= ONIBI_RSEQ_FEATURE_MATCH_RESET;        \
		execution_requirements |= ONIBI_EXEC_REQUIRE_TAGGED;           \
		break;                                                         \
	    case ONIBI_GA_COUNTER_INIT:                                        \
		result.rseq_features |= ONIBI_RSEQ_FEATURE_COUNTER;            \
		break;                                                         \
	    case ONIBI_GA_CAPTURE_OPEN:                                        \
		result.rseq_features |= ONIBI_RSEQ_FEATURE_CAPTURE;            \
		break;                                                         \
	    case ONIBI_GA_CAPTURE_OPEN_UNSCOPED:                               \
		result.rseq_features |= ONIBI_RSEQ_FEATURE_CAPTURE;            \
		execution_requirements |= ONIBI_EXEC_REQUIRE_TAGGED;           \
		break;                                                         \
	    default: break;                                                    \
	    }                                                                  \
	    if (_action->code == ONIBI_GA_PROGRESS ||                          \
		_action->code == ONIBI_GA_COUNTER_INIT ||                      \
		_action->code == ONIBI_GA_COUNTER_INCREMENT ||                 \
		_action->code == ONIBI_GA_TEST_COUNTER_LT ||                   \
		_action->code == ONIBI_GA_TEST_COUNTER_GE ||                   \
		(_action->code >= ONIBI_GA_NULL_ENTER &&                       \
		 _action->code <= ONIBI_GA_NULL_STOP)) {                       \
		if (_action->has_slot &&                                       \
		    (uint32_t)_action->slot + 1U > result.counter_count)       \
		    result.counter_count = (uint32_t)_action->slot + 1U;       \
		execution_requirements |= ONIBI_EXEC_REQUIRE_TAGGED;           \
	    }                                                                  \
	    if (_action->code >= ONIBI_GA_NULL_ENTER &&                        \
		_action->code <= ONIBI_GA_NULL_STOP &&                         \
		(uint32_t)_action->slot + 2U > result.counter_count)           \
		result.counter_count = (uint32_t)_action->slot + 2U;           \
	    if (_action->code == ONIBI_GA_NULL_CAPTURE)                        \
		MARK_SEMANTIC_CAPTURE(_action->arg32);                         \
	}                                                                      \
    } while (0)
    for (size_t i = 0; i < builder->edges.count; i++)
	CLASSIFY_ACTION_VECTOR(&builder->edges.entries[i].actions);
    for (size_t i = 0; i < start_edges->count; i++)
	CLASSIFY_ACTION_VECTOR(&start_edges->entries[i].actions);
    for (size_t i = 0; i < builder->subprogram_entries.count; i++)
	CLASSIFY_ACTION_VECTOR(&builder->subprogram_entries.entries[i].actions);
#undef CLASSIFY_ACTION_VECTOR
#undef MARK_SEMANTIC_CAPTURE
    result.execution_kind =
	onibi_execution_kind_for_requirements(execution_requirements);
    onibi_compiler_fail_if(owner, 6);
    onibi_owned_free(builder->allocation_owner, semantic);
    return result;
}

static void
onibi_compiler_pass_optimize(onibi_gir_builder_t *builder,
			     OnibiCompilerOwner *owner)
{
    /* Optimization must not change ordered edge semantics. The first safe
     * optimization is performed by the RSeq lowerer after this boundary. */
    (void)builder;
    onibi_compiler_fail_if(owner, 7);
}

/* Analyze pass.  This pass reads only the immutable AST.  Lowering must not
 * perform these queries while it walks nodes. */
static OnibiAnalyzeOutput
onibi_compiler_pass_analyze(OnibiNormalizeOutput normalize,
			    onibi_gir_builder_t *builder,
			    OnibiCompilerOwner *owner)
{
    OnibiParsed *parsed = normalize.parsed;
    onibi_analyze_semantic_node(parsed, parsed->arena.root);
    const OnibiResolvedNode *root =
	&normalize.semantics->nodes[parsed->arena.root];
    for (size_t i = 0; i < normalize.semantics->count; i++) {
	const OnibiResolvedNode *node = &normalize.semantics->nodes[i];
	if (!(node->flags & ONIBI_SEMANTIC_RESOLVED)) continue;
	if ((node->flags &
	     (ONIBI_SEMANTIC_RESOLVED | ONIBI_SEMANTIC_NORMALIZED |
	      ONIBI_SEMANTIC_ANALYZED)) !=
	    (ONIBI_SEMANTIC_RESOLVED | ONIBI_SEMANTIC_NORMALIZED |
	     ONIBI_SEMANTIC_ANALYZED))
	    rb_raise(eRegexpError, "semantic analysis invariant failed");
	if ((node->kind == ONIBI_AST_BACKREF ||
	     node->kind == ONIBI_AST_SUBROUTINE ||
	     node->kind == ONIBI_AST_CONDITIONAL) &&
	    node->reference_target == ONIBI_AST_NONE)
	    rb_raise(eRegexpError, "semantic reference invariant failed");
	if ((node->kind == ONIBI_AST_SUBROUTINE ||
	     node->kind == ONIBI_AST_ATOMIC ||
	     node->kind == ONIBI_AST_ABSENCE ||
	     node->kind == ONIBI_AST_LOOKAHEAD ||
	     node->kind == ONIBI_AST_LOOKBEHIND) &&
	    node->subprogram_id == UINT32_MAX)
	    rb_raise(eRegexpError, "semantic subprogram invariant failed");
    }
    onibi_compiler_fail_if(owner, 3);
    return (OnibiAnalyzeOutput){parsed,
				normalize.semantics,
				builder,
				(long)normalize.semantics->capture_count,
				(root->flags & ONIBI_SEMANTIC_NULLABLE) != 0,
				root->min_width,
				root->max_width};
}

/* Publish pass: transfer verified immutable GIR records to the result. */
static VALUE
onibi_compiler_pass_publish(onibi_gir_builder_t *builder,
			    OnibiGirEdgeVector *start_edges, long accept,
			    long root_entry, long counter_count,
			    int parsed_options, VerifiedGIRAnalysis analysis,
			    OnibiCompilerOwner *owner)
{
    onibi_compiler_fail_if(owner, 8);
    OnibiCompiled *compiled_result;
    VALUE result = TypedData_Make_Struct(rb_cObject, OnibiCompiled,
					 &onibi_compiled_type, compiled_result);
    memset(compiled_result, 0, sizeof(*compiled_result));
    onibi_rseq_subprogram_vector_init(&compiled_result->subprograms);
    onibi_backref_desc_vector_init(&compiled_result->backrefs);
    onibi_id_vector_init(&compiled_result->backref_capture_ids);
    onibi_gir_edge_vector_init(&compiled_result->subprogram_entries);
    onibi_id_vector_init(&compiled_result->lookbehind_widths);
    onibi_semantic_class_vector_init(&compiled_result->classes);
    onibi_gir_state_vector_init(&compiled_result->states);
    onibi_gir_edge_vector_init(&compiled_result->edges);
    onibi_gir_edge_vector_init(&compiled_result->start_edges);

    for (size_t i = 0; i < builder->edges.count; i++)
	if (!onibi_owned_pointer_p(builder->allocation_owner,
				   builder->edges.entries[i].actions.entries))
	    rb_raise(eRegexpError,
		     "GIR edge action publication owner is invalid");
    for (size_t i = 0; i < start_edges->count; i++)
	if (!onibi_owned_pointer_p(builder->allocation_owner,
				   start_edges->entries[i].actions.entries))
	    rb_raise(eRegexpError,
		     "GIR start action publication owner is invalid");
    for (size_t i = 0; i < builder->subprogram_entries.count; i++)
	if (!onibi_owned_pointer_p(
		builder->allocation_owner,
		builder->subprogram_entries.entries[i].actions.entries))
	    rb_raise(eRegexpError,
		     "GIR subprogram entry publication owner is invalid");
    if (!onibi_owned_pointer_p(builder->allocation_owner,
			       builder->states.entries) ||
	!onibi_owned_pointer_p(builder->allocation_owner,
			       builder->edges.entries) ||
	!onibi_owned_pointer_p(builder->allocation_owner,
			       start_edges->entries) ||
	!onibi_owned_pointer_p(builder->allocation_owner,
			       builder->subprograms.entries) ||
	(builder->backrefs.count != 0 &&
	 !onibi_owned_pointer_p(builder->allocation_owner,
				builder->backrefs.entries)) ||
	(builder->backref_capture_ids.count != 0 &&
	 !onibi_owned_pointer_p(builder->allocation_owner,
				builder->backref_capture_ids.entries)) ||
	(builder->subprogram_entries.count != 0 &&
	 !onibi_owned_pointer_p(builder->allocation_owner,
				builder->subprogram_entries.entries)) ||
	(builder->lookbehind_widths.count != 0 &&
	 !onibi_owned_pointer_p(builder->allocation_owner,
				builder->lookbehind_widths.entries)))
	rb_raise(eRegexpError, "GIR publication owner is invalid");

    for (size_t i = 0; i < builder->edges.count; i++) {
	onibi_owned_transfer(builder->allocation_owner,
			     builder->edges.entries[i].actions.entries);
	builder->edges.entries[i].actions.allocation_owner = NULL;
    }
    for (size_t i = 0; i < start_edges->count; i++) {
	onibi_owned_transfer(builder->allocation_owner,
			     start_edges->entries[i].actions.entries);
	start_edges->entries[i].actions.allocation_owner = NULL;
    }
    for (size_t i = 0; i < builder->subprogram_entries.count; i++) {
	onibi_owned_transfer(
	    builder->allocation_owner,
	    builder->subprogram_entries.entries[i].actions.entries);
	builder->subprogram_entries.entries[i].actions.allocation_owner = NULL;
    }
    onibi_owned_transfer(builder->allocation_owner, builder->states.entries);
    onibi_owned_transfer(builder->allocation_owner, builder->edges.entries);
    onibi_owned_transfer(builder->allocation_owner, start_edges->entries);
    onibi_owned_transfer(builder->allocation_owner,
			 builder->subprograms.entries);
    if (builder->backrefs.entries)
	onibi_owned_transfer(builder->allocation_owner,
			     builder->backrefs.entries);
    if (builder->backref_capture_ids.entries)
	onibi_owned_transfer(builder->allocation_owner,
			     builder->backref_capture_ids.entries);
    onibi_owned_transfer(builder->allocation_owner,
			 builder->subprogram_entries.entries);
    if (builder->lookbehind_widths.entries)
	onibi_owned_transfer(builder->allocation_owner,
			     builder->lookbehind_widths.entries);
    for (size_t i = 0; i < builder->classes.count; i++)
	onibi_owned_transfer(builder->allocation_owner,
			     builder->classes.entries[i].data);
    onibi_owned_transfer(builder->allocation_owner, builder->classes.entries);
    builder->states.allocation_owner = NULL;
    builder->edges.allocation_owner = NULL;
    start_edges->allocation_owner = NULL;
    builder->subprograms.allocation_owner = NULL;
    builder->backrefs.allocation_owner = NULL;
    builder->backref_capture_ids.allocation_owner = NULL;
    builder->subprogram_entries.allocation_owner = NULL;
    builder->lookbehind_widths.allocation_owner = NULL;
    builder->classes.allocation_owner = NULL;
    compiled_result->states = builder->states;
    compiled_result->edges = builder->edges;
    compiled_result->start_edges = *start_edges;
    compiled_result->subprograms = builder->subprograms;
    compiled_result->backrefs = builder->backrefs;
    compiled_result->backref_capture_ids = builder->backref_capture_ids;
    compiled_result->subprogram_entries = builder->subprogram_entries;
    compiled_result->lookbehind_widths = builder->lookbehind_widths;
    compiled_result->classes = builder->classes;
    onibi_gir_state_vector_init(&builder->states);
    onibi_gir_edge_vector_init(&builder->edges);
    onibi_gir_edge_vector_init(start_edges);
    onibi_rseq_subprogram_vector_init(&builder->subprograms);
    onibi_backref_desc_vector_init(&builder->backrefs);
    onibi_id_vector_init(&builder->backref_capture_ids);
    onibi_gir_edge_vector_init(&builder->subprogram_entries);
    onibi_id_vector_init(&builder->lookbehind_widths);
    onibi_semantic_class_vector_init(&builder->classes);
    compiled_result->accept = accept;
    compiled_result->capture_count = builder->capture_count;
    compiled_result->counter_count = analysis.counter_count;
    compiled_result->analysis = analysis;
    compiled_result->lowering_work = builder->lowering_work;
    compiled_result->options = parsed_options;
    return result;
}

static VALUE
onibi_compiler_compile_body(VALUE opaque)
{
    OnibiCompilerCall *call = (OnibiCompilerCall *)(uintptr_t)opaque;
    OnibiCompilerOwner *owner = call->owner;
    VALUE parsed = call->parsed;
    OnibiParsed *parsed_data = onibi_parsed_get(parsed);
    if (parsed_data->arena.root == ONIBI_AST_NONE)
	rb_raise(rb_eArgError, "compiler requires parser output");
    if (owner->compile_outcome)
	owner->compile_outcome->error_kind = ONIBI_COMPILE_INTERNAL_ERROR;
    OnibiParseOutput parse = {parsed_data, parsed_data->options};
    onibi_allocation_owner_set_phase(&owner->allocations, 1);
    OnibiResolveOutput resolve = onibi_compiler_pass_resolve(parse, owner);
    onibi_allocation_owner_set_phase(&owner->allocations, 2);
    OnibiNormalizeOutput normalize =
	onibi_compiler_pass_normalize(resolve, owner);
    int parsed_options = parse.options;

    onibi_compiler_pass_init_builder(&owner->builder, parsed_data,
				     normalize.semantics, &owner->allocations);
    onibi_allocation_owner_set_phase(&owner->allocations, 3);
    OnibiAnalyzeOutput analyze =
	onibi_compiler_pass_analyze(normalize, &owner->builder, owner);
    owner->builder.capture_count = analyze.capture_count;
    long accept;
    long root_entry;
    VALUE nfa_diagnostics = Qnil;

    onibi_allocation_owner_set_phase(&owner->allocations, 4);
    onibi_compiler_pass_lower(parsed_data, owner, &owner->start_edges, &accept,
			      &root_entry,
			      call->nfa_diagnostics ? &nfa_diagnostics : NULL);

    if (call->nfa_diagnostics) return nfa_diagnostics;

    OnibiLowerNfaOutput lower_nfa = {&owner->builder, &owner->start_edges,
				     accept, root_entry};
    /* onibi_compiler_pass_lower owns the tagged-NFA and epsilon-elimination
     * boundary.  Keep the result contract explicit for later split passes. */
    (void)lower_nfa;
    OnibiGirOutput gir = {&owner->builder};
    (void)gir;
    OnibiRSeqSubprogramEntry root_descriptor;
    memset(&root_descriptor, 0, sizeof(root_descriptor));
    root_descriptor.entry = (OnibiStateId)root_entry;
    root_descriptor.accept = (OnibiStateId)accept;
    root_descriptor.option_env =
	(OnibiOptionEnv){(uint32_t)parsed_options, parsed_data->encoding_index};
    root_descriptor.kind = ONIBI_SUBPROGRAM_ROOT;
    onibi_rseq_subprogram_vector_store(&owner->builder.subprograms, 0,
				       root_descriptor);
    onibi_allocation_owner_set_phase(&owner->allocations, 5);
    onibi_compile_outcome_verifier_error(&owner->allocations);
    onibi_compiler_pass_verify_gir(&owner->builder, &owner->start_edges, accept,
				   root_entry, parsed_options, owner);
    onibi_allocation_owner_set_phase(&owner->allocations, 6);
    VerifiedGIRAnalysis analysis = onibi_compiler_pass_classify(
	&owner->builder, &owner->start_edges, owner);
    if (analyze.max_width == 0)
	analysis.rseq_features |= ONIBI_RSEQ_FEATURE_ZERO_WIDTH_ONLY;
    onibi_allocation_owner_set_phase(&owner->allocations, 7);
    onibi_compiler_pass_optimize(&owner->builder, owner);
    onibi_allocation_owner_set_phase(&owner->allocations, 8);
    VALUE result = onibi_compiler_pass_publish(
	&owner->builder, &owner->start_edges, accept, root_entry,
	analysis.counter_count, parsed_options, analysis, owner);
    owner->gir_transferred = 1;
    if (owner->compile_outcome) {
	owner->compile_outcome->error_kind = ONIBI_COMPILE_OK;
	owner->compile_outcome->unsupported_reason = ONIBI_UNSUPPORTED_NONE;
    }
    rb_obj_freeze(result);
    return result;
}

static VALUE
onibi_compiler_compile_with_failure_and_outcome(
    VALUE parsed, int failure_phase, int *failure_fired,
    OnibiAllocationAccounting *accounting, OnibiCompileOutcome *outcome)
{
    OnibiCompilerOwner owner;
    memset(&owner, 0, sizeof(owner));
    onibi_allocation_owner_init(&owner.allocations, accounting);
    owner.failure_phase = failure_phase;
    owner.failure_fired = failure_fired;
    owner.compile_outcome = outcome;
    owner.allocations.failure_phase = failure_phase;
    owner.allocations.failure_fired = failure_fired;
    owner.allocations.compile_outcome = outcome;
    onibi_gir_edge_vector_init(&owner.start_edges);
    onibi_gir_edge_vector_bind(&owner.start_edges, &owner.allocations);
    OnibiCompilerCall call = {&owner, parsed, 0};
    return rb_ensure(onibi_compiler_compile_body, (VALUE)(uintptr_t)&call,
		     onibi_compiler_owner_ensure, (VALUE)(uintptr_t)&owner);
}

static VALUE
onibi_compiler_compile_with_failure(VALUE parsed, int failure_phase,
				    int *failure_fired,
				    OnibiAllocationAccounting *accounting)
{
    return onibi_compiler_compile_with_failure_and_outcome(
	parsed, failure_phase, failure_fired, accounting, NULL);
}

static VALUE
onibi_compiler_compile_with_outcome(VALUE parsed, OnibiCompileOutcome *outcome)
{
    return onibi_compiler_compile_with_failure_and_outcome(parsed, 0, NULL,
							   NULL, outcome);
}

static VALUE
onibi_compiler_nfa_diagnostics(VALUE parsed)
{
    OnibiCompilerOwner owner;
    memset(&owner, 0, sizeof(owner));
    onibi_allocation_owner_init(&owner.allocations, NULL);
    onibi_gir_edge_vector_init(&owner.start_edges);
    onibi_gir_edge_vector_bind(&owner.start_edges, &owner.allocations);
    OnibiCompilerCall call = {&owner, parsed, 1};
    return rb_ensure(onibi_compiler_compile_body, (VALUE)(uintptr_t)&call,
		     onibi_compiler_owner_ensure, (VALUE)(uintptr_t)&owner);
}
