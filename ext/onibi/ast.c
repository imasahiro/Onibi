/* C AST ownership and parser-result lifetime. */
/* GIR payloads remain Ruby objects.  These accessors are only for that
 * semantic boundary.  The tokenizer and parser use OnibiTokenRecord. */
static inline OnibiTokenKind
onibi_token_kind_code(VALUE token)
{
    VALUE kind = onibi_hash_value_id(token, id_key_kind_code);
    return NIL_P(kind) ? (OnibiTokenKind)-1 : (OnibiTokenKind)NUM2UINT(kind);
}

static inline ID
onibi_token_name_id(VALUE token)
{
    VALUE name_id = onibi_hash_value_id(token, id_key_name_id);
    return NIL_P(name_id) ? (ID)0 : (ID)NUM2ULONG(name_id);
}

static VALUE onibi_deep_freeze(VALUE value);

static int
onibi_deep_freeze_hash_entry(VALUE key, VALUE value, VALUE unused)
{
    (void)key;
    (void)unused;
    onibi_deep_freeze(value);
    return ST_CONTINUE;
}

/* AST and compiled metadata are published as immutable object graphs. */
static VALUE
onibi_deep_freeze(VALUE value)
{
    if (RB_TYPE_P(value, T_ARRAY)) {
	for (long i = 0; i < RARRAY_LEN(value); i++)
	    onibi_deep_freeze(rb_ary_entry(value, i));
    }
    else if (RB_TYPE_P(value, T_HASH)) {
	rb_hash_foreach(value, onibi_deep_freeze_hash_entry, Qnil);
    }
    rb_obj_freeze(value);
    return value;
}

static long
onibi_c_find_close(const OnibiTokenVector *tokens, long begin, long end,
		   OnibiTokenKind open, OnibiTokenKind close)
{
    long depth = 0;
    for (long i = begin; i < end; i++) {
	OnibiTokenKind kind = onibi_token_at(tokens, i)->kind;
	if (kind == open || kind == ONIBI_TOKEN_GROUP_START ||
	    kind == ONIBI_TOKEN_NONCAPTURE_START ||
	    kind == ONIBI_TOKEN_ATOMIC_START ||
	    kind == ONIBI_TOKEN_LOOKAHEAD_START ||
	    kind == ONIBI_TOKEN_LOOKBEHIND_START ||
	    kind == ONIBI_TOKEN_OPTION_SCOPE_START ||
	    kind == ONIBI_TOKEN_ABSENCE_START ||
	    kind == ONIBI_TOKEN_CONDITIONAL_START)
	    depth++;
	else if (kind == close && --depth == 0)
	    return i;
    }
    return -1;
}

typedef struct {
    OnibiAstArena arena;
    int options;
    int encoding_index;
    unsigned int ast_flags;
} OnibiParsed;
typedef struct {
    unsigned int flags;
} OnibiAstAnalysis;

static void
onibi_parsed_mark(void *ptr)
{
    (void)ptr;
}
static void
onibi_parsed_free(void *ptr)
{
    OnibiParsed *parsed = (OnibiParsed *)ptr;
    if (parsed != NULL) onibi_ast_arena_free(&parsed->arena);
    xfree(parsed);
}
static size_t
onibi_parsed_memsize(const void *ptr)
{
    const OnibiParsed *parsed = (const OnibiParsed *)ptr;
    if (parsed == NULL) return 0;
    size_t size = sizeof(*parsed) +
		  parsed->arena.capacity * sizeof(OnibiAstNode) +
		  parsed->arena.bytes_count;
    for (size_t i = 0; i < parsed->arena.count; i++) {
	size += parsed->arena.nodes[i].child_capacity * sizeof(OnibiAstId);
	size += parsed->arena.nodes[i].range_capacity * sizeof(OnibiAstRange);
    }
    return size;
}
static const rb_data_type_t onibi_parsed_type = {
    "Onibi::Parsed",
    {onibi_parsed_mark, onibi_parsed_free, onibi_parsed_memsize, NULL, {NULL}},
    0,
    0,
    RUBY_TYPED_FREE_IMMEDIATELY};
static inline OnibiParsed *
onibi_parsed_get(VALUE value)
{
    OnibiParsed *parsed;
    TypedData_Get_Struct(value, OnibiParsed, &onibi_parsed_type, parsed);
    return parsed;
}

static int onibi_ast_safe_multibyte_class(const OnibiAstArena *arena,
					  OnibiAstId id);
static int onibi_ast_nullable_scan(const OnibiAstArena *arena, OnibiAstId id,
				   OnibiAstAnalysis *analysis);
