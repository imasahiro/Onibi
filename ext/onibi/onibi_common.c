#include "onibi_ir.h"
#include "ruby.h"
#include "ruby/encoding.h"
#include "ruby/onigmo.h"
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
#define ONIBI_FEATURE_DYNAMIC (1U << 0)
#define ONIBI_FEATURE_TAGGED (1U << 1)
#define ONIBI_FEATURE_ATOMIC (1U << 2)
#define ONIBI_FEATURE_GRAPHEME (1U << 3)
#define ONIBI_FEATURE_WILDCARD (1U << 4)
#define ONIBI_FEATURE_ANCHOR (1U << 5)
#define ONIBI_FEATURE_META_ESCAPE (1U << 6)
#define ONIBI_FEATURE_UNICODE_ESCAPE (1U << 7)
#define ONIBI_FEATURE_CLASS_INTERSECTION (1U << 8)
#define ONIBI_FEATURE_NESTED_CLASS (1U << 9)
#define ONIBI_FEATURE_LARGE_REPEAT (1U << 10)
#define ONIBI_FEATURE_ABSENCE (1U << 11)
#define ONIBI_FEATURE_CONDITIONAL (1U << 12)
#define ONIBI_FEATURE_BACKREF (1U << 13)
#define ONIBI_FEATURE_SUBROUTINE (1U << 14)
#define ONIBI_FEATURE_ASCII_PROPERTY (1U << 15)
#define ONIBI_FEATURE_UNICODE_PROPERTY (1U << 16)
#define ONIBI_FEATURE_UNICODE_PROPERTY_CLASS (1U << 17)
#define ONIBI_FEATURE_PROPERTY_ESCAPE (1U << 18)
#define ONIBI_FEATURE_NON_ASCII_LITERAL (1U << 19)
#define ONIBI_FEATURE_NON_ASCII_CLASS (1U << 20)
#define ONIBI_FEATURE_INLINE_IGNORECASE (1U << 21)
#define ONIBI_FEATURE_P(obj, flag) (((obj)->feature_flags & (flag)) != 0)
#include <alloca.h>
#include <ctype.h>
#include <errno.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define ONIBI_RSEQ_REPEAT_UNROLL_LIMIT 4096L

static VALUE mOnibi, cRegexp, eRegexpError, eTimeoutError;
static VALUE onibi_empty_actions = Qnil;
static double onibi_default_timeout = 0.0;
static _Thread_local uint64_t onibi_deadline_ns = 0;
/* The call metadata is explicit VM state.  The graph walker still uses its
 * existing depth-first control flow, but subprogram recursion no longer
 * stores its semantic depth only in a C integer. */
#define ONIBI_CALL_STACK_LIMIT 256U
static _Thread_local OnibiCallFrame onibi_call_frames[ONIBI_CALL_STACK_LIMIT];
static _Thread_local unsigned int onibi_call_stack_size = 0;
static ID id_initialize, id_match, id_match_p, id_source, id_options,
    id_inspect, id_to_s, id_new;
static ID id_instance_method, id_bind, id_call;
static ID id_bytebegin, id_byteend, id_length;
static ID id_case_equal, id_last_match, id_tilde;
static VALUE onibi_rseq_execution_graph(VALUE rseq);
static ID id_scan, id_gsub, id_encoding, id_index;
static ID id_g_accept, id_g_grapheme, id_g_atomic, id_g_absent, id_g_call,
    id_g_char, id_g_class, id_g_any, id_g_backref;
static ID id_capture_open, id_capture_close, id_match_reset;
static ID id_a_test_capture, id_a_test_counter_lt, id_a_test_counter_ge;
static ID id_a_counter_init, id_a_counter_increment;
static ID id_a_assert_begin_buffer, id_a_assert_search_origin,
    id_a_assert_end_buffer;
static ID id_a_assert_begin_line, id_a_assert_end_line,
    id_a_assert_word_boundary;
static ID id_a_assert_nonword_boundary, id_a_assert_semi_end_buffer;
static ID id_a_assert_lookahead, id_a_assert_lookbehind;
static ID id_pred_byte, id_pred_bitmap, id_pred_any;
static ID id_a_end;
static ID id_insert;
static ID id_timeout, id_encode, id_message, id_names, id_named_captures;
static ID id_escape, id_union, id_to_regexp;
static ID id_opt_ignorecase, id_opt_multiline, id_opt_extended,
    id_opt_fixedencoding, id_opt_noencoding;
static ID id_prop_ascii, id_prop_ascii_hex;
static ID id_key_op, id_key_payload, id_key_actions, id_key_to,
    id_key_multiline, id_key_ignorecase;
static ID id_key_byte, id_key_capture, id_key_subprogram, id_key_entry,
    id_key_entry_actions;
static ID id_key_kind, id_key_kind_code, id_key_opcode, id_key_action_code,
    id_key_assert_kind, id_key_predicate_code;
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
static ID id_key_states, id_key_outgoing, id_key_start_edges,
    id_key_subprograms;
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
static VALUE onibi_vm_match_p(VALUE self, VALUE str);
static void onibi_rseq_validate(VALUE rseq);
static inline VALUE
onibi_hash_value_id(VALUE hash, ID key)
{
    return rb_hash_aref(hash, ID2SYM(key));
}
static OnibiGActionOp onibi_gir_action_opcode(ID op);
static void onibi_set_gir_action_opcode(VALUE action, ID op);
static OnibiRAssertKind onibi_rseq_assert_kind(ID op);
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
onibi_ascii_pattern(VALUE source)
{
    return rb_enc_str_asciionly_p(source);
}

static int
onibi_valid_encoding(VALUE str)
{
    return rb_enc_str_coderange(str) != RUBY_ENC_CODERANGE_BROKEN;
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
    if (onibi_deadline_ns != 0 && onibi_now_ns() >= onibi_deadline_ns)
	rb_raise(eTimeoutError, "regexp match timeout");
}

static void onibi_vm_stack_overflow(void) __attribute__((noreturn));
static void
onibi_vm_stack_overflow(void)
{
    if (onibi_deadline_ns != 0) rb_raise(eTimeoutError, "regexp match timeout");
    rb_raise(eRegexpError, "GIR graph is too deep");
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
    VALUE names;
    VALUE named_captures;
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
    return (obj->options & 16) ||
	   (obj->source_ascii_only &&
	    ONIBI_FEATURE_P(obj, ONIBI_FEATURE_NON_ASCII_LITERAL));
}

/* Some Unicode/POSIX property rules are not representable by the compact
 * ctype payload yet.  The MRI regexp is compiled once during initialize, so
 * this compatibility path does not rescan source text during a match. */
static int
onibi_mri_compat_path_p(const onibi_regexp_t *obj)
{
    return (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_CLASS_INTERSECTION) &&
	    (obj->options & 1)) ||
	   ONIBI_FEATURE_P(obj, ONIBI_FEATURE_ASCII_PROPERTY) ||
	   (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_NON_ASCII_LITERAL) &&
	    ((obj->options & 1) ||
	     ONIBI_FEATURE_P(obj, ONIBI_FEATURE_INLINE_IGNORECASE))) ||
	   (obj->ast_flags & ONIBI_AST_FLAG_ANCHOR_REPEAT) != 0 ||
	   (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_ABSENCE) &&
	    (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_CONDITIONAL) ||
	     (obj->ast_flags & ONIBI_AST_FLAG_NULLABLE_ABSENCE) != 0));
}

static void
onibi_call_stack_reset(void)
{
    onibi_call_stack_size = 0;
}

static OnibiCallFrame *
onibi_call_frame_push(OnibiSubprogramId subprogram_id)
{
    if (onibi_call_stack_size >= ONIBI_CALL_STACK_LIMIT)
	rb_raise(eRegexpError, "subroutine call depth exceeded");
    unsigned int index = onibi_call_stack_size++;
    OnibiCallFrame *frame = &onibi_call_frames[index];
    frame->subprogram_id = subprogram_id;
    frame->continuation = ONIBI_ACCEPT_STATE;
    frame->tag_history = 0;
    frame->recursion_depth = index;
    frame->parent = index == 0 ? ONIBI_CALL_STACK_LIMIT : index - 1;
    return frame;
}

static void
onibi_call_frame_pop(void)
{
    if (onibi_call_stack_size > 0) onibi_call_stack_size--;
}
static int
onibi_encoded_literal_program_p(const onibi_regexp_t *obj)
{
    return (obj->options & 16) && !(obj->options & (1 | 32)) &&
	   obj->source_encoding_index != rb_ascii8bit_encindex() &&
	   !obj->source_ascii_only &&
	   ONIBI_FEATURE_P(obj, ONIBI_FEATURE_NON_ASCII_LITERAL) &&
	   !(obj->feature_flags & ONIBI_FEATURE_WILDCARD) &&
	   !(obj->feature_flags & ONIBI_FEATURE_ANCHOR) &&
	   (!ONIBI_FEATURE_P(obj, ONIBI_FEATURE_NON_ASCII_CLASS) ||
	    (obj->ast_flags & ONIBI_AST_FLAG_SAFE_MULTIBYTE_CLASS) != 0);
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
    /* A fixed-encoding regexp cannot consume non-ASCII bytes tagged as
     * ASCII-8BIT.  Let MRI report Encoding::CompatibilityError instead of
     * entering the byte-oriented RSeq path. */
    if (onibi_regexp_fixed_p(obj) && encoding == rb_ascii8bit_encindex() &&
	!rb_enc_str_asciionly_p(str))
	return 0;
    if (rb_enc_compatible(str, obj->source) == NULL) return 0;
    if (rb_enc_str_asciionly_p(str) || encoding == rb_ascii8bit_encindex())
	return 1;
    if (onibi_encoded_literal_program_p(obj) &&
	encoding == obj->source_encoding_index)
	return onibi_valid_encoding(str);
    if (ONIBI_FEATURE_P(obj, ONIBI_FEATURE_UNICODE_PROPERTY) &&
	(!ONIBI_FEATURE_P(obj, ONIBI_FEATURE_UNICODE_PROPERTY_CLASS) ||
	 (!ONIBI_FEATURE_P(obj, ONIBI_FEATURE_NESTED_CLASS) &&
	  !ONIBI_FEATURE_P(obj, ONIBI_FEATURE_CLASS_INTERSECTION))) &&
	encoding == rb_utf8_encindex())
	return onibi_valid_encoding(str);
    return 0;
}

static int
onibi_utf8_decode(VALUE bytes, uint32_t *codepoint)
{
    const unsigned char *p = (const unsigned char *)RSTRING_PTR(bytes);
    long length = RSTRING_LEN(bytes);
    if (length == 1 && p[0] < 0x80) {
	*codepoint = p[0];
	return 1;
    }
    if (length == 2 && (p[0] & 0xe0) == 0xc0 && (p[1] & 0xc0) == 0x80) {
	*codepoint = ((uint32_t)(p[0] & 0x1f) << 6) | (p[1] & 0x3f);
	return *codepoint >= 0x80;
    }
    if (length == 3 && (p[0] & 0xf0) == 0xe0 && (p[1] & 0xc0) == 0x80 &&
	(p[2] & 0xc0) == 0x80) {
	*codepoint = ((uint32_t)(p[0] & 0x0f) << 12) |
		     ((uint32_t)(p[1] & 0x3f) << 6) | (p[2] & 0x3f);
	return *codepoint >= 0x800;
    }
    if (length == 4 && (p[0] & 0xf8) == 0xf0 && (p[1] & 0xc0) == 0x80 &&
	(p[2] & 0xc0) == 0x80 && (p[3] & 0xc0) == 0x80) {
	*codepoint = ((uint32_t)(p[0] & 0x07) << 18) |
		     ((uint32_t)(p[1] & 0x3f) << 12) |
		     ((uint32_t)(p[2] & 0x3f) << 6) | (p[3] & 0x3f);
	return *codepoint >= 0x10000 && *codepoint <= 0x10ffff;
    }
    return 0;
}

static VALUE
onibi_utf8_encode(uint32_t codepoint)
{
    char out[4];
    long length = 0;
    if (codepoint <= 0x7f)
	out[length++] = (char)codepoint;
    else if (codepoint <= 0x7ff) {
	out[length++] = (char)(0xc0 | (codepoint >> 6));
	out[length++] = (char)(0x80 | (codepoint & 0x3f));
    }
    else if (codepoint <= 0xffff &&
	     !(codepoint >= 0xd800 && codepoint <= 0xdfff)) {
	out[length++] = (char)(0xe0 | (codepoint >> 12));
	out[length++] = (char)(0x80 | ((codepoint >> 6) & 0x3f));
	out[length++] = (char)(0x80 | (codepoint & 0x3f));
    }
    else if (codepoint <= 0x10ffff) {
	out[length++] = (char)(0xf0 | (codepoint >> 18));
	out[length++] = (char)(0x80 | ((codepoint >> 12) & 0x3f));
	out[length++] = (char)(0x80 | ((codepoint >> 6) & 0x3f));
	out[length++] = (char)(0x80 | (codepoint & 0x3f));
    }
    return rb_str_new(out, length);
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
