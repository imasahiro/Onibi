#include "onibi_ir.h"
#include "ruby.h"
#include "ruby/encoding.h"
#include "ruby/onigmo.h"
#include "ruby/re.h"
#include "ruby/thread.h"

#define ONIBI_SUBPROGRAM_ATOMIC UINT32_C(1)
#define ONIBI_SUBPROGRAM_ABSENT UINT32_C(2)
#define ONIBI_AST_FLAG_SAFE_MULTIBYTE_CLASS (1U << 0)
#define ONIBI_AST_FLAG_ANCHOR_REPEAT (1U << 1)
#define ONIBI_AST_FLAG_NULLABLE_ABSENCE (1U << 2)
#define ONIBI_AST_FLAG_NULLABLE_CAPTURE (1U << 3)
#define ONIBI_AST_ANALYSIS_HAS_CAPTURE (1U << 0)
#define ONIBI_AST_ANALYSIS_NULLABLE_CAPTURE (1U << 1)
#define ONIBI_AST_ANALYSIS_NULLABLE_ABSENCE (1U << 2)
#define ONIBI_AST_ANALYSIS_HAS_ANCHOR (1U << 3)
#define ONIBI_AST_ANALYSIS_ANCHOR_REPEAT (1U << 4)
#define ONIBI_FEATURE_P(obj, flag) (((obj)->feature_flags & (flag)) != 0)
#include <alloca.h>
#include <ctype.h>
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define ONIBI_RSEQ_REPEAT_UNROLL_LIMIT 8L

typedef struct onibi_owned_allocation {
    struct onibi_owned_allocation *next;
    struct onibi_owned_allocation *previous;
    void *pointer;
    size_t size;
} onibi_owned_allocation_t;

typedef struct {
    size_t live_count;
} OnibiAllocationAccounting;

struct onibi_allocation_owner {
    onibi_owned_allocation_t *first;
    size_t allocation_count;
    size_t byte_count;
    int failure_phase;
    int active_phase;
    int failure_raised;
    int *failure_fired;
    OnibiAllocationAccounting *accounting;
};

static void
onibi_allocation_owner_init(onibi_allocation_owner_t *owner,
			    OnibiAllocationAccounting *accounting)
{
    memset(owner, 0, sizeof(*owner));
    owner->accounting = accounting;
}

static void
onibi_allocation_owner_set_phase(onibi_allocation_owner_t *owner, int phase)
{
    owner->active_phase = phase;
}

static void
onibi_allocation_owner_fail_if_armed(onibi_allocation_owner_t *owner)
{
    if (owner->failure_phase == owner->active_phase && !owner->failure_raised) {
	owner->failure_raised = 1;
	if (owner->failure_fired) *owner->failure_fired = 1;
	rb_raise(rb_eRegexpError,
		 "injected failure during owned allocation in pass %d",
		 owner->active_phase);
    }
}

static onibi_owned_allocation_t *
onibi_owned_allocation_find(onibi_allocation_owner_t *owner, void *pointer)
{
    if (!owner || !pointer) return NULL;
    for (onibi_owned_allocation_t *allocation = owner->first; allocation;
	 allocation = allocation->next)
	if (allocation->pointer == pointer) return allocation;
    return NULL;
}

static void
onibi_owned_allocation_unlink(onibi_allocation_owner_t *owner,
			      onibi_owned_allocation_t *allocation)
{
    if (allocation->previous)
	allocation->previous->next = allocation->next;
    else
	owner->first = allocation->next;
    if (allocation->next) allocation->next->previous = allocation->previous;
    owner->allocation_count--;
    owner->byte_count -= allocation->size;
    if (owner->accounting) owner->accounting->live_count--;
}

static void *
onibi_owned_realloc(onibi_allocation_owner_t *owner, void *pointer, size_t size)
{
    if (!owner) return ruby_xrealloc(pointer, size);
    if (!pointer) {
	onibi_owned_allocation_t *allocation = ALLOC(onibi_owned_allocation_t);
	memset(allocation, 0, sizeof(*allocation));
	allocation->next = owner->first;
	if (owner->first) owner->first->previous = allocation;
	owner->first = allocation;
	owner->allocation_count++;
	if (owner->accounting) owner->accounting->live_count++;
	allocation->pointer = ruby_xmalloc(size);
	allocation->size = size;
	owner->byte_count += size;
	onibi_allocation_owner_fail_if_armed(owner);
	return allocation->pointer;
    }
    onibi_owned_allocation_t *allocation =
	onibi_owned_allocation_find(owner, pointer);
    if (!allocation)
	rb_raise(rb_eRuntimeError, "allocation owner invariant failed");
    void *replacement = ruby_xrealloc(pointer, size);
    owner->byte_count -= allocation->size;
    owner->byte_count += size;
    allocation->pointer = replacement;
    allocation->size = size;
    onibi_allocation_owner_fail_if_armed(owner);
    return replacement;
}

static void
onibi_owned_free(onibi_allocation_owner_t *owner, void *pointer)
{
    if (!pointer) return;
    if (!owner) {
	xfree(pointer);
	return;
    }
    onibi_owned_allocation_t *allocation =
	onibi_owned_allocation_find(owner, pointer);
    if (!allocation) return;
    onibi_owned_allocation_unlink(owner, allocation);
    xfree(allocation->pointer);
    xfree(allocation);
}

static int
onibi_owned_pointer_p(onibi_allocation_owner_t *owner, void *pointer)
{
    return !pointer || onibi_owned_allocation_find(owner, pointer) != NULL;
}

static void
onibi_owned_transfer(onibi_allocation_owner_t *owner, void *pointer)
{
    if (!owner || !pointer) return;
    onibi_owned_allocation_t *allocation =
	onibi_owned_allocation_find(owner, pointer);
    if (!allocation) return;
    onibi_owned_allocation_unlink(owner, allocation);
    xfree(allocation);
}

static void
onibi_allocation_owner_cleanup(onibi_allocation_owner_t *owner)
{
    while (owner->first) {
	onibi_owned_allocation_t *allocation = owner->first;
	onibi_owned_allocation_unlink(owner, allocation);
	xfree(allocation->pointer);
	xfree(allocation);
    }
}

static VALUE mOnibi, cRegexp, eRegexpError, eTimeoutError;
static double onibi_default_timeout = 0.0;
static _Thread_local uint64_t onibi_deadline_ns = 0;

/* Match-local execution ABI.  The interpreter owns this object for the
 * complete search.  The pointer fields are storage owned by the context or
 * by its frontier arenas; they are never borrowed from Ruby objects. */
typedef struct {
    uint32_t *states;
    unsigned char *membership;
    size_t count;
    size_t capacity;
} OnibiFrontier;
typedef struct {
    unsigned char *data;
    size_t count, capacity;
} OnibiTagArena;
typedef struct {
    long *values;
    size_t count;
} OnibiSemanticCaptureFile;
typedef struct {
    long *values;
    size_t count;
} OnibiCounterFile;
typedef struct {
    uint32_t *frames;
    size_t count, capacity;
} OnibiCallStack;
typedef struct {
    VALUE regexp;
    VALUE subject;
    const OnibiRSeqHeader *program;
    OnigPosition search_origin;
    OnigPosition attempt_start;
    OnigPosition reported_start;
    OnigPosition current_position;
    OnibiFrontier current;
    OnibiFrontier next;
    OnibiTagArena tags;
    OnibiSemanticCaptureFile semantic_captures;
    OnibiCounterFile counters;
    OnibiCallStack calls;
    uint64_t work_before_poll;
    /* Ruby's private rb_hrtime_t is not public in this MRI release. */
    uint64_t timeout_deadline;
    VALUE rseq;
    const OnibiRSeqView *view;
    rb_encoding *encoding;
    OnibiEncodingMode encoding_mode;
    unsigned char *class_stack;
    size_t class_stack_capacity;
    long matched_end;
} OnibiExecCtx;
typedef enum {
    ONIBI_EXEC_STATUS_NO_MATCH = 0,
    ONIBI_EXEC_STATUS_MATCH = 1,
    ONIBI_EXEC_STATUS_INTERNAL_ERROR = -1,
    ONIBI_EXEC_STATUS_FALLBACK = 2
} OnibiExecStatus;

/* Test-only execution telemetry.  These counters are reset for each search
 * by the diagnostic entry point and are never used for matching decisions. */
typedef struct {
    unsigned long regular, tagged, dynamic, dfs, fallback, tag_events;
} OnibiDiagnostics;
static _Thread_local OnibiDiagnostics onibi_diagnostics;
static _Thread_local long *onibi_regular_capture_result = NULL;
static OnibiExecStatus onibi_exec_regular(OnibiExecCtx *ctx);
static int onibi_rseq_regular_match(OnibiExecCtx *ctx);
static int onibi_rseq_backtracking_match(VALUE rseq, const OnibiRSeqView *view,
					 VALUE subject, long start,
					 long search_origin, long *matched_end,
					 unsigned char *class_stack,
					 size_t class_stack_capacity);
static OnibiExecStatus onibi_exec_tagged(OnibiExecCtx *ctx);
static OnibiExecStatus onibi_exec_dynamic(OnibiExecCtx *ctx);
static OnibiExecStatus onibi_execute(OnibiExecCtx *ctx);
static _Thread_local OnibiExecCtx *onibi_active_exec_ctx = NULL;
static _Thread_local int onibi_inject_internal_error = 0;
static ID id_initialize, id_source, id_options, id_inspect, id_to_s, id_new,
    id_match, id_aref;
static ID id_instance_method, id_bind, id_call;
static ID id_bytebegin, id_byteend, id_length;
static ID id_scan, id_gsub;
static int onibi_rseq_view_init(VALUE blob, OnibiRSeqView *view);
static void onibi_rseq_view_prepare(OnibiRSeqView *view);
static int onibi_rseq_regular_capable(const OnibiRSeqView *view);
static void onibi_rseq_blob_validate(VALUE blob);
static ID id_encoding, id_index;
static ID id_a_assert_begin_buffer, id_a_assert_search_origin,
    id_a_assert_end_buffer;
static ID id_a_assert_begin_line, id_a_assert_end_line,
    id_a_assert_word_boundary;
static ID id_a_assert_nonword_boundary, id_a_assert_semi_end_buffer;
static ID id_a_assert_lookahead, id_a_assert_lookbehind;
static ID id_pred_byte, id_pred_bitmap, id_pred_any;
static ID id_insert;
static ID id_timeout, id_encode, id_message, id_names, id_named_captures;
static ID id_escape, id_union, id_to_regexp;
static ID id_opt_ignorecase, id_opt_multiline, id_opt_extended,
    id_opt_fixedencoding, id_opt_noencoding;
static ID id_prop_ascii, id_prop_ascii_hex;
static ID id_key_op, id_key_multiline, id_key_ignorecase;
static ID id_key_byte, id_key_capture, id_key_subprogram, id_key_entry;
static ID id_key_kind, id_key_kind_code, id_key_opcode, id_key_assert_kind,
    id_key_predicate_code;
static ID id_key_start, id_key_end, id_key_captures;
static ID id_key_slot, id_key_set, id_key_value;
static ID id_key_type_code, id_key_name, id_key_name_id, id_key_ctype,
    id_key_ranges, id_key_children;
static ID id_key_operands, id_key_negated, id_key_bitmap,
    id_key_preserve_if_set;
static ID id_key_class_mode;
static ID id_key_limit, id_key_positive, id_key_predicates;
static ID id_key_inline_ignorecase;
static ID id_key_body, id_key_options, id_key_negative_options,
    id_key_capturing;
static ID id_key_condition, id_key_branches, id_key_yes, id_key_no, id_key_atom;
static ID id_key_min, id_key_max, id_key_greedy, id_key_possessive;
static ID id_key_width;
static ID id_key_bytes, id_key_blob, id_key_header, id_key_edges;
static ID id_key_from, id_key_accept, id_key_action_offset;
static ID id_key_flags;
static ID id_key_id;
static ID id_key_capture_count;
static ID id_key_counter_count;
static ID id_key_state_count, id_key_features, id_key_edge_count,
    id_key_action_count;
static ID id_key_class_count, id_key_subprogram_count, id_key_start_edge_base,
    id_key_start_edge_count;
static ID id_key_blob_size, id_key_literal_count;
static ID id_key_version, id_key_semantic_capture_count;
static ID id_key_states_offset, id_key_edges_offset, id_key_actions_offset;
static ID id_key_classes_offset, id_key_literals_offset,
    id_key_descriptors_offset, id_key_subprograms_offset;
static ID id_key_negative_name, id_key_negative;
static ID id_anchor, id_anchor_start, id_anchor_end;
static ID id_kind_literal;
static ID id_recursive_marker;
static OnibiExecStatus onibi_vm_search(VALUE self, VALUE str,
				       long search_origin, long *match_start,
				       long *match_end);
static inline VALUE
onibi_hash_value_id(VALUE hash, ID key)
{
    return rb_hash_aref(hash, ID2SYM(key));
}
static int onibi_option_mask(VALUE options);
static int onibi_ascii_property_name_p(ID name_id);
static int onibi_valid_encoding(VALUE str);
static int onibi_unicode_ctype_id(ID property);
typedef enum {
    ONIBI_POSIX_UNKNOWN = 0,
    ONIBI_POSIX_ALPHA,
    ONIBI_POSIX_DIGIT,
    ONIBI_POSIX_ALNUM,
    ONIBI_POSIX_SPACE,
    ONIBI_POSIX_BLANK,
    ONIBI_POSIX_LOWER,
    ONIBI_POSIX_UPPER,
    ONIBI_POSIX_WORD,
    ONIBI_POSIX_XDIGIT
} OnibiPosixKind;
static OnibiPosixKind onibi_posix_kind_id(ID property);

static int
onibi_valid_encoding(VALUE str)
{
    return rb_enc_str_coderange(str) != RUBY_ENC_CODERANGE_BROKEN;
}

static OnibiEncodingMode
onibi_encoding_mode_for(VALUE str, rb_encoding *encoding)
{
    if (rb_enc_str_asciionly_p(str)) return ONIBI_ENC_ASCII_7BIT;
    if (rb_enc_mbmaxlen(encoding) == 1) return ONIBI_ENC_SINGLE_BYTE;
    if (rb_enc_get_index(str) == rb_utf8_encindex()) return ONIBI_ENC_UTF8;
    return ONIBI_ENC_GENERIC_MB;
}

static int
onibi_hex_digit(unsigned char c)
{
    return c >= '0' && c <= '9'
	       ? c - '0'
	       : (c >= 'a' && c <= 'f'
		      ? c - 'a' + 10
		      : (c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1));
}

static long
onibi_parse_count(const char *text, char **end)
{
    errno = 0;
    long value = strtol(text, end, 10);
    if (errno == ERANGE) rb_raise(eRegexpError, "quantifier is too large");
    return value;
}

static uint64_t
onibi_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

static void
onibi_check_deadline(void)
{
    if (onibi_active_exec_ctx) {
	if (onibi_active_exec_ctx->work_before_poll > 0)
	    onibi_active_exec_ctx->work_before_poll--;
	if (onibi_active_exec_ctx->timeout_deadline != 0 &&
	    onibi_now_ns() >= onibi_active_exec_ctx->timeout_deadline)
	    rb_raise(eTimeoutError, "regexp match timeout");
    }
    if (onibi_deadline_ns != 0 && onibi_now_ns() >= onibi_deadline_ns)
	rb_raise(eTimeoutError, "regexp match timeout");
}

static void
onibi_set_deadline(double seconds)
{
    if (seconds <= 0.0 || seconds >= (double)UINT64_MAX / 1e9) {
	onibi_deadline_ns = 0;
	return;
    }
    uint64_t now = onibi_now_ns();
    uint64_t delta = (uint64_t)(seconds * 1e9);
    onibi_deadline_ns = UINT64_MAX - now < delta ? 0 : now + delta;
}

static double
onibi_timeout_value(VALUE value)
{
    if (NIL_P(value)) return 0.0;
    if (RB_TYPE_P(value, T_STRING))
	rb_raise(rb_eTypeError, "no implicit conversion to float from string");
    if (value == Qtrue || value == Qfalse)
	rb_raise(rb_eTypeError, "no implicit conversion to float from %s",
		 value == Qtrue ? "true" : "false");
    double seconds = NUM2DBL(rb_to_float(value));
    if (isnan(seconds)) return 0.0;
    if (seconds <= 0.0) rb_raise(rb_eArgError, "invalid timeout: %g", seconds);
    return isinf(seconds) ? (double)UINT64_MAX / 1e9 : seconds;
}

typedef struct {
    /* Ruby-visible MRI compatibility values. */
    VALUE regexp;
    VALUE source;
    VALUE rseq;
    VALUE rseq_blob;
    VALUE names;
    VALUE named_captures;
    OnibiRSeqView rseq_view;
    unsigned char rseq_view_valid;
    /* Immutable compile-time decisions used by the C dispatcher. */
    OnibiExecutionKind execution_kind;
    int options;
    int source_encoding_index;
    unsigned char source_ascii_only;
    unsigned int ast_flags;
    unsigned int execution_flags;
    unsigned int feature_flags;
    double timeout_seconds;
} onibi_regexp_t;

static int
onibi_regexp_fixed_p(const onibi_regexp_t *obj)
{
    return (obj->options & ONIBI_OPT_FIXEDENCODING) ||
	   (obj->source_ascii_only &&
	    ONIBI_FEATURE_P(obj, ONIBI_FEATURE_NON_ASCII_LITERAL));
}

static int
onibi_character_boundary(VALUE str, long pos)
{
    const char *start = RSTRING_PTR(str);
    const char *current = start + pos;
    const char *end = start + RSTRING_LEN(str);
    if (pos <= 0 || pos >= RSTRING_LEN(str)) return 1;
    return rb_enc_left_char_head(start, current, end, rb_enc_get(str)) ==
	   current;
}

static int
onibi_vm_input_eligible(const onibi_regexp_t *obj, VALUE str)
{
    int encoding = rb_enc_get_index(str);
    int subject_ascii_only = rb_enc_str_asciionly_p(str);
    if (!rb_enc_asciicompat(rb_enc_from_index(obj->source_encoding_index)))
	return 0;
    /* The verified RSeq feature records folds that still require DAG paths. */
    if ((obj->rseq_view.header->features &
	 ONIBI_RSEQ_FEATURE_INCOMPLETE_CASEFOLD) != 0)
	return 0;
    if ((obj->rseq_view.header->features &
	 ONIBI_RSEQ_FEATURE_LITERAL_CASEFOLD) != 0 &&
	(!obj->source_ascii_only || !subject_ascii_only))
	return 0;
    /* Keep zero-width multibyte search on the existing API fallback path. */
    if (!subject_ascii_only && (obj->rseq_view.header->features &
				ONIBI_RSEQ_FEATURE_ZERO_WIDTH_ONLY) != 0)
	return 0;
    /* A fixed-encoding regexp cannot consume non-ASCII bytes tagged as
     * ASCII-8BIT.  Let MRI report Encoding::CompatibilityError instead of
     * entering the byte-oriented RSeq path. */
    if (onibi_regexp_fixed_p(obj) && encoding == rb_ascii8bit_encindex() &&
	!rb_enc_str_asciionly_p(str))
	return 0;
    if (rb_enc_compatible(str, obj->source) == NULL) return 0;
    return subject_ascii_only || onibi_valid_encoding(str);
}

static void
onibi_free(void *ptr)
{
    xfree(ptr);
}
static void
onibi_mark(void *ptr)
{
    onibi_regexp_t *obj = (onibi_regexp_t *)ptr;
    if (!obj) return;
    rb_gc_mark(obj->regexp);
    rb_gc_mark(obj->source);
    rb_gc_mark(obj->rseq);
    rb_gc_mark(obj->rseq_blob);
    rb_gc_mark(obj->names);
    rb_gc_mark(obj->named_captures);
}
static size_t
onibi_memsize(const void *ptr)
{
    const onibi_regexp_t *obj = (const onibi_regexp_t *)ptr;
    return obj ? sizeof(*obj) : 0;
}
static const rb_data_type_t onibi_type = {
    "Onibi::Regexp",
    {onibi_mark, onibi_free, onibi_memsize, NULL, {NULL}},
    0,
    0,
    RUBY_TYPED_FREE_IMMEDIATELY};

typedef enum {
    ONIBI_TOKEN_LITERAL = 0,
    ONIBI_TOKEN_LOOKAHEAD_START,
    ONIBI_TOKEN_LOOKBEHIND_START,
    ONIBI_TOKEN_OPTION_GLOBAL,
    ONIBI_TOKEN_OPTION_SCOPE_START,
    ONIBI_TOKEN_NONCAPTURE_START,
    ONIBI_TOKEN_ATOMIC_START,
    ONIBI_TOKEN_ABSENCE_START,
    ONIBI_TOKEN_CONDITIONAL_START,
    ONIBI_TOKEN_GROUP_START,
    ONIBI_TOKEN_POSIX_CLASS,
    ONIBI_TOKEN_BACKREF,
    ONIBI_TOKEN_SUBROUTINE,
    ONIBI_TOKEN_META_ESCAPE,
    ONIBI_TOKEN_ANCHOR,
    ONIBI_TOKEN_MATCH_RESET,
    ONIBI_TOKEN_ESCAPE,
    ONIBI_TOKEN_CLASS_START,
    ONIBI_TOKEN_CLASS_END,
    ONIBI_TOKEN_CLASS_RANGE,
    ONIBI_TOKEN_CLASS_NEGATE,
    ONIBI_TOKEN_ALTERNATION,
    ONIBI_TOKEN_GROUP_END,
    ONIBI_TOKEN_QUANTIFIER,
    ONIBI_TOKEN_WILDCARD
} OnibiTokenKind;

typedef enum {
    ONIBI_ASCII_PROP_UNKNOWN = -1,
    ONIBI_ASCII_PROP_ASCII = 0,
    ONIBI_ASCII_PROP_HEX,
    ONIBI_ASCII_PROP_DIGIT,
    ONIBI_ASCII_PROP_ALPHA,
    ONIBI_ASCII_PROP_ALNUM,
    ONIBI_ASCII_PROP_LOWER,
    ONIBI_ASCII_PROP_UPPER,
    ONIBI_ASCII_PROP_SPACE,
    ONIBI_ASCII_PROP_BLANK,
    ONIBI_ASCII_PROP_WORD,
    ONIBI_ASCII_PROP_XDIGIT,
    ONIBI_ASCII_PROP_CNTRL,
    ONIBI_ASCII_PROP_PRINT,
    ONIBI_ASCII_PROP_GRAPH,
    ONIBI_ASCII_PROP_PUNCT
} OnibiAsciiProperty;

static OnibiAsciiProperty onibi_ascii_property_kind_id(ID property);

typedef struct {
    size_t offset;
    size_t length;
    unsigned char present;
} OnibiTokenSlice;

typedef enum {
    ONIBI_AST_UNKNOWN = 0,
    ONIBI_AST_SEQUENCE,
    ONIBI_AST_ALTERNATIVE,
    ONIBI_AST_LITERAL,
    ONIBI_AST_ESCAPE,
    ONIBI_AST_ANY,
    ONIBI_AST_ANCHOR,
    ONIBI_AST_CHARACTER_CLASS,
    ONIBI_AST_CLASS_INTERSECTION,
    ONIBI_AST_QUANTIFIER,
    ONIBI_AST_CAPTURE,
    ONIBI_AST_GROUP,
    ONIBI_AST_ATOMIC,
    ONIBI_AST_ABSENCE,
    ONIBI_AST_CONDITIONAL,
    ONIBI_AST_LOOKAHEAD,
    ONIBI_AST_LOOKBEHIND,
    ONIBI_AST_OPTION_SCOPE,
    ONIBI_AST_OPTION_GLOBAL,
    ONIBI_AST_BACKREF,
    ONIBI_AST_SUBROUTINE,
    ONIBI_AST_MATCH_RESET
} OnibiAstKind;

typedef uint32_t OnibiAstId;
#define ONIBI_AST_NONE UINT32_MAX

enum {
    ONIBI_AST_NODE_NEGATED = 1U << 0,
    ONIBI_AST_NODE_NEGATIVE = 1U << 1,
    ONIBI_AST_NODE_POSITIVE = 1U << 2,
    ONIBI_AST_NODE_CAPTURING = 1U << 3,
    ONIBI_AST_NODE_GREEDY = 1U << 4,
    ONIBI_AST_NODE_POSSESSIVE = 1U << 5,
    ONIBI_AST_NODE_HAS_MAX = 1U << 6
};

typedef struct {
    OnibiTokenSlice first;
    OnibiTokenSlice last;
    unsigned char first_byte;
    unsigned char last_byte;
    unsigned char first_has_bytes;
    unsigned char last_has_bytes;
} OnibiAstRange;

typedef struct {
    OnibiAstKind kind;
    OnibiTokenKind token_kind;
    long start;
    long end;
    long byte;
    long capture;
    long min;
    long max;
    ID name_id;
    unsigned int flags;
    OnibiTokenSlice name;
    OnibiTokenSlice negative_options;
    OnibiTokenSlice bytes;
    OnibiAstId body;
    OnibiAstId atom;
    OnibiAstId yes;
    OnibiAstId no;
    OnibiAstId *children;
    size_t child_count;
    size_t child_capacity;
    OnibiAstRange *ranges;
    size_t range_count;
    size_t range_capacity;
} OnibiAstNode;

typedef struct {
    OnibiAstNode *nodes;
    size_t count;
    size_t capacity;
    unsigned char *bytes;
    size_t bytes_count;
    size_t bytes_capacity;
    OnibiAstId root;
} OnibiAstArena;

enum {
    ONIBI_SEMANTIC_RESOLVED = 1U << 0,
    ONIBI_SEMANTIC_NORMALIZED = 1U << 1,
    ONIBI_SEMANTIC_ANALYZED = 1U << 2,
    ONIBI_SEMANTIC_NULLABLE = 1U << 3,
    ONIBI_SEMANTIC_REPEAT_HAS_MAX = 1U << 4,
    ONIBI_SEMANTIC_REPEAT_GREEDY = 1U << 5,
    ONIBI_SEMANTIC_REPEAT_POSSESSIVE = 1U << 6,
    ONIBI_SEMANTIC_ANALYZING = 1U << 7
};

/* C-owned semantic data. Source positions are diagnostic data only. */
typedef struct {
    OnibiAstKind kind;
    OnibiAstId source_id;
    OnibiAstId reference_target;
    OnibiSubprogramId subprogram_id;
    uint32_t lexical_options;
    int encoding_index;
    int32_t capture_id;
    int32_t assertion_kind;
    long repeat_min;
    long repeat_max;
    long min_width;
    long max_width;
    long source_start;
    long source_end;
    uint32_t flags;
} OnibiResolvedNode;

typedef struct OnibiNameIndexEntry {
    OnibiTokenSlice name;
    OnibiAstId *definitions;
    size_t definition_count;
    size_t definition_capacity;
    OnibiSubprogramId subprogram_id;
    unsigned char used;
} OnibiNameIndexEntry;

typedef struct {
    OnibiResolvedNode *nodes;
    size_t count;
    uint32_t capture_count;
    uint32_t subprogram_count;
    uint32_t lowered_subprogram_count;
    /* Compiler-owned indexes.  The source arena owns all name bytes. */
    OnibiAstId *capture_by_number;
    size_t capture_by_number_count;
    OnibiNameIndexEntry *name_entries;
    size_t name_entry_count;
    size_t name_index_capacity;
} OnibiResolvedArena;

static void
onibi_resolved_indexes_free(OnibiResolvedArena *semantics)
{
    xfree(semantics->capture_by_number);
    semantics->capture_by_number = NULL;
    if (semantics->name_entries != NULL) {
	for (size_t i = 0; i < semantics->name_index_capacity; i++)
	    xfree(semantics->name_entries[i].definitions);
	xfree(semantics->name_entries);
    }
    semantics->name_entries = NULL;
    semantics->capture_by_number_count = 0;
    semantics->name_entry_count = 0;
    semantics->name_index_capacity = 0;
}

typedef enum {
    ONIBI_CLASS_MODE_NORMAL = 0,
    ONIBI_CLASS_MODE_INTERSECTION = 1
} OnibiClassMatchMode;

static inline OnibiAstKind
onibi_ast_kind(VALUE node)
{
    VALUE code = onibi_hash_value_id(node, id_key_type_code);
    return NIL_P(code) ? ONIBI_AST_UNKNOWN : (OnibiAstKind)NUM2UINT(code);
}
