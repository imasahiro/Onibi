#include "ruby.h"
#include "ruby/encoding.h"
#include "ruby/thread.h"
#include "ruby/onigmo.h"
#include "onibi_ir.h"

#define ONIBI_SUBPROGRAM_ATOMIC UINT32_C(1)
#define ONIBI_SUBPROGRAM_ABSENT UINT32_C(2)
#include <string.h>
#include <stdio.h>
#include <ctype.h>
#include <time.h>
#include <math.h>
#include <float.h>
#include <errno.h>
#include <alloca.h>

#define ONIBI_RSEQ_REPEAT_UNROLL_LIMIT 4096L

static VALUE mOnibi, cRegexp, eRegexpError, eTimeoutError;
static double onibi_default_timeout = 0.0;
static _Thread_local uint64_t onibi_deadline_ns = 0;
/* The call metadata is explicit VM state.  The graph walker still uses its
 * existing depth-first control flow, but subprogram recursion no longer
 * stores its semantic depth only in a C integer. */
#define ONIBI_CALL_STACK_LIMIT 256U
static _Thread_local OnibiCallFrame onibi_call_frames[ONIBI_CALL_STACK_LIMIT];
static _Thread_local unsigned int onibi_call_stack_size = 0;
static ID id_initialize, id_match, id_match_p, id_source, id_options, id_inspect, id_to_s, id_new;
static ID id_instance_method, id_bind, id_call;
static ID id_bytebegin, id_byteend, id_length;
static ID id_case_equal, id_last_match, id_tilde;
static VALUE onibi_rseq_physical_graph(VALUE rseq);
static ID id_scan, id_gsub, id_encoding, id_index;
static ID id_g_accept, id_g_grapheme, id_g_atomic, id_g_absent, id_g_call, id_g_char, id_g_class, id_g_any, id_g_backref;
static ID id_capture_open, id_capture_close, id_match_reset;
static ID id_a_test_capture, id_a_test_counter_lt, id_a_test_counter_ge;
static ID id_a_counter_init, id_a_counter_increment;
static ID id_a_assert_begin_buffer, id_a_assert_search_origin, id_a_assert_end_buffer;
static ID id_a_assert_begin_line, id_a_assert_end_line, id_a_assert_word_boundary;
static ID id_a_assert_nonword_boundary, id_a_assert_semi_end_buffer;
static ID id_a_assert_lookahead, id_a_assert_lookbehind;
static ID id_pred_byte, id_pred_bitmap, id_pred_any;
static ID id_a_end, id_key_physical_graph;
static ID id_insert;
static ID id_timeout, id_encode, id_message, id_names, id_named_captures;
static ID id_escape, id_union, id_to_regexp;
static ID id_opt_ignorecase, id_opt_multiline, id_opt_extended, id_opt_fixedencoding, id_opt_noencoding;
static ID id_prop_ascii, id_prop_ascii_hex;
static ID id_key_op, id_key_payload, id_key_actions, id_key_to, id_key_multiline, id_key_ignorecase;
static ID id_key_byte, id_key_capture, id_key_subprogram, id_key_entry, id_key_entry_actions;
static ID id_key_kind, id_key_kind_code, id_key_opcode, id_key_action_code, id_key_assert_kind, id_key_predicate_code;
static ID id_key_start, id_key_end, id_key_captures;
static ID id_key_slot, id_key_set, id_key_value;
static ID id_key_type_code, id_key_name, id_key_name_id, id_key_ctype, id_key_ranges, id_key_children;
static ID id_key_operands, id_key_negated, id_key_bitmap, id_key_preserve_if_set;
static ID id_key_limit, id_key_positive, id_key_predicates;
static ID id_key_body, id_key_options, id_key_negative_options, id_key_capturing;
static ID id_key_condition, id_key_branches, id_key_yes, id_key_no, id_key_atom;
static ID id_key_min, id_key_max, id_key_greedy, id_key_possessive;
static ID id_key_width;
static ID id_key_states, id_key_outgoing, id_key_start_edges, id_key_subprograms;
static ID id_key_bytes, id_key_blob, id_key_header, id_key_edges;
static ID id_key_from, id_key_accept, id_key_action_offset;
static ID id_key_flags;
static ID id_key_id;
static ID id_key_capture_count;
static ID id_key_counter_count;
static ID id_key_state_count, id_key_features, id_key_edge_count, id_key_action_count;
static ID id_key_class_count, id_key_subprogram_count, id_key_start_edge_base, id_key_start_edge_count;
static ID id_key_blob_size, id_key_literal_count;
static ID id_key_version, id_key_semantic_capture_count;
static ID id_key_states_offset, id_key_edges_offset, id_key_actions_offset;
static ID id_key_classes_offset, id_key_literals_offset, id_key_descriptors_offset, id_key_subprograms_offset;
static ID id_key_negative_name, id_key_negative;
static ID id_anchor, id_anchor_start, id_anchor_end;
static ID id_kind_literal;
static ID id_recursive_marker;
static VALUE onibi_vm_match_p(VALUE self, VALUE str);
static void onibi_rseq_validate(VALUE rseq);
static inline VALUE onibi_hash_value_id(VALUE hash, ID key) { return rb_hash_aref(hash, ID2SYM(key)); }
static OnibiGActionOp onibi_gir_action_opcode(ID op);
static void onibi_set_gir_action_opcode(VALUE action, ID op);
static OnibiRAssertKind onibi_rseq_assert_kind(ID op);
static int onibi_option_mask(VALUE options);
static int onibi_ascii_property_name_p(VALUE name);
static int onibi_valid_encoding(VALUE str);
static int onibi_unicode_ctype_id(ID property);
typedef enum {
  ONIBI_POSIX_UNKNOWN = 0,
  ONIBI_POSIX_ALPHA, ONIBI_POSIX_DIGIT, ONIBI_POSIX_ALNUM,
  ONIBI_POSIX_SPACE, ONIBI_POSIX_BLANK, ONIBI_POSIX_LOWER,
  ONIBI_POSIX_UPPER, ONIBI_POSIX_WORD, ONIBI_POSIX_XDIGIT
} OnibiPosixKind;
static OnibiPosixKind onibi_posix_kind_id(ID property);

static int onibi_ascii_pattern(VALUE source) {
  return rb_enc_str_asciionly_p(source);
}

static int onibi_valid_encoding(VALUE str) {
  return rb_enc_str_coderange(str) != RUBY_ENC_CODERANGE_BROKEN;
}

static int onibi_hex_digit(unsigned char c) {
  return c >= '0' && c <= '9' ? c - '0' : (c >= 'a' && c <= 'f' ? c - 'a' + 10 : (c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1));
}

static long onibi_parse_count(const char *text, char **end) {
  errno = 0;
  long value = strtol(text, end, 10);
  if (errno == ERANGE) rb_raise(eRegexpError, "quantifier is too large");
  return value;
}

static uint64_t onibi_now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

static void onibi_check_deadline(void) {
  if (onibi_deadline_ns != 0 && onibi_now_ns() >= onibi_deadline_ns)
    rb_raise(eTimeoutError, "regexp match timeout");
}

static void onibi_vm_stack_overflow(void) __attribute__((noreturn));
static void onibi_vm_stack_overflow(void) {
  if (onibi_deadline_ns != 0)
    rb_raise(eTimeoutError, "regexp match timeout");
  rb_raise(eRegexpError, "GIR graph is too deep");
}

static void onibi_set_deadline(double seconds) {
  if (seconds <= 0.0 || seconds >= (double)UINT64_MAX / 1e9) {
    onibi_deadline_ns = 0;
    return;
  }
  uint64_t now = onibi_now_ns();
  uint64_t delta = (uint64_t)(seconds * 1e9);
  onibi_deadline_ns = UINT64_MAX - now < delta ? 0 : now + delta;
}

static double onibi_timeout_value(VALUE value) {
  if (NIL_P(value)) return 0.0;
  if (RB_TYPE_P(value, T_STRING)) rb_raise(rb_eTypeError, "no implicit conversion to float from string");
  if (value == Qtrue || value == Qfalse) rb_raise(rb_eTypeError, "no implicit conversion to float from %s", value == Qtrue ? "true" : "false");
  double seconds = NUM2DBL(rb_to_float(value));
  if (isnan(seconds)) return 0.0;
  if (seconds <= 0.0) rb_raise(rb_eArgError, "invalid timeout: %g", seconds);
  return isinf(seconds) ? (double)UINT64_MAX / 1e9 : seconds;
}

typedef struct { VALUE regexp; VALUE source; OnibiExecutionKind execution_kind; VALUE rseq; VALUE names; VALUE named_captures; int options; double timeout_seconds; struct OnibiFeatureToken *feature_tokens; size_t feature_token_count; int has_class_intersection; int has_nested_class; int has_large_repeat; int has_absence; int has_conditional; int has_atomic; int has_backref; int has_ascii_property; int has_unicode_property; int has_unicode_property_in_class; int has_nullable_capture; int has_grapheme; int has_property_escape; int has_unicode_escape; int has_non_ascii_literal; int has_non_ascii_class; int has_safe_multibyte_class; int has_wildcard; int has_anchor; int has_meta_escape; int has_subroutine; int has_dynamic; int has_tagged; int has_inline_ignorecase; int has_anchor_repeat; int has_nullable_absence; } onibi_regexp_t;

static int onibi_regexp_fixed_p(const onibi_regexp_t *obj) {
  return (obj->options & 16) ||
    (rb_enc_str_asciionly_p(obj->source) && obj->has_non_ascii_literal);
}

/* Some Unicode/POSIX property rules are not representable by the compact
 * ctype payload yet.  The MRI regexp is compiled once during initialize, so
 * this compatibility path does not rescan source text during a match. */
static int onibi_mri_compat_path_p(const onibi_regexp_t *obj) {
  return (obj->has_class_intersection && (obj->options & 1)) ||
    obj->has_ascii_property ||
    (obj->has_non_ascii_literal &&
     ((obj->options & 1) || obj->has_inline_ignorecase)) ||
    obj->has_anchor_repeat ||
    (obj->has_absence && (obj->has_conditional || obj->has_nullable_absence));
}

static void onibi_call_stack_reset(void) {
  onibi_call_stack_size = 0;
}

static OnibiCallFrame *onibi_call_frame_push(OnibiSubprogramId subprogram_id) {
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

static void onibi_call_frame_pop(void) {
  if (onibi_call_stack_size > 0) onibi_call_stack_size--;
}
static int onibi_encoded_literal_program_p(const onibi_regexp_t *obj) {
  return (obj->options & 16) && !(obj->options & (1 | 32)) &&
    rb_enc_get_index(obj->source) != rb_ascii8bit_encindex() &&
    !rb_enc_str_asciionly_p(obj->source) &&
    obj->has_non_ascii_literal && !obj->has_wildcard && !obj->has_anchor &&
    (!obj->has_non_ascii_class || obj->has_safe_multibyte_class);
}

static int onibi_character_boundary(VALUE str, long pos) {
  const char *start = RSTRING_PTR(str);
  const char *current = start + pos;
  const char *end = start + RSTRING_LEN(str);
  if (pos <= 0 || pos >= RSTRING_LEN(str)) return 1;
  return rb_enc_left_char_head(start, current, end, rb_enc_get(str)) == current;
}

static int onibi_vm_input_eligible(const onibi_regexp_t *obj, VALUE str) {
  int encoding = rb_enc_get_index(str);
  /* A fixed-encoding regexp cannot consume non-ASCII bytes tagged as
   * ASCII-8BIT.  Let MRI report Encoding::CompatibilityError instead of
   * entering the byte-oriented RSeq path. */
  if (onibi_regexp_fixed_p(obj) && encoding == rb_ascii8bit_encindex() &&
      !rb_enc_str_asciionly_p(str)) return 0;
  if (rb_enc_compatible(str, obj->source) == NULL) return 0;
  if (rb_enc_str_asciionly_p(str) || encoding == rb_ascii8bit_encindex()) return 1;
  if (onibi_encoded_literal_program_p(obj) &&
      encoding == rb_enc_get_index(obj->source))
    return onibi_valid_encoding(str);
  if (obj->has_unicode_property &&
      (!obj->has_unicode_property_in_class ||
       (!obj->has_nested_class && !obj->has_class_intersection)) &&
      encoding == rb_utf8_encindex())
    return onibi_valid_encoding(str);
  return 0;
}

static int onibi_utf8_decode(VALUE bytes, uint32_t *codepoint) {
  const unsigned char *p = (const unsigned char *)RSTRING_PTR(bytes);
  long length = RSTRING_LEN(bytes);
  if (length == 1 && p[0] < 0x80) { *codepoint = p[0]; return 1; }
  if (length == 2 && (p[0] & 0xe0) == 0xc0 && (p[1] & 0xc0) == 0x80) {
    *codepoint = ((uint32_t)(p[0] & 0x1f) << 6) | (p[1] & 0x3f); return *codepoint >= 0x80;
  }
  if (length == 3 && (p[0] & 0xf0) == 0xe0 && (p[1] & 0xc0) == 0x80 && (p[2] & 0xc0) == 0x80) {
    *codepoint = ((uint32_t)(p[0] & 0x0f) << 12) | ((uint32_t)(p[1] & 0x3f) << 6) | (p[2] & 0x3f);
    return *codepoint >= 0x800;
  }
  if (length == 4 && (p[0] & 0xf8) == 0xf0 && (p[1] & 0xc0) == 0x80 &&
      (p[2] & 0xc0) == 0x80 && (p[3] & 0xc0) == 0x80) {
    *codepoint = ((uint32_t)(p[0] & 0x07) << 18) | ((uint32_t)(p[1] & 0x3f) << 12) |
      ((uint32_t)(p[2] & 0x3f) << 6) | (p[3] & 0x3f);
    return *codepoint >= 0x10000 && *codepoint <= 0x10ffff;
  }
  return 0;
}

static VALUE onibi_utf8_encode(uint32_t codepoint) {
  char out[4]; long length = 0;
  if (codepoint <= 0x7f) out[length++] = (char)codepoint;
  else if (codepoint <= 0x7ff) {
    out[length++] = (char)(0xc0 | (codepoint >> 6)); out[length++] = (char)(0x80 | (codepoint & 0x3f));
  } else if (codepoint <= 0xffff && !(codepoint >= 0xd800 && codepoint <= 0xdfff)) {
    out[length++] = (char)(0xe0 | (codepoint >> 12)); out[length++] = (char)(0x80 | ((codepoint >> 6) & 0x3f)); out[length++] = (char)(0x80 | (codepoint & 0x3f));
  } else if (codepoint <= 0x10ffff) {
    out[length++] = (char)(0xf0 | (codepoint >> 18)); out[length++] = (char)(0x80 | ((codepoint >> 12) & 0x3f)); out[length++] = (char)(0x80 | ((codepoint >> 6) & 0x3f)); out[length++] = (char)(0x80 | (codepoint & 0x3f));
  }
  return rb_str_new(out, length);
}

static void onibi_free(void *ptr) {
  onibi_regexp_t *obj = (onibi_regexp_t *)ptr;
  if (obj) xfree(obj->feature_tokens);
  xfree(ptr);
}
static void onibi_mark(void *ptr) {
  onibi_regexp_t *obj = (onibi_regexp_t *)ptr;
  if (!obj) return;
  rb_gc_mark(obj->regexp);
  rb_gc_mark(obj->source);
  rb_gc_mark(obj->rseq);
  rb_gc_mark(obj->names);
  rb_gc_mark(obj->named_captures);
}
static size_t onibi_feature_token_bytes(size_t count);
static size_t onibi_memsize(const void *ptr) {
  const onibi_regexp_t *obj = (const onibi_regexp_t *)ptr;
  return obj ? sizeof(*obj) + onibi_feature_token_bytes(obj->feature_token_count) : 0;
}
static const rb_data_type_t onibi_type = {
  "Onibi::Regexp", { onibi_mark, onibi_free, onibi_memsize, NULL, { NULL } }, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY
};

typedef enum {
  ONIBI_TOKEN_LITERAL = 0, ONIBI_TOKEN_LOOKAHEAD_START, ONIBI_TOKEN_LOOKBEHIND_START,
  ONIBI_TOKEN_OPTION_GLOBAL, ONIBI_TOKEN_OPTION_SCOPE_START, ONIBI_TOKEN_NONCAPTURE_START,
  ONIBI_TOKEN_ATOMIC_START, ONIBI_TOKEN_ABSENCE_START, ONIBI_TOKEN_CONDITIONAL_START,
  ONIBI_TOKEN_GROUP_START, ONIBI_TOKEN_POSIX_CLASS, ONIBI_TOKEN_BACKREF,
  ONIBI_TOKEN_SUBROUTINE, ONIBI_TOKEN_META_ESCAPE, ONIBI_TOKEN_ANCHOR,
  ONIBI_TOKEN_MATCH_RESET, ONIBI_TOKEN_ESCAPE, ONIBI_TOKEN_CLASS_START,
  ONIBI_TOKEN_CLASS_END, ONIBI_TOKEN_CLASS_RANGE, ONIBI_TOKEN_CLASS_NEGATE,
  ONIBI_TOKEN_ALTERNATION, ONIBI_TOKEN_GROUP_END, ONIBI_TOKEN_QUANTIFIER,
  ONIBI_TOKEN_WILDCARD
} OnibiTokenKind;

static inline OnibiTokenKind onibi_token_kind_code(VALUE token);
static long onibi_token_byte(VALUE token);

typedef enum {
  ONIBI_ASCII_PROP_UNKNOWN = -1, ONIBI_ASCII_PROP_ASCII = 0,
  ONIBI_ASCII_PROP_HEX, ONIBI_ASCII_PROP_DIGIT, ONIBI_ASCII_PROP_ALPHA,
  ONIBI_ASCII_PROP_ALNUM, ONIBI_ASCII_PROP_LOWER, ONIBI_ASCII_PROP_UPPER,
  ONIBI_ASCII_PROP_SPACE, ONIBI_ASCII_PROP_BLANK, ONIBI_ASCII_PROP_WORD,
  ONIBI_ASCII_PROP_XDIGIT, ONIBI_ASCII_PROP_CNTRL, ONIBI_ASCII_PROP_PRINT,
  ONIBI_ASCII_PROP_GRAPH, ONIBI_ASCII_PROP_PUNCT
} OnibiAsciiProperty;

static OnibiAsciiProperty onibi_ascii_property_kind_id(ID property);

typedef struct OnibiFeatureToken {
  OnibiTokenKind kind;
  long byte;
  ID name_id;
  OnibiAsciiProperty property_kind;
  unsigned char inline_ignorecase;
} OnibiFeatureToken;

static size_t onibi_feature_token_bytes(size_t count) {
  return count > SIZE_MAX / sizeof(OnibiFeatureToken) ? 0 : count * sizeof(OnibiFeatureToken);
}

typedef struct {
  OnibiFeatureToken *items;
  size_t count;
} OnibiFeatureTokenVector;

static OnibiFeatureTokenVector onibi_feature_tokens(VALUE tokens) {
  OnibiFeatureTokenVector vector = { NULL, (size_t)RARRAY_LEN(tokens) };
  if (vector.count > 0) {
    if (vector.count > SIZE_MAX / sizeof(*vector.items))
      rb_raise(rb_eNoMemError, "token feature vector is too large");
    vector.items = ALLOC_N(OnibiFeatureToken, vector.count);
    for (size_t i = 0; i < vector.count; i++) {
      VALUE token = rb_ary_entry(tokens, (long)i);
      vector.items[i].kind = onibi_token_kind_code(token);
      vector.items[i].byte = onibi_token_byte(token);
      VALUE name = onibi_hash_value_id(token, id_key_name);
      VALUE name_id = onibi_hash_value_id(token, id_key_name_id);
      vector.items[i].name_id = NIL_P(name_id) ? 0 : NUM2ULONG(name_id);
      vector.items[i].property_kind = vector.items[i].name_id == 0 ? ONIBI_ASCII_PROP_UNKNOWN :
        onibi_ascii_property_kind_id(vector.items[i].name_id);
      vector.items[i].inline_ignorecase = (!NIL_P(name) &&
        memchr(RSTRING_PTR(name), 'i', (size_t)RSTRING_LEN(name)) != NULL) ? 1 : 0;
    }
  }
  return vector;
}

typedef enum {
  ONIBI_AST_UNKNOWN = 0,
  ONIBI_AST_SEQUENCE, ONIBI_AST_ALTERNATIVE, ONIBI_AST_LITERAL,
  ONIBI_AST_ESCAPE, ONIBI_AST_ANY, ONIBI_AST_ANCHOR, ONIBI_AST_CHARACTER_CLASS,
  ONIBI_AST_CLASS_INTERSECTION, ONIBI_AST_QUANTIFIER, ONIBI_AST_CAPTURE,
  ONIBI_AST_GROUP, ONIBI_AST_ATOMIC, ONIBI_AST_ABSENCE, ONIBI_AST_CONDITIONAL,
  ONIBI_AST_LOOKAHEAD, ONIBI_AST_LOOKBEHIND, ONIBI_AST_OPTION_SCOPE,
  ONIBI_AST_OPTION_GLOBAL, ONIBI_AST_BACKREF, ONIBI_AST_SUBROUTINE,
  ONIBI_AST_MATCH_RESET
} OnibiAstKind;

static inline OnibiAstKind onibi_ast_kind(VALUE node) {
  VALUE code = onibi_hash_value_id(node, id_key_type_code);
  return NIL_P(code) ? ONIBI_AST_UNKNOWN : (OnibiAstKind)NUM2UINT(code);
}

/* These sets are lexer grammar, not user data.  Keep them as direct
 * predicates so tokenization does not call a string-search routine for each
 * source byte. */
static int onibi_option_char_p(unsigned char c) {
  return c == 'i' || c == 'm' || c == 'x';
}

static int onibi_anchor_escape_p(unsigned char c) {
  switch (c) {
    case 'A': case 'z': case 'Z': case 'G': case 'b': case 'B': return 1;
    default: return 0;
  }
}

static int onibi_class_escape_p(unsigned char c) {
  switch (c) {
    case 'd': case 'D': case 's': case 'S': case 'w': case 'W':
    case 'h': case 'H': case 'R': case 'X': case 'p': case 'P':
    case 'u': return 1;
    default: return 0;
  }
}

static int onibi_simple_escape_p(unsigned char c) {
  return c == 'd' || c == 'D' || c == 's' || c == 'S' ||
         c == 'w' || c == 'W' || c == 'h' || c == 'H';
}

static int onibi_quantifier_byte_p(unsigned char c) {
  return c == '*' || c == '+' || c == '?' || c == '{' || c == '}';
}

static VALUE onibi_tokenize_internal(VALUE src, int extended) {
  VALUE tokens = rb_ary_new();
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
    VALUE token = rb_hash_new();
    OnibiTokenKind kind = ONIBI_TOKEN_LITERAL;
    unsigned char byte = (unsigned char)RSTRING_PTR(src)[i];
    if (extended && !in_class && byte == '#') {
      while (i + 1 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] != '\n') i++;
      continue;
    }
    if (extended && !in_class && (byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n')) continue;
    VALUE backref_name = Qnil;
    VALUE backref_number = Qnil;
    VALUE group_name = Qnil;
    VALUE posix_name = Qnil;
    VALUE literal_bytes = Qnil;
    VALUE option_negative_name = Qnil;
    VALUE escape_name = Qnil;
    int option_negative = 0;
    int option_scope_x = -1;
    if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' &&
        (RSTRING_PTR(src)[i + 2] == '=' || RSTRING_PTR(src)[i + 2] == '!')) {
      kind = ONIBI_TOKEN_LOOKAHEAD_START;
      byte = (unsigned char)RSTRING_PTR(src)[i + 2];
      i += 2;
    } else if (!in_class && byte == '(' && i + 3 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' &&
               RSTRING_PTR(src)[i + 2] == '<' && (RSTRING_PTR(src)[i + 3] == '=' || RSTRING_PTR(src)[i + 3] == '!')) {
      kind = ONIBI_TOKEN_LOOKBEHIND_START;
      byte = (unsigned char)RSTRING_PTR(src)[i + 3];
      i += 3;
    } else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) &&
               RSTRING_PTR(src)[i + 1] == '?' &&
               (RSTRING_PTR(src)[i + 2] == '-' ||
               onibi_option_char_p((unsigned char)RSTRING_PTR(src)[i + 2]))) {
      long option_end = i + 2;
      int valid = 1;
      if (RSTRING_PTR(src)[option_end] == '-') { option_negative = 1; option_end++; }
      long option_count = option_end;
      while (option_end < RSTRING_LEN(src) &&
             onibi_option_char_p((unsigned char)RSTRING_PTR(src)[option_end])) option_end++;
      long positive_end = option_end;
      long negative_start = -1;
      if (!option_negative && option_end < RSTRING_LEN(src) && RSTRING_PTR(src)[option_end] == '-') {
        negative_start = ++option_end;
        while (option_end < RSTRING_LEN(src) &&
               onibi_option_char_p((unsigned char)RSTRING_PTR(src)[option_end])) option_end++;
        if (option_end == negative_start) valid = 0;
      }
      int global_modifier = 0;
      if (option_end == option_count || option_end >= RSTRING_LEN(src)) valid = 0;
      else if (RSTRING_PTR(src)[option_end] == ')') global_modifier = 1;
      else if (RSTRING_PTR(src)[option_end] != ':') valid = 0;
      if (valid) {
        kind = global_modifier ? ONIBI_TOKEN_OPTION_GLOBAL : ONIBI_TOKEN_OPTION_SCOPE_START;
        byte = global_modifier ? ')' : ':';
        i = option_end;
        long name_end = negative_start >= 0 ? positive_end : option_end;
        group_name = rb_str_substr(src, option_count, name_end - option_count);
        if (option_negative) option_scope_x = 0;
        else option_scope_x = memchr(RSTRING_PTR(src) + option_count, 'x',
                                     (size_t)(negative_start >= 0 ? negative_start - option_count : option_end - option_count)) != NULL;
        if (negative_start >= 0) {
          option_negative_name = rb_str_substr(src, negative_start, option_end - negative_start);
        }
      }
    } else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' &&
               RSTRING_PTR(src)[i + 2] == ':') {
      kind = ONIBI_TOKEN_NONCAPTURE_START;
      byte = ':';
      i += 2;
    } else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' &&
               RSTRING_PTR(src)[i + 2] == '>') {
      kind = ONIBI_TOKEN_ATOMIC_START;
      byte = '>';
      i += 2;
    } else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' &&
               RSTRING_PTR(src)[i + 2] == '~') {
      kind = ONIBI_TOKEN_ABSENCE_START;
      byte = '~';
      i += 2;
    } else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' &&
               RSTRING_PTR(src)[i + 2] == '(') {
      long close = i + 3;
      while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != ')') close++;
      if (close < RSTRING_LEN(src)) {
        kind = ONIBI_TOKEN_CONDITIONAL_START;
        byte = '(';
        group_name = rb_str_substr(src, i + 3, close - (i + 3));
        i = close;
      }
    } else if (!in_class && byte == '(' && i + 3 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' && RSTRING_PTR(src)[i + 2] == '<') {
      long close = i + 3;
      while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != '>') close++;
      if (close < RSTRING_LEN(src)) {
        kind = ONIBI_TOKEN_GROUP_START;
        group_name = rb_str_substr(src, i + 3, close - (i + 3));
        i = close;
      }
    }
    if (in_class && byte == '[' && i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == ':') {
      long close = i + 2;
      while (close + 1 < RSTRING_LEN(src) && !(RSTRING_PTR(src)[close] == ':' && RSTRING_PTR(src)[close + 1] == ']')) close++;
      if (close + 1 < RSTRING_LEN(src)) {
        kind = ONIBI_TOKEN_POSIX_CLASS;
        posix_name = rb_str_substr(src, i + 2, close - (i + 2));
        i = close + 1;
      }
    }
    if (!in_class && byte == '\\' && i + 3 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == 'k' && RSTRING_PTR(src)[i + 2] == '<') {
      long close = i + 3;
      while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != '>') close++;
      if (close < RSTRING_LEN(src)) {
        kind = ONIBI_TOKEN_BACKREF;
        byte = 'k';
        backref_name = rb_str_substr(src, i + 3, close - (i + 3));
        i = close;
        }
    }
    if (kind == ONIBI_TOKEN_LITERAL && !in_class && byte == '\\' &&
        i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == 'g' && RSTRING_PTR(src)[i + 2] == '<') {
      long close = i + 3;
      while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != '>') close++;
      if (close < RSTRING_LEN(src)) {
        kind = ONIBI_TOKEN_SUBROUTINE;
        byte = 'g';
        backref_name = rb_str_substr(src, i + 3, close - (i + 3));
        i = close;
      }
    }
    if (kind == ONIBI_TOKEN_LITERAL && byte == '\\' && i + 2 < RSTRING_LEN(src) &&
        (RSTRING_PTR(src)[i + 1] == 'M' || RSTRING_PTR(src)[i + 1] == 'C') &&
        RSTRING_PTR(src)[i + 2] == '-') {
      if (RSTRING_PTR(src)[i + 1] == 'C' && i + 3 < RSTRING_LEN(src)) {
        kind = ONIBI_TOKEN_LITERAL;
        byte = (unsigned char)RSTRING_PTR(src)[i + 3] & 0x1f;
        i += 3;
      } else {
        kind = ONIBI_TOKEN_META_ESCAPE;
        byte = (unsigned char)RSTRING_PTR(src)[i + 1];
        i += 2;
      }
    }
    if (kind == ONIBI_TOKEN_LITERAL && byte == '\\' && i + 1 < RSTRING_LEN(src)) {
      unsigned char escaped = (unsigned char)RSTRING_PTR(src)[i + 1];
      int hex_literal = 0;
      int octal_literal = 0;
      byte = escaped;
      if (escaped == 'c' && i + 2 < RSTRING_LEN(src)) {
        byte = (unsigned char)RSTRING_PTR(src)[i + 2] & 0x1f;
        i += 2;
      }
      if (escaped == 'x' && i + 3 < RSTRING_LEN(src)) {
        int hi = onibi_hex_digit((unsigned char)RSTRING_PTR(src)[i + 2]);
        int lo = onibi_hex_digit((unsigned char)RSTRING_PTR(src)[i + 3]);
        if (hi >= 0 && lo >= 0) {
          VALUE decoded = rb_str_new((const char[]){(char)((hi << 4) | lo)}, 1);
          byte = (unsigned char)RSTRING_PTR(decoded)[0]; i += 3; hex_literal = 1;
          while (i + 4 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '\\' &&
                 RSTRING_PTR(src)[i + 2] == 'x') {
            int next_hi = onibi_hex_digit((unsigned char)RSTRING_PTR(src)[i + 3]);
            int next_lo = onibi_hex_digit((unsigned char)RSTRING_PTR(src)[i + 4]);
            if (next_hi < 0 || next_lo < 0) break;
            char next_byte = (char)((next_hi << 4) | next_lo);
            rb_str_cat(decoded, &next_byte, 1);
            i += 4;
          }
          if (RSTRING_LEN(decoded) > 1) {
            rb_enc_associate(decoded, rb_enc_get(src));
            literal_bytes = decoded;
          }
        }
      }
      if (escaped >= '1' && escaped <= '9' && i + 1 < RSTRING_LEN(src) &&
          RSTRING_PTR(src)[i + 1] >= '0' && RSTRING_PTR(src)[i + 1] <= '9') {
        long number = escaped - '0';
        while (i + 1 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] >= '0' && RSTRING_PTR(src)[i + 1] <= '9') {
          number = number * 10 + (RSTRING_PTR(src)[++i] - '0');
        }
        kind = ONIBI_TOKEN_BACKREF;
        backref_number = LONG2NUM(number);
      }
      if (NIL_P(backref_number) && escaped >= '1' && escaped <= '7' && i + 2 < RSTRING_LEN(src) &&
          RSTRING_PTR(src)[i + 2] >= '0' && RSTRING_PTR(src)[i + 2] <= '7') {
        VALUE decoded = rb_str_new(NULL, 0);
        int value = 0;
        int digits = 0;
        while (digits < 3 && i + 1 < RSTRING_LEN(src) &&
               RSTRING_PTR(src)[i + 1] >= '0' && RSTRING_PTR(src)[i + 1] <= '7') {
          value = (value << 3) | (RSTRING_PTR(src)[i + 1] - '0');
          i++; digits++;
        }
        char first_byte = (char)value;
        rb_str_cat(decoded, &first_byte, 1);
        while (i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '\\' &&
               RSTRING_PTR(src)[i + 2] >= '0' && RSTRING_PTR(src)[i + 2] <= '7') {
          long cursor = i + 2;
          int next_value = 0;
          int next_digits = 0;
          while (next_digits < 3 && cursor < RSTRING_LEN(src) &&
                 RSTRING_PTR(src)[cursor] >= '0' && RSTRING_PTR(src)[cursor] <= '7') {
            next_value = (next_value << 3) | (RSTRING_PTR(src)[cursor] - '0');
            cursor++; next_digits++;
          }
          char next_byte = (char)next_value;
          rb_str_cat(decoded, &next_byte, 1);
          i = cursor - 1;
        }
        byte = (unsigned char)RSTRING_PTR(decoded)[0];
        octal_literal = 1;
        if (RSTRING_LEN(decoded) > 1) {
          rb_enc_associate(decoded, rb_enc_get(src));
          literal_bytes = decoded;
        }
      }
      if (escaped == '0') {
        int value = 0, digits = 0;
        while (digits < 3 && i + 1 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] >= '0' && RSTRING_PTR(src)[i + 1] <= '7') {
          value = (value << 3) | (RSTRING_PTR(src)[i + 1] - '0');
          i++; digits++;
        }
        byte = (unsigned char)value;
        octal_literal = 1;
      }
      if (escaped == 'n') byte = '\n';
      else if (escaped == 'r') byte = '\r';
      else if (escaped == 't') byte = '\t';
      else if (escaped == 'f') byte = '\f';
      else if (escaped == 'v') byte = '\v';
      else if (escaped == 'a') byte = '\a';
      else if (escaped == 'e') byte = 0x1b;
    if (hex_literal || octal_literal) kind = ONIBI_TOKEN_LITERAL;
    else if (!in_class && onibi_anchor_escape_p(escaped)) kind = ONIBI_TOKEN_ANCHOR;
      else if (!in_class && escaped == 'K') kind = ONIBI_TOKEN_MATCH_RESET;
      else if (!in_class && escaped >= '1' && escaped <= '9') kind = ONIBI_TOKEN_BACKREF;
      else if (onibi_class_escape_p(escaped)) kind = ONIBI_TOKEN_ESCAPE;
      i++;
      if ((escaped == 'p' || escaped == 'P') && i + 1 < RSTRING_LEN(src) &&
          RSTRING_PTR(src)[i + 1] == '{') {
        long close = i + 2;
        while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != '}') close++;
        if (close < RSTRING_LEN(src)) {
          escape_name = rb_str_substr(src, i + 2, close - (i + 2));
          i = close;
        }
      }
    } else if (byte == '[' && !in_class) {
      kind = ONIBI_TOKEN_CLASS_START;
      in_class = 1;
      class_depth = 1;
      class_body_start = i + 1;
    } else if (kind == ONIBI_TOKEN_LITERAL && byte == '[' && in_class) {
      kind = ONIBI_TOKEN_CLASS_START;
      if (class_depth >= (long)(sizeof(class_body_starts) / sizeof(class_body_starts[0])))
        rb_raise(eRegexpError, "regexp character class nesting is too deep");
      class_body_starts[class_depth - 1] = class_body_start;
      class_depth++;
      class_body_start = i + 1;
    } else if (byte == ']' && in_class && class_depth > 1) {
      kind = ONIBI_TOKEN_CLASS_END;
      class_depth--;
      class_body_start = class_body_starts[class_depth - 1];
    } else if (byte == ']' && in_class) {
      kind = ONIBI_TOKEN_CLASS_END;
      in_class = 0;
      class_depth = 0;
    } else if (in_class) {
      if (byte == '-' && i > class_body_start) kind = ONIBI_TOKEN_CLASS_RANGE;
      else if (byte == '^' && i == class_body_start) kind = ONIBI_TOKEN_CLASS_NEGATE;
    } else if (byte == '|') kind = ONIBI_TOKEN_ALTERNATION;
    else if (kind == ONIBI_TOKEN_LITERAL && byte == '(') kind = ONIBI_TOKEN_GROUP_START;
    else if (kind == ONIBI_TOKEN_LITERAL && byte == ')') kind = ONIBI_TOKEN_GROUP_END;
    else if (kind == ONIBI_TOKEN_LITERAL && onibi_quantifier_byte_p(byte)) kind = ONIBI_TOKEN_QUANTIFIER;
    else if (kind == ONIBI_TOKEN_LITERAL && byte == '.') kind = ONIBI_TOKEN_WILDCARD;
    else if (kind == ONIBI_TOKEN_LITERAL && (byte == '^' || byte == '$')) kind = ONIBI_TOKEN_ANCHOR;
    if (kind == ONIBI_TOKEN_LITERAL && byte >= 0x80) {
      int char_len = rb_enc_mbclen(RSTRING_PTR(src) + start,
                                   RSTRING_PTR(src) + RSTRING_LEN(src),
                                   rb_enc_get(src));
      if (char_len > 1 && start + char_len <= RSTRING_LEN(src)) {
        /* rb_str_substr uses character offsets.  `start` and `char_len`
           are byte offsets from the encoding callback, so copy bytes
           directly and keep the complete encoded character only. */
        literal_bytes = rb_str_new(RSTRING_PTR(src) + start, char_len);
        rb_enc_associate(literal_bytes, rb_enc_get(src));
        i += char_len - 1;
        byte = (unsigned char)RSTRING_PTR(src)[start];
      }
    }
    if (kind == ONIBI_TOKEN_GROUP_START || kind == ONIBI_TOKEN_NONCAPTURE_START ||
        kind == ONIBI_TOKEN_ATOMIC_START || kind == ONIBI_TOKEN_ABSENCE_START || kind == ONIBI_TOKEN_CONDITIONAL_START || kind == ONIBI_TOKEN_LOOKAHEAD_START ||
        kind == ONIBI_TOKEN_LOOKBEHIND_START || kind == ONIBI_TOKEN_OPTION_SCOPE_START) {
      if (extended_depth >= (long)(sizeof(extended_stack) / sizeof(extended_stack[0])))
        rb_raise(eRegexpError, "regexp nesting is too deep");
      extended_stack[extended_depth++] = -1;
      if (kind == ONIBI_TOKEN_OPTION_SCOPE_START) {
        extended_stack[extended_depth - 1] = extended;
        if (option_scope_x >= 0) extended = option_negative ? 0 : 1;
      }
    }
    if (kind == ONIBI_TOKEN_OPTION_GLOBAL && option_scope_x >= 0)
      extended = option_scope_x;
    rb_hash_aset(token, ID2SYM(id_key_kind_code), UINT2NUM((unsigned int)kind));
    rb_hash_aset(token, ID2SYM(id_key_byte), INT2NUM(byte));
    rb_hash_aset(token, ID2SYM(id_key_start), LONG2NUM(start));
    rb_hash_aset(token, ID2SYM(id_key_end), LONG2NUM(i + 1));
    if (!NIL_P(backref_name)) { rb_obj_freeze(backref_name); rb_hash_aset(token, ID2SYM(id_key_name), backref_name); }
    if (!NIL_P(backref_number)) rb_hash_aset(token, ID2SYM(id_key_capture), backref_number);
    if (!NIL_P(group_name)) { rb_obj_freeze(group_name); rb_hash_aset(token, ID2SYM(id_key_name), group_name); }
    if (!NIL_P(option_negative_name)) { rb_obj_freeze(option_negative_name); rb_hash_aset(token, ID2SYM(id_key_negative_name), option_negative_name); }
    if (!NIL_P(posix_name)) { rb_obj_freeze(posix_name); rb_hash_aset(token, ID2SYM(id_key_name), posix_name); }
    if (!NIL_P(escape_name)) { rb_obj_freeze(escape_name); rb_hash_aset(token, ID2SYM(id_key_name), escape_name); }
    VALUE token_name = onibi_hash_value_id(token, id_key_name);
    if (!NIL_P(token_name))
      rb_hash_aset(token, ID2SYM(id_key_name_id), ULONG2NUM(rb_intern_str(token_name)));
    if (!NIL_P(literal_bytes)) { rb_obj_freeze(literal_bytes); rb_hash_aset(token, ID2SYM(id_key_bytes), literal_bytes); }
    if (kind == ONIBI_TOKEN_OPTION_SCOPE_START || kind == ONIBI_TOKEN_OPTION_GLOBAL)
      rb_hash_aset(token, ID2SYM(id_key_negative), option_negative ? Qtrue : Qfalse);
    rb_obj_freeze(token);
    rb_ary_push(tokens, token);
    if (kind == ONIBI_TOKEN_GROUP_END && extended_depth > 0) {
      int prior_extended = extended_stack[--extended_depth];
      if (prior_extended >= 0) extended = prior_extended;
    }
  }
  rb_obj_freeze(tokens);
  return tokens;
}

static int onibi_extended_option_p(VALUE options) {
  if (NIL_P(options) || options == Qfalse) return 0;
  if (options == Qtrue) return 0;
  if (RB_TYPE_P(options, T_STRING))
    return memchr(RSTRING_PTR(options), 'x', (size_t)RSTRING_LEN(options)) != NULL;
  if (RB_TYPE_P(options, T_ARRAY)) {
    for (long i = 0; i < RARRAY_LEN(options); i++) {
      VALUE item = rb_ary_entry(options, i);
      ID option_id = SYMBOL_P(item) ? SYM2ID(item) : rb_intern_str(StringValue(item));
      if (option_id == id_opt_extended) return 1;
    }
    return 0;
  }
  return (NUM2INT(options) & 2) != 0;
}

static inline OnibiTokenKind onibi_token_kind_code(VALUE token) {
  return (OnibiTokenKind)NUM2UINT(onibi_hash_value_id(token, id_key_kind_code));
}

static long onibi_token_byte(VALUE token) {
  return NUM2LONG(onibi_hash_value_id(token, id_key_byte));
}

static VALUE onibi_ast_node(OnibiAstKind kind, VALUE token) {
  VALUE node = rb_hash_new();
  rb_hash_aset(node, ID2SYM(id_key_type_code),
               UINT2NUM((unsigned int)kind));
  if (!NIL_P(token)) {
    rb_hash_aset(node, ID2SYM(id_key_start),
                 onibi_hash_value_id(token, id_key_start));
    rb_hash_aset(node, ID2SYM(id_key_end),
                 onibi_hash_value_id(token, id_key_end));
    VALUE name_id = onibi_hash_value_id(token, id_key_name_id);
    if (!NIL_P(name_id)) rb_hash_aset(node, ID2SYM(id_key_name_id), name_id);
  }
  return node;
}

static VALUE onibi_parse_range(VALUE tokens, long begin, long end);
static VALUE onibi_deep_freeze(VALUE value);

static int onibi_deep_freeze_hash_entry(VALUE key, VALUE value, VALUE unused) {
  (void)key;
  (void)unused;
  onibi_deep_freeze(value);
  return ST_CONTINUE;
}

/* AST and compiled metadata are published as immutable object graphs. */
static VALUE onibi_deep_freeze(VALUE value) {
  if (RB_TYPE_P(value, T_ARRAY)) {
    for (long i = 0; i < RARRAY_LEN(value); i++)
      onibi_deep_freeze(rb_ary_entry(value, i));
  } else if (RB_TYPE_P(value, T_HASH)) {
    rb_hash_foreach(value, onibi_deep_freeze_hash_entry, Qnil);
  }
  rb_obj_freeze(value);
  return value;
}

static long onibi_find_close(VALUE tokens, long begin, long end, OnibiTokenKind open, OnibiTokenKind close) {
  long depth = 0;
  for (long i = begin; i < end; i++) {
    OnibiTokenKind kind = onibi_token_kind_code(rb_ary_entry(tokens, i));
    if (kind == open || kind == ONIBI_TOKEN_GROUP_START || kind == ONIBI_TOKEN_NONCAPTURE_START ||
        kind == ONIBI_TOKEN_ATOMIC_START || kind == ONIBI_TOKEN_LOOKAHEAD_START ||
        kind == ONIBI_TOKEN_LOOKBEHIND_START || kind == ONIBI_TOKEN_OPTION_SCOPE_START ||
        kind == ONIBI_TOKEN_ABSENCE_START || kind == ONIBI_TOKEN_CONDITIONAL_START) depth++;
    else if (kind == close && --depth == 0) return i;
  }
  return -1;
}

static VALUE onibi_parse_class(VALUE tokens, long begin, long close) {
  VALUE node = onibi_ast_node(ONIBI_AST_CHARACTER_CLASS, rb_ary_entry(tokens, begin));
  VALUE children = rb_ary_new(), ranges = rb_ary_new();
  int negated = 0;
  long intersection = -1;
  long depth = 0;
  for (long i = begin + 1; i + 1 < close; i++) {
    OnibiTokenKind kind = onibi_token_kind_code(rb_ary_entry(tokens, i));
    if (kind == ONIBI_TOKEN_CLASS_START) { depth++; continue; }
    if (kind == ONIBI_TOKEN_CLASS_END) { if (depth > 0) depth--; continue; }
    if (depth == 0 && kind == ONIBI_TOKEN_LITERAL && onibi_token_byte(rb_ary_entry(tokens, i)) == '&' &&
        onibi_token_kind_code(rb_ary_entry(tokens, i + 1)) == ONIBI_TOKEN_LITERAL &&
        onibi_token_byte(rb_ary_entry(tokens, i + 1)) == '&') { intersection = i; break; }
  }
  if (intersection >= 0) {
    VALUE result = onibi_ast_node(ONIBI_AST_CLASS_INTERSECTION, rb_ary_entry(tokens, begin));
    VALUE operands = rb_ary_new();
    for (int side = 0; side < 2; side++) {
      long part_begin = side == 0 ? begin + 1 : intersection + 2;
      long part_end = side == 0 ? intersection : close;
      VALUE slice = rb_ary_new();
      VALUE open = rb_hash_dup(rb_ary_entry(tokens, part_begin));
      VALUE finish = rb_hash_dup(rb_ary_entry(tokens, part_end - 1));
      rb_hash_aset(open, ID2SYM(id_key_kind_code), UINT2NUM(ONIBI_TOKEN_CLASS_START));
      rb_hash_aset(open, ID2SYM(id_key_byte), INT2NUM('['));
      rb_hash_aset(finish, ID2SYM(id_key_kind_code), UINT2NUM(ONIBI_TOKEN_CLASS_END));
      rb_hash_aset(finish, ID2SYM(id_key_byte), INT2NUM(']'));
      rb_ary_push(slice, open);
      for (long i = part_begin; i < part_end; i++) rb_ary_push(slice, rb_ary_entry(tokens, i));
      rb_ary_push(slice, finish);
      rb_ary_push(operands, onibi_parse_class(slice, 0, RARRAY_LEN(slice) - 1));
    }
    rb_hash_aset(result, ID2SYM(id_key_operands), operands);
    rb_obj_freeze(operands);
    return result;
  }
  for (long i = begin + 1; i < close; i++) {
    VALUE token = rb_ary_entry(tokens, i);
    OnibiTokenKind kind = (OnibiTokenKind)NUM2UINT(rb_hash_aref(token, ID2SYM(id_key_kind_code)));
    if (kind == ONIBI_TOKEN_CLASS_START) {
      long nested_close = onibi_find_close(tokens, i, close, ONIBI_TOKEN_CLASS_START, ONIBI_TOKEN_CLASS_END);
      if (nested_close < 0) rb_raise(eRegexpError, "unterminated nested character class");
      VALUE nested = onibi_parse_class(tokens, i, nested_close);
      rb_hash_aset(nested, ID2SYM(id_key_end),
                   rb_hash_aref(rb_ary_entry(tokens, nested_close), ID2SYM(id_key_end)));
      rb_obj_freeze(nested);
      rb_ary_push(children, nested);
      i = nested_close;
      continue;
    }
    if (kind == ONIBI_TOKEN_CLASS_NEGATE) { negated = 1; continue; }
    if (kind == ONIBI_TOKEN_POSIX_CLASS) {
      VALUE name = rb_hash_aref(token, ID2SYM(id_key_name));
      VALUE name_id = onibi_hash_value_id(token, id_key_name_id);
      ID property = NIL_P(name_id) ? rb_intern_str(name) : (ID)NUM2ULONG(name_id);
      if (onibi_posix_kind_id(property) == ONIBI_POSIX_UNKNOWN)
        rb_raise(eRegexpError, "unknown POSIX character class");
      rb_ary_push(children, token);
      continue;
    }
    if (kind == ONIBI_TOKEN_CLASS_RANGE && i > begin + 1 && i + 1 < close) {
      OnibiTokenKind first_kind = (OnibiTokenKind)NUM2UINT(rb_hash_aref(rb_ary_entry(tokens, i - 1), ID2SYM(id_key_kind_code)));
      OnibiTokenKind last_kind = (OnibiTokenKind)NUM2UINT(rb_hash_aref(rb_ary_entry(tokens, i + 1), ID2SYM(id_key_kind_code)));
      if (first_kind != ONIBI_TOKEN_LITERAL || last_kind != ONIBI_TOKEN_LITERAL)
        rb_raise(eRegexpError, "invalid range endpoint in character class");
      VALUE first_token = rb_ary_entry(tokens, i - 1);
      VALUE last_token = rb_ary_entry(tokens, i + 1);
      VALUE first_bytes = onibi_hash_value_id(first_token, id_key_bytes);
      VALUE last_bytes = onibi_hash_value_id(last_token, id_key_bytes);
      if (NIL_P(first_bytes) != NIL_P(last_bytes)) {
        if (NIL_P(first_bytes)) first_bytes = rb_str_new((const char[]){(char)onibi_token_byte(first_token)}, 1);
        if (NIL_P(last_bytes)) last_bytes = rb_str_new((const char[]){(char)onibi_token_byte(last_token)}, 1);
      }
      if ((!NIL_P(first_bytes) && !NIL_P(last_bytes) && rb_str_cmp(first_bytes, last_bytes) > 0) ||
          (NIL_P(first_bytes) && NIL_P(last_bytes) &&
           onibi_token_byte(first_token) > onibi_token_byte(last_token)))
        rb_raise(eRegexpError, "empty range in character class");
      VALUE range = rb_ary_new();
      rb_ary_push(range, NIL_P(first_bytes) ? LONG2NUM(onibi_token_byte(first_token)) : first_bytes);
      rb_ary_push(range, NIL_P(last_bytes) ? LONG2NUM(onibi_token_byte(last_token)) : last_bytes);
      rb_obj_freeze(range);
      rb_ary_push(ranges, range);
      i++;
      continue;
    }
    rb_ary_push(children, token);
  }
  rb_hash_aset(node, ID2SYM(id_key_children), children);
  rb_hash_aset(node, ID2SYM(id_key_ranges), ranges);
  rb_hash_aset(node, ID2SYM(id_key_negated), negated ? Qtrue : Qfalse);
  rb_obj_freeze(children); rb_obj_freeze(ranges);
  return node;
}

static VALUE onibi_parse_atom(VALUE tokens, long *index, long end) {
  VALUE token = rb_ary_entry(tokens, *index);
  OnibiTokenKind kind_code = (OnibiTokenKind)NUM2UINT(rb_hash_aref(token, ID2SYM(id_key_kind_code)));
  if (kind_code == ONIBI_TOKEN_LOOKAHEAD_START || kind_code == ONIBI_TOKEN_LOOKBEHIND_START) {
    long close = onibi_find_close(tokens, *index, end, kind_code, ONIBI_TOKEN_GROUP_END);
    if (close < 0) rb_raise(eRegexpError, "unterminated lookaround");
    int behind = kind_code == ONIBI_TOKEN_LOOKBEHIND_START;
    VALUE node = onibi_ast_node(behind ? ONIBI_AST_LOOKBEHIND : ONIBI_AST_LOOKAHEAD, token);
    rb_hash_aset(node, ID2SYM(id_key_body), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(id_key_positive), onibi_token_byte(token) == '=' ? Qtrue : Qfalse);
    rb_hash_aset(node, ID2SYM(id_key_end), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(id_key_end)));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind_code == ONIBI_TOKEN_OPTION_SCOPE_START) {
    long close = onibi_find_close(tokens, *index, end, ONIBI_TOKEN_OPTION_SCOPE_START, ONIBI_TOKEN_GROUP_END);
    if (close < 0) rb_raise(eRegexpError, "unterminated option scope");
    VALUE node = onibi_ast_node(ONIBI_AST_OPTION_SCOPE, token);
    rb_hash_aset(node, ID2SYM(id_key_body), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(id_key_options), rb_hash_aref(token, ID2SYM(id_key_name)));
    VALUE negative_options = rb_hash_aref(token, ID2SYM(id_key_negative_name));
    if (!NIL_P(negative_options))
      rb_hash_aset(node, ID2SYM(id_key_negative_options), negative_options);
    rb_hash_aset(node, ID2SYM(id_key_negative), rb_hash_aref(token, ID2SYM(id_key_negative)));
    rb_hash_aset(node, ID2SYM(id_key_end), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(id_key_end)));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind_code == ONIBI_TOKEN_OPTION_GLOBAL) {
    VALUE node = onibi_ast_node(ONIBI_AST_OPTION_GLOBAL, token);
    rb_hash_aset(node, ID2SYM(id_key_options), rb_hash_aref(token, ID2SYM(id_key_name)));
    VALUE negative_options = rb_hash_aref(token, ID2SYM(id_key_negative_name));
    if (!NIL_P(negative_options))
      rb_hash_aset(node, ID2SYM(id_key_negative_options), negative_options);
    rb_hash_aset(node, ID2SYM(id_key_negative), rb_hash_aref(token, ID2SYM(id_key_negative)));
    rb_obj_freeze(node);
    *index = *index + 1;
    return node;
  }
  if (kind_code == ONIBI_TOKEN_NONCAPTURE_START) {
    long close = onibi_find_close(tokens, *index, end, ONIBI_TOKEN_NONCAPTURE_START, ONIBI_TOKEN_GROUP_END);
    if (close < 0) rb_raise(eRegexpError, "unterminated group");
    VALUE node = onibi_ast_node(ONIBI_AST_GROUP, token);
    rb_hash_aset(node, ID2SYM(id_key_body), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(id_key_capturing), Qfalse);
    rb_hash_aset(node, ID2SYM(id_key_end), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(id_key_end)));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind_code == ONIBI_TOKEN_ATOMIC_START) {
    long close = onibi_find_close(tokens, *index, end, ONIBI_TOKEN_ATOMIC_START, ONIBI_TOKEN_GROUP_END);
    if (close < 0) rb_raise(eRegexpError, "unterminated atomic group");
    VALUE node = onibi_ast_node(ONIBI_AST_ATOMIC, token);
    rb_hash_aset(node, ID2SYM(id_key_body), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(id_key_end), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(id_key_end)));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind_code == ONIBI_TOKEN_ABSENCE_START) {
    long close = onibi_find_close(tokens, *index, end, ONIBI_TOKEN_ABSENCE_START, ONIBI_TOKEN_GROUP_END);
    if (close < 0) rb_raise(eRegexpError, "unterminated absence operator");
    VALUE node = onibi_ast_node(ONIBI_AST_ABSENCE, token);
    rb_hash_aset(node, ID2SYM(id_key_body), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(id_key_end), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(id_key_end)));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind_code == ONIBI_TOKEN_CONDITIONAL_START) {
    long close = onibi_find_close(tokens, *index, end, ONIBI_TOKEN_CONDITIONAL_START, ONIBI_TOKEN_GROUP_END);
    if (close < 0) rb_raise(eRegexpError, "unterminated conditional group");
    VALUE node = onibi_ast_node(ONIBI_AST_CONDITIONAL, token);
    VALUE condition = rb_hash_aref(token, ID2SYM(id_key_name));
    if (!NIL_P(condition)) rb_hash_aset(node, ID2SYM(id_key_condition), condition);
    VALUE body = onibi_parse_range(tokens, *index + 1, close);
    VALUE branches = rb_hash_aref(body, ID2SYM(id_key_branches));
    if (RB_TYPE_P(branches, T_ARRAY) && RARRAY_LEN(branches) == 2) {
      rb_hash_aset(node, ID2SYM(id_key_yes), rb_ary_entry(branches, 0));
      rb_hash_aset(node, ID2SYM(id_key_no), rb_ary_entry(branches, 1));
    } else {
      rb_hash_aset(node, ID2SYM(id_key_yes), body);
      rb_hash_aset(node, ID2SYM(id_key_no), onibi_parse_range(tokens, close, close));
    }
    rb_hash_aset(node, ID2SYM(id_key_end), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(id_key_end)));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind_code == ONIBI_TOKEN_GROUP_START) {
    long close = onibi_find_close(tokens, *index, end, ONIBI_TOKEN_GROUP_START, ONIBI_TOKEN_GROUP_END);
    if (close < 0) rb_raise(eRegexpError, "unterminated group");
    VALUE node = onibi_ast_node(ONIBI_AST_CAPTURE, token);
    rb_hash_aset(node, ID2SYM(id_key_body), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(id_key_capturing), Qtrue);
    VALUE name = rb_hash_aref(token, ID2SYM(id_key_name));
    if (!NIL_P(name)) {
      if (RSTRING_LEN(name) == 0 || !isalpha((unsigned char)RSTRING_PTR(name)[0]))
        rb_raise(eRegexpError, "invalid capture name");
      for (long n = 1; n < RSTRING_LEN(name); n++)
        if (!isalnum((unsigned char)RSTRING_PTR(name)[n]) && RSTRING_PTR(name)[n] != '_')
          rb_raise(eRegexpError, "invalid capture name");
      rb_hash_aset(node, ID2SYM(id_key_name), name);
    }
    rb_hash_aset(node, ID2SYM(id_key_end),
                 rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(id_key_end)));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind_code == ONIBI_TOKEN_CLASS_START) {
    long close = onibi_find_close(tokens, *index, end, ONIBI_TOKEN_CLASS_START, ONIBI_TOKEN_CLASS_END);
    if (close < 0) rb_raise(eRegexpError, "unterminated character class");
    VALUE node = onibi_parse_class(tokens, *index, close);
    rb_hash_aset(node, ID2SYM(id_key_end),
                 rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(id_key_end)));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind_code == ONIBI_TOKEN_SUBROUTINE) {
    VALUE node = onibi_ast_node(ONIBI_AST_SUBROUTINE, token);
    VALUE name = rb_hash_aref(token, ID2SYM(id_key_name));
    if (!NIL_P(name)) rb_hash_aset(node, ID2SYM(id_key_name), name);
    rb_hash_aset(node, ID2SYM(id_key_byte), LONG2NUM(onibi_token_byte(token)));
    rb_obj_freeze(node);
    *index = *index + 1;
    return node;
  }
  VALUE node = NIL_P(token) ? Qnil :
    (kind_code == ONIBI_TOKEN_WILDCARD ? onibi_ast_node(ONIBI_AST_ANY, token) :
     (kind_code == ONIBI_TOKEN_ANCHOR ? onibi_ast_node(ONIBI_AST_ANCHOR, token) :
     (kind_code == ONIBI_TOKEN_ESCAPE || kind_code == ONIBI_TOKEN_META_ESCAPE ? onibi_ast_node(ONIBI_AST_ESCAPE, token) :
       (kind_code == ONIBI_TOKEN_MATCH_RESET ? onibi_ast_node(ONIBI_AST_MATCH_RESET, token) :
       (kind_code == ONIBI_TOKEN_BACKREF ? onibi_ast_node(ONIBI_AST_BACKREF, token) :
       (kind_code == ONIBI_TOKEN_LITERAL ? onibi_ast_node(ONIBI_AST_LITERAL, token) : Qnil))))));
  if (NIL_P(node)) rb_raise(eRegexpError, "unexpected token in expression");
  rb_hash_aset(node, ID2SYM(id_key_byte), LONG2NUM(onibi_token_byte(token)));
  VALUE token_bytes = rb_hash_aref(token, ID2SYM(id_key_bytes));
  if (!NIL_P(token_bytes)) rb_hash_aset(node, ID2SYM(id_key_bytes), token_bytes);
  if (kind_code == ONIBI_TOKEN_ANCHOR) {
    long marker = onibi_token_byte(token);
    const char *anchor = (marker == '^' || marker == 'A' || marker == 'G') ?
      "anchor_start" : ((marker == '$' || marker == 'z' || marker == 'Z') ?
      "anchor_end" : "anchor");
    ID anchor_id = (anchor[7] == 's') ? id_anchor_start :
      ((anchor[7] == 'e') ? id_anchor_end : id_anchor);
    rb_hash_aset(node, ID2SYM(id_key_kind), ID2SYM(anchor_id));
  }
  if (kind_code == ONIBI_TOKEN_ESCAPE || kind_code == ONIBI_TOKEN_META_ESCAPE) {
    VALUE token_name = rb_hash_aref(token, ID2SYM(id_key_name));
    rb_hash_aset(node, ID2SYM(id_key_name), NIL_P(token_name) ?
                rb_str_new((const char[]){(char)onibi_token_byte(token)}, 1) : token_name);
  }
  if (kind_code == ONIBI_TOKEN_BACKREF) {
    VALUE name = rb_hash_aref(token, ID2SYM(id_key_name));
    VALUE capture_number = rb_hash_aref(token, ID2SYM(id_key_capture));
    if (NIL_P(name)) rb_hash_aset(node, ID2SYM(id_key_capture),
                                  NIL_P(capture_number) ? LONG2NUM(onibi_token_byte(token) - '0') : capture_number);
    else rb_hash_aset(node, ID2SYM(id_key_name), name);
  }
  rb_obj_freeze(node);
  *index = *index + 1;
  return node;
}

static VALUE onibi_parse_range(VALUE tokens, long begin, long end) {
  VALUE branches = rb_ary_new();
  long part = begin, depth = 0;
  for (long i = begin; i < end; i++) {
    VALUE token = rb_ary_entry(tokens, i);
    OnibiTokenKind kind = (OnibiTokenKind)NUM2UINT(rb_hash_aref(token, ID2SYM(id_key_kind_code)));
    if (kind == ONIBI_TOKEN_GROUP_START || kind == ONIBI_TOKEN_NONCAPTURE_START ||
        kind == ONIBI_TOKEN_ATOMIC_START || kind == ONIBI_TOKEN_ABSENCE_START ||
        kind == ONIBI_TOKEN_CONDITIONAL_START || kind == ONIBI_TOKEN_LOOKAHEAD_START ||
        kind == ONIBI_TOKEN_LOOKBEHIND_START || kind == ONIBI_TOKEN_OPTION_SCOPE_START ||
        kind == ONIBI_TOKEN_CLASS_START) depth++;
    else if (kind == ONIBI_TOKEN_GROUP_END || kind == ONIBI_TOKEN_CLASS_END) depth--;
    else if (kind == ONIBI_TOKEN_ALTERNATION && depth == 0) {
      rb_ary_push(branches, onibi_parse_range(tokens, part, i));
      part = i + 1;
    }
  }
  if (RARRAY_LEN(branches) > 0) {
    rb_ary_push(branches, onibi_parse_range(tokens, part, end));
    VALUE node = onibi_ast_node(ONIBI_AST_ALTERNATIVE, Qnil);
    rb_hash_aset(node, ID2SYM(id_key_branches), branches);
    rb_obj_freeze(branches); rb_obj_freeze(node);
    return node;
  }

  VALUE children = rb_ary_new();
  for (long i = begin; i < end;) {
    VALUE node = onibi_parse_atom(tokens, &i, end);
    if (i < end && onibi_token_kind_code(rb_ary_entry(tokens, i)) == ONIBI_TOKEN_QUANTIFIER) {
      VALUE modifier = rb_ary_entry(tokens, i);
      long marker = onibi_token_byte(modifier);
      if (marker == '*' || marker == '+' || marker == '?') {
        if (onibi_ast_kind(node) == ONIBI_AST_QUANTIFIER)
          rb_raise(eRegexpError, "nested quantifier");
        long min = marker == '+' ? 1 : 0;
        VALUE max = marker == '?' ? LONG2NUM(1) : Qnil;
        i++;
        int greedy = 1, possessive = 0;
        if (i < end && onibi_token_kind_code(rb_ary_entry(tokens, i)) == ONIBI_TOKEN_QUANTIFIER) {
          long suffix = onibi_token_byte(rb_ary_entry(tokens, i));
          if (suffix == '?') { greedy = 0; i++; }
          else if (suffix == '+') { possessive = 1; i++; }
        }
        VALUE quantifier = onibi_ast_node(ONIBI_AST_QUANTIFIER, modifier);
        rb_hash_aset(quantifier, ID2SYM(id_key_atom), node);
        rb_hash_aset(quantifier, ID2SYM(id_key_min), LONG2NUM(min));
        rb_hash_aset(quantifier, ID2SYM(id_key_max), max);
        rb_hash_aset(quantifier, ID2SYM(id_key_greedy), greedy ? Qtrue : Qfalse);
        rb_hash_aset(quantifier, ID2SYM(id_key_possessive), possessive ? Qtrue : Qfalse);
        rb_obj_freeze(quantifier); node = quantifier;
      } else if (marker == '{') {
        if (onibi_ast_kind(node) == ONIBI_AST_QUANTIFIER)
          rb_raise(eRegexpError, "nested quantifier");
        long close = i + 1;
        while (close < end && onibi_token_byte(rb_ary_entry(tokens, close)) != '}') close++;
        if (close >= end) rb_raise(eRegexpError, "unterminated quantifier");
        char spec_buf[128];
        size_t spec_len = 0;
        for (long spec_i = i + 1; spec_i < close; spec_i++) {
          VALUE spec_token = rb_ary_entry(tokens, spec_i);
          if (spec_len + 1 >= sizeof(spec_buf)) rb_raise(eRegexpError, "quantifier is too large");
          spec_buf[spec_len++] = (char)onibi_token_byte(spec_token);
        }
        spec_buf[spec_len] = '\0';
        int valid_spec = spec_len > 0;
        long comma_count = 0, comma_at = -1;
        for (size_t spec_i = 0; valid_spec && spec_i < spec_len; spec_i++) {
          if (spec_buf[spec_i] == ',') {
            comma_count++; comma_at = (long)spec_i;
          } else if (spec_buf[spec_i] < '0' || spec_buf[spec_i] > '9') valid_spec = 0;
        }
        if (comma_count > 1 || (comma_count == 1 &&
            (comma_at == 0 && comma_at + 1 == (long)spec_len))) valid_spec = 0;
        if (comma_count == 1 && comma_at > 0 && comma_at + 1 < (long)spec_len) {
          /* both sides contain digits */
        } else if (comma_count == 1 && comma_at == 0 && spec_len == 1) valid_spec = 0;
        if (!valid_spec) {
          if (memchr(spec_buf, '-', spec_len) != NULL)
            rb_raise(eRegexpError, "invalid quantifier");
          rb_ary_push(children, node);
          for (long literal_i = i; literal_i <= close; literal_i++) {
            VALUE literal_token = rb_ary_entry(tokens, literal_i);
            VALUE literal = onibi_ast_node(ONIBI_AST_LITERAL, literal_token);
            rb_hash_aset(literal, ID2SYM(id_key_byte), LONG2NUM(onibi_token_byte(literal_token)));
            rb_obj_freeze(literal);
            rb_ary_push(children, literal);
          }
          i = close + 1;
          continue;
        }
        long min = 0, max_value = 0;
        const char *body = spec_buf;
        char *comma = strchr(body, ',');
        int has_max = 1;
        if (comma != NULL) {
          char *endptr = NULL;
          min = onibi_parse_count(body, &endptr);
          if (endptr != comma) rb_raise(eRegexpError, "invalid quantifier");
          if (comma[1] == '\0') has_max = 0;
          else {
            char *max_end = NULL;
            max_value = onibi_parse_count(comma + 1, &max_end);
            if (*max_end != '\0') rb_raise(eRegexpError, "invalid quantifier");
          }
        } else {
          char *endptr = NULL;
          min = onibi_parse_count(body, &endptr);
          if (*endptr != '\0') rb_raise(eRegexpError, "invalid quantifier");
          max_value = min;
        }
        if (min < 0 || (has_max && max_value < 0)) rb_raise(eRegexpError, "invalid quantifier");
        if (has_max && max_value < min) rb_raise(eRegexpError, "invalid quantifier range");
        VALUE quantifier = onibi_ast_node(ONIBI_AST_QUANTIFIER, modifier);
        rb_hash_aset(quantifier, ID2SYM(id_key_atom), node);
        rb_hash_aset(quantifier, ID2SYM(id_key_min), LONG2NUM(min));
        rb_hash_aset(quantifier, ID2SYM(id_key_max), has_max ? LONG2NUM(max_value) : Qnil);
        i = close + 1;
        int greedy = 1, possessive = 0;
        if (i < end && onibi_token_kind_code(rb_ary_entry(tokens, i)) == ONIBI_TOKEN_QUANTIFIER) {
          long suffix = onibi_token_byte(rb_ary_entry(tokens, i));
          if (suffix == '?') { greedy = 0; i++; }
          else if (suffix == '+') { possessive = 1; i++; }
        }
        rb_hash_aset(quantifier, ID2SYM(id_key_greedy), greedy ? Qtrue : Qfalse);
        rb_hash_aset(quantifier, ID2SYM(id_key_possessive), possessive ? Qtrue : Qfalse);
        rb_obj_freeze(quantifier); node = quantifier;
      }
    }
    rb_ary_push(children, node);
  }
  VALUE sequence = onibi_ast_node(ONIBI_AST_SEQUENCE, Qnil);
  rb_hash_aset(sequence, ID2SYM(id_key_children), children);
  rb_obj_freeze(children); rb_obj_freeze(sequence);
  return sequence;
}

typedef enum {
  ONIBI_AST_FLAG_SAFE_MULTIBYTE_CLASS = 1U << 0,
  ONIBI_AST_FLAG_ANCHOR_REPEAT = 1U << 1,
  ONIBI_AST_FLAG_NULLABLE_ABSENCE = 1U << 2,
  ONIBI_AST_FLAG_NULLABLE_CAPTURE = 1U << 3
} OnibiAstAnalysisFlag;

typedef struct {
  VALUE ast;
  int options;
  unsigned int ast_flags;
} OnibiParsed;

static void onibi_parsed_mark(void *ptr) {
  OnibiParsed *parsed = (OnibiParsed *)ptr;
  if (parsed) rb_gc_mark(parsed->ast);
}
static void onibi_parsed_free(void *ptr) { xfree(ptr); }
static size_t onibi_parsed_memsize(const void *ptr) { return ptr ? sizeof(OnibiParsed) : 0; }
static const rb_data_type_t onibi_parsed_type = {
  "Onibi::Parsed", { onibi_parsed_mark, onibi_parsed_free, onibi_parsed_memsize, NULL, { NULL } },
  0, 0, RUBY_TYPED_FREE_IMMEDIATELY
};
static inline OnibiParsed *onibi_parsed_get(VALUE value) {
  OnibiParsed *parsed;
  TypedData_Get_Struct(value, OnibiParsed, &onibi_parsed_type, parsed);
  return parsed;
}

static int onibi_ast_safe_multibyte_class(VALUE ast);
static int onibi_ast_anchor_repeat(VALUE ast);
static int onibi_ast_nullable_absence(VALUE ast);
static int onibi_ast_nullable(VALUE ast, int *nullable_capture);

static VALUE onibi_parser_parse_internal(VALUE source, VALUE options, VALUE supplied_tokens) {
  source = StringValue(source);
  VALUE tokens = supplied_tokens;
  if (NIL_P(tokens)) {
    tokens = onibi_tokenize_internal(source, onibi_extended_option_p(options));
  }
  OnibiParsed *parsed;
  VALUE result = TypedData_Make_Struct(rb_cObject, OnibiParsed, &onibi_parsed_type, parsed);
  parsed->ast = Qnil;
  parsed->ast_flags = 0;
  parsed->options = onibi_option_mask(options);
  /* The AST is an internal compiler value.  Do not deep-freeze it here: it is
     never exposed through the Regexp API and freezing would rescan the tree. */
  parsed->ast = onibi_parse_range(tokens, 0, RARRAY_LEN(tokens));
  if (onibi_ast_safe_multibyte_class(parsed->ast)) parsed->ast_flags |= ONIBI_AST_FLAG_SAFE_MULTIBYTE_CLASS;
  if (onibi_ast_anchor_repeat(parsed->ast)) parsed->ast_flags |= ONIBI_AST_FLAG_ANCHOR_REPEAT;
  if (onibi_ast_nullable_absence(parsed->ast)) parsed->ast_flags |= ONIBI_AST_FLAG_NULLABLE_ABSENCE;
  int nullable_capture = 0;
  (void)onibi_ast_nullable(parsed->ast, &nullable_capture);
  if (nullable_capture) parsed->ast_flags |= ONIBI_AST_FLAG_NULLABLE_CAPTURE;
  return result;
}

typedef struct { OnibiIdVector starts; OnibiIdVector exits; VALUE start_actions; VALUE pending_actions; int nullable; int lazy; } onibi_fragment_t;
typedef struct { OnibiStateId state; VALUE actions; } OnibiGuardEntry;
typedef struct { OnibiGuardEntry *entries; size_t count; size_t capacity; } OnibiGuardVector;
typedef struct { VALUE key; VALUE value; } OnibiValueEntry;
typedef struct { OnibiValueEntry *entries; size_t count; size_t capacity; } OnibiValueMap;
typedef struct { long id; ID op; OnibiGStateOp opcode; VALUE payload; uint32_t payload_index; } OnibiGirStateEntry;
typedef struct { OnibiGirStateEntry *entries; size_t count; size_t capacity; } OnibiGirStateVector;
typedef struct { long from; long to; long action_offset; uint32_t action_count; VALUE actions; } OnibiGirEdgeEntry;
typedef struct { OnibiGirEdgeEntry *entries; size_t count; size_t capacity; } OnibiGirEdgeVector;
typedef struct { VALUE value; OnibiGActionOp code; ID op; } OnibiRSeqActionEntry;
typedef struct { OnibiRSeqActionEntry *entries; size_t count; size_t capacity; } OnibiRSeqActionVector;
typedef struct { VALUE payload; VALUE bitmap; int negated; } OnibiRSeqClassPayloadEntry;
typedef struct { OnibiRSeqClassPayloadEntry *entries; size_t count; size_t capacity; } OnibiRSeqClassPayloadVector;
typedef struct { VALUE payload; int byte; int ignorecase; } OnibiRSeqLiteralPayloadEntry;
typedef struct { OnibiRSeqLiteralPayloadEntry *entries; size_t count; size_t capacity; } OnibiRSeqLiteralPayloadVector;
typedef struct { VALUE descriptor; OnibiStateId entry; OnibiStateId accept; uint32_t flags; } OnibiRSeqSubprogramEntry;
typedef struct { OnibiRSeqSubprogramEntry *entries; size_t count; size_t capacity; } OnibiRSeqSubprogramVector;
typedef struct { OnibiGirStateVector states; OnibiGirEdgeVector edges; long next_id; long capture_count; long counter_count; OnibiValueMap capture_names; OnibiValueMap capture_bodies; OnibiValueMap capture_ids; OnibiGuardVector capture_guards; OnibiGuardVector exit_guards; OnibiValueMap active_subroutines; VALUE subprograms; OnibiValueMap subprogram_ids; VALUE map_roots; int ignorecase; int multiline; int optional_seen; } onibi_gir_builder_t;
static void onibi_append_values(VALUE destination, VALUE values);

static void onibi_id_vector_init(OnibiIdVector *vector) {
  vector->items = NULL; vector->count = 0; vector->capacity = 0;
}

static void onibi_id_vector_push(OnibiIdVector *vector, OnibiStateId value) {
  if (vector->count == vector->capacity) {
    size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
    if (next > SIZE_MAX / sizeof(*vector->items)) rb_raise(rb_eNoMemError, "GIR state vector is too large");
    vector->items = REALLOC_N(vector->items, OnibiStateId, next);
    vector->capacity = next;
  }
  vector->items[vector->count++] = value;
}

static void onibi_id_vector_free(OnibiIdVector *vector) {
  xfree(vector->items); vector->items = NULL; vector->count = vector->capacity = 0;
}

static void onibi_id_vector_move(OnibiIdVector *destination, OnibiIdVector *source) {
  onibi_id_vector_free(destination);
  *destination = *source;
  onibi_id_vector_init(source);
}

static void onibi_id_vector_append(OnibiIdVector *destination, const OnibiIdVector *source) {
  for (size_t i = 0; i < source->count; i++) onibi_id_vector_push(destination, source->items[i]);
}

static void onibi_id_vector_single(OnibiIdVector *vector, OnibiStateId value) {
  onibi_id_vector_init(vector);
  onibi_id_vector_push(vector, value);
}

static void onibi_guard_vector_init(OnibiGuardVector *vector) {
  vector->entries = NULL; vector->count = 0; vector->capacity = 0;
}

static VALUE onibi_guard_vector_find(const OnibiGuardVector *vector, OnibiStateId state) {
  for (size_t i = 0; i < vector->count; i++)
    if (vector->entries[i].state == state) return vector->entries[i].actions;
  return Qnil;
}

static void onibi_guard_vector_add(OnibiGuardVector *vector, OnibiStateId state, VALUE actions, VALUE roots) {
  for (size_t i = 0; i < vector->count; i++) {
    if (vector->entries[i].state == state) {
      VALUE merged = rb_ary_dup(vector->entries[i].actions);
      onibi_append_values(merged, actions);
      vector->entries[i].actions = merged;
      rb_ary_push(roots, merged);
      return;
    }
  }
  if (vector->count == vector->capacity) {
    size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
    if (next > SIZE_MAX / sizeof(*vector->entries)) rb_raise(rb_eNoMemError, "GIR guard vector is too large");
    vector->entries = REALLOC_N(vector->entries, OnibiGuardEntry, next);
    vector->capacity = next;
  }
  vector->entries[vector->count].state = state;
  vector->entries[vector->count].actions = rb_ary_dup(actions);
  rb_ary_push(roots, vector->entries[vector->count].actions);
  vector->count++;
}

static void onibi_guard_vector_free(OnibiGuardVector *vector) {
  xfree(vector->entries); vector->entries = NULL; vector->count = vector->capacity = 0;
}

static void onibi_value_map_init(OnibiValueMap *map) {
  map->entries = NULL; map->count = 0; map->capacity = 0;
}

static int onibi_value_map_key_equal(VALUE left, VALUE right) {
  return left == right || RTEST(rb_equal(left, right));
}

static VALUE onibi_value_map_find(const OnibiValueMap *map, VALUE key) {
  for (size_t i = 0; i < map->count; i++)
    if (onibi_value_map_key_equal(map->entries[i].key, key)) return map->entries[i].value;
  return Qnil;
}

static void onibi_value_map_set(OnibiValueMap *map, VALUE key, VALUE value, VALUE roots) {
  for (size_t i = 0; i < map->count; i++) {
    if (onibi_value_map_key_equal(map->entries[i].key, key)) {
      map->entries[i].value = value;
      rb_ary_push(roots, key);
      rb_ary_push(roots, value);
      return;
    }
  }
  if (map->count == map->capacity) {
    size_t next = map->capacity == 0 ? 8 : map->capacity * 2;
    if (next > SIZE_MAX / sizeof(*map->entries)) rb_raise(rb_eNoMemError, "GIR value map is too large");
    map->entries = REALLOC_N(map->entries, OnibiValueEntry, next);
    map->capacity = next;
  }
  map->entries[map->count].key = key;
  map->entries[map->count].value = value;
  rb_ary_push(roots, key);
  rb_ary_push(roots, value);
  map->count++;
}

static void onibi_value_map_delete(OnibiValueMap *map, VALUE key) {
  for (size_t i = 0; i < map->count; i++) {
    if (onibi_value_map_key_equal(map->entries[i].key, key)) {
      map->entries[i] = map->entries[--map->count];
      return;
    }
  }
}

static void onibi_value_map_free(OnibiValueMap *map) {
  xfree(map->entries); map->entries = NULL; map->count = map->capacity = 0;
}

static void onibi_gir_state_vector_init(OnibiGirStateVector *vector) {
  vector->entries = NULL; vector->count = 0; vector->capacity = 0;
}

static void onibi_gir_state_vector_push(OnibiGirStateVector *vector, OnibiGirStateEntry entry, VALUE roots) {
  if (vector->count == vector->capacity) {
    size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
    if (next > SIZE_MAX / sizeof(*vector->entries)) rb_raise(rb_eNoMemError, "GIR state vector is too large");
    vector->entries = REALLOC_N(vector->entries, OnibiGirStateEntry, next);
    vector->capacity = next;
  }
  vector->entries[vector->count++] = entry;
  rb_ary_push(roots, entry.payload);
}

static void onibi_gir_edge_vector_init(OnibiGirEdgeVector *vector) {
  vector->entries = NULL; vector->count = 0; vector->capacity = 0;
}

static void onibi_gir_edge_vector_push(OnibiGirEdgeVector *vector, OnibiGirEdgeEntry entry, VALUE roots) {
  if (vector->count == vector->capacity) {
    size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
    if (next > SIZE_MAX / sizeof(*vector->entries)) rb_raise(rb_eNoMemError, "GIR edge vector is too large");
    vector->entries = REALLOC_N(vector->entries, OnibiGirEdgeEntry, next);
    vector->capacity = next;
  }
  vector->entries[vector->count++] = entry;
  rb_ary_push(roots, entry.actions);
}

static void onibi_gir_edge_vector_insert(OnibiGirEdgeVector *vector, size_t index, OnibiGirEdgeEntry entry, VALUE roots) {
  if (index > vector->count) index = vector->count;
  if (vector->count == vector->capacity) {
    size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
    if (next > SIZE_MAX / sizeof(*vector->entries)) rb_raise(rb_eNoMemError, "GIR edge vector is too large");
    vector->entries = REALLOC_N(vector->entries, OnibiGirEdgeEntry, next);
    vector->capacity = next;
  }
  memmove(&vector->entries[index + 1], &vector->entries[index], (vector->count - index) * sizeof(*vector->entries));
  vector->entries[index] = entry; vector->count++;
  rb_ary_push(roots, entry.actions);
}

static void onibi_gir_state_vector_free(OnibiGirStateVector *vector) {
  xfree(vector->entries); vector->entries = NULL; vector->count = vector->capacity = 0;
}
static void onibi_gir_edge_vector_free(OnibiGirEdgeVector *vector) {
  xfree(vector->entries); vector->entries = NULL; vector->count = vector->capacity = 0;
}

static void onibi_rseq_action_vector_init(OnibiRSeqActionVector *vector) {
  vector->entries = NULL; vector->count = vector->capacity = 0;
}
static void onibi_rseq_action_vector_push(OnibiRSeqActionVector *vector, VALUE value) {
  if (vector->count == vector->capacity) {
    size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
    if (next > SIZE_MAX / sizeof(*vector->entries)) rb_raise(rb_eNoMemError, "RSeq action vector is too large");
    vector->entries = REALLOC_N(vector->entries, OnibiRSeqActionEntry, next); vector->capacity = next;
  }
  vector->entries[vector->count++] = (OnibiRSeqActionEntry){
    value, (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(value, id_key_action_code)),
    SYM2ID(onibi_hash_value_id(value, id_key_op))
  };
}
static void onibi_rseq_action_vector_free(OnibiRSeqActionVector *vector) {
  xfree(vector->entries); vector->entries = NULL; vector->count = vector->capacity = 0;
}
static void onibi_rseq_class_payload_vector_init(OnibiRSeqClassPayloadVector *vector) {
  vector->entries = NULL; vector->count = vector->capacity = 0;
}
static void onibi_rseq_class_payload_vector_push(OnibiRSeqClassPayloadVector *vector, VALUE payload) {
  if (vector->count == vector->capacity) {
    size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
    if (next > SIZE_MAX / sizeof(*vector->entries)) rb_raise(rb_eNoMemError, "RSeq class payload vector is too large");
    vector->entries = REALLOC_N(vector->entries, OnibiRSeqClassPayloadEntry, next); vector->capacity = next;
  }
  vector->entries[vector->count++] = (OnibiRSeqClassPayloadEntry){
    payload, onibi_hash_value_id(payload, id_key_bitmap), RTEST(onibi_hash_value_id(payload, id_key_negated))
  };
}
static void onibi_rseq_class_payload_vector_free(OnibiRSeqClassPayloadVector *vector) {
  xfree(vector->entries); vector->entries = NULL; vector->count = vector->capacity = 0;
}
static void onibi_rseq_literal_payload_vector_init(OnibiRSeqLiteralPayloadVector *vector) {
  vector->entries = NULL; vector->count = vector->capacity = 0;
}
static void onibi_rseq_literal_payload_vector_push(OnibiRSeqLiteralPayloadVector *vector, VALUE payload) {
  if (vector->count == vector->capacity) {
    size_t next = vector->capacity == 0 ? 8 : vector->capacity * 2;
    if (next > SIZE_MAX / sizeof(*vector->entries)) rb_raise(rb_eNoMemError, "RSeq literal payload vector is too large");
    vector->entries = REALLOC_N(vector->entries, OnibiRSeqLiteralPayloadEntry, next); vector->capacity = next;
  }
  vector->entries[vector->count++] = (OnibiRSeqLiteralPayloadEntry){
    payload, NUM2INT(onibi_hash_value_id(payload, id_key_byte)), RTEST(onibi_hash_value_id(payload, id_key_ignorecase))
  };
}
static void onibi_rseq_literal_payload_vector_free(OnibiRSeqLiteralPayloadVector *vector) {
  xfree(vector->entries); vector->entries = NULL; vector->count = vector->capacity = 0;
}
static void onibi_rseq_subprogram_vector_init(OnibiRSeqSubprogramVector *vector) {
  vector->entries = NULL; vector->count = vector->capacity = 0;
}
static void onibi_rseq_subprogram_vector_push(OnibiRSeqSubprogramVector *vector, VALUE descriptor) {
  if (vector->count == vector->capacity) {
    size_t next = vector->capacity == 0 ? 4 : vector->capacity * 2;
    if (next > SIZE_MAX / sizeof(*vector->entries)) rb_raise(rb_eNoMemError, "RSeq subprogram vector is too large");
    vector->entries = REALLOC_N(vector->entries, OnibiRSeqSubprogramEntry, next); vector->capacity = next;
  }
  vector->entries[vector->count++] = (OnibiRSeqSubprogramEntry){
    descriptor,
    (OnibiStateId)NUM2ULONG(onibi_hash_value_id(descriptor, id_key_entry)),
    (OnibiStateId)NUM2ULONG(onibi_hash_value_id(descriptor, id_key_accept)),
    (uint32_t)NUM2ULONG(onibi_hash_value_id(descriptor, id_key_flags))
  };
}
static void onibi_rseq_subprogram_vector_free(OnibiRSeqSubprogramVector *vector) {
  xfree(vector->entries); vector->entries = NULL; vector->count = vector->capacity = 0;
}
static void onibi_bitmap_set(unsigned char *bits, unsigned char value, int fold) {
  bits[value >> 3] |= (unsigned char)(1U << (value & 7));
  if (fold) {
    unsigned char lower = (unsigned char)tolower(value);
    unsigned char upper = (unsigned char)toupper(value);
    bits[lower >> 3] |= (unsigned char)(1U << (lower & 7));
    bits[upper >> 3] |= (unsigned char)(1U << (upper & 7));
  }
}

static OnibiAsciiProperty onibi_ascii_property_kind_id(ID property) {
  static ID ids[15]; static int ready = 0;
  if (!ready) {
    const char *names[] = {"ASCII", "ASCII_Hex_Digit", "Digit", "Alpha", "Alnum", "Lower", "Upper", "Space", "Blank", "Word", "XDigit", "Cntrl", "Print", "Graph", "Punct"};
    for (size_t i = 0; i < 15; i++) ids[i] = rb_intern(names[i]);
    ready = 1;
  }
  for (int i = 0; i < 15; i++) if (property == ids[i]) return (OnibiAsciiProperty)i;
  return ONIBI_ASCII_PROP_UNKNOWN;
}

static OnibiAsciiProperty onibi_ascii_property_kind(VALUE name) {
  return NIL_P(name) ? ONIBI_ASCII_PROP_UNKNOWN :
    onibi_ascii_property_kind_id(rb_intern_str(name));
}

static int onibi_ascii_property_hit_kind(OnibiAsciiProperty kind, int c) {
  int ascii_alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
  int ascii_digit = c >= '0' && c <= '9';
  switch (kind) {
    case ONIBI_ASCII_PROP_ASCII: return c < 128;
    case ONIBI_ASCII_PROP_HEX: case ONIBI_ASCII_PROP_XDIGIT:
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
    case ONIBI_ASCII_PROP_PUNCT: return c >= 33 && c <= 126 && !ascii_alpha && !ascii_digit && c != '_';
    default: return -1;
  }
}

static int onibi_ascii_property_name_p(VALUE name) {
  if (NIL_P(name)) return 0;
  return onibi_ascii_property_kind(name) != ONIBI_ASCII_PROP_UNKNOWN;
}

static VALUE onibi_class_bitmap(VALUE payload, int fold) {
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
        if ((original[c >> 3] & (1U << (c & 7))) != 0) onibi_bitmap_set(bits, (unsigned char)c, 1);
      }
    }
    VALUE result = rb_str_new((const char *)bits, sizeof(bits));
    rb_obj_freeze(result);
    return result;
  }
  VALUE ranges = onibi_hash_value_id(payload, id_key_ranges);
  VALUE escape_name = onibi_hash_value_id(payload, id_key_name);
  if (!NIL_P(escape_name) && RSTRING_LEN(escape_name) == 1) {
    int upper = isupper((unsigned char)RSTRING_PTR(escape_name)[0]);
    int code = tolower((unsigned char)RSTRING_PTR(escape_name)[0]);
    for (int c = 0; c < 256; c++) {
      int hit = code == 'd' ? isdigit(c) : (code == 's' ? isspace(c) :
        (code == 'w' ? (isalnum(c) || c == '_') : (code == 'h' ? isxdigit(c) : 0)));
      if (upper ? !hit : hit) onibi_bitmap_set(bits, (unsigned char)c, fold);
    }
  } else {
    OnibiAsciiProperty property_kind = NIL_P(escape_name) ? ONIBI_ASCII_PROP_UNKNOWN :
      onibi_ascii_property_kind(escape_name);
    if (property_kind == ONIBI_ASCII_PROP_UNKNOWN) goto class_children;
    for (int c = 0; c < 256; c++) {
      int hit = onibi_ascii_property_hit_kind(property_kind, c);
      if (hit > 0) onibi_bitmap_set(bits, (unsigned char)c, fold);
    }
    if (NUM2INT(onibi_hash_value_id(payload, id_key_byte)) == 'P')
      for (long i = 0; i < 32; i++) bits[i] = (unsigned char)~bits[i];
  }
class_children:
  for (long i = 0; i < RARRAY_LEN(ranges); i++) {
    VALUE range = rb_ary_entry(ranges, i);
    if (RARRAY_LEN(range) != 2) continue;
    if (!RB_INTEGER_TYPE_P(rb_ary_entry(range, 0)) || !RB_INTEGER_TYPE_P(rb_ary_entry(range, 1))) continue;
    int first = NUM2INT(rb_ary_entry(range, 0));
    int last = NUM2INT(rb_ary_entry(range, 1));
    if (first < 0) first = 0; if (last > 255) last = 255;
    for (int c = first; c <= last; c++) onibi_bitmap_set(bits, (unsigned char)c, fold);
  }
  VALUE children = onibi_hash_value_id(payload, id_key_children);
  for (long i = 0; i < RARRAY_LEN(children); i++) {
    VALUE child = rb_ary_entry(children, i);
    OnibiTokenKind token_kind = NIL_P(onibi_hash_value_id(child, id_key_kind_code)) ?
      (OnibiTokenKind)-1 : onibi_token_kind_code(child);
    OnibiAstKind ast_kind = onibi_ast_kind(child);
    if (token_kind == ONIBI_TOKEN_LITERAL || ast_kind == ONIBI_AST_LITERAL) {
      onibi_bitmap_set(bits, (unsigned char)NUM2INT(onibi_hash_value_id(child, id_key_byte)), fold);
    } else if (token_kind == ONIBI_TOKEN_ESCAPE || token_kind == ONIBI_TOKEN_META_ESCAPE || ast_kind == ONIBI_AST_ESCAPE) {
      VALUE name = onibi_hash_value_id(child, id_key_name);
      VALUE name_id = onibi_hash_value_id(child, id_key_name_id);
      OnibiAsciiProperty property_kind = NIL_P(name_id) ? onibi_ascii_property_kind(name) :
        onibi_ascii_property_kind_id(NUM2ULONG(name_id));
      if (property_kind != ONIBI_ASCII_PROP_UNKNOWN) {
        for (int c = 0; c < 256; c++) {
          int hit = onibi_ascii_property_hit_kind(property_kind, c);
          if (hit > 0) onibi_bitmap_set(bits, (unsigned char)c, fold);
        }
        if (NUM2INT(onibi_hash_value_id(child, id_key_byte)) == 'P')
          for (long byte = 0; byte < 32; byte++) bits[byte] = (unsigned char)~bits[byte];
        continue;
      }
      int escape_code = NIL_P(name) ? tolower((unsigned char)NUM2INT(onibi_hash_value_id(child, id_key_byte))) :
        (RSTRING_LEN(name) == 1 ? tolower((unsigned char)RSTRING_PTR(name)[0]) : 0);
      if (escape_code == 'r' || escape_code == 'p' || escape_code == 'x' || escape_code == 'u')
        rb_raise(eRegexpError, "escape is not supported in RSeq class");
      int upper = NIL_P(name) ? isupper((unsigned char)NUM2INT(onibi_hash_value_id(child, id_key_byte))) :
        (RSTRING_LEN(name) == 1 && isupper((unsigned char)RSTRING_PTR(name)[0]));
      int code = escape_code;
      for (int c = 0; c < 256; c++) {
        int hit = code == 'd' ? isdigit(c) : (code == 's' ? isspace(c) :
          (code == 'w' ? (isalnum(c) || c == '_') : (code == 'h' ? isxdigit(c) : 0)));
        if (upper ? !hit : hit) onibi_bitmap_set(bits, (unsigned char)c, fold);
      }
    } else if (token_kind == ONIBI_TOKEN_POSIX_CLASS) {
      VALUE name = onibi_hash_value_id(child, id_key_name);
      VALUE name_id = onibi_hash_value_id(child, id_key_name_id);
      ID property = NIL_P(name_id) ? rb_intern_str(name) : (ID)NUM2ULONG(name_id);
      OnibiPosixKind posix = onibi_posix_kind_id(property);
      for (int c = 0; c < 256; c++) {
        int hit = posix == ONIBI_POSIX_ALPHA ? isalpha(c) :
          posix == ONIBI_POSIX_DIGIT ? isdigit(c) :
          posix == ONIBI_POSIX_ALNUM ? isalnum(c) :
          posix == ONIBI_POSIX_SPACE ? isspace(c) :
          posix == ONIBI_POSIX_BLANK ? (c == ' ' || c == '\t') :
          posix == ONIBI_POSIX_LOWER ? islower(c) :
          posix == ONIBI_POSIX_UPPER ? isupper(c) :
          posix == ONIBI_POSIX_WORD ? (isalnum(c) || c == '_') :
          posix == ONIBI_POSIX_XDIGIT ? isxdigit(c) : 0;
        if (hit) onibi_bitmap_set(bits, (unsigned char)c, fold);
      }
    } else if (ast_kind == ONIBI_AST_CHARACTER_CLASS || ast_kind == ONIBI_AST_CLASS_INTERSECTION) {
      VALUE nested = onibi_class_bitmap(child, fold);
      for (long byte = 0; byte < 32; byte++)
        bits[byte] |= (unsigned char)RSTRING_PTR(nested)[byte];
    }
  }
  if (RTEST(onibi_hash_value_id(payload, id_key_negated)))
    for (long i = 0; i < 32; i++) bits[i] = (unsigned char)~bits[i];
  VALUE bitmap = rb_str_new((const char *)bits, sizeof(bits));
  rb_obj_freeze(bitmap);
  return bitmap;
}

static int onibi_ast_has_capture(VALUE ast) {
  if (NIL_P(ast)) return 0;
  if (RB_TYPE_P(ast, T_ARRAY)) {
    for (long i = 0; i < RARRAY_LEN(ast); i++)
      if (onibi_ast_has_capture(rb_ary_entry(ast, i))) return 1;
    return 0;
  }
  if (!RB_TYPE_P(ast, T_HASH)) return 0;
  if (onibi_ast_kind(ast) == ONIBI_AST_CAPTURE) return 1;
  const ID keys[] = { id_key_body, id_key_children, id_key_branches, id_key_atom };
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
    if (onibi_ast_has_capture(onibi_hash_value_id(ast, keys[i]))) return 1;
  return 0;
}

static int onibi_ast_has_subroutine_name(VALUE ast, VALUE name) {
  if (NIL_P(ast)) return 0;
  if (RB_TYPE_P(ast, T_ARRAY)) {
    for (long i = 0; i < RARRAY_LEN(ast); i++)
      if (onibi_ast_has_subroutine_name(rb_ary_entry(ast, i), name)) return 1;
    return 0;
  }
  if (!RB_TYPE_P(ast, T_HASH)) return 0;
  if (onibi_ast_kind(ast) == ONIBI_AST_SUBROUTINE &&
      rb_equal(onibi_hash_value_id(ast, id_key_name), name)) return 1;
  const ID keys[] = {id_key_body, id_key_children, id_key_branches, id_key_atom};
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
    if (onibi_ast_has_subroutine_name(onibi_hash_value_id(ast, keys[i]), name)) return 1;
  return 0;
}

static OnibiPosixKind onibi_posix_kind_id(ID property) {
  static ID ids[9]; static int ready = 0;
  if (!ready) { const char *names[] = {"alpha", "digit", "alnum", "space", "blank", "lower", "upper", "word", "xdigit"}; for (size_t i = 0; i < 9; i++) ids[i] = rb_intern(names[i]); ready = 1; }
  for (int i = 0; i < 9; i++) if (property == ids[i]) return (OnibiPosixKind)(i + 1);
  return ONIBI_POSIX_UNKNOWN;
}

static void onibi_gir_state(onibi_gir_builder_t *builder, long id, ID op, VALUE payload) {
  OnibiGStateOp opcode = op == id_g_accept ? ONIBI_G_ACCEPT :
    op == id_g_char ? ONIBI_G_CHAR : op == id_g_class ? ONIBI_G_CLASS :
    op == id_g_any ? ONIBI_G_ANY : op == id_g_grapheme ? ONIBI_G_GRAPHEME :
    op == id_g_backref ? ONIBI_G_BACKREF : op == id_g_call ? ONIBI_G_CALL :
    op == id_g_atomic ? ONIBI_G_ATOMIC : op == id_g_absent ? ONIBI_G_ABSENT :
    (OnibiGStateOp)-1;
  onibi_gir_state_vector_push(&builder->states, (OnibiGirStateEntry){id, op, opcode, payload, 0}, builder->map_roots);
}

static void onibi_gir_edge(onibi_gir_builder_t *builder, long from, long to) {
  VALUE actions = rb_ary_new();
  VALUE guard = onibi_guard_vector_find(&builder->capture_guards, (OnibiStateId)to);
  if (!NIL_P(guard)) { VALUE merged = rb_ary_dup(guard); onibi_append_values(merged, actions); actions = merged; }
  VALUE exit_guard = onibi_guard_vector_find(&builder->exit_guards, (OnibiStateId)from);
  if (!NIL_P(exit_guard)) { VALUE merged = rb_ary_dup(exit_guard); onibi_append_values(merged, actions); actions = merged; }
  if (!NIL_P(guard)) { VALUE merged = rb_ary_dup(actions); onibi_append_values(merged, guard); actions = merged; }
  onibi_gir_edge_vector_push(&builder->edges, (OnibiGirEdgeEntry){from, to, 0, (uint32_t)RARRAY_LEN(actions), actions}, builder->map_roots);
}

static void onibi_gir_edge_actions(onibi_gir_builder_t *builder, long from, long to, VALUE actions) {
  for (size_t i = 0; i < builder->edges.count; i++) {
    OnibiGirEdgeEntry *prior = &builder->edges.entries[i];
    if (prior->from == from && prior->to == to) {
      VALUE prior_actions = prior->actions;
      VALUE merged_actions = rb_ary_dup(actions);
      onibi_append_values(merged_actions, prior_actions);
      prior->actions = merged_actions;
      rb_ary_push(builder->map_roots, merged_actions);
      return;
    }
  }
  VALUE guard = onibi_guard_vector_find(&builder->capture_guards, (OnibiStateId)to);
  if (!NIL_P(guard)) { VALUE merged = rb_ary_dup(guard); onibi_append_values(merged, actions); actions = merged; }
  VALUE exit_guard = onibi_guard_vector_find(&builder->exit_guards, (OnibiStateId)from);
  if (!NIL_P(exit_guard)) { VALUE merged = rb_ary_dup(exit_guard); onibi_append_values(merged, actions); actions = merged; }
  if (!NIL_P(guard)) { VALUE merged = rb_ary_dup(actions); onibi_append_values(merged, guard); actions = merged; }
  onibi_gir_edge_vector_push(&builder->edges, (OnibiGirEdgeEntry){from, to, 0, (uint32_t)RARRAY_LEN(actions), actions}, builder->map_roots);
}

static onibi_fragment_t onibi_fragment_empty(void) {
  onibi_fragment_t fragment;
  onibi_id_vector_init(&fragment.starts); onibi_id_vector_init(&fragment.exits);
  fragment.start_actions = rb_ary_new(); fragment.pending_actions = rb_ary_new(); fragment.nullable = 1; fragment.lazy = 0;
  return fragment;
}

static void onibi_connect_vector_actions(onibi_gir_builder_t *builder,
                                         const OnibiIdVector *exits,
                                         VALUE starts, VALUE actions) {
  VALUE *start_values = RARRAY_PTR(starts);
  long start_count = RARRAY_LEN(starts);
  for (size_t i = 0; i < exits->count; i++)
    for (long j = 0; j < start_count; j++)
      onibi_gir_edge_actions(builder, (long)exits->items[i], NUM2LONG(start_values[j]), actions);
}

static void onibi_connect_vector_prepend_actions(onibi_gir_builder_t *builder,
                                                 const OnibiIdVector *exits,
                                                 VALUE starts, VALUE actions) {
  VALUE *start_values = RARRAY_PTR(starts);
  long start_count = RARRAY_LEN(starts);
  for (size_t i = 0; i < exits->count; i++) {
    long from = (long)exits->items[i];
    for (long j = 0; j < start_count; j++) {
      size_t insert_at = builder->edges.count;
      for (size_t k = 0; k < builder->edges.count; k++) {
        if (builder->edges.entries[k].from == from) { insert_at = k; break; }
      }
      onibi_gir_edge_vector_insert(&builder->edges, insert_at,
                                   (OnibiGirEdgeEntry){from, NUM2LONG(start_values[j]), 0, (uint32_t)RARRAY_LEN(actions), actions},
                                   builder->map_roots);
    }
  }
}

/* Fragment composition still stores Ruby arrays, but all numeric exit
 * traversal goes through the C vector boundary. */
static void onibi_connect_fragment_actions(onibi_gir_builder_t *builder,
                                           const OnibiIdVector *exits, const OnibiIdVector *starts, VALUE actions,
                                           int prepend) {
  VALUE start_values = rb_ary_new_capa((long)starts->count);
  for (size_t i = 0; i < starts->count; i++) rb_ary_push(start_values, ULONG2NUM(starts->items[i]));
  if (prepend) onibi_connect_vector_prepend_actions(builder, exits, start_values, actions);
  else onibi_connect_vector_actions(builder, exits, start_values, actions);
}

static void onibi_connect_fragment(onibi_gir_builder_t *builder, const OnibiIdVector *exits, const OnibiIdVector *starts) {
  for (size_t i = 0; i < exits->count; i++)
    for (size_t j = 0; j < starts->count; j++)
      onibi_gir_edge(builder, (long)exits->items[i], (long)starts->items[j]);
}

static void onibi_append_values(VALUE destination, VALUE values) {
  VALUE *items = RARRAY_PTR(values);
  long count = RARRAY_LEN(values);
  for (long i = 0; i < count; i++) rb_ary_push(destination, items[i]);
}

static void onibi_add_capture_guard_fragment(onibi_gir_builder_t *builder,
                                             const OnibiIdVector *starts, VALUE guard) {
  for (size_t i = 0; i < starts->count; i++) {
    onibi_guard_vector_add(&builder->capture_guards, starts->items[i], guard, builder->map_roots);
  }
}

static void onibi_add_exit_guard_fragment(onibi_gir_builder_t *builder,
                                          const OnibiIdVector *exits, VALUE actions) {
  for (size_t i = 0; i < exits->count; i++) {
    onibi_guard_vector_add(&builder->exit_guards, exits->items[i], actions, builder->map_roots);
  }
}

static VALUE onibi_capture_test_action(long slot, int set) {
  VALUE action = rb_hash_new();
  rb_hash_aset(action, ID2SYM(id_key_op), ID2SYM(id_a_test_capture));
  onibi_set_gir_action_opcode(action, id_a_test_capture);
  rb_hash_aset(action, ID2SYM(id_key_slot), LONG2NUM(slot));
  rb_hash_aset(action, ID2SYM(id_key_set), set ? Qtrue : Qfalse);
  return action;
}

static VALUE onibi_counter_action(ID op, long slot, VALUE limit) {
  VALUE action = rb_hash_new();
  rb_hash_aset(action, ID2SYM(id_key_op), ID2SYM(op));
  onibi_set_gir_action_opcode(action, op);
  rb_hash_aset(action, ID2SYM(id_key_slot), LONG2NUM(slot));
  if (!NIL_P(limit)) rb_hash_aset(action, ID2SYM(id_key_limit), limit);
  if (op == id_a_counter_init)
    rb_hash_aset(action, ID2SYM(id_key_value), INT2NUM(1));
  return action;
}

static void onibi_materialize_gir(onibi_gir_builder_t *builder, VALUE *states_out, VALUE *edges_out) {
  VALUE states = rb_ary_new_capa((long)builder->states.count);
  for (size_t i = 0; i < builder->states.count; i++) {
    OnibiGirStateEntry *entry = &builder->states.entries[i];
    VALUE state = rb_hash_new();
    rb_hash_aset(state, ID2SYM(id_key_id), LONG2NUM(entry->id));
    rb_hash_aset(state, ID2SYM(id_key_op), ID2SYM(entry->op));
    if (entry->opcode >= ONIBI_G_ACCEPT) rb_hash_aset(state, ID2SYM(id_key_opcode), UINT2NUM(entry->opcode));
    rb_hash_aset(state, ID2SYM(id_key_payload), entry->payload);
    rb_obj_freeze(state); rb_ary_push(states, state);
  }
  VALUE edges = rb_ary_new_capa((long)builder->edges.count);
  for (size_t i = 0; i < builder->edges.count; i++) {
    OnibiGirEdgeEntry *entry = &builder->edges.entries[i];
    VALUE edge = rb_hash_new();
    rb_hash_aset(edge, ID2SYM(id_key_from), LONG2NUM(entry->from));
    rb_hash_aset(edge, ID2SYM(id_key_to), LONG2NUM(entry->to));
    rb_obj_freeze(entry->actions);
    rb_hash_aset(edge, ID2SYM(id_key_actions), entry->actions);
    rb_obj_freeze(edge); rb_ary_push(edges, edge);
  }
  rb_obj_freeze(states); rb_obj_freeze(edges);
  *states_out = states; *edges_out = edges;
}

static onibi_fragment_t onibi_compile_node(VALUE ast, onibi_gir_builder_t *builder);
static void onibi_gir_state(onibi_gir_builder_t *builder, long id, ID op, VALUE payload);
static VALUE onibi_class_payload_with_ctypes(VALUE payload);
static int onibi_unicode_ctype_id(ID property);

typedef struct { VALUE graph; int options; } OnibiCompiled;
static void onibi_compiled_mark(void *ptr) {
  OnibiCompiled *compiled = (OnibiCompiled *)ptr;
  if (compiled) rb_gc_mark(compiled->graph);
}
static void onibi_compiled_free(void *ptr) { xfree(ptr); }
static size_t onibi_compiled_memsize(const void *ptr) { return ptr ? sizeof(OnibiCompiled) : 0; }
static const rb_data_type_t onibi_compiled_type = {
  "Onibi::Compiled", { onibi_compiled_mark, onibi_compiled_free, onibi_compiled_memsize, NULL, { NULL } },
  0, 0, RUBY_TYPED_FREE_IMMEDIATELY
};
static inline OnibiCompiled *onibi_compiled_get(VALUE value) {
  OnibiCompiled *compiled;
  TypedData_Get_Struct(value, OnibiCompiled, &onibi_compiled_type, compiled);
  return compiled;
}

static long onibi_compile_subprogram(VALUE body, onibi_gir_builder_t *builder, uint32_t flags) {
  onibi_fragment_t fragment = onibi_compile_node(body, builder);
  long accept = builder->next_id++;
  onibi_gir_state(builder, accept, id_g_accept, Qnil);
  OnibiIdVector accept_starts;
  onibi_id_vector_init(&accept_starts);
  onibi_id_vector_push(&accept_starts, (OnibiStateId)accept);
  onibi_connect_fragment_actions(builder, &fragment.exits, &accept_starts, fragment.pending_actions, 0);
  long entry = fragment.starts.count > 0 ? (long)fragment.starts.items[0] : accept;
  VALUE descriptor = rb_hash_new();
    rb_hash_aset(descriptor, ID2SYM(id_key_entry), LONG2NUM(entry));
    rb_hash_aset(descriptor, ID2SYM(id_key_accept), LONG2NUM(accept));
    rb_hash_aset(descriptor, ID2SYM(id_key_flags), UINT2NUM(flags));
    rb_hash_aset(descriptor, ID2SYM(id_key_entry_actions), onibi_deep_freeze(rb_ary_dup(fragment.start_actions)));
  rb_obj_freeze(descriptor);
  rb_ary_push(builder->subprograms, descriptor);
  onibi_id_vector_free(&fragment.starts);
  onibi_id_vector_free(&fragment.exits);
  onibi_id_vector_free(&accept_starts);
  return RARRAY_LEN(builder->subprograms) - 1;
}

static void onibi_collect_captures(VALUE ast, onibi_gir_builder_t *builder, long *next_capture) {
  if (!RB_TYPE_P(ast, T_HASH)) return;
  OnibiAstKind type = onibi_ast_kind(ast);
  if (type == ONIBI_AST_CAPTURE) {
    VALUE start = onibi_hash_value_id(ast, id_key_start);
    VALUE id_value = onibi_value_map_find(&builder->capture_ids, start);
    long id;
    if (NIL_P(id_value)) {
      id = (*next_capture)++;
      onibi_value_map_set(&builder->capture_ids, start, LONG2NUM(id), builder->map_roots);
    } else id = NUM2LONG(id_value);
    VALUE key = rb_str_new_cstr("");
    char number[32];
    snprintf(number, sizeof(number), "%ld", id + 1);
    key = rb_str_new_cstr(number);
    onibi_value_map_set(&builder->capture_bodies, key, onibi_hash_value_id(ast, id_key_body), builder->map_roots);
    VALUE name = onibi_hash_value_id(ast, id_key_name);
    if (!NIL_P(name)) {
      if (!NIL_P(onibi_value_map_find(&builder->capture_names, name)))
        rb_raise(eRegexpError, "duplicate named capture requires compatibility execution");
      /* MRI resolves a duplicate named backreference to the first matching
         group definition.  Keep the earliest slot in the compile index. */
      onibi_value_map_set(&builder->capture_names, name, LONG2NUM(id), builder->map_roots);
      onibi_value_map_set(&builder->capture_bodies, name, onibi_hash_value_id(ast, id_key_body), builder->map_roots);
    }
    onibi_collect_captures(onibi_hash_value_id(ast, id_key_body), builder, next_capture);
    return;
  }
  const ID keys[] = { id_key_body, id_key_children, id_key_branches, id_key_atom, id_key_yes, id_key_no };
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
    VALUE child = onibi_hash_value_id(ast, keys[i]);
    if (RB_TYPE_P(child, T_ARRAY))
      for (long j = 0; j < RARRAY_LEN(child); j++) onibi_collect_captures(rb_ary_entry(child, j), builder, next_capture);
    else onibi_collect_captures(child, builder, next_capture);
  }
}

static long onibi_compile_named_subprogram(VALUE name, VALUE body,
                                           onibi_gir_builder_t *builder) {
  long id = RARRAY_LEN(builder->subprograms);
  rb_ary_push(builder->subprograms, Qnil); /* reserve the recursive target */
  onibi_value_map_set(&builder->subprogram_ids, name, LONG2NUM(id), builder->map_roots);
  onibi_value_map_set(&builder->active_subroutines, name, Qtrue, builder->map_roots);
  onibi_fragment_t fragment = onibi_compile_node(body, builder);
  onibi_value_map_delete(&builder->active_subroutines, name);
  VALUE capture_id_value = onibi_value_map_find(&builder->capture_names, name);
  if (!NIL_P(capture_id_value)) {
    long capture_id = NUM2LONG(capture_id_value);
    VALUE open = rb_hash_new(), close = rb_hash_new();
    rb_hash_aset(open, ID2SYM(id_key_op), ID2SYM(id_capture_open));
    onibi_set_gir_action_opcode(open, id_capture_open);
    rb_hash_aset(open, ID2SYM(id_key_slot), LONG2NUM(2 * capture_id));
    rb_hash_aset(close, ID2SYM(id_key_op), ID2SYM(id_capture_close));
    onibi_set_gir_action_opcode(close, id_capture_close);
    rb_hash_aset(close, ID2SYM(id_key_slot), LONG2NUM(2 * capture_id + 1));
    if (onibi_ast_has_subroutine_name(body, name))
      rb_hash_aset(close, ID2SYM(id_key_preserve_if_set), Qtrue);
    VALUE starts = rb_ary_new_from_args(1, open);
    onibi_append_values(starts, fragment.start_actions);
    fragment.start_actions = starts;
    VALUE exits = rb_ary_new_from_args(1, close);
    onibi_append_values(exits, fragment.pending_actions);
    fragment.pending_actions = exits;
  }
  long accept = builder->next_id++;
  onibi_gir_state(builder, accept, id_g_accept, Qnil);
  OnibiIdVector accept_starts;
  onibi_id_vector_single(&accept_starts, (OnibiStateId)accept);
  onibi_connect_fragment_actions(builder, &fragment.exits, &accept_starts,
                                 fragment.pending_actions, 0);
  long entry = fragment.starts.count > 0 ? (long)fragment.starts.items[0] : accept;
  VALUE descriptor = rb_hash_new();
    rb_hash_aset(descriptor, ID2SYM(id_key_entry), LONG2NUM(entry));
    rb_hash_aset(descriptor, ID2SYM(id_key_accept), LONG2NUM(accept));
    rb_hash_aset(descriptor, ID2SYM(id_key_flags), INT2NUM(0));
    rb_hash_aset(descriptor, ID2SYM(id_key_entry_actions), onibi_deep_freeze(rb_ary_dup(fragment.start_actions)));
  rb_obj_freeze(descriptor);
  rb_ary_store(builder->subprograms, id, descriptor);
  onibi_id_vector_free(&fragment.starts);
  onibi_id_vector_free(&fragment.exits);
  onibi_id_vector_free(&accept_starts);
  return id;
}

static OnibiGActionOp onibi_gir_action_opcode(ID op) {
  if (op == id_a_end) return ONIBI_GA_END;
  if (op == id_capture_open) return ONIBI_GA_CAPTURE_OPEN;
  if (op == id_capture_close) return ONIBI_GA_CAPTURE_CLOSE;
  if (op == id_match_reset) return ONIBI_GA_MATCH_RESET;
  if (op == id_a_assert_begin_buffer || op == id_a_assert_end_buffer ||
      op == id_a_assert_begin_line || op == id_a_assert_end_line ||
      op == id_a_assert_semi_end_buffer || op == id_a_assert_search_origin ||
      op == id_a_assert_word_boundary || op == id_a_assert_nonword_boundary ||
      op == id_a_assert_lookahead || op == id_a_assert_lookbehind)
    return ONIBI_GA_ASSERT_POSITION;
  if (op == id_a_test_capture) return ONIBI_GA_TEST_CAPTURE;
  if (op == id_a_counter_init) return ONIBI_GA_COUNTER_INIT;
  if (op == id_a_counter_increment) return ONIBI_GA_COUNTER_INCREMENT;
  if (op == id_a_test_counter_lt) return ONIBI_GA_TEST_COUNTER_LT;
  if (op == id_a_test_counter_ge) return ONIBI_GA_TEST_COUNTER_GE;
  return (OnibiGActionOp)UINT8_MAX;
}

static void onibi_set_gir_action_opcode(VALUE action, ID op) {
  OnibiGActionOp code = onibi_gir_action_opcode(op);
  rb_hash_aset(action, ID2SYM(id_key_action_code), UINT2NUM((unsigned int)code));
  if (code == ONIBI_GA_ASSERT_POSITION) {
    uint16_t subtype = onibi_rseq_assert_kind(op);
    if (subtype != 0) rb_hash_aset(action, ID2SYM(id_key_assert_kind), UINT2NUM(subtype));
  }
}

static void onibi_gir_validate_action_operands(VALUE action) {
  VALUE code_value = onibi_hash_value_id(action, id_key_action_code);
  if (NIL_P(code_value)) rb_raise(eRegexpError, "GIR action opcode is missing");
  OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(code_value);
  VALUE slot = onibi_hash_value_id(action, id_key_slot);
  if (code == ONIBI_GA_CAPTURE_OPEN || code == ONIBI_GA_CAPTURE_CLOSE) {
    if (NIL_P(slot) || NUM2LONG(slot) < 0)
      rb_raise(eRegexpError, "invalid GIR capture slot");
  } else if (code == ONIBI_GA_TEST_CAPTURE || code == ONIBI_GA_COUNTER_INIT ||
             code == ONIBI_GA_COUNTER_INCREMENT || code == ONIBI_GA_TEST_COUNTER_LT ||
             code == ONIBI_GA_TEST_COUNTER_GE) {
    if (NIL_P(slot) || NUM2LONG(slot) < 0)
      rb_raise(eRegexpError, "invalid GIR counter slot");
  }
  if (code == ONIBI_GA_TEST_COUNTER_LT || code == ONIBI_GA_TEST_COUNTER_GE) {
    VALUE limit = onibi_hash_value_id(action, id_key_limit);
    if (NIL_P(limit) || NUM2LONG(limit) < 0)
      rb_raise(eRegexpError, "invalid GIR counter limit");
  }
  if (code == ONIBI_GA_ASSERT_POSITION) {
    VALUE assert_kind = onibi_hash_value_id(action, id_key_assert_kind);
    if (NIL_P(assert_kind) || NUM2ULONG(assert_kind) < ONIBI_RAP_BEGIN_BUFFER ||
        NUM2ULONG(assert_kind) > ONIBI_RAP_LOOKBEHIND)
      rb_raise(eRegexpError, "invalid GIR assertion subtype");
  }
}

static void onibi_gir_validate(VALUE graph) {
  VALUE states = onibi_hash_value_id(graph, id_key_states);
  VALUE edges = onibi_hash_value_id(graph, id_key_edges);
  VALUE starts = onibi_hash_value_id(graph, id_key_start_edges);
  VALUE subprograms = onibi_hash_value_id(graph, id_key_subprograms);
  long capture_count = NUM2LONG(onibi_hash_value_id(graph, id_key_capture_count));
  long counter_count = NUM2LONG(onibi_hash_value_id(graph, id_key_counter_count));
  long state_count = RARRAY_LEN(states);
  if (!RB_TYPE_P(subprograms, T_ARRAY) || !RTEST(rb_obj_frozen_p(subprograms)))
    rb_raise(eRegexpError, "GIR subprogram table is not immutable");
  for (long i = 0; i < RARRAY_LEN(subprograms); i++) {
    VALUE entry = rb_ary_entry(subprograms, i);
    if (!RB_TYPE_P(entry, T_HASH)) rb_raise(eRegexpError, "GIR subprogram descriptor is not a hash");
    VALUE entry_state = onibi_hash_value_id(entry, id_key_entry);
    VALUE accept_state = onibi_hash_value_id(entry, id_key_accept);
    VALUE flags = onibi_hash_value_id(entry, id_key_flags);
    if (NIL_P(entry_state) || NIL_P(accept_state) || NIL_P(flags) ||
        NUM2LONG(entry_state) < 0 || NUM2LONG(entry_state) >= state_count ||
        NUM2LONG(accept_state) < 0 || NUM2LONG(accept_state) >= state_count ||
        NUM2LONG(flags) < 0)
      rb_raise(eRegexpError, "GIR subprogram entry is out of range");
  }
  VALUE accept_value = onibi_hash_value_id(graph, id_key_accept);
  if (NIL_P(accept_value)) rb_raise(eRegexpError, "GIR accept state is missing");
  long accept = NUM2LONG(accept_value);
  if (accept < 0 || accept >= state_count)
    rb_raise(eRegexpError, "GIR accept state is out of range");
  for (long i = 0; i < state_count; i++) {
    VALUE state = rb_ary_entry(states, i);
    if (NUM2LONG(onibi_hash_value_id(state, id_key_id)) != (long)i)
      rb_raise(eRegexpError, "GIR state ids are not contiguous");
    VALUE opcode_value = onibi_hash_value_id(state, id_key_opcode);
    if (NIL_P(opcode_value)) rb_raise(eRegexpError, "GIR state opcode is missing");
    unsigned int opcode = NUM2UINT(opcode_value);
    if (opcode > ONIBI_G_ABSENT)
      rb_raise(eRegexpError, "unknown GIR state opcode");
    if (i == accept && opcode != ONIBI_G_ACCEPT)
      rb_raise(eRegexpError, "GIR accept state has a non-accept opcode");
    if (opcode == ONIBI_G_BACKREF) {
      VALUE capture = onibi_hash_value_id(onibi_hash_value_id(state, id_key_payload), id_key_capture);
      if (NIL_P(capture) || NUM2LONG(capture) < 1 || NUM2LONG(capture) > capture_count)
        rb_raise(eRegexpError, "GIR backreference capture is out of range");
    }
  }
  for (long i = 0; i < RARRAY_LEN(edges); i++) {
    VALUE edge = rb_ary_entry(edges, i);
    long from = NUM2LONG(onibi_hash_value_id(edge, id_key_from));
    long to = NUM2LONG(onibi_hash_value_id(edge, id_key_to));
    if (from < 0 || from >= state_count || to < 0 || to >= state_count)
      rb_raise(eRegexpError, "GIR edge is out of range");
    if (!RB_TYPE_P(onibi_hash_value_id(edge, id_key_actions), T_ARRAY))
      rb_raise(eRegexpError, "GIR edge actions are not an array");
    VALUE actions = onibi_hash_value_id(edge, id_key_actions);
    for (long j = 0; j < RARRAY_LEN(actions); j++) {
      VALUE action_value = rb_ary_entry(actions, j);
      VALUE code_value = onibi_hash_value_id(action_value, id_key_action_code);
      if (NIL_P(code_value) || NUM2UINT(code_value) > ONIBI_GA_TEST_COUNTER_GE)
        rb_raise(eRegexpError, "unknown GIR edge action opcode");
      onibi_gir_validate_action_operands(action_value);
      VALUE slot = onibi_hash_value_id(action_value, id_key_slot);
      OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(code_value);
      if ((code == ONIBI_GA_CAPTURE_OPEN || code == ONIBI_GA_CAPTURE_CLOSE) &&
          NUM2LONG(slot) >= capture_count * 2)
        rb_raise(eRegexpError, "GIR capture slot is out of range");
      if ((code == ONIBI_GA_COUNTER_INIT || code == ONIBI_GA_COUNTER_INCREMENT ||
           code == ONIBI_GA_TEST_COUNTER_LT || code == ONIBI_GA_TEST_COUNTER_GE) &&
          NUM2LONG(slot) >= counter_count)
        rb_raise(eRegexpError, "GIR counter slot is out of range");
    }
  }
  for (long i = 0; i < RARRAY_LEN(starts); i++) {
    VALUE edge = rb_ary_entry(starts, i);
    long to = NUM2LONG(onibi_hash_value_id(edge, id_key_to));
    if (to < 0 || to >= state_count)
      rb_raise(eRegexpError, "GIR start edge is out of range");
    if (!RB_TYPE_P(onibi_hash_value_id(edge, id_key_actions), T_ARRAY))
      rb_raise(eRegexpError, "GIR start actions are not an array");
    VALUE actions = onibi_hash_value_id(edge, id_key_actions);
    for (long j = 0; j < RARRAY_LEN(actions); j++) {
      VALUE action_value = rb_ary_entry(actions, j);
      VALUE code_value = onibi_hash_value_id(action_value, id_key_action_code);
      if (NIL_P(code_value) || NUM2UINT(code_value) > ONIBI_GA_TEST_COUNTER_GE)
        rb_raise(eRegexpError, "unknown GIR start action opcode");
      onibi_gir_validate_action_operands(action_value);
      VALUE slot = onibi_hash_value_id(action_value, id_key_slot);
      OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(code_value);
      if ((code == ONIBI_GA_CAPTURE_OPEN || code == ONIBI_GA_CAPTURE_CLOSE) &&
          NUM2LONG(slot) >= capture_count * 2)
        rb_raise(eRegexpError, "GIR capture slot is out of range");
      if ((code == ONIBI_GA_COUNTER_INIT || code == ONIBI_GA_COUNTER_INCREMENT ||
           code == ONIBI_GA_TEST_COUNTER_LT || code == ONIBI_GA_TEST_COUNTER_GE) &&
          NUM2LONG(slot) >= counter_count)
        rb_raise(eRegexpError, "GIR counter slot is out of range");
    }
  }
}

static onibi_fragment_t onibi_compile_sequence(VALUE children, onibi_gir_builder_t *builder) {
  onibi_fragment_t result = onibi_fragment_empty();
  int have_consuming = 0;
  for (long i = 0; i < RARRAY_LEN(children); i++) {
    onibi_fragment_t part = onibi_compile_node(rb_ary_entry(children, i), builder);
    if (part.starts.count == 0) {
      if (have_consuming) {
        onibi_append_values(result.pending_actions, part.start_actions);
        onibi_append_values(result.pending_actions, part.pending_actions);
      } else {
        onibi_append_values(result.start_actions, part.start_actions);
        onibi_append_values(result.start_actions, part.pending_actions);
      }
      result.nullable = result.nullable && part.nullable;
      onibi_id_vector_free(&part.starts);
      onibi_id_vector_free(&part.exits);
      continue;
    }
    if (!have_consuming) {
      onibi_id_vector_move(&result.starts, &part.starts);
      onibi_id_vector_move(&result.exits, &part.exits);
      onibi_append_values(result.start_actions, part.start_actions);
      result.lazy = part.lazy;
      have_consuming = 1;
    } else {
      OnibiIdVector old_exits = result.exits;
      onibi_id_vector_init(&result.exits);
      if (result.nullable) {
        if (result.lazy) {
          OnibiIdVector reordered;
          onibi_id_vector_init(&reordered);
          onibi_id_vector_append(&reordered, &part.starts);
          onibi_id_vector_append(&reordered, &result.starts);
          onibi_id_vector_free(&result.starts);
          result.starts = reordered;
        } else onibi_id_vector_append(&result.starts, &part.starts);
      }
      VALUE transition_actions = rb_ary_dup(result.pending_actions);
      onibi_append_values(transition_actions, part.start_actions);
      onibi_connect_fragment_actions(builder, &old_exits, &part.starts, transition_actions, result.lazy);
      onibi_id_vector_move(&result.exits, &part.exits);
      /* A prior exit can bypass this part only when this part is nullable. */
      if (part.nullable) onibi_id_vector_append(&result.exits, &old_exits);
      onibi_id_vector_free(&old_exits);
      result.pending_actions = rb_ary_new();
      result.lazy = part.lazy;
    }
    onibi_append_values(result.pending_actions, part.pending_actions);
    result.nullable = result.nullable && part.nullable;
  }
  return result;
}

static onibi_fragment_t onibi_compile_node(VALUE ast, onibi_gir_builder_t *builder) {
  OnibiAstKind type_code = onibi_ast_kind(ast);
  if (type_code == ONIBI_AST_CHARACTER_CLASS) {
    VALUE children = onibi_hash_value_id(ast, id_key_children);
    VALUE ranges = onibi_hash_value_id(ast, id_key_ranges);
    if (!RTEST(onibi_hash_value_id(ast, id_key_negated)) && RB_TYPE_P(children, T_ARRAY) &&
        RARRAY_LEN(ranges) == 0 && RARRAY_LEN(children) > 0) {
      int literal_only = 1;
      for (long i = 0; i < RARRAY_LEN(children); i++) {
        VALUE child = rb_ary_entry(children, i);
        if (NUM2UINT(onibi_hash_value_id(child, id_key_kind_code)) != ONIBI_TOKEN_LITERAL) {
          literal_only = 0;
          break;
        }
      }
      int has_multibyte = 0;
      for (long i = 0; literal_only && i < RARRAY_LEN(children); i++) {
        VALUE bytes = onibi_hash_value_id(rb_ary_entry(children, i), id_key_bytes);
        if (!NIL_P(bytes) && RSTRING_LEN(bytes) > 1) has_multibyte = 1;
      }
      if (literal_only && has_multibyte) {
        /* A literal-only class is an ordered union of encoded literals.
           Each branch lowers to one or more G_CHAR states. */
        onibi_fragment_t result = onibi_fragment_empty();
        result.nullable = 0;
        for (long i = 0; i < RARRAY_LEN(children); i++) {
          VALUE child = rb_hash_dup(rb_ary_entry(children, i));
          rb_hash_aset(child, ID2SYM(id_key_type_code), UINT2NUM(ONIBI_AST_LITERAL));
          onibi_fragment_t branch = onibi_compile_node(child, builder);
          onibi_id_vector_append(&result.starts, &branch.starts);
          onibi_id_vector_append(&result.exits, &branch.exits);
          onibi_id_vector_free(&branch.starts); onibi_id_vector_free(&branch.exits);
        }
        return result;
      }
    }
    if (!RTEST(onibi_hash_value_id(ast, id_key_negated)) && RB_TYPE_P(children, T_ARRAY) &&
        RB_TYPE_P(ranges, T_ARRAY) && RARRAY_LEN(ranges) > 0 && RARRAY_LEN(ranges) <= 4) {
      int literal_children = 1;
      for (long i = 0; i < RARRAY_LEN(children); i++)
        if (NUM2UINT(onibi_hash_value_id(rb_ary_entry(children, i), id_key_kind_code)) != ONIBI_TOKEN_LITERAL) literal_children = 0;
      if (!literal_children) goto skip_utf8_range_expansion;
      onibi_fragment_t result = onibi_fragment_empty();
      result.nullable = 0;
      int expandable = 1; long expanded = 0;
      for (long i = 0; i < RARRAY_LEN(children); i++) {
        VALUE child = rb_hash_dup(rb_ary_entry(children, i));
        rb_hash_aset(child, ID2SYM(id_key_type_code), UINT2NUM(ONIBI_AST_LITERAL));
        onibi_fragment_t branch = onibi_compile_node(child, builder);
        onibi_id_vector_append(&result.starts, &branch.starts);
        onibi_id_vector_append(&result.exits, &branch.exits);
        onibi_id_vector_free(&branch.starts); onibi_id_vector_free(&branch.exits);
      }
      for (long i = 0; i < RARRAY_LEN(ranges); i++) {
        VALUE range = rb_ary_entry(ranges, i);
        uint32_t first = 0, last = 0;
        if (!RB_TYPE_P(range, T_ARRAY) || RARRAY_LEN(range) != 2 ||
            !RB_TYPE_P(rb_ary_entry(range, 0), T_STRING) || !RB_TYPE_P(rb_ary_entry(range, 1), T_STRING) ||
            !onibi_utf8_decode(rb_ary_entry(range, 0), &first) || !onibi_utf8_decode(rb_ary_entry(range, 1), &last) ||
            last < first || last - first > 256U) { expandable = 0; break; }
        expanded += (long)(last - first + 1U);
        if (expanded > 256) { expandable = 0; break; }
        for (uint32_t cp = first; cp <= last; cp++) {
          VALUE literal = rb_hash_new();
          VALUE bytes = onibi_utf8_encode(cp);
          rb_hash_aset(literal, ID2SYM(id_key_type_code), UINT2NUM(ONIBI_AST_LITERAL));
          rb_hash_aset(literal, ID2SYM(id_key_byte), INT2NUM((unsigned char)RSTRING_PTR(bytes)[0]));
          rb_hash_aset(literal, ID2SYM(id_key_bytes), bytes);
          onibi_fragment_t branch = onibi_compile_node(literal, builder);
          onibi_id_vector_append(&result.starts, &branch.starts);
          onibi_id_vector_append(&result.exits, &branch.exits);
          onibi_id_vector_free(&branch.starts); onibi_id_vector_free(&branch.exits);
          if (cp == last) break;
        }
      }
      if (expandable) return result;
    }
skip_utf8_range_expansion:
    ;
  }
  /* A tokenizer literal can contain one encoded UTF-8 character.  Lower its
     bytes as a short sequence of G_CHAR states.  The VM still reports byte
     offsets, and the encoding gate below limits this path to valid UTF-8. */
  if (type_code == ONIBI_AST_LITERAL) {
    VALUE literal_bytes = onibi_hash_value_id(ast, id_key_bytes);
    if (!NIL_P(literal_bytes) && RSTRING_LEN(literal_bytes) > 1) {
      onibi_fragment_t result = onibi_fragment_empty();
      result.nullable = 0;
      for (long i = 0; i < RSTRING_LEN(literal_bytes); i++) {
        VALUE byte_ast = rb_hash_dup(ast);
        rb_hash_aset(byte_ast, ID2SYM(id_key_byte),
                     INT2NUM((unsigned char)RSTRING_PTR(literal_bytes)[i]));
        rb_hash_aset(byte_ast, ID2SYM(id_key_bytes),
                     rb_str_new(RSTRING_PTR(literal_bytes) + i, 1));
        onibi_fragment_t part = onibi_compile_node(byte_ast, builder);
      if (i == 0) onibi_id_vector_move(&result.starts, &part.starts);
      else onibi_connect_fragment(builder, &result.exits, &part.starts);
      if (i != 0) onibi_id_vector_free(&part.starts);
      onibi_id_vector_move(&result.exits, &part.exits);
      }
      return result;
    }
  }
  if (type_code == ONIBI_AST_SEQUENCE)
    return onibi_compile_sequence(onibi_hash_value_id(ast, id_key_children), builder);
  if (type_code == ONIBI_AST_ALTERNATIVE) {
    onibi_fragment_t result = onibi_fragment_empty();
    result.nullable = 0;
    VALUE branches = onibi_hash_value_id(ast, id_key_branches);
    for (long i = 0; i < RARRAY_LEN(branches); i++) {
      onibi_fragment_t branch = onibi_compile_node(rb_ary_entry(branches, i), builder);
      onibi_id_vector_append(&result.starts, &branch.starts);
      onibi_id_vector_append(&result.exits, &branch.exits);
      /* Preserve actions on each alternative edge.  A branch action cannot
         be lifted to the fragment because that would apply it to siblings. */
      if (RARRAY_LEN(branch.start_actions) > 0)
        onibi_add_capture_guard_fragment(builder, &branch.starts, branch.start_actions);
      if (RARRAY_LEN(branch.pending_actions) > 0)
        onibi_add_exit_guard_fragment(builder, &branch.exits, branch.pending_actions);
      result.nullable = result.nullable || branch.nullable;
      onibi_id_vector_free(&branch.starts); onibi_id_vector_free(&branch.exits);
    }
    return result;
  }
  if (type_code == ONIBI_AST_LITERAL || type_code == ONIBI_AST_ESCAPE ||
      type_code == ONIBI_AST_BACKREF || type_code == ONIBI_AST_CHARACTER_CLASS ||
      type_code == ONIBI_AST_CLASS_INTERSECTION || type_code == ONIBI_AST_ANY) {
    VALUE literal_bytes = onibi_hash_value_id(ast, id_key_bytes);
    if (type_code == ONIBI_AST_LITERAL && !NIL_P(literal_bytes) && RSTRING_LEN(literal_bytes) != 1)
      rb_raise(eRegexpError, "multibyte literals require encoded GIR states");
    if (type_code == ONIBI_AST_ESCAPE) {
      VALUE name = onibi_hash_value_id(ast, id_key_name);
      VALUE name_id = onibi_hash_value_id(ast, id_key_name_id);
      int is_property = !NIL_P(name_id) ?
        (onibi_ascii_property_kind_id(NUM2ULONG(name_id)) != ONIBI_ASCII_PROP_UNKNOWN) :
        onibi_ascii_property_name_p(name);
      if (!NIL_P(name) && RSTRING_LEN(name) > 1 && !is_property)
        rb_raise(eRegexpError, "Unicode property escapes require encoded GIR classes");
      int code = NIL_P(name) ? 0 : (RSTRING_LEN(name) == 1 ?
        tolower((unsigned char)RSTRING_PTR(name)[0]) : 0);
      if ((NIL_P(name) || RSTRING_LEN(name) <= 1) &&
          (code == 'r' || code == 'p' || code == 'u'))
        rb_raise(eRegexpError, "escape is not supported in RSeq");
    }
    VALUE payload = ast;
    if (type_code == ONIBI_AST_BACKREF && !NIL_P(onibi_hash_value_id(ast, id_key_name))) {
      VALUE id_value = onibi_value_map_find(&builder->capture_names, onibi_hash_value_id(ast, id_key_name));
      if (NIL_P(id_value)) rb_raise(eRegexpError, "undefined named backreference");
      payload = rb_hash_dup(ast);
      rb_hash_aset(payload, ID2SYM(id_key_capture), LONG2NUM(NUM2LONG(id_value) + 1));
      rb_obj_freeze(payload);
    }
    if (builder->ignorecase && type_code == ONIBI_AST_BACKREF) {
      payload = rb_hash_dup(payload);
      rb_hash_aset(payload, ID2SYM(id_key_ignorecase), Qtrue);
      rb_obj_freeze(payload);
    }
    VALUE escape_name_for_op = onibi_hash_value_id(ast, id_key_name);
    int grapheme_escape = type_code == ONIBI_AST_ESCAPE &&
      ((NIL_P(escape_name_for_op) && tolower((unsigned char)NUM2INT(onibi_hash_value_id(ast, id_key_byte))) == 'x') ||
       (!NIL_P(escape_name_for_op) && RSTRING_LEN(escape_name_for_op) == 1 &&
        tolower((unsigned char)RSTRING_PTR(escape_name_for_op)[0]) == 'x'));
    long id = builder->next_id++;
    ID op = type_code == ONIBI_AST_LITERAL ? id_g_char :
      ((type_code == ONIBI_AST_ANY) ? id_g_any :
       ((type_code == ONIBI_AST_BACKREF) ? id_g_backref :
        (grapheme_escape ? id_g_grapheme : id_g_class)));
    if (builder->ignorecase && type_code == ONIBI_AST_LITERAL) {
      payload = rb_hash_dup(payload);
      rb_hash_aset(payload, ID2SYM(id_key_byte), INT2NUM(tolower(NUM2INT(onibi_hash_value_id(payload, id_key_byte)))));
      rb_hash_aset(payload, ID2SYM(id_key_ignorecase), Qtrue);
      rb_obj_freeze(payload);
    }
    if (builder->ignorecase &&
        (type_code == ONIBI_AST_CHARACTER_CLASS ||
         type_code == ONIBI_AST_CLASS_INTERSECTION)) {
      payload = rb_hash_dup(payload);
      rb_hash_aset(payload, ID2SYM(id_key_ignorecase), Qtrue);
      rb_obj_freeze(payload);
    }
    if (type_code == ONIBI_AST_CHARACTER_CLASS || type_code == ONIBI_AST_CLASS_INTERSECTION) {
      payload = onibi_class_payload_with_ctypes(payload);
      rb_hash_aset(payload, ID2SYM(id_key_bitmap),
                   onibi_class_bitmap(payload, builder->ignorecase));
      rb_obj_freeze(payload);
    }
    if (type_code == ONIBI_AST_ESCAPE) {
      payload = rb_hash_dup(payload);
      rb_hash_aset(payload, ID2SYM(id_key_ranges), rb_ary_new());
      rb_hash_aset(payload, ID2SYM(id_key_children), rb_ary_new());
      rb_hash_aset(payload, ID2SYM(id_key_bitmap),
                   onibi_class_bitmap(payload, builder->ignorecase));
      VALUE property_name = onibi_hash_value_id(payload, id_key_name);
      VALUE property_name_id = onibi_hash_value_id(payload, id_key_name_id);
      ID property = NIL_P(property_name_id) ? (NIL_P(property_name) ? 0 : rb_intern_str(property_name)) : (ID)NUM2ULONG(property_name_id);
      int property_ctype = onibi_unicode_ctype_id(property);
      if (property_ctype >= 0)
        rb_hash_aset(payload, ID2SYM(id_key_ctype), INT2NUM(property_ctype));
      rb_obj_freeze(payload);
    }
    if (builder->multiline && type_code == ONIBI_AST_ANY) {
      payload = rb_hash_dup(payload);
      rb_hash_aset(payload, ID2SYM(id_key_multiline), Qtrue);
      rb_obj_freeze(payload);
    }
    onibi_gir_state(builder, id, op, payload);
    onibi_fragment_t result = onibi_fragment_empty();
    onibi_id_vector_single(&result.starts, (OnibiStateId)id);
    onibi_id_vector_single(&result.exits, (OnibiStateId)id);
    result.nullable = 0;
    return result;
  }
  if (type_code == ONIBI_AST_SUBROUTINE)
  {
    VALUE name = onibi_hash_value_id(ast, id_key_name);
    VALUE body = NIL_P(name) ? Qnil : onibi_value_map_find(&builder->capture_bodies, name);
    if (NIL_P(body)) rb_raise(eRegexpError, "undefined subroutine call");
    VALUE existing = onibi_value_map_find(&builder->subprogram_ids, name);
    long subprogram_id;
    if (!NIL_P(existing)) subprogram_id = NUM2LONG(existing);
    else subprogram_id = onibi_compile_named_subprogram(name, body, builder);
    VALUE payload = rb_hash_new();
    rb_hash_aset(payload, ID2SYM(id_key_subprogram), LONG2NUM(subprogram_id));
    rb_obj_freeze(payload);
    long id = builder->next_id++;
    onibi_gir_state(builder, id, id_g_call, payload);
    onibi_fragment_t result = onibi_fragment_empty();
    onibi_id_vector_single(&result.starts, (OnibiStateId)id);
    onibi_id_vector_single(&result.exits, (OnibiStateId)id);
    result.nullable = 0;
    return result;
  }
  if (type_code == ONIBI_AST_OPTION_GLOBAL) {
    VALUE option_names = onibi_hash_value_id(ast, id_key_options);
    int negative = RTEST(onibi_hash_value_id(ast, id_key_negative));
    if (NIL_P(option_names) || !RB_TYPE_P(option_names, T_STRING))
      rb_raise(eRegexpError, "global option modifier has no flags");
    for (long i = 0; i < RSTRING_LEN(option_names); i++) {
      int enabled = negative ? 0 : 1;
      if (RSTRING_PTR(option_names)[i] == 'i') builder->ignorecase = enabled;
      else if (RSTRING_PTR(option_names)[i] == 'm') builder->multiline = enabled;
      else if (RSTRING_PTR(option_names)[i] == 'x') continue;
      else rb_raise(eRegexpError, "unknown global option flag");
    }
    VALUE negative_options = onibi_hash_value_id(ast, id_key_negative_options);
    if (!NIL_P(negative_options)) {
      for (long i = 0; i < RSTRING_LEN(negative_options); i++) {
        if (RSTRING_PTR(negative_options)[i] == 'i') builder->ignorecase = 0;
        else if (RSTRING_PTR(negative_options)[i] == 'm') builder->multiline = 0;
        else if (RSTRING_PTR(negative_options)[i] == 'x') continue;
        else rb_raise(eRegexpError, "unknown global option flag");
      }
    }
    return onibi_fragment_empty();
  }
  if (type_code == ONIBI_AST_OPTION_SCOPE) {
    VALUE option_names = onibi_hash_value_id(ast, id_key_options);
    if (NIL_P(option_names) || !RB_TYPE_P(option_names, T_STRING))
      rb_raise(eRegexpError, "option scope has no flags");
    int saved_ignorecase = builder->ignorecase;
    int saved_multiline = builder->multiline;
    int negative = RTEST(onibi_hash_value_id(ast, id_key_negative));
    for (long i = 0; i < RSTRING_LEN(option_names); i++) {
      int enabled = negative ? 0 : 1;
      if (RSTRING_PTR(option_names)[i] == 'i') builder->ignorecase = enabled;
      else if (RSTRING_PTR(option_names)[i] == 'm') builder->multiline = enabled;
      else if (RSTRING_PTR(option_names)[i] == 'x') continue;
      else rb_raise(eRegexpError, "unknown option scope flag");
    }
    VALUE negative_options = onibi_hash_value_id(ast, id_key_negative_options);
    if (!NIL_P(negative_options)) {
      for (long i = 0; i < RSTRING_LEN(negative_options); i++) {
        if (RSTRING_PTR(negative_options)[i] == 'i') builder->ignorecase = 0;
        else if (RSTRING_PTR(negative_options)[i] == 'm') builder->multiline = 0;
        else if (RSTRING_PTR(negative_options)[i] == 'x') continue;
        else rb_raise(eRegexpError, "unknown option scope flag");
      }
    }
  onibi_fragment_t result = onibi_compile_node(onibi_hash_value_id(ast, id_key_body), builder);
    builder->ignorecase = saved_ignorecase;
    builder->multiline = saved_multiline;
    return result;
  }
  if (type_code == ONIBI_AST_ANCHOR)
  {
    onibi_fragment_t result = onibi_fragment_empty();
    VALUE action = rb_hash_new();
    long marker = NUM2LONG(onibi_hash_value_id(ast, id_key_byte));
    ID op = id_a_assert_end_buffer;
    /* Ruby keeps ^ and $ line anchors independent of the m option.  The
       option changes dot-newline matching only. */
    if (marker == '^') op = id_a_assert_begin_line;
    else if (marker == '$') op = id_a_assert_end_line;
    else if (marker == 'b') op = id_a_assert_word_boundary;
    else if (marker == 'B') op = id_a_assert_nonword_boundary;
    else if (marker == 'A') op = id_a_assert_begin_buffer;
    else if (marker == 'G') op = id_a_assert_search_origin;
    else if (marker == 'Z') op = id_a_assert_semi_end_buffer;
    rb_hash_aset(action, ID2SYM(id_key_op), ID2SYM(op));
    onibi_set_gir_action_opcode(action, op);
    rb_ary_push(result.pending_actions, action);
    return result;
  }
  if (type_code == ONIBI_AST_MATCH_RESET) {
    onibi_fragment_t result = onibi_fragment_empty();
    VALUE action = rb_hash_new();
    rb_hash_aset(action, ID2SYM(id_key_op), ID2SYM(id_match_reset));
    onibi_set_gir_action_opcode(action, id_match_reset);
    rb_ary_push(result.pending_actions, action);
    return result;
  }
  if (type_code == ONIBI_AST_CONDITIONAL) {
    VALUE condition = onibi_hash_value_id(ast, id_key_condition);
    char *endptr = NULL;
    const char *condition_text = StringValueCStr(condition);
    long capture_id = strtol(condition_text, &endptr, 10) - 1;
    if (endptr == condition_text || *endptr != '\0') {
      VALUE named_condition = condition;
      if (RSTRING_LEN(condition) >= 2 && RSTRING_PTR(condition)[0] == '<' &&
          RSTRING_PTR(condition)[RSTRING_LEN(condition) - 1] == '>')
        named_condition = rb_str_substr(condition, 1, RSTRING_LEN(condition) - 2);
      VALUE named = onibi_value_map_find(&builder->capture_names, named_condition);
      if (NIL_P(named)) rb_raise(eRegexpError, "conditional capture is undefined");
      capture_id = NUM2LONG(named);
    }
    if (capture_id < 0) rb_raise(eRegexpError, "conditional capture is invalid");
    onibi_fragment_t yes = onibi_compile_node(onibi_hash_value_id(ast, id_key_yes), builder);
    onibi_fragment_t no = onibi_compile_node(onibi_hash_value_id(ast, id_key_no), builder);
    VALUE yes_guard = rb_ary_new();
    rb_ary_push(yes_guard, onibi_capture_test_action(capture_id, 1));
    onibi_append_values(yes_guard, yes.start_actions);
    VALUE no_guard = rb_ary_new();
    rb_ary_push(no_guard, onibi_capture_test_action(capture_id, 0));
    onibi_append_values(no_guard, no.start_actions);
    onibi_add_capture_guard_fragment(builder, &yes.starts, yes_guard);
    onibi_add_capture_guard_fragment(builder, &no.starts, no_guard);
    onibi_add_exit_guard_fragment(builder, &yes.exits, yes.pending_actions);
    onibi_add_exit_guard_fragment(builder, &no.exits, no.pending_actions);
    onibi_fragment_t result = onibi_fragment_empty();
    onibi_id_vector_append(&result.starts, &yes.starts);
    onibi_id_vector_append(&result.starts, &no.starts);
    onibi_id_vector_append(&result.exits, &yes.exits);
    onibi_id_vector_append(&result.exits, &no.exits);
    onibi_id_vector_free(&yes.starts); onibi_id_vector_free(&yes.exits);
    onibi_id_vector_free(&no.starts); onibi_id_vector_free(&no.exits);
    result.nullable = yes.nullable || no.nullable;
    result.lazy = yes.lazy;
    return result;
  }
  if (type_code == ONIBI_AST_ATOMIC) {
    VALUE body = onibi_hash_value_id(ast, id_key_body);
    long subprogram_id = onibi_compile_subprogram(body, builder, ONIBI_SUBPROGRAM_ATOMIC);
    VALUE payload = rb_hash_new();
    rb_hash_aset(payload, ID2SYM(id_key_subprogram), LONG2NUM(subprogram_id));
    rb_obj_freeze(payload);
    long id = builder->next_id++;
    onibi_gir_state(builder, id, id_g_atomic, payload);
    onibi_fragment_t result = onibi_fragment_empty();
    onibi_id_vector_single(&result.starts, (OnibiStateId)id);
    onibi_id_vector_single(&result.exits, (OnibiStateId)id);
    result.nullable = 0;
    return result;
  }
  if (type_code == ONIBI_AST_ABSENCE) {
    long subprogram_id = onibi_compile_subprogram(onibi_hash_value_id(ast, id_key_body), builder,
                                                   ONIBI_SUBPROGRAM_ABSENT);
    VALUE payload = rb_hash_new();
    rb_hash_aset(payload, ID2SYM(id_key_subprogram), LONG2NUM(subprogram_id));
    rb_obj_freeze(payload);
    long id = builder->next_id++;
    onibi_gir_state(builder, id, id_g_absent, payload);
    onibi_fragment_t result = onibi_fragment_empty();
    onibi_id_vector_single(&result.starts, (OnibiStateId)id);
    onibi_id_vector_single(&result.exits, (OnibiStateId)id);
    result.nullable = 1;
    return result;
  }
  if (type_code == ONIBI_AST_LOOKAHEAD || type_code == ONIBI_AST_LOOKBEHIND) {
    VALUE body = onibi_hash_value_id(ast, id_key_body);
    if (!RB_TYPE_P(body, T_HASH))
      rb_raise(eRegexpError, "lookaround body has no literal sequence");
    VALUE children = onibi_hash_value_id(body, id_key_children);
    if (!RB_TYPE_P(children, T_ARRAY))
      rb_raise(eRegexpError, "lookaround body has no literal sequence");
    VALUE bytes = rb_str_new(NULL, 0);
    VALUE predicates = rb_ary_new();
    for (long i = 0; i < RARRAY_LEN(children); i++) {
      VALUE child = rb_ary_entry(children, i);
      OnibiAstKind child_type = onibi_ast_kind(child);
      if (child_type == ONIBI_AST_CHARACTER_CLASS ||
          child_type == ONIBI_AST_CLASS_INTERSECTION) {
        VALUE predicate = rb_hash_new();
        rb_hash_aset(predicate, ID2SYM(id_key_kind), ID2SYM(id_pred_bitmap));
        rb_hash_aset(predicate, ID2SYM(id_key_predicate_code), UINT2NUM(ONIBI_PRED_BITMAP));
        rb_hash_aset(predicate, ID2SYM(id_key_bitmap), onibi_class_bitmap(child, builder->ignorecase));
        rb_ary_push(predicates, predicate);
        continue;
      }
      if (child_type == ONIBI_AST_ANY) {
        VALUE predicate = rb_hash_new();
        rb_hash_aset(predicate, ID2SYM(id_key_kind), ID2SYM(id_pred_any));
        rb_hash_aset(predicate, ID2SYM(id_key_predicate_code), UINT2NUM(ONIBI_PRED_ANY));
        rb_hash_aset(predicate, ID2SYM(id_key_multiline), builder->multiline ? Qtrue : Qfalse);
        rb_ary_push(predicates, predicate);
        continue;
      }
      if (child_type == ONIBI_AST_ESCAPE) {
        VALUE name = onibi_hash_value_id(child, id_key_name);
        int simple = !NIL_P(name) &&
           (onibi_ascii_property_name_p(name) ||
           (RSTRING_LEN(name) == 1 &&
            onibi_simple_escape_p((unsigned char)RSTRING_PTR(name)[0])));
        if (!simple) rb_raise(eRegexpError, "lookaround body has an unsupported escape");
        VALUE payload = rb_hash_dup(child);
        rb_hash_aset(payload, ID2SYM(id_key_ranges), rb_ary_new());
        rb_hash_aset(payload, ID2SYM(id_key_children), rb_ary_new());
        VALUE predicate = rb_hash_new();
        rb_hash_aset(predicate, ID2SYM(id_key_kind), ID2SYM(id_pred_bitmap));
        rb_hash_aset(predicate, ID2SYM(id_key_predicate_code), UINT2NUM(ONIBI_PRED_BITMAP));
        rb_hash_aset(predicate, ID2SYM(id_key_bitmap), onibi_class_bitmap(payload, builder->ignorecase));
        rb_ary_push(predicates, predicate);
        continue;
      }
      if (child_type != ONIBI_AST_LITERAL)
        rb_raise(eRegexpError, "lookaround body is not a fixed literal/class sequence");
      VALUE predicate = rb_hash_new();
      rb_hash_aset(predicate, ID2SYM(id_key_kind), ID2SYM(id_pred_byte));
      rb_hash_aset(predicate, ID2SYM(id_key_predicate_code), UINT2NUM(ONIBI_PRED_BYTE));
      rb_hash_aset(predicate, ID2SYM(id_key_byte), onibi_hash_value_id(child, id_key_byte));
      rb_hash_aset(predicate, ID2SYM(id_key_ignorecase), builder->ignorecase ? Qtrue : Qfalse);
      rb_ary_push(predicates, predicate);
      rb_str_cat(bytes, (const char[]){(char)NUM2INT(onibi_hash_value_id(child, id_key_byte))}, 1);
    }
    rb_obj_freeze(bytes);
    rb_obj_freeze(predicates);
    VALUE action = rb_hash_new();
    ID assertion_op = type_code == ONIBI_AST_LOOKBEHIND ?
      id_a_assert_lookbehind : id_a_assert_lookahead;
    rb_hash_aset(action, ID2SYM(id_key_op), ID2SYM(assertion_op));
    onibi_set_gir_action_opcode(action, assertion_op);
    rb_hash_aset(action, ID2SYM(id_key_positive), onibi_hash_value_id(ast, id_key_positive));
    rb_hash_aset(action, ID2SYM(id_key_bytes), bytes);
    if (RARRAY_LEN(predicates) > 0) rb_hash_aset(action, ID2SYM(id_key_predicates), predicates);
    rb_hash_aset(action, ID2SYM(id_key_width), LONG2NUM(RARRAY_LEN(predicates)));
    onibi_fragment_t result = onibi_fragment_empty();
    result.nullable = 1;
    rb_ary_push(result.start_actions, action);
    return result;
  }
  if (type_code == ONIBI_AST_CAPTURE) {
    VALUE capture_ast_key = onibi_hash_value_id(ast, id_key_start);
    VALUE capture_id_value = onibi_value_map_find(&builder->capture_ids, capture_ast_key);
    long capture_id;
    if (NIL_P(capture_id_value)) {
      capture_id = builder->capture_count++;
      onibi_value_map_set(&builder->capture_ids, capture_ast_key, LONG2NUM(capture_id), builder->map_roots);
    } else capture_id = NUM2LONG(capture_id_value);
    VALUE capture_body = onibi_hash_value_id(ast, id_key_body);
    onibi_fragment_t result = onibi_compile_node(capture_body, builder);
    VALUE open = rb_hash_new(), close = rb_hash_new();
    rb_hash_aset(open, ID2SYM(id_key_op), ID2SYM(id_capture_open));
    onibi_set_gir_action_opcode(open, id_capture_open);
    rb_hash_aset(open, ID2SYM(id_key_slot), LONG2NUM(2 * capture_id));
    rb_hash_aset(close, ID2SYM(id_key_op), ID2SYM(id_capture_close));
    onibi_set_gir_action_opcode(close, id_capture_close);
    rb_hash_aset(close, ID2SYM(id_key_slot), LONG2NUM(2 * capture_id + 1));
    VALUE capture_name = onibi_hash_value_id(ast, id_key_name);
    if (!NIL_P(capture_name) && onibi_ast_has_subroutine_name(capture_body, capture_name))
      rb_hash_aset(close, ID2SYM(id_key_preserve_if_set), Qtrue);
    char capture_name_key[32];
    snprintf(capture_name_key, sizeof(capture_name_key), "%ld", capture_id + 1);
    onibi_value_map_set(&builder->capture_bodies, rb_str_new_cstr(capture_name_key), onibi_hash_value_id(ast, id_key_body), builder->map_roots);
    if (!NIL_P(capture_name)) {
      if (NIL_P(onibi_value_map_find(&builder->capture_names, capture_name)))
        onibi_value_map_set(&builder->capture_names, capture_name, LONG2NUM(capture_id), builder->map_roots);
      onibi_value_map_set(&builder->capture_bodies, capture_name, onibi_hash_value_id(ast, id_key_body), builder->map_roots);
    }
    rb_ary_push(result.start_actions, open);
    rb_ary_push(result.pending_actions, close);
    if (result.nullable) onibi_append_values(result.start_actions, result.pending_actions);
    return result;
  }
  if (type_code == ONIBI_AST_GROUP)
    return onibi_compile_node(onibi_hash_value_id(ast, id_key_body), builder);
  if (type_code == ONIBI_AST_QUANTIFIER) {
    VALUE min_value = onibi_hash_value_id(ast, id_key_min), max_value = onibi_hash_value_id(ast, id_key_max);
    long min = NUM2LONG(min_value);
    VALUE atom = onibi_hash_value_id(ast, id_key_atom);
    if (min == 0) builder->optional_seen = 1;
    if (RTEST(onibi_hash_value_id(ast, id_key_possessive)) &&
        (NIL_P(max_value) || NUM2LONG(max_value) != min))
      rb_raise(eRegexpError, "variable possessive quantifier is not supported in RSeq");
    if (RTEST(onibi_hash_value_id(ast, id_key_possessive)) && onibi_ast_has_capture(atom))
      rb_raise(eRegexpError, "possessive capture repeat is not supported in RSeq");
    if (!NIL_P(max_value) && min == 0 && NUM2LONG(max_value) == 0)
      return onibi_fragment_empty();
    if (!NIL_P(max_value) && min == 0 && NUM2LONG(max_value) == 1) {
      onibi_fragment_t result = onibi_compile_node(onibi_hash_value_id(ast, id_key_atom), builder);
      result.nullable = 1;
      result.lazy = !RTEST(onibi_hash_value_id(ast, id_key_greedy));
      return result;
    }
    long counter_slot = -1;
    if (!NIL_P(max_value) && NUM2LONG(max_value) != min)
      counter_slot = builder->counter_count++;
    onibi_fragment_t result = onibi_fragment_empty();
    result.nullable = min == 0;
    if (!NIL_P(max_value) && NUM2LONG(max_value) < min)
      rb_raise(eRegexpError, "invalid quantifier range");
    long max = NIL_P(max_value) ? -1 : NUM2LONG(max_value);
    if (max > ONIBI_RSEQ_REPEAT_UNROLL_LIMIT)
      rb_raise(eRegexpError, "quantifier exceeds RSeq representation limit");
    if (max >= 0 && max != min) {
      /* Counted repeats use one counter slot.  The first start edge
         initializes it.  Optional bodies use ordered test edges. */
      VALUE init = onibi_counter_action(id_a_counter_init, counter_slot, Qnil);
      rb_hash_aset(init, ID2SYM(id_key_value), INT2NUM(min > 0 ? 1 : 0));
      rb_ary_push(result.start_actions, init);
    }
    for (long i = 0; i < min; i++) {
      onibi_fragment_t part = onibi_compile_node(atom, builder);
      if (i == 0) onibi_id_vector_move(&result.starts, &part.starts);
      else {
        VALUE actions = rb_ary_new();
        if (counter_slot >= 0)
          rb_ary_push(actions, onibi_counter_action(id_a_counter_increment, counter_slot, Qnil));
        onibi_connect_fragment_actions(builder, &result.exits, &part.starts, actions, 0);
      }
      onibi_id_vector_move(&result.exits, &part.exits);
    }
    if (max >= 0 && max > min) {
      long optional = max - min;
      for (long i = 0; i < optional; i++) {
        onibi_fragment_t part = onibi_compile_node(atom, builder);
        if (result.starts.count == 0) onibi_id_vector_move(&result.starts, &part.starts);
        VALUE repeat_actions = rb_ary_new();
        rb_ary_push(repeat_actions, onibi_counter_action(id_a_test_counter_lt, counter_slot, LONG2NUM(max)));
        rb_ary_push(repeat_actions, onibi_counter_action(id_a_counter_increment, counter_slot, Qnil));
        if (result.exits.count > 0)
          onibi_connect_fragment_actions(builder, &result.exits, &part.starts, repeat_actions, 0);
        onibi_id_vector_append(&result.exits, &part.exits);
        onibi_id_vector_free(&part.starts); onibi_id_vector_free(&part.exits);
      }
      rb_ary_push(result.pending_actions, onibi_counter_action(id_a_test_counter_ge, counter_slot, LONG2NUM(min)));
    } else if (NIL_P(max_value)) {
      onibi_fragment_t repeat = onibi_compile_node(atom, builder);
      if (result.starts.count == 0) onibi_id_vector_move(&result.starts, &repeat.starts);
      if (!repeat.nullable) onibi_append_values(result.start_actions, repeat.start_actions);
      if (result.exits.count > 0) {
        if (repeat.nullable) {
          onibi_connect_fragment(builder, &result.exits, &repeat.starts);
        } else {
          VALUE next_actions = rb_ary_dup(repeat.pending_actions);
          onibi_append_values(next_actions, repeat.start_actions);
          onibi_connect_fragment_actions(builder, &result.exits, &repeat.starts, next_actions, 0);
        }
      }
      if (repeat.nullable) {
        onibi_connect_fragment(builder, &repeat.exits, &repeat.starts);
      } else {
        VALUE loop_actions = rb_ary_dup(repeat.pending_actions);
        onibi_append_values(loop_actions, repeat.start_actions);
        onibi_connect_fragment_actions(builder, &repeat.exits, &repeat.starts, loop_actions, 0);
      }
      onibi_append_values(result.pending_actions, repeat.pending_actions);
      onibi_id_vector_append(&result.exits, &repeat.exits);
      onibi_id_vector_free(&repeat.starts); onibi_id_vector_free(&repeat.exits);
    }
    result.lazy = !RTEST(onibi_hash_value_id(ast, id_key_greedy));
    return result;
  }
  rb_raise(eRegexpError, "unsupported AST node");
  return onibi_fragment_empty();
}

static VALUE onibi_compiler_compile(VALUE self, VALUE parsed) {
  (void)self;
  OnibiParsed *parsed_data = onibi_parsed_get(parsed);
  VALUE ast = parsed_data->ast;
  if (NIL_P(ast)) rb_raise(rb_eArgError, "compiler requires parser output");
  int parsed_options = parsed_data->options;
  int ignorecase = (parsed_options & 1) != 0;
  int multiline = (parsed_options & 4) != 0;
  VALUE subprograms = rb_ary_new();
  rb_ary_push(subprograms, Qnil); /* root descriptor is filled after compile */
  onibi_gir_builder_t builder;
  memset(&builder, 0, sizeof(builder));
  onibi_gir_edge_vector_init(&builder.edges);
  builder.states.entries = NULL; builder.states.count = builder.states.capacity = 0;
  onibi_value_map_init(&builder.capture_names);
  onibi_value_map_init(&builder.capture_bodies);
  onibi_value_map_init(&builder.capture_ids);
  onibi_value_map_init(&builder.active_subroutines);
  builder.subprograms = subprograms;
  onibi_value_map_init(&builder.subprogram_ids);
  builder.map_roots = rb_ary_new();
  onibi_guard_vector_init(&builder.capture_guards);
  onibi_guard_vector_init(&builder.exit_guards);
  builder.ignorecase = ignorecase;
  builder.multiline = multiline;
  long prepass_capture_count = 0;
  onibi_collect_captures(ast, &builder, &prepass_capture_count);
  builder.capture_count = prepass_capture_count;
  onibi_fragment_t fragment = onibi_compile_node(ast, &builder);
  long accept = builder.next_id++;
  onibi_gir_state(&builder, accept, id_g_accept, Qnil);
  VALUE accept_starts = rb_ary_new();
  rb_ary_push(accept_starts, LONG2NUM(accept));
  OnibiIdVector exit_ids;
  exit_ids = fragment.exits;
  if (fragment.lazy) onibi_connect_vector_prepend_actions(&builder, &exit_ids, accept_starts, fragment.pending_actions);
  else onibi_connect_vector_actions(&builder, &exit_ids, accept_starts, fragment.pending_actions);
  VALUE start_edges = rb_ary_new();
  long root_entry = fragment.starts.count > 0 ? (long)fragment.starts.items[0] : accept;
  if (fragment.nullable && fragment.lazy) {
    VALUE edge = rb_hash_new();
    rb_hash_aset(edge, ID2SYM(id_key_to), LONG2NUM(accept));
    VALUE actions = rb_ary_dup(fragment.start_actions);
    onibi_append_values(actions, fragment.pending_actions);
    rb_hash_aset(edge, ID2SYM(id_key_actions), actions);
    rb_ary_push(start_edges, edge);
  }
  OnibiIdVector start_ids;
  start_ids = fragment.starts;
  for (size_t i = 0; i < start_ids.count; i++) {
    VALUE edge = rb_hash_new();
    VALUE destination = UINT2NUM(start_ids.items[i]);
    VALUE actions = rb_ary_new();
    VALUE guard = onibi_guard_vector_find(&builder.capture_guards, (OnibiStateId)start_ids.items[i]);
    onibi_append_values(actions, fragment.start_actions);
    if (!NIL_P(guard)) onibi_append_values(actions, guard);
    rb_hash_aset(edge, ID2SYM(id_key_to), destination);
    rb_hash_aset(edge, ID2SYM(id_key_actions), actions);
    rb_ary_push(start_edges, edge);
  }
  onibi_id_vector_free(&start_ids);
  onibi_id_vector_free(&exit_ids);
  if (fragment.nullable && !fragment.lazy) {
    VALUE edge = rb_hash_new();
    rb_hash_aset(edge, ID2SYM(id_key_to), LONG2NUM(accept));
    VALUE actions = rb_ary_dup(fragment.start_actions);
    onibi_append_values(actions, fragment.pending_actions);
    rb_hash_aset(edge, ID2SYM(id_key_actions), actions);
    rb_ary_push(start_edges, edge);
  }
  for (long i = 0; i < RARRAY_LEN(start_edges); i++) {
    VALUE edge = rb_ary_entry(start_edges, i);
    rb_obj_freeze(onibi_hash_value_id(edge, id_key_actions));
    rb_obj_freeze(edge);
  }
  rb_obj_freeze(start_edges);
  VALUE gir_states, gir_edges;
  onibi_materialize_gir(&builder, &gir_states, &gir_edges);
  VALUE graph = rb_hash_new();
  rb_hash_aset(graph, ID2SYM(id_key_states), gir_states);
  rb_hash_aset(graph, ID2SYM(id_key_edges), gir_edges);
  rb_hash_aset(graph, ID2SYM(id_key_start_edges), start_edges);
  rb_hash_aset(graph, ID2SYM(id_key_accept), LONG2NUM(accept));
  /* Program zero is the root callable program.  Keep an explicit descriptor
     even before nested dynamic constructs add their own entries. */
  VALUE root_descriptor = rb_hash_new();
  rb_hash_aset(root_descriptor, ID2SYM(id_key_entry), LONG2NUM(root_entry));
  rb_hash_aset(root_descriptor, ID2SYM(id_key_accept), LONG2NUM(accept));
  rb_hash_aset(root_descriptor, ID2SYM(id_key_flags), INT2NUM(0));
  rb_obj_freeze(root_descriptor);
  rb_ary_store(builder.subprograms, 0, root_descriptor);
  subprograms = builder.subprograms;
  rb_obj_freeze(subprograms);
  rb_hash_aset(graph, ID2SYM(id_key_subprograms), subprograms);
  rb_hash_aset(graph, ID2SYM(id_key_capture_count), LONG2NUM(builder.capture_count));
  long counter_count = builder.counter_count;
  for (size_t i = 0; i < builder.edges.count; i++) {
    VALUE actions = builder.edges.entries[i].actions;
    for (long j = 0; j < RARRAY_LEN(actions); j++) {
      VALUE action = rb_ary_entry(actions, j);
      OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(action, id_key_action_code));
      if (code == ONIBI_GA_COUNTER_INIT || code == ONIBI_GA_COUNTER_INCREMENT ||
          code == ONIBI_GA_TEST_COUNTER_LT || code == ONIBI_GA_TEST_COUNTER_GE) {
        long slot = NUM2LONG(onibi_hash_value_id(action, id_key_slot));
        if (slot + 1 > counter_count) counter_count = slot + 1;
      }
    }
  }
  for (long i = 0; i < RARRAY_LEN(start_edges); i++) {
    VALUE actions = onibi_hash_value_id(rb_ary_entry(start_edges, i), id_key_actions);
    for (long j = 0; j < RARRAY_LEN(actions); j++) {
      VALUE action = rb_ary_entry(actions, j);
      OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(action, id_key_action_code));
      if (code == ONIBI_GA_COUNTER_INIT || code == ONIBI_GA_COUNTER_INCREMENT ||
          code == ONIBI_GA_TEST_COUNTER_LT || code == ONIBI_GA_TEST_COUNTER_GE) {
        long slot = NUM2LONG(onibi_hash_value_id(action, id_key_slot));
        if (slot + 1 > counter_count) counter_count = slot + 1;
      }
    }
  }
  rb_hash_aset(graph, ID2SYM(id_key_counter_count), LONG2NUM(counter_count));
  rb_hash_aset(graph, ID2SYM(id_key_subprogram_count), LONG2NUM(RARRAY_LEN(subprograms)));
  onibi_gir_validate(graph);
  rb_obj_freeze(graph);
  OnibiCompiled *compiled_result;
  VALUE result = TypedData_Make_Struct(rb_cObject, OnibiCompiled, &onibi_compiled_type, compiled_result);
  compiled_result->graph = graph;
  compiled_result->options = parsed_options;
  onibi_guard_vector_free(&builder.capture_guards);
  onibi_guard_vector_free(&builder.exit_guards);
  onibi_value_map_free(&builder.capture_names);
  onibi_value_map_free(&builder.capture_bodies);
  onibi_value_map_free(&builder.capture_ids);
  onibi_value_map_free(&builder.active_subroutines);
  onibi_value_map_free(&builder.subprogram_ids);
  onibi_gir_state_vector_free(&builder.states);
  onibi_gir_edge_vector_free(&builder.edges);
  rb_obj_freeze(result);
  return result;
}

static uint8_t onibi_rseq_action_flags(ID op) {
  if (op == id_capture_close) return ONIBI_RA_CAPTURE_CLOSE;
  if (op == id_a_test_capture) return ONIBI_RA_TEST_CAPTURE_SET;
  if (op == id_a_test_counter_ge) return ONIBI_RA_COUNTER_GE;
  return 0;
}

static OnibiRAssertKind onibi_rseq_assert_kind(ID op) {
  if (op == id_a_assert_begin_buffer) return ONIBI_RAP_BEGIN_BUFFER;
  if (op == id_a_assert_end_buffer) return ONIBI_RAP_END_BUFFER;
  if (op == id_a_assert_begin_line) return ONIBI_RAP_BEGIN_LINE;
  if (op == id_a_assert_end_line) return ONIBI_RAP_END_LINE;
  if (op == id_a_assert_semi_end_buffer) return ONIBI_RAP_SEMI_END_BUFFER;
  if (op == id_a_assert_search_origin) return ONIBI_RAP_SEARCH_ORIGIN;
  if (op == id_a_assert_word_boundary) return ONIBI_RAP_WORD_BOUNDARY;
  if (op == id_a_assert_nonword_boundary) return ONIBI_RAP_NONWORD_BOUNDARY;
  if (op == id_a_assert_lookahead) return ONIBI_RAP_LOOKAHEAD;
  if (op == id_a_assert_lookbehind) return ONIBI_RAP_LOOKBEHIND;
  return 0;
}

static VALUE onibi_rseq_lower(VALUE self, VALUE compiled) {
  (void)self;
  OnibiCompiled *compiled_data = onibi_compiled_get(compiled);
  VALUE graph = compiled_data->graph;
  if (NIL_P(graph)) rb_raise(rb_eArgError, "RSeq lowering requires compiler output");
  VALUE states = onibi_hash_value_id(graph, id_key_states);
  VALUE edges = onibi_hash_value_id(graph, id_key_edges);
  VALUE start_edges = onibi_hash_value_id(graph, id_key_start_edges);
  VALUE subprograms = onibi_hash_value_id(graph, id_key_subprograms);
  if (!RTEST(rb_obj_frozen_p(compiled)) || !RTEST(rb_obj_frozen_p(graph)) ||
      !RTEST(rb_obj_frozen_p(states)) || !RTEST(rb_obj_frozen_p(edges)) ||
      !RTEST(rb_obj_frozen_p(start_edges)) || !RB_TYPE_P(subprograms, T_ARRAY) ||
      !RTEST(rb_obj_frozen_p(subprograms)))
    rb_raise(rb_eArgError, "RSeq lowering requires immutable GIR");
  long state_count = RARRAY_LEN(states);
  OnibiGirStateVector state_records;
  onibi_gir_state_vector_init(&state_records);
  VALUE state_roots = rb_ary_new();
  for (long i = 0; i < state_count; i++) {
    VALUE state = rb_ary_entry(states, i);
    OnibiGirStateEntry record = {
      NUM2LONG(onibi_hash_value_id(state, id_key_id)),
      SYM2ID(onibi_hash_value_id(state, id_key_op)),
      (OnibiGStateOp)NUM2UINT(onibi_hash_value_id(state, id_key_opcode)),
      onibi_hash_value_id(state, id_key_payload),
      0
    };
    onibi_gir_state_vector_push(&state_records, record, state_roots);
  }
  OnibiRSeqSubprogramVector subprogram_records;
  onibi_rseq_subprogram_vector_init(&subprogram_records);
  for (long i = 0; i < RARRAY_LEN(subprograms); i++)
    onibi_rseq_subprogram_vector_push(&subprogram_records, rb_ary_entry(subprograms, i));
  long accept_state = NUM2LONG(onibi_hash_value_id(graph, id_key_accept));
  if (accept_state < 0 || accept_state >= state_count)
    rb_raise(rb_eArgError, "RSeq lowering received an invalid accept state");
  for (long i = 0; i < RARRAY_LEN(edges); i++) {
    VALUE edge = rb_ary_entry(edges, i);
    long from = NUM2LONG(onibi_hash_value_id(edge, id_key_from));
    long to = NUM2LONG(onibi_hash_value_id(edge, id_key_to));
    if (from < 0 || from >= state_count || to < 0 || to >= state_count)
      rb_raise(rb_eArgError, "RSeq lowering received an invalid edge");
  }
  for (long i = 0; i < RARRAY_LEN(start_edges); i++) {
    long to = NUM2LONG(onibi_hash_value_id(rb_ary_entry(start_edges, i), id_key_to));
    if (to < 0 || to >= state_count)
      rb_raise(rb_eArgError, "RSeq lowering received an invalid start edge");
  }
  OnibiRSeqClassPayloadVector class_payloads;
  onibi_rseq_class_payload_vector_init(&class_payloads);
  for (size_t i = 0; i < state_records.count; i++) {
    OnibiGirStateEntry *state = &state_records.entries[i];
    if (state->opcode != ONIBI_G_CLASS) continue;
    VALUE payload = state->payload;
    int found = 0;
    size_t payload_index = class_payloads.count;
    for (size_t j = 0; j < class_payloads.count; j++) {
      OnibiRSeqClassPayloadEntry *prior = &class_payloads.entries[j];
      if (rb_equal(prior->bitmap, onibi_hash_value_id(payload, id_key_bitmap)) &&
          prior->negated == RTEST(onibi_hash_value_id(payload, id_key_negated))) {
        found = 1;
        payload_index = j;
        break;
      }
    }
    if (!found) onibi_rseq_class_payload_vector_push(&class_payloads, payload);
    state->payload_index = (uint32_t)payload_index;
  }
  uint32_t class_count = (uint32_t)class_payloads.count;
  OnibiRSeqActionVector action_records;
  onibi_rseq_action_vector_init(&action_records);
  VALUE action_roots = rb_ary_new();
  OnibiGirEdgeVector r_edge_records;
  onibi_gir_edge_vector_init(&r_edge_records);
  for (long i = 0; i < RARRAY_LEN(edges); i++) {
    VALUE edge = rb_ary_entry(edges, i);
    VALUE edge_actions = onibi_hash_value_id(edge, id_key_actions);
    if (!RTEST(rb_obj_frozen_p(edge)) || !RTEST(rb_obj_frozen_p(edge_actions)))
      rb_raise(rb_eArgError, "RSeq lowering requires immutable GIR edges");
    long from = NUM2LONG(onibi_hash_value_id(edge, id_key_from));
    long to = NUM2LONG(onibi_hash_value_id(edge, id_key_to));
    long action_offset = RARRAY_LEN(edge_actions) == 0 ? 0 : (long)action_records.count;
    VALUE copied_actions = rb_ary_new();
    for (long j = 0; j < RARRAY_LEN(edge_actions); j++) {
      VALUE action = rb_ary_entry(edge_actions, j);
      VALUE copy = onibi_deep_freeze(rb_hash_dup(action));
      rb_ary_push(copied_actions, copy);
      onibi_rseq_action_vector_push(&action_records, copy);
    }
    if (RARRAY_LEN(edge_actions) > 0) {
      VALUE terminator = rb_hash_new();
      rb_hash_aset(terminator, ID2SYM(id_key_op), ID2SYM(id_a_end));
      onibi_set_gir_action_opcode(terminator, id_a_end);
      terminator = onibi_deep_freeze(terminator);
      rb_ary_push(copied_actions, terminator);
      onibi_rseq_action_vector_push(&action_records, terminator);
    }
    rb_obj_freeze(copied_actions);
    onibi_gir_edge_vector_push(&r_edge_records, (OnibiGirEdgeEntry){from, to, action_offset, (uint32_t)RARRAY_LEN(copied_actions), copied_actions}, action_roots);
  }
  OnibiGirEdgeVector r_start_edge_records;
  onibi_gir_edge_vector_init(&r_start_edge_records);
  for (long i = 0; i < RARRAY_LEN(start_edges); i++) {
    VALUE edge = rb_ary_entry(start_edges, i);
    VALUE edge_actions = onibi_hash_value_id(edge, id_key_actions);
    if (!RTEST(rb_obj_frozen_p(edge)) || !RTEST(rb_obj_frozen_p(edge_actions)))
      rb_raise(rb_eArgError, "RSeq lowering requires immutable GIR start edges");
    long to = NUM2LONG(onibi_hash_value_id(edge, id_key_to));
    long action_offset = RARRAY_LEN(edge_actions) == 0 ? 0 : (long)action_records.count;
    VALUE copied_actions = rb_ary_new();
    for (long j = 0; j < RARRAY_LEN(edge_actions); j++) {
      VALUE action = rb_ary_entry(edge_actions, j);
      VALUE copy = onibi_deep_freeze(rb_hash_dup(action));
      rb_ary_push(copied_actions, copy);
      onibi_rseq_action_vector_push(&action_records, copy);
    }
    if (RARRAY_LEN(edge_actions) > 0) {
      VALUE terminator = rb_hash_new();
      rb_hash_aset(terminator, ID2SYM(id_key_op), ID2SYM(id_a_end));
      onibi_set_gir_action_opcode(terminator, id_a_end);
      terminator = onibi_deep_freeze(terminator);
      rb_ary_push(copied_actions, terminator);
      onibi_rseq_action_vector_push(&action_records, terminator);
    }
    rb_obj_freeze(copied_actions);
    onibi_gir_edge_vector_push(&r_start_edge_records, (OnibiGirEdgeEntry){-1, to, action_offset, (uint32_t)RARRAY_LEN(copied_actions), copied_actions}, action_roots);
  }
  VALUE actions = rb_ary_new_capa((long)action_records.count);
  for (size_t i = 0; i < action_records.count; i++) rb_ary_push(actions, action_records.entries[i].value);
  rb_obj_freeze(actions);
  VALUE r_edges = rb_ary_new_capa((long)r_edge_records.count);
  for (size_t i = 0; i < r_edge_records.count; i++) {
    OnibiGirEdgeEntry *record = &r_edge_records.entries[i];
    VALUE out = rb_hash_new();
    rb_hash_aset(out, ID2SYM(id_key_from), LONG2NUM(record->from));
    rb_hash_aset(out, ID2SYM(id_key_to), LONG2NUM(record->to));
    rb_hash_aset(out, ID2SYM(id_key_action_offset), LONG2NUM(record->action_offset));
    rb_hash_aset(out, ID2SYM(id_key_actions), record->actions); rb_obj_freeze(out); rb_ary_push(r_edges, out);
  }
  VALUE r_start_edges = rb_ary_new_capa((long)r_start_edge_records.count);
  for (size_t i = 0; i < r_start_edge_records.count; i++) {
    OnibiGirEdgeEntry *record = &r_start_edge_records.entries[i];
    VALUE out = rb_hash_new();
    rb_hash_aset(out, ID2SYM(id_key_to), LONG2NUM(record->to));
    rb_hash_aset(out, ID2SYM(id_key_action_offset), LONG2NUM(record->action_offset));
    rb_hash_aset(out, ID2SYM(id_key_actions), record->actions); rb_obj_freeze(out); rb_ary_push(r_start_edges, out);
  }
  rb_obj_freeze(r_edges); rb_obj_freeze(r_start_edges);
  VALUE header = rb_hash_new();
  int options = compiled_data->options;
  int ignorecase = (options & 1) != 0;
  int multiline = (options & 4) != 0;
  uint64_t physical_edge_count = (uint64_t)r_edge_records.count + (uint64_t)r_start_edge_records.count;
  OnibiRSeqLiteralPayloadVector literal_payloads;
  onibi_rseq_literal_payload_vector_init(&literal_payloads);
  for (size_t i = 0; i < state_records.count; i++) {
    unsigned int opcode = state_records.entries[i].opcode;
    if (opcode != ONIBI_G_CHAR) continue;
    VALUE payload = state_records.entries[i].payload;
    int found = 0;
    size_t payload_index = literal_payloads.count;
    for (size_t j = 0; j < literal_payloads.count; j++) {
      OnibiRSeqLiteralPayloadEntry *prior = &literal_payloads.entries[j];
      if (prior->byte == NUM2INT(onibi_hash_value_id(payload, id_key_byte)) &&
          prior->ignorecase == RTEST(onibi_hash_value_id(payload, id_key_ignorecase))) {
        found = 1;
        payload_index = j;
        break;
      }
    }
    if (!found) onibi_rseq_literal_payload_vector_push(&literal_payloads, payload);
    state_records.entries[i].payload_index = (uint32_t)payload_index;
  }
  uint32_t literal_count = (uint32_t)literal_payloads.count;
  uint64_t class_section_size = (uint64_t)class_count * (sizeof(OnibiClassDesc) + 32U);
  uint64_t literal_desc_size = (uint64_t)literal_count * sizeof(OnibiLiteralDesc);
  uint64_t literal_data_size = ((uint64_t)literal_count + 3U) & ~UINT64_C(3);
  uint64_t subprogram_section_size = (uint64_t)subprogram_records.count * sizeof(OnibiSubprogramDesc);
  uint64_t physical_size = sizeof(OnibiRSeqHeader) +
    (uint64_t)sizeof(OnibiRState) * (uint64_t)state_records.count +
    (uint64_t)sizeof(OnibiREdge) * physical_edge_count +
    (uint64_t)sizeof(OnibiRAction) * (uint64_t)action_records.count +
    class_section_size + literal_desc_size + literal_data_size + subprogram_section_size;
  if (state_records.count > UINT32_MAX || physical_edge_count > UINT32_MAX ||
      action_records.count > UINT32_MAX || physical_size > UINT32_MAX)
    rb_raise(eRegexpError, "RSeq program exceeds the v1 size limit");
  uint32_t features = 0, capture_count = 0, counter_count = 0;
  for (size_t i = 0; i < state_records.count; i++) {
    if (state_records.entries[i].opcode == ONIBI_G_BACKREF) features |= 1U;
  }
  for (size_t i = 0; i < action_records.count; i++) {
    VALUE action = action_records.entries[i].value;
    OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(action, id_key_action_code));
    ID op = SYM2ID(onibi_hash_value_id(action, id_key_op));
    if (code == ONIBI_GA_CAPTURE_OPEN) { capture_count++; features |= 2U; }
    if (code == ONIBI_GA_COUNTER_INIT) features |= 4U;
    if (code == ONIBI_GA_COUNTER_INIT || code == ONIBI_GA_COUNTER_INCREMENT ||
        code == ONIBI_GA_TEST_COUNTER_LT || code == ONIBI_GA_TEST_COUNTER_GE) {
      VALUE slot = onibi_hash_value_id(action, id_key_slot);
      if (!NIL_P(slot) && RB_INTEGER_TYPE_P(slot)) {
        uint32_t required = (uint32_t)NUM2ULONG(slot) + 1U;
        if (required > counter_count) counter_count = required;
      }
    }
    if (op == id_match_reset) features |= 8U;
    if (op == id_a_assert_begin_buffer || op == id_a_assert_end_buffer ||
        op == id_a_assert_begin_line || op == id_a_assert_end_line ||
        op == id_a_assert_semi_end_buffer || op == id_a_assert_search_origin || op == id_a_assert_word_boundary ||
        op == id_a_assert_nonword_boundary || op == id_a_assert_lookahead ||
        op == id_a_assert_lookbehind) features |= 16U;
  }
  rb_hash_aset(header, ID2SYM(id_key_features), UINT2NUM(features));
  rb_hash_aset(header, ID2SYM(id_key_class_count), UINT2NUM(class_count));
  rb_hash_aset(header, ID2SYM(id_key_capture_count), UINT2NUM(capture_count));
  rb_hash_aset(header, ID2SYM(id_key_semantic_capture_count), UINT2NUM(capture_count));
  rb_hash_aset(header, ID2SYM(id_key_subprogram_count), UINT2NUM((uint32_t)subprogram_records.count));
  rb_hash_aset(header, ID2SYM(id_key_counter_count), UINT2NUM(counter_count));
  rb_hash_aset(header, ID2SYM(id_key_literal_count), UINT2NUM(literal_count));
  rb_hash_aset(header, ID2SYM(id_key_version), INT2NUM(1));
  rb_hash_aset(header, ID2SYM(id_key_ignorecase), ignorecase ? Qtrue : Qfalse);
  rb_hash_aset(header, ID2SYM(id_key_multiline), multiline ? Qtrue : Qfalse);
  rb_hash_aset(header, ID2SYM(id_key_state_count), LONG2NUM((long)state_records.count));
  rb_hash_aset(header, ID2SYM(id_key_edge_count), LONG2NUM((long)r_edge_records.count));
  rb_hash_aset(header, ID2SYM(id_key_action_count), LONG2NUM((long)action_records.count));
  rb_hash_aset(header, ID2SYM(id_key_start_edge_base), LONG2NUM((long)r_edge_records.count));
  rb_hash_aset(header, ID2SYM(id_key_start_edge_count), LONG2NUM((long)r_start_edge_records.count));
  OnibiRSeqHeader physical;
  memset(&physical, 0, sizeof(physical));
  physical.magic = ONIBI_RSEQ_MAGIC;
  physical.version = ONIBI_RSEQ_VERSION;
  physical.flags = (ignorecase ? 1 : 0) | (multiline ? 2 : 0);
  physical.features = features;
  physical.class_count = class_count;
  physical.subprogram_count = (uint32_t)subprogram_records.count;
  physical.capture_count = capture_count;
  physical.semantic_capture_count = capture_count;
  physical.counter_count = counter_count;
  physical.start_edge_base = (uint32_t)r_edge_records.count;
  for (size_t i = 0; i < state_records.count; i++) {
    unsigned int opcode = state_records.entries[i].opcode;
    if (opcode == ONIBI_G_GRAPHEME || opcode == ONIBI_G_BACKREF || opcode == ONIBI_G_CALL ||
        opcode == ONIBI_G_ATOMIC || opcode == ONIBI_G_ABSENT) {
      physical.exec_kind = 2;
      break;
    }
    if (opcode == ONIBI_G_ACCEPT) continue;
  }
  if (physical.exec_kind == 0) {
    for (size_t i = 0; i < action_records.count; i++) {
      OnibiGActionOp code = action_records.entries[i].code;
      if (code == ONIBI_GA_CAPTURE_OPEN || code == ONIBI_GA_CAPTURE_CLOSE ||
          code == ONIBI_GA_COUNTER_INIT || code == ONIBI_GA_COUNTER_INCREMENT ||
          code == ONIBI_GA_TEST_COUNTER_LT || code == ONIBI_GA_TEST_COUNTER_GE) {
        physical.exec_kind = 1;
        break;
      }
    }
    for (long i = 0; i < RARRAY_LEN(start_edges) && physical.exec_kind == 0; i++) {
      VALUE edge_actions = onibi_hash_value_id(rb_ary_entry(start_edges, i), id_key_actions);
      for (long j = 0; j < RARRAY_LEN(edge_actions); j++) {
        OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(rb_ary_entry(edge_actions, j), id_key_action_code));
        if (code == ONIBI_GA_CAPTURE_OPEN || code == ONIBI_GA_COUNTER_INIT) {
          physical.exec_kind = 1;
          break;
        }
      }
    }
  }
  physical.state_count = (uint32_t)state_records.count;
  physical.edge_count = (uint32_t)(r_edge_records.count + r_start_edge_records.count);
  physical.action_count = (uint32_t)action_records.count;
  physical.start_edge_count = (uint32_t)r_start_edge_records.count;
  uint64_t offset = sizeof(OnibiRSeqHeader);
  physical.states_offset = (uint32_t)offset;
  offset += (uint64_t)sizeof(OnibiRState) * (uint64_t)state_records.count;
  physical.edges_offset = (uint32_t)offset;
  offset += (uint64_t)sizeof(OnibiREdge) * (uint64_t)physical.edge_count;
  physical.actions_offset = (uint32_t)offset;
  offset += (uint64_t)sizeof(OnibiRAction) * (uint64_t)action_records.count;
  physical.classes_offset = (uint32_t)offset;
  offset += class_section_size;
  physical.literals_offset = (uint32_t)offset;
  offset += literal_data_size;
  physical.descriptors_offset = (uint32_t)offset;
  offset += literal_desc_size;
  physical.subprograms_offset = (uint32_t)offset;
  offset += subprogram_section_size;
  physical.blob_size = (uint32_t)offset;
  rb_hash_aset(header, ID2SYM(id_key_states_offset), UINT2NUM(physical.states_offset));
  rb_hash_aset(header, ID2SYM(id_key_edges_offset), UINT2NUM(physical.edges_offset));
  rb_hash_aset(header, ID2SYM(id_key_actions_offset), UINT2NUM(physical.actions_offset));
  rb_hash_aset(header, ID2SYM(id_key_classes_offset), UINT2NUM(physical.classes_offset));
  rb_hash_aset(header, ID2SYM(id_key_literals_offset), UINT2NUM(physical.literals_offset));
  rb_hash_aset(header, ID2SYM(id_key_descriptors_offset), UINT2NUM(physical.descriptors_offset));
  rb_hash_aset(header, ID2SYM(id_key_subprograms_offset), UINT2NUM(physical.subprograms_offset));
  rb_hash_aset(header, ID2SYM(id_key_blob_size), UINT2NUM(physical.blob_size));
  VALUE blob = rb_str_new(NULL, (long)offset);
  memset(RSTRING_PTR(blob), 0, (size_t)offset);
  memcpy(RSTRING_PTR(blob), &physical, sizeof(physical));
  OnibiRState *physical_states = (OnibiRState *)(RSTRING_PTR(blob) + physical.states_offset);
  uint32_t class_index = 0, literal_index = 0;
  for (size_t i = 0; i < state_records.count; i++) {
    OnibiGirStateEntry *state = &state_records.entries[i];
    unsigned int opcode = state->opcode;
    physical_states[i].op = (uint8_t)(opcode == ONIBI_G_CHAR ? ONIBI_RS_CHAR :
      opcode == ONIBI_G_CLASS ? ONIBI_RS_CLASS : opcode == ONIBI_G_ANY ? ONIBI_RS_ANY :
      opcode == ONIBI_G_GRAPHEME ? ONIBI_RS_GRAPHEME : opcode == ONIBI_G_BACKREF ? ONIBI_RS_BACKREF :
      opcode == ONIBI_G_CALL ? ONIBI_RS_CALL : opcode == ONIBI_G_ATOMIC ? ONIBI_RS_ATOMIC :
      opcode == ONIBI_G_ABSENT ? ONIBI_RS_ABSENT : opcode == ONIBI_G_ACCEPT ? 0 : 0xff);
    uint32_t edge_base = 0;
    uint16_t edge_count = 0;
    for (size_t e = 0; e < r_edge_records.count; e++) {
      if (r_edge_records.entries[e].from != (long)i) continue;
      if (edge_count == 0) edge_base = (uint32_t)e;
      edge_count++;
    }
    physical_states[i].edge_base = edge_base;
    physical_states[i].edge_count = edge_count;
    if (opcode == ONIBI_G_CLASS || opcode == ONIBI_G_CHAR)
      physical_states[i].payload = state->payload_index;
  }
  OnibiREdge *physical_edges = (OnibiREdge *)(RSTRING_PTR(blob) + physical.edges_offset);
  for (size_t i = 0; i < r_edge_records.count; i++) {
    OnibiGirEdgeEntry *record = &r_edge_records.entries[i];
    uint32_t destination = (uint32_t)record->to;
    if (destination == (uint32_t)(state_records.count - 1)) destination = ONIBI_ACCEPT_STATE;
    physical_edges[i].destination = destination;
    physical_edges[i].action_offset = record->action_count == 0 ? 0 :
      (uint32_t)(sizeof(OnibiRAction) * ((uint32_t)record->action_offset + 1));
  }
  for (size_t i = 0; i < r_start_edge_records.count; i++) {
    OnibiGirEdgeEntry *record = &r_start_edge_records.entries[i];
    size_t index = r_edge_records.count + i;
    physical_edges[index].destination = (uint32_t)record->to;
    physical_edges[index].action_offset = record->action_count == 0 ? 0 :
      (uint32_t)(sizeof(OnibiRAction) * ((uint32_t)record->action_offset + 1));
  }
  OnibiRAction *physical_actions = (OnibiRAction *)(RSTRING_PTR(blob) + physical.actions_offset);
  for (size_t i = 0; i < action_records.count; i++) {
    VALUE action = action_records.entries[i].value;
    ID op = action_records.entries[i].op;
    OnibiGActionOp action_code = action_records.entries[i].code;
    physical_actions[i].op = (uint8_t)(action_code == ONIBI_GA_CAPTURE_OPEN || action_code == ONIBI_GA_CAPTURE_CLOSE ? ONIBI_RA_CAPTURE :
      action_code == ONIBI_GA_MATCH_RESET ? ONIBI_RA_MATCH_RESET :
      action_code == ONIBI_GA_ASSERT_POSITION ? ONIBI_RA_ASSERT_POSITION :
      action_code == ONIBI_GA_TEST_CAPTURE ? ONIBI_RA_TEST_CAPTURE :
      action_code == ONIBI_GA_COUNTER_INIT ? ONIBI_RA_COUNTER_SET :
      action_code == ONIBI_GA_COUNTER_INCREMENT ? ONIBI_RA_COUNTER_ADD :
      action_code == ONIBI_GA_TEST_COUNTER_LT || action_code == ONIBI_GA_TEST_COUNTER_GE ? ONIBI_RA_COUNTER_TEST : ONIBI_RA_END);
    physical_actions[i].flags = onibi_rseq_action_flags(op);
    if (op == id_a_test_capture && !RTEST(onibi_hash_value_id(action, id_key_set)))
      physical_actions[i].flags = ONIBI_RA_TEST_CAPTURE_UNSET;
    VALUE assert_kind = onibi_hash_value_id(action, id_key_assert_kind);
    physical_actions[i].arg16 = NIL_P(assert_kind) ? onibi_rseq_assert_kind(op) :
      (uint16_t)NUM2ULONG(assert_kind);
    if (op == id_a_assert_lookahead || op == id_a_assert_lookbehind) {
      int positive = RTEST(onibi_hash_value_id(action, id_key_positive));
      physical_actions[i].flags = op == id_a_assert_lookahead ?
        (positive ? 1 : 2) : (positive ? 5 : 6);
    }
    VALUE slot = onibi_hash_value_id(action, id_key_slot);
    if (!NIL_P(slot)) physical_actions[i].arg16 = (uint16_t)NUM2ULONG(slot);
    VALUE limit = onibi_hash_value_id(action, id_key_limit);
    if (!NIL_P(limit)) physical_actions[i].arg32 = (uint32_t)NUM2ULONG(limit);
    VALUE value = onibi_hash_value_id(action, id_key_value);
    if (!NIL_P(value)) physical_actions[i].arg32 = (uint32_t)NUM2ULONG(value);
    VALUE width = onibi_hash_value_id(action, id_key_width);
    if (!NIL_P(width)) physical_actions[i].arg32 = (uint32_t)NUM2ULONG(width);
  }
  OnibiClassDesc *class_descs = (OnibiClassDesc *)(RSTRING_PTR(blob) + physical.classes_offset);
  unsigned char *class_data = (unsigned char *)(class_descs + class_count);
  class_index = 0;
  for (size_t i = 0; i < class_payloads.count; i++) {
    OnibiRSeqClassPayloadEntry *entry = &class_payloads.entries[i];
    VALUE bitmap = entry->bitmap;
    class_descs[class_index].data_offset = (uint32_t)(physical.classes_offset + class_count * sizeof(OnibiClassDesc) + class_index * 32U);
    class_descs[class_index].data_length = 32;
    class_descs[class_index].kind = 0;
    class_descs[class_index].flags = entry->negated ? 1 : 0;
    if (!NIL_P(bitmap) && RSTRING_LEN(bitmap) == 32) memcpy(class_data + class_index * 32U, RSTRING_PTR(bitmap), 32);
    class_index++;
  }
  unsigned char *literal_data = (unsigned char *)(RSTRING_PTR(blob) + physical.literals_offset);
  OnibiLiteralDesc *literal_descs = (OnibiLiteralDesc *)(RSTRING_PTR(blob) + physical.descriptors_offset);
  literal_index = 0;
  for (size_t i = 0; i < literal_payloads.count; i++) {
    OnibiRSeqLiteralPayloadEntry *entry = &literal_payloads.entries[i];
    literal_descs[literal_index].data_offset = physical.literals_offset + literal_index;
    literal_descs[literal_index].data_length = 1;
    literal_descs[literal_index].flags = entry->ignorecase ? 1 : 0;
    literal_data[literal_index] = (unsigned char)entry->byte;
    literal_index++;
  }
  OnibiSubprogramDesc *physical_subprograms =
    (OnibiSubprogramDesc *)(RSTRING_PTR(blob) + physical.subprograms_offset);
  for (size_t i = 0; i < subprogram_records.count; i++) {
    OnibiRSeqSubprogramEntry *record = &subprogram_records.entries[i];
    physical_subprograms[i].entry = record->entry;
    physical_subprograms[i].accept = record->accept;
    physical_subprograms[i].flags = record->flags;
  }
  rb_obj_freeze(blob);
  VALUE result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(id_key_header), header);
  rb_hash_aset(result, ID2SYM(id_key_states), states);
  rb_hash_aset(result, ID2SYM(id_key_edges), r_edges);
  rb_hash_aset(result, ID2SYM(id_key_start_edges), r_start_edges);
  rb_hash_aset(result, ID2SYM(id_key_actions), actions);
  rb_hash_aset(result, ID2SYM(id_key_subprograms), subprograms);
  rb_hash_aset(result, ID2SYM(id_key_blob), blob);
  rb_hash_aset(result, ID2SYM(id_key_physical_graph),
               onibi_deep_freeze(onibi_rseq_physical_graph(result)));
  rb_obj_freeze(header); rb_obj_freeze(r_edges); rb_obj_freeze(r_start_edges); rb_obj_freeze(actions);
  rb_obj_freeze(result);
  /* Validate once, before publication.  Match calls use this immutable
     validated representation without repeating structural scans. */
  onibi_rseq_validate(result);
  onibi_rseq_class_payload_vector_free(&class_payloads);
  onibi_rseq_literal_payload_vector_free(&literal_payloads);
  onibi_rseq_action_vector_free(&action_records);
  onibi_gir_edge_vector_free(&r_edge_records);
  onibi_gir_edge_vector_free(&r_start_edge_records);
  onibi_gir_state_vector_free(&state_records);
  onibi_rseq_subprogram_vector_free(&subprogram_records);
  return result;
}

static VALUE onibi_alloc(VALUE klass) {
  onibi_regexp_t *obj;
  VALUE result = TypedData_Make_Struct(klass, onibi_regexp_t, &onibi_type, obj);
  MEMZERO(obj, onibi_regexp_t, 1);
  return result;
}

static VALUE onibi_build_program(VALUE argument) {
  VALUE source = rb_ary_entry(argument, 0);
  VALUE options = rb_ary_entry(argument, 1);
  VALUE tokens = rb_ary_entry(argument, 2);
  VALUE parsed = onibi_parser_parse_internal(source, options, tokens);
  VALUE compiled = onibi_compiler_compile(Qnil, parsed);
  VALUE rseq = onibi_rseq_lower(Qnil, compiled);
  return rb_ary_new_from_args(2, parsed, rseq);
}

static VALUE onibi_parse_program(VALUE argument) {
  VALUE source = rb_ary_entry(argument, 0);
  VALUE options = rb_ary_entry(argument, 1);
  VALUE tokens = rb_ary_entry(argument, 2);
  return onibi_parser_parse_internal(source, options, tokens);
}

static VALUE onibi_make_mri_regexp(VALUE argument) {
  VALUE source = rb_ary_entry(argument, 0);
  VALUE options = rb_ary_entry(argument, 1);
  return rb_funcall(rb_cRegexp, id_new, 2, source, options);
}

/* Compute all dispatch/compiler feature bits in one pass over the immutable
   token stream.  Runtime entry points use these bits and never rescan source. */
static void onibi_token_features(const OnibiFeatureTokenVector *feature_tokens, onibi_regexp_t *obj) {
  int in_class = 0;
  long class_depth = 0;
  int repeat_active = 0;
  uint64_t repeat_value = 0;
  int repeat_have_digit = 0;
  int repeat_over_limit = 0;
  OnibiFeatureToken *previous = NULL;
  obj->has_class_intersection = 0;
  obj->has_nested_class = 0;
  obj->has_large_repeat = 0;
  obj->has_absence = 0;
  obj->has_conditional = 0;
  obj->has_atomic = 0;
  obj->has_backref = 0;
  obj->has_ascii_property = 0;
  obj->has_unicode_property = 0;
  obj->has_unicode_property_in_class = 0;
  obj->has_grapheme = 0;
  obj->has_property_escape = 0;
  obj->has_unicode_escape = 0;
  obj->has_non_ascii_literal = 0;
  obj->has_non_ascii_class = 0;
  obj->has_safe_multibyte_class = 0;
  obj->has_wildcard = 0;
  obj->has_anchor = 0;
  obj->has_meta_escape = 0;
  obj->has_subroutine = 0;
  obj->has_dynamic = 0;
  obj->has_tagged = 0;
  obj->has_inline_ignorecase = 0;
  for (size_t i = 0; i < feature_tokens->count; i++) {
    OnibiFeatureToken *token = &feature_tokens->items[i];
    OnibiTokenKind kind_code = token->kind;
    if (kind_code == ONIBI_TOKEN_LITERAL && token->byte > 127) {
      obj->has_non_ascii_literal = 1;
      if (in_class) obj->has_non_ascii_class = 1;
    }
    if (kind_code == ONIBI_TOKEN_WILDCARD) obj->has_wildcard = 1;
    if (kind_code == ONIBI_TOKEN_ANCHOR) obj->has_anchor = 1;
    if (kind_code == ONIBI_TOKEN_OPTION_SCOPE_START || kind_code == ONIBI_TOKEN_OPTION_GLOBAL) {
      if (token->inline_ignorecase)
        obj->has_inline_ignorecase = 1;
    }
    if (kind_code == ONIBI_TOKEN_CLASS_START) {
      if (in_class) obj->has_nested_class = 1;
      in_class = 1;
      class_depth++;
      previous = NULL;
      continue;
    }
    if (kind_code == ONIBI_TOKEN_CLASS_END) {
      if (class_depth > 0) class_depth--;
      in_class = class_depth > 0;
      previous = NULL;
      continue;
    }
    if (repeat_active) {
      long value = token->byte;
      if (kind_code == ONIBI_TOKEN_QUANTIFIER && value == '}') {
        if (repeat_have_digit && repeat_over_limit) obj->has_large_repeat = 1;
        repeat_active = 0;
      } else if (kind_code == ONIBI_TOKEN_QUANTIFIER && value == ',') {
        if (repeat_have_digit && repeat_over_limit) obj->has_large_repeat = 1;
        repeat_value = 0; repeat_have_digit = 0; repeat_over_limit = 0;
      } else if (kind_code == ONIBI_TOKEN_LITERAL && value >= '0' && value <= '9') {
        repeat_have_digit = 1;
        if (repeat_value > (uint64_t)ONIBI_RSEQ_REPEAT_UNROLL_LIMIT ||
            (repeat_value == (uint64_t)ONIBI_RSEQ_REPEAT_UNROLL_LIMIT && (uint64_t)(value - '0') > 0U))
          repeat_over_limit = 1;
        else if (repeat_value <= UINT64_MAX / 10U)
          repeat_value = repeat_value * 10U + (uint64_t)(value - '0');
      } else {
        repeat_active = 0;
      }
    }
    if (in_class && kind_code == ONIBI_TOKEN_LITERAL && token->byte == '[')
      obj->has_nested_class = 1;
    if (!in_class && kind_code == ONIBI_TOKEN_QUANTIFIER && token->byte == '{') {
      repeat_active = 1;
      repeat_value = 0; repeat_have_digit = 0; repeat_over_limit = 0;
    }
    if (in_class && previous && previous->kind == ONIBI_TOKEN_LITERAL &&
        kind_code == ONIBI_TOKEN_LITERAL && previous->byte == '&' && token->byte == '&')
      obj->has_class_intersection = 1;
    if (kind_code == ONIBI_TOKEN_SUBROUTINE) {
      obj->has_subroutine = 1;
      obj->has_dynamic = 1;
    } else if (kind_code == ONIBI_TOKEN_BACKREF ||
               kind_code == ONIBI_TOKEN_ATOMIC_START ||
               kind_code == ONIBI_TOKEN_ABSENCE_START) {
      obj->has_dynamic = 1;
      if (kind_code == ONIBI_TOKEN_BACKREF) obj->has_backref = 1;
      if (kind_code == ONIBI_TOKEN_ATOMIC_START) obj->has_atomic = 1;
      if (kind_code == ONIBI_TOKEN_ABSENCE_START) obj->has_absence = 1;
    } else if (kind_code == ONIBI_TOKEN_CONDITIONAL_START) {
      /* Simple capture conditionals lower to guarded GIR edges.  Mark the
         construct only for diagnostics; compile failure selects MRI. */
      obj->has_conditional = 1;
    } else if (kind_code == ONIBI_TOKEN_ESCAPE) {
      if (token->byte == 'X') { obj->has_grapheme = 1; obj->has_dynamic = 1; }
      if (token->byte == 'p' || token->byte == 'P') {
        if (token->property_kind != ONIBI_ASCII_PROP_UNKNOWN) {
          obj->has_ascii_property = 1;
          ID property_id = token->name_id;
          if (property_id != id_prop_ascii && property_id != id_prop_ascii_hex)
            obj->has_unicode_property = 1;
          if (in_class) obj->has_unicode_property_in_class = 1;
        }
        else { obj->has_property_escape = 1; obj->has_dynamic = 1; }
      }
      if (token->byte == 'u') obj->has_unicode_escape = 1;
    } else if (kind_code == ONIBI_TOKEN_META_ESCAPE) {
      obj->has_meta_escape = 1;
      obj->has_dynamic = 1;
    } else if (kind_code == ONIBI_TOKEN_GROUP_START ||
               (kind_code == ONIBI_TOKEN_QUANTIFIER && token->byte == '{')) {
      obj->has_tagged = 1;
    }
    previous = token;
  }
}

static int onibi_ast_safe_multibyte_class(VALUE ast) {
  if (!RB_TYPE_P(ast, T_HASH)) return 0;
  OnibiAstKind type = onibi_ast_kind(ast);
  if (type == ONIBI_AST_CHARACTER_CLASS) {
    VALUE children = onibi_hash_value_id(ast, id_key_children);
    VALUE ranges = onibi_hash_value_id(ast, id_key_ranges);
    if (RTEST(onibi_hash_value_id(ast, id_key_negated)) || !RB_TYPE_P(children, T_ARRAY) ||
        !RB_TYPE_P(ranges, T_ARRAY) || RARRAY_LEN(children) == 0) return 0;
    for (long i = 0; i < RARRAY_LEN(children); i++) {
      VALUE child = rb_ary_entry(children, i);
      VALUE kind_code = onibi_hash_value_id(child, id_key_kind_code);
      OnibiAstKind child_type = onibi_ast_kind(child);
      if ((!NIL_P(kind_code) && NUM2UINT(kind_code) == ONIBI_TOKEN_LITERAL) || child_type == ONIBI_AST_LITERAL) continue;
      VALUE child_name = onibi_hash_value_id(child, id_key_name);
      VALUE child_name_id = onibi_hash_value_id(child, id_key_name_id);
      ID property = NIL_P(child_name_id) ? (NIL_P(child_name) ? 0 : rb_intern_str(child_name)) : (ID)NUM2ULONG(child_name_id);
      if (((!NIL_P(kind_code) && NUM2UINT(kind_code) == ONIBI_TOKEN_ESCAPE) || child_type == ONIBI_AST_ESCAPE) && !NIL_P(child_name) &&
          onibi_unicode_ctype_id(property) >= 0) continue;
      return 0;
    }
    for (long i = 0; i < RARRAY_LEN(ranges); i++) {
      VALUE range = rb_ary_entry(ranges, i);
      if (!RB_TYPE_P(range, T_ARRAY) || RARRAY_LEN(range) != 2) return 0;
      VALUE first = rb_ary_entry(range, 0), last = rb_ary_entry(range, 1);
      if ((!RB_INTEGER_TYPE_P(first) && !RB_TYPE_P(first, T_STRING)) ||
          (!RB_INTEGER_TYPE_P(last) && !RB_TYPE_P(last, T_STRING))) return 0;
    }
    return 1;
  }
  if (type == ONIBI_AST_SEQUENCE) {
    VALUE children = onibi_hash_value_id(ast, id_key_children);
    if (!RB_TYPE_P(children, T_ARRAY)) return 0;
    for (long i = 0; i < RARRAY_LEN(children); i++)
      if (!onibi_ast_safe_multibyte_class(rb_ary_entry(children, i))) return 0;
    return 1;
  }
  if (type == ONIBI_AST_LITERAL || type == ONIBI_AST_ANCHOR) return 1;
  return 0;
}

static int onibi_ast_contains_anchor(VALUE ast) {
  if (NIL_P(ast)) return 0;
  if (RB_TYPE_P(ast, T_ARRAY)) {
    for (long i = 0; i < RARRAY_LEN(ast); i++)
      if (onibi_ast_contains_anchor(rb_ary_entry(ast, i))) return 1;
    return 0;
  }
  if (!RB_TYPE_P(ast, T_HASH)) return 0;
  if (onibi_ast_kind(ast) == ONIBI_AST_ANCHOR) return 1;
  const ID keys[] = {id_key_body, id_key_children, id_key_branches, id_key_atom, id_key_yes, id_key_no};
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
    if (onibi_ast_contains_anchor(onibi_hash_value_id(ast, keys[i]))) return 1;
  return 0;
}

static int onibi_ast_anchor_repeat(VALUE ast) {
  if (NIL_P(ast)) return 0;
  if (RB_TYPE_P(ast, T_ARRAY)) {
    for (long i = 0; i < RARRAY_LEN(ast); i++)
      if (onibi_ast_anchor_repeat(rb_ary_entry(ast, i))) return 1;
    return 0;
  }
  if (!RB_TYPE_P(ast, T_HASH)) return 0;
  if (onibi_ast_kind(ast) == ONIBI_AST_QUANTIFIER &&
      onibi_ast_contains_anchor(onibi_hash_value_id(ast, id_key_atom))) return 1;
  const ID keys[] = {id_key_body, id_key_children, id_key_branches, id_key_atom, id_key_yes, id_key_no};
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
    if (onibi_ast_anchor_repeat(onibi_hash_value_id(ast, keys[i]))) return 1;
  return 0;
}

static int onibi_ast_nullable(VALUE ast, int *nullable_capture) {
  if (!RB_TYPE_P(ast, T_HASH)) return 1;
  OnibiAstKind type = onibi_ast_kind(ast);
  if (type == ONIBI_AST_CAPTURE) {
    int body_nullable = onibi_ast_nullable(onibi_hash_value_id(ast, id_key_body), nullable_capture);
    if (body_nullable) *nullable_capture = 1;
    return body_nullable;
  }
  if (type == ONIBI_AST_QUANTIFIER) {
    VALUE min = onibi_hash_value_id(ast, id_key_min);
    if (!NIL_P(min) && NUM2LONG(min) == 0) {
      if (onibi_ast_has_capture(onibi_hash_value_id(ast, id_key_atom))) *nullable_capture = 1;
      (void)onibi_ast_nullable(onibi_hash_value_id(ast, id_key_atom), nullable_capture);
      return 1;
    }
    return onibi_ast_nullable(onibi_hash_value_id(ast, id_key_atom), nullable_capture);
  }
  if (type == ONIBI_AST_SEQUENCE) {
    int result = 1;
    VALUE children = onibi_hash_value_id(ast, id_key_children);
    for (long i = 0; i < RARRAY_LEN(children); i++)
      if (!onibi_ast_nullable(rb_ary_entry(children, i), nullable_capture)) result = 0;
    return result;
  }
  if (type == ONIBI_AST_ALTERNATIVE) {
    int result = 0;
    VALUE branches = onibi_hash_value_id(ast, id_key_branches);
    for (long i = 0; i < RARRAY_LEN(branches); i++)
      if (onibi_ast_nullable(rb_ary_entry(branches, i), nullable_capture)) result = 1;
    return result;
  }
  if (type == ONIBI_AST_GROUP || type == ONIBI_AST_OPTION_SCOPE || type == ONIBI_AST_ATOMIC)
    return onibi_ast_nullable(onibi_hash_value_id(ast, id_key_body), nullable_capture);
  if (type == ONIBI_AST_LOOKAHEAD || type == ONIBI_AST_LOOKBEHIND ||
      type == ONIBI_AST_ANCHOR || type == ONIBI_AST_MATCH_RESET) return 1;
  return 0;
}

static int onibi_ast_nullable_absence(VALUE ast) {
  if (NIL_P(ast)) return 0;
  if (RB_TYPE_P(ast, T_ARRAY)) {
    for (long i = 0; i < RARRAY_LEN(ast); i++)
      if (onibi_ast_nullable_absence(rb_ary_entry(ast, i))) return 1;
    return 0;
  }
  if (!RB_TYPE_P(ast, T_HASH)) return 0;
  if (onibi_ast_kind(ast) == ONIBI_AST_ABSENCE) {
    int ignored = 0;
    if (onibi_ast_nullable(onibi_hash_value_id(ast, id_key_body), &ignored)) return 1;
  }
  const ID keys[] = {id_key_body, id_key_children, id_key_branches, id_key_atom, id_key_yes, id_key_no};
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
    if (onibi_ast_nullable_absence(onibi_hash_value_id(ast, keys[i]))) return 1;
  return 0;
}

static int onibi_option_mask(VALUE options) {
  if (NIL_P(options)) return 0;
  if (options == Qtrue) return 1;
  if (options == Qfalse) return 0;
  if (RB_TYPE_P(options, T_STRING)) {
    int mask = 0;
    const char *text = StringValueCStr(options);
    for (long i = 0; i < RSTRING_LEN(options); i++) {
      if (text[i] == 'i') mask |= 1;
      else if (text[i] == 'x') mask |= 2;
      else if (text[i] == 'm') mask |= 4;
      else if (text[i] == 'n') mask |= 32;
      else rb_raise(rb_eArgError, "unknown regexp option: %s", text);
    }
    return mask;
  }
  if (RB_TYPE_P(options, T_ARRAY)) {
    int mask = 0;
    for (long i = 0; i < RARRAY_LEN(options); i++) {
      VALUE item = rb_ary_entry(options, i);
      ID option_id = SYMBOL_P(item) ? SYM2ID(item) : rb_intern_str(StringValue(item));
      if (option_id == id_opt_ignorecase) mask |= 1;
      else if (option_id == id_opt_multiline) mask |= 4;
      else if (option_id == id_opt_extended) mask |= 2;
      else if (option_id == id_opt_fixedencoding) mask |= 16;
      else if (option_id == id_opt_noencoding) mask |= 32;
      else rb_raise(rb_eArgError, "unknown regexp option");
    }
    return mask;
  }
  /* MRI treats any other truthy scalar as the default true option. */
  if (RTEST(options) && !RB_INTEGER_TYPE_P(options)) return 1;
  /* MRI ignores option bits that are not part of the public regexp mask. */
  return NUM2INT(options) & (1 | 2 | 4 | 16 | 32);
}

static VALUE onibi_initialize(int argc, VALUE *argv, VALUE self) {
  VALUE pattern, options = Qnil;
  rb_scan_args(argc, argv, "11", &pattern, &options);
  onibi_regexp_t *obj;
  TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  VALUE inherited_timeout = Qnil;
  if (rb_obj_is_kind_of(pattern, cRegexp)) {
    onibi_regexp_t *prior; TypedData_Get_Struct(pattern, onibi_regexp_t, &onibi_type, prior);
    pattern = rb_funcall(prior->regexp, id_source, 0);
    if (NIL_P(options)) options = INT2NUM(prior->options);
    inherited_timeout = prior->timeout_seconds > 0.0 ? DBL2NUM(prior->timeout_seconds) : Qnil;
  } else if (rb_obj_is_kind_of(pattern, rb_cRegexp)) {
    VALUE prior = pattern;
    pattern = rb_funcall(prior, id_source, 0);
    if (NIL_P(options)) options = rb_funcall(prior, id_options, 0);
  }
  VALUE timeout = Qnil;
  if (RB_TYPE_P(options, T_HASH)) {
    timeout = rb_hash_aref(options, ID2SYM(id_timeout));
    options = rb_hash_aref(options, ID2SYM(id_options));
  }
  if (NIL_P(timeout)) timeout = inherited_timeout;
  int opts = onibi_option_mask(options);
  obj->timeout_seconds = NIL_P(timeout) ? onibi_default_timeout : onibi_timeout_value(timeout);
  VALUE source = StringValue(pattern);
  if ((opts & 32) && rb_enc_get_index(source) != rb_ascii8bit_encindex() &&
      !rb_enc_str_asciionly_p(source))
    rb_raise(eRegexpError, "non-ASCII pattern with no encoding");
  if (!(opts & 32) && !rb_enc_str_asciionly_p(source) && !(opts & 16)) opts |= 16;
  obj->options = opts;
  obj->source = rb_str_dup(source);
  rb_obj_freeze(obj->source);
  obj->names = Qnil;
  obj->named_captures = Qnil;
  obj->rseq = Qnil;
  obj->feature_tokens = NULL;
  obj->feature_token_count = 0;
  obj->has_nullable_capture = 0;
  VALUE tokens = onibi_tokenize_internal(source, (opts & 2) != 0);
  OnibiFeatureTokenVector feature_tokens = onibi_feature_tokens(tokens);
  obj->feature_tokens = feature_tokens.items;
  obj->feature_token_count = feature_tokens.count;
  OnibiFeatureTokenVector feature_view = { obj->feature_tokens, obj->feature_token_count };
  onibi_token_features(&feature_view, obj);
  if (!(opts & 32) && rb_enc_get_index(source) == rb_utf8_encindex() &&
      obj->has_property_escape) opts |= 16;
  if (((opts & 32) && rb_enc_str_asciionly_p(source) &&
       (obj->has_non_ascii_literal || obj->has_property_escape)) ||
      (!(opts & 32) && rb_enc_get_index(source) != rb_utf8_encindex() &&
       rb_enc_get_index(source) != rb_usascii_encindex() &&
       (obj->has_non_ascii_literal || obj->has_property_escape))) opts |= 16;
  obj->options = opts;
  VALUE regexp_source = source;
  if (rb_enc_get_index(source) != rb_utf8_encindex() && obj->has_unicode_escape) {
    regexp_source = rb_funcall(source, id_encode, 1, rb_enc_from_encoding(rb_utf8_encoding()));
    opts |= 16;
    obj->options = opts;
  }
  VALUE regexp_args = rb_ary_new_from_args(2, regexp_source, INT2NUM(opts));
  int regexp_state = 0;
  obj->regexp = rb_protect(onibi_make_mri_regexp, regexp_args, &regexp_state);
  if (regexp_state) {
    VALUE error = rb_errinfo();
    VALUE message = rb_funcall(error, id_message, 0);
    rb_set_errinfo(Qnil);
    rb_raise(eRegexpError, "%s", StringValueCStr(message));
  }
  obj->names = rb_funcall(obj->regexp, id_names, 0);
  obj->named_captures = rb_funcall(obj->regexp, id_named_captures, 0);
  rb_obj_freeze(obj->names);
  rb_obj_freeze(obj->named_captures);
  VALUE program_args = rb_ary_new_from_args(3, source, INT2NUM(opts), tokens);
  int program_state = 0;
  VALUE parsed = Qnil;
  VALUE program = (obj->has_large_repeat ||
                   obj->has_property_escape || obj->has_meta_escape) ?
    rb_protect(onibi_parse_program, program_args, &program_state) :
    rb_protect(onibi_build_program, program_args, &program_state);
  if (!program_state) {
    parsed = (obj->has_large_repeat ||
                   obj->has_property_escape || obj->has_meta_escape) ? program : rb_ary_entry(program, 0);
    obj->rseq = (obj->has_large_repeat ||
                 obj->has_property_escape || obj->has_meta_escape) ? Qnil : rb_ary_entry(program, 1);
    if (!NIL_P(parsed)) {
      OnibiParsed *parsed_data = onibi_parsed_get(parsed);
      obj->has_safe_multibyte_class = (parsed_data->ast_flags & ONIBI_AST_FLAG_SAFE_MULTIBYTE_CLASS) != 0;
      obj->has_anchor_repeat = (parsed_data->ast_flags & ONIBI_AST_FLAG_ANCHOR_REPEAT) != 0;
      obj->has_nullable_absence = (parsed_data->ast_flags & ONIBI_AST_FLAG_NULLABLE_ABSENCE) != 0;
      obj->has_nullable_capture = (parsed_data->ast_flags & ONIBI_AST_FLAG_NULLABLE_CAPTURE) != 0;
      /* The AST is an initialization artifact.  The published RSeq/GIR
         objects carry all runtime data, so release the Ruby adapter now. */
      parsed_data->ast = Qnil;
    }
    /* Keep constructs without a complete GIR lowering on MRI.  This test
       runs once during compilation.  Match calls do not inspect source. */
    int encoded_literal_program = (opts & 16) && !(opts & (1 | 32)) &&
      rb_enc_get_index(source) != rb_ascii8bit_encindex() &&
      !rb_enc_str_asciionly_p(source) &&
      obj->has_non_ascii_literal && !obj->has_wildcard && !obj->has_anchor &&
      (!obj->has_non_ascii_class || obj->has_safe_multibyte_class);
    if ((!onibi_ascii_pattern(source) && !encoded_literal_program) ||
        ((opts & 16) && !encoded_literal_program) || (opts & 32)) {
      parsed = obj->rseq = Qnil;
    }
  } else {
    rb_set_errinfo(Qnil);
    /* Keep a failed lowering on the dynamic MRI boundary. */
    obj->has_dynamic = 1;
  }
  if (obj->has_subroutine && !NIL_P(obj->rseq)) obj->has_dynamic = 0;
  obj->execution_kind = obj->has_dynamic ? ONIBI_EXEC_DYNAMIC :
    (obj->has_tagged ? ONIBI_EXEC_TAGGED : ONIBI_EXEC_REGULAR);
  rb_obj_freeze(self);
  return self;
}

static VALUE onibi_match(int argc, VALUE *argv, VALUE self) {
  VALUE str, pos = Qnil;
  rb_scan_args(argc, argv, "11", &str, &pos);
  if (argc == 2 && NIL_P(pos)) rb_raise(rb_eTypeError, "no implicit conversion from nil to integer");
  if (argc == 2 && RB_TYPE_P(pos, T_STRING)) rb_raise(rb_eTypeError, "no implicit conversion of String into Integer");
  onibi_regexp_t *obj;
  TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  /* Run the compiled C interpreter before MatchData materialization.  The
     MRI call below remains only the final host-side MatchData constructor. */
  if (NIL_P(pos) && RB_TYPE_P(str, T_STRING) && !NIL_P(obj->rseq) &&
      !onibi_mri_compat_path_p(obj) && !(obj->options & 32) &&
      (!onibi_regexp_fixed_p(obj) || onibi_encoded_literal_program_p(obj)) &&
      onibi_vm_input_eligible(obj, str) &&
      (!obj->has_ascii_property || rb_enc_str_asciionly_p(str) ||
       (obj->has_unicode_property &&
        (rb_enc_get_index(str) == rb_utf8_encindex() ||
         rb_enc_get_index(str) == rb_enc_get_index(obj->source)))) &&
      (rb_enc_str_asciionly_p(str) || onibi_valid_encoding(str))) {
    if (!RTEST(onibi_vm_match_p(self, str))) { rb_backref_set(Qnil); return Qnil; }
  }
  VALUE match = NIL_P(pos) ? rb_funcall(obj->regexp, id_match, 1, str)
                           : rb_funcall(obj->regexp, id_match, 2, str, pos);
  if (NIL_P(match)) { rb_backref_set(Qnil); return Qnil; }
  return rb_block_given_p() ? rb_yield(match) : match;
}

static VALUE onibi_match_p(int argc, VALUE *argv, VALUE self) {
  VALUE str, pos = Qnil;
  rb_scan_args(argc, argv, "11", &str, &pos);
  onibi_regexp_t *obj;
  TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  if (NIL_P(pos) && !NIL_P(obj->rseq) && RB_TYPE_P(str, T_STRING) &&
      !onibi_mri_compat_path_p(obj) && !(obj->options & 32) && (!onibi_regexp_fixed_p(obj) || onibi_encoded_literal_program_p(obj)) &&
      onibi_vm_input_eligible(obj, str) &&
      (!obj->has_ascii_property || rb_enc_str_asciionly_p(str) ||
       (obj->has_unicode_property &&
        (rb_enc_get_index(str) == rb_utf8_encindex() ||
         rb_enc_get_index(str) == rb_enc_get_index(obj->source)))) &&
      (rb_enc_str_asciionly_p(str) || onibi_valid_encoding(str)))
    return onibi_vm_match_p(self, str);
  return NIL_P(pos) ? rb_funcall(obj->regexp, id_match_p, 1, str)
                    : rb_funcall(obj->regexp, id_match_p, 2, str, pos);
}

/* The parser and compiler decide support at initialize time.  Keep this
   entry point free of source inspection. */
static VALUE onibi_source(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(obj->regexp, id_source, 0);
}
static VALUE onibi_names(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return obj->names;
}
static VALUE onibi_named_captures(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return obj->named_captures;
}
static VALUE onibi_casefold_p(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return (obj->options & 1) ? Qtrue : Qfalse;
}
static VALUE onibi_hash(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  st_index_t value = rb_str_hash(obj->source);
  value ^= (st_index_t)(unsigned int)obj->options;
  return ULONG2NUM((unsigned long)value);
}
static VALUE onibi_equal(VALUE self, VALUE other) {
  if (!rb_obj_is_kind_of(other, cRegexp)) return Qfalse;
  onibi_regexp_t *left; onibi_regexp_t *right;
  TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, left);
  TypedData_Get_Struct(other, onibi_regexp_t, &onibi_type, right);
  return (left->options == right->options && rb_str_equal(left->source, right->source)) ? Qtrue : Qfalse;
}
static VALUE onibi_options(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return INT2NUM(obj->options);
}
static VALUE onibi_fixed_encoding_p(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  /* MRI fixes NOENCODING only when syntax forces a binary property mode. */
  return onibi_regexp_fixed_p(obj) ||
    ((obj->options & 32) && obj->has_ascii_property) ||
    (rb_enc_str_asciionly_p(obj->source) && obj->has_non_ascii_literal) ? Qtrue : Qfalse;
}
static VALUE onibi_no_encoding_p(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return (obj->options & 32) ? Qtrue : Qfalse;
}
static VALUE onibi_inspect(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(obj->regexp, id_inspect, 0);
}
static VALUE onibi_to_s(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(obj->regexp, id_to_s, 0);
}
static VALUE onibi_encoding(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(obj->regexp, id_encoding, 0);
}
static VALUE onibi_timeout(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return obj->timeout_seconds > 0.0 ? DBL2NUM(obj->timeout_seconds) : Qnil;
}
static VALUE onibi_timeout_set(VALUE klass, VALUE value) {
  (void)klass;
  onibi_default_timeout = onibi_timeout_value(value);
  return NIL_P(value) ? Qnil : DBL2NUM(onibi_default_timeout);
}
static VALUE onibi_timeout_default(VALUE klass) {
  (void)klass;
  return onibi_default_timeout > 0.0 ? DBL2NUM(onibi_default_timeout) : Qnil;
}

static VALUE onibi_regexp_escape(VALUE klass, VALUE string) {
  (void)klass;
  return rb_funcall(rb_cRegexp, id_escape, 1, string);
}

static VALUE onibi_native_regexp_source(VALUE regexp) {
  VALUE method = rb_funcall(rb_cRegexp, id_instance_method, 1, ID2SYM(id_source));
  VALUE bound = rb_funcall(method, id_bind, 1, regexp);
  return rb_funcall(bound, id_call, 0);
}

static VALUE onibi_regexp_union(int argc, VALUE *argv, VALUE klass) {
  VALUE normalized = rb_ary_new_capa(argc);
  for (int i = 0; i < argc; i++) {
    VALUE item = argv[i];
    if (rb_obj_is_kind_of(item, rb_cRegexp) && rb_obj_class(item) != rb_cRegexp) {
      VALUE source = onibi_native_regexp_source(item);
      item = rb_funcall(rb_cRegexp, id_new, 2, source, INT2NUM(rb_reg_options(item)));
    }
    rb_ary_push(normalized, item);
  }
  VALUE mri_regexp = rb_funcallv(rb_cRegexp, id_union, (int)RARRAY_LEN(normalized), RARRAY_PTR(normalized));
  return rb_funcall(klass, id_new, 1, mri_regexp);
}

static VALUE onibi_regexp_try_convert(VALUE klass, VALUE value) {
  (void)klass;
  if (rb_obj_is_kind_of(value, cRegexp) || rb_obj_is_kind_of(value, rb_cRegexp)) return value;
  if (!rb_respond_to(value, id_to_regexp)) return Qnil;
  VALUE converted = rb_funcall(value, id_to_regexp, 0);
  if (NIL_P(converted)) return Qnil;
  if (!rb_obj_is_kind_of(converted, cRegexp) && !rb_obj_is_kind_of(converted, rb_cRegexp))
    rb_raise(rb_eTypeError, "can't convert %s into Regexp", rb_obj_classname(value));
  return converted;
}

static VALUE onibi_regexp_linear_time_p(VALUE klass, VALUE pattern) {
  VALUE regexp = rb_funcall(klass, id_new, 1, pattern);
  onibi_regexp_t *obj;
  TypedData_Get_Struct(regexp, onibi_regexp_t, &onibi_type, obj);
  return (!obj->has_dynamic && !obj->has_backref && !obj->has_subroutine &&
          !obj->has_absence && !obj->has_conditional && !obj->has_atomic) ? Qtrue : Qfalse;
}

#if 0 /* Private diagnostic pipeline; kept only as historical reference. */
static VALUE onibi_pipeline_token_slice(VALUE source, VALUE token) {
  long start = NUM2LONG(onibi_hash_value(token, "start"));
  long finish = NUM2LONG(onibi_hash_value(token, "end"));
  VALUE slice = rb_str_substr(source, start, finish - start);
  return NIL_P(slice) ? rb_str_new_cstr("") : slice;
}

static VALUE onibi_pipeline_build(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  VALUE out = rb_hash_new();
  VALUE parsed = obj->parsed;
  VALUE src = NIL_P(parsed) ? obj->source : onibi_hash_value(parsed, "source");
  VALUE tokens = obj->tokens;
  rb_hash_aset(out, ID2SYM(rb_intern("tokens")), tokens);
  VALUE ast = rb_hash_new();
  int is_quant = RARRAY_LEN(tokens) >= 2 &&
    onibi_token_kind(rb_ary_entry(tokens, RARRAY_LEN(tokens) - 1)) == rb_intern("quantifier");
  int is_alt = 0, is_anchor = 0;
  for (long i = 0; i < RARRAY_LEN(tokens); i++) {
    ID kind = onibi_token_kind(rb_ary_entry(tokens, i));
    if (kind == rb_intern("alternation")) is_alt = 1;
    if (kind == rb_intern("anchor")) is_anchor = 1;
  }
  int is_class = RARRAY_LEN(tokens) >= 2 &&
    onibi_token_kind(rb_ary_entry(tokens, 0)) == rb_intern("class_start") &&
    onibi_token_kind(rb_ary_entry(tokens, RARRAY_LEN(tokens) - 1)) == rb_intern("class_end");
  rb_hash_aset(ast, ID2SYM(rb_intern("type")), ID2SYM(rb_intern(is_quant ? "quantifier" : (is_alt ? "alternation" : (is_class ? "character_class" : (is_anchor ? "anchor" : "sequence"))))));
  VALUE children = rb_ary_new();
  for (long i = 0; i < RARRAY_LEN(tokens); i++) {
    VALUE token = rb_ary_entry(tokens, i), node = rb_hash_new();
    ID kind = SYM2ID(rb_hash_aref(token, ID2SYM(rb_intern("kind"))));
    const char *type = "character_class";
    if (kind == rb_intern("literal")) type = "literal";
    else if (kind == rb_intern("escape")) type = "escape";
    else if (kind == rb_intern("wildcard")) type = "any";
    else if (kind == rb_intern("anchor")) type = "anchor";
    else if (kind == rb_intern("alternation")) type = "alternative";
    else if (kind == rb_intern("group_start") || kind == rb_intern("group_end")) type = "capture";
    else if (kind == rb_intern("quantifier")) type = "quantifier";
    rb_hash_aset(node, ID2SYM(rb_intern("type")), ID2SYM(rb_intern(type)));
    rb_hash_aset(node, ID2SYM(rb_intern("byte")), rb_hash_aref(token, ID2SYM(rb_intern("byte"))));
    rb_ary_push(children, node);
  }
  rb_hash_aset(ast, ID2SYM(rb_intern("children")), children);
  if (is_class) {
    VALUE ranges = rb_ary_new();
    for (long i = 1; i + 2 < RARRAY_LEN(tokens); i++) {
      VALUE left = rb_ary_entry(tokens, i), marker = rb_ary_entry(tokens, i + 1), right = rb_ary_entry(tokens, i + 2);
      if (onibi_token_kind(marker) == rb_intern("class_range") &&
          onibi_token_kind(left) == rb_intern("literal") && onibi_token_kind(right) == rb_intern("literal")) {
        VALUE range = rb_ary_new();
        rb_ary_push(range, LONG2NUM(onibi_token_byte(left)));
        rb_ary_push(range, LONG2NUM(onibi_token_byte(right)));
        rb_ary_push(ranges, range);
      }
    }
    rb_hash_aset(ast, ID2SYM(rb_intern("ranges")), ranges);
    rb_hash_aset(ast, ID2SYM(rb_intern("negated")),
                 RARRAY_LEN(tokens) > 1 && onibi_token_kind(rb_ary_entry(tokens, 1)) == rb_intern("class_negate") ? Qtrue : Qfalse);
  }
  if (is_quant) {
    VALUE quantifier = rb_ary_entry(tokens, RARRAY_LEN(tokens) - 1);
    VALUE atom = rb_ary_entry(tokens, RARRAY_LEN(tokens) - 2);
    VALUE quantifier_source = onibi_pipeline_token_slice(src, quantifier);
    rb_hash_aset(ast, ID2SYM(rb_intern("atom")), onibi_pipeline_token_slice(src, atom));
    rb_hash_aset(ast, ID2SYM(rb_intern("quantifier")), quantifier_source);
    long qlen = RSTRING_LEN(quantifier_source);
    unsigned char tail = qlen > 0 ? (unsigned char)RSTRING_PTR(quantifier_source)[qlen - 1] : 0;
    rb_hash_aset(ast, ID2SYM(rb_intern("greedy")), tail == '?' ? Qfalse : Qtrue);
    rb_hash_aset(ast, ID2SYM(rb_intern("possessive")), tail == '+' ? Qtrue : Qfalse);
    if (!NIL_P(parsed)) {
      VALUE parsed_ast = onibi_hash_value(parsed, "ast");
      VALUE parsed_children = onibi_hash_value(parsed_ast, "children");
      if (!NIL_P(parsed_children) && RARRAY_LEN(parsed_children) == 1)
        parsed_ast = rb_ary_entry(parsed_children, 0);
      if (onibi_symbol_value(parsed_ast, "type") == ID2SYM(rb_intern("quantifier"))) {
        VALUE min = onibi_hash_value(parsed_ast, "min");
        VALUE max = onibi_hash_value(parsed_ast, "max");
        if (!NIL_P(min)) rb_hash_aset(ast, ID2SYM(rb_intern("min")), min);
        if (!NIL_P(max)) rb_hash_aset(ast, ID2SYM(rb_intern("max")), max);
      }
    }
  }
  int braced_quantifier = RARRAY_LEN(tokens) >= 5 &&
    onibi_token_byte(rb_ary_entry(tokens, 1)) == '{' &&
    onibi_token_byte(rb_ary_entry(tokens, RARRAY_LEN(tokens) - 1)) == '}';
  int class_expression = RARRAY_LEN(tokens) >= 2 &&
    onibi_token_kind(rb_ary_entry(tokens, 0)) == rb_intern("class_start") &&
    (onibi_token_kind(rb_ary_entry(tokens, RARRAY_LEN(tokens) - 1)) == rb_intern("class_end") ||
     (RARRAY_LEN(tokens) >= 2 && onibi_token_kind(rb_ary_entry(tokens, RARRAY_LEN(tokens) - 2)) == rb_intern("class_end") &&
      onibi_token_byte(rb_ary_entry(tokens, RARRAY_LEN(tokens) - 1)) == '+'));
  int any_expression = RARRAY_LEN(tokens) == 1 && onibi_token_kind(rb_ary_entry(tokens, 0)) == rb_intern("wildcard");
  int capture_expression = RARRAY_LEN(tokens) >= 2 &&
    onibi_token_kind(rb_ary_entry(tokens, 0)) == rb_intern("group_start") &&
    onibi_token_kind(rb_ary_entry(tokens, RARRAY_LEN(tokens) - 1)) == rb_intern("group_end");
  if (is_alt) {
    VALUE branches = rb_ary_new(); long begin = 0;
    for (long i = 0; i <= RARRAY_LEN(tokens); i++) if (i == RARRAY_LEN(tokens) ||
        onibi_token_kind(rb_ary_entry(tokens, i)) == rb_intern("alternation")) {
      VALUE branch = rb_hash_new(), branch_children = rb_ary_new();
      rb_hash_aset(branch, ID2SYM(rb_intern("type")), ID2SYM(rb_intern("sequence")));
      if (begin < i) {
        VALUE first = rb_ary_entry(tokens, begin), last = rb_ary_entry(tokens, i - 1);
        long start = NUM2LONG(onibi_hash_value(first, "start"));
        long finish = NUM2LONG(onibi_hash_value(last, "end"));
        rb_hash_aset(branch, ID2SYM(rb_intern("source")), rb_str_substr(src, start, finish - start));
      } else rb_hash_aset(branch, ID2SYM(rb_intern("source")), rb_str_new_cstr(""));
      for (long j = begin; j < i; j++) {
        VALUE token = rb_ary_entry(tokens, j);
        if (onibi_token_kind(token) != rb_intern("literal")) continue;
        VALUE node = rb_hash_new();
        rb_hash_aset(node, ID2SYM(rb_intern("type")), ID2SYM(rb_intern("literal")));
        rb_hash_aset(node, ID2SYM(rb_intern("byte")), LONG2NUM(onibi_token_byte(token)));
        rb_ary_push(branch_children, node);
      }
      rb_hash_aset(branch, ID2SYM(rb_intern("children")), branch_children);
      rb_ary_push(branches, branch); begin = i + 1;
    }
    rb_hash_aset(ast, ID2SYM(rb_intern("branches")), branches);
  }
  rb_hash_aset(out, ID2SYM(rb_intern("ast")), (obj->has_subroutine || obj->has_class_intersection || obj->has_nested_class || NIL_P(obj->compiled)) && !NIL_P(parsed) ?
               onibi_hash_value(parsed, "ast") : ast);
  VALUE gir = rb_ary_new();
  for (long i = 0; i < RARRAY_LEN(tokens); i++) {
    VALUE op = rb_hash_new();
    VALUE tk = rb_ary_entry(tokens, i);
    ID kindid = SYM2ID(rb_hash_aref(tk, ID2SYM(rb_intern("kind"))));
    ID opid = kindid == rb_intern("class_start") ? rb_intern("CLASS") :
              (kindid == rb_intern("alternation") ? rb_intern("ALT") :
               (kindid == rb_intern("quantifier") ? rb_intern("REPEAT") :
               (kindid == rb_intern("wildcard") ? rb_intern("ANY") :
                (kindid == rb_intern("anchor") ? rb_intern("ASSERT") : rb_intern("CHAR")))));
    if (kindid == rb_intern("escape")) opid = rb_intern("ESCAPE");
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(opid));
    rb_hash_aset(op, ID2SYM(rb_intern("arg")), tk);
    rb_ary_push(gir, op);
  }
  rb_hash_aset(out, ID2SYM(rb_intern("gir")), gir);
  VALUE graph = rb_hash_new(), states = rb_ary_new(), edges = rb_ary_new();
  for (long i = 0; i < RARRAY_LEN(gir); i++) {
    VALUE state = rb_hash_new();
    rb_hash_aset(state, ID2SYM(rb_intern("id")), LONG2NUM(i));
    rb_hash_aset(state, ID2SYM(rb_intern("op")), rb_hash_aref(rb_ary_entry(gir, i), ID2SYM(rb_intern("op"))));
    VALUE op = rb_hash_aref(rb_ary_entry(gir, i), ID2SYM(rb_intern("op")));
    rb_hash_aset(state, ID2SYM(rb_intern("gir_op")), rb_equal(op, ID2SYM(rb_intern("CHAR"))) ? ID2SYM(rb_intern("G_CHAR")) : op);
    rb_hash_aset(state, ID2SYM(rb_intern("arg")), rb_hash_aref(rb_ary_entry(gir, i), ID2SYM(rb_intern("arg"))));
    rb_ary_push(states, state);
    VALUE edge = rb_hash_new();
    rb_hash_aset(edge, ID2SYM(rb_intern("from")), LONG2NUM(i));
    rb_hash_aset(edge, ID2SYM(rb_intern("to")), LONG2NUM(i + 1));
    rb_hash_aset(edge, ID2SYM(rb_intern("actions")), rb_ary_new());
    rb_ary_push(edges, edge);
  }
  VALUE accept = rb_hash_new();
  rb_hash_aset(accept, ID2SYM(rb_intern("id")), LONG2NUM(RARRAY_LEN(gir)));
  rb_hash_aset(accept, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("ACCEPT")));
  rb_hash_aset(accept, ID2SYM(rb_intern("gir_op")), ID2SYM(rb_intern("G_ACCEPT")));
  rb_ary_push(states, accept);
  long pipe = -1;
  for (long i = 0; i < RARRAY_LEN(tokens); i++) {
    VALUE tk = rb_ary_entry(tokens, i);
    if (SYM2ID(rb_hash_aref(tk, ID2SYM(rb_intern("kind")))) == rb_intern("alternation")) { pipe = i; break; }
  }
  if (pipe >= 0) {
    edges = rb_ary_new();
    VALUE start = rb_hash_new();
    rb_hash_aset(start, ID2SYM(rb_intern("id")), LONG2NUM(RARRAY_LEN(gir) + 1));
    rb_hash_aset(start, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("START")));
    rb_ary_push(states, start);
    VALUE left = rb_hash_new(), right = rb_hash_new();
    rb_hash_aset(left, ID2SYM(rb_intern("from")), LONG2NUM(RARRAY_LEN(gir) + 1));
    rb_hash_aset(left, ID2SYM(rb_intern("to")), LONG2NUM(0));
    rb_hash_aset(left, ID2SYM(rb_intern("actions")), rb_ary_new());
    rb_hash_aset(right, ID2SYM(rb_intern("from")), LONG2NUM(RARRAY_LEN(gir) + 1));
    rb_hash_aset(right, ID2SYM(rb_intern("to")), LONG2NUM(pipe + 1));
    rb_hash_aset(right, ID2SYM(rb_intern("actions")), rb_ary_new());
    rb_ary_push(edges, left); rb_ary_push(edges, right);
  } else if (RARRAY_LEN(tokens) == 2 && onibi_token_kind(rb_ary_entry(tokens, 1)) == rb_intern("quantifier") &&
             (onibi_token_byte(rb_ary_entry(tokens, 1)) == '*' ||
              onibi_token_byte(rb_ary_entry(tokens, 1)) == '+' ||
              onibi_token_byte(rb_ary_entry(tokens, 1)) == '?')) {
    edges = rb_ary_new();
    VALUE first = rb_hash_new();
    rb_hash_aset(first, ID2SYM(rb_intern("from")), LONG2NUM(0));
    rb_hash_aset(first, ID2SYM(rb_intern("to")), LONG2NUM(1));
    rb_hash_aset(first, ID2SYM(rb_intern("actions")), rb_ary_new());
    rb_ary_push(edges, first);
    VALUE repeat = rb_hash_new(), exit = rb_hash_new();
    rb_hash_aset(repeat, ID2SYM(rb_intern("from")), LONG2NUM(1));
    rb_hash_aset(repeat, ID2SYM(rb_intern("to")), LONG2NUM(0));
    rb_hash_aset(repeat, ID2SYM(rb_intern("actions")), rb_ary_new());
    rb_hash_aset(exit, ID2SYM(rb_intern("from")), LONG2NUM(1));
    rb_hash_aset(exit, ID2SYM(rb_intern("to")), LONG2NUM(2));
    rb_hash_aset(exit, ID2SYM(rb_intern("actions")), rb_ary_new());
    rb_ary_push(edges, repeat); rb_ary_push(edges, exit);
  } else if (braced_quantifier) {
    edges = rb_ary_new();
    VALUE first = rb_hash_new();
    rb_hash_aset(first, ID2SYM(rb_intern("from")), LONG2NUM(0));
    rb_hash_aset(first, ID2SYM(rb_intern("to")), LONG2NUM(1));
    VALUE init = rb_hash_new(); rb_hash_aset(init, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("COUNTER_INIT"))); rb_hash_aset(init, ID2SYM(rb_intern("slot")), INT2NUM(0));
    VALUE actions = rb_ary_new(); rb_ary_push(actions, init); rb_hash_aset(first, ID2SYM(rb_intern("actions")), actions); rb_ary_push(edges, first);
    VALUE repeat = rb_hash_new(), exit = rb_hash_new();
    rb_hash_aset(repeat, ID2SYM(rb_intern("from")), LONG2NUM(1)); rb_hash_aset(repeat, ID2SYM(rb_intern("to")), LONG2NUM(0));
    VALUE repeat_actions = rb_ary_new(), increment = rb_hash_new(); rb_hash_aset(increment, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("COUNTER_INCREMENT"))); rb_hash_aset(increment, ID2SYM(rb_intern("slot")), INT2NUM(0)); rb_ary_push(repeat_actions, increment); rb_hash_aset(repeat, ID2SYM(rb_intern("actions")), repeat_actions);
    rb_hash_aset(exit, ID2SYM(rb_intern("from")), LONG2NUM(1)); rb_hash_aset(exit, ID2SYM(rb_intern("to")), LONG2NUM(2)); rb_hash_aset(exit, ID2SYM(rb_intern("actions")), rb_ary_new());
    rb_ary_push(edges, repeat); rb_ary_push(edges, exit);
  }
  if (RARRAY_LEN(tokens) > 0 && onibi_token_kind(rb_ary_entry(tokens, 0)) == rb_intern("anchor") &&
      onibi_token_byte(rb_ary_entry(tokens, 0)) == '^' && RARRAY_LEN(edges) > 0) {
    VALUE action = rb_hash_new();
    rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("ASSERT_BEGIN_BUFFER")));
    rb_ary_push(rb_hash_aref(rb_ary_entry(edges, 0), ID2SYM(rb_intern("actions"))), action);
  }
  if (RARRAY_LEN(tokens) > 0 && onibi_token_kind(rb_ary_entry(tokens, RARRAY_LEN(tokens) - 1)) == rb_intern("anchor") &&
      onibi_token_byte(rb_ary_entry(tokens, RARRAY_LEN(tokens) - 1)) == '$' && RARRAY_LEN(edges) > 0) {
    VALUE action = rb_hash_new();
    rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("ASSERT_END_BUFFER")));
    rb_ary_push(rb_hash_aref(rb_ary_entry(edges, RARRAY_LEN(edges) - 1), ID2SYM(rb_intern("actions"))), action);
  }
  for (long i = 0; i < RARRAY_LEN(tokens) && i < RARRAY_LEN(edges); i++) {
    VALUE token = rb_ary_entry(tokens, i);
    ID kind = SYM2ID(rb_hash_aref(token, ID2SYM(rb_intern("kind"))));
    if (kind == rb_intern("group_start") || kind == rb_intern("group_end")) {
      VALUE action = rb_hash_new();
      const char *capture_op = kind == rb_intern("group_start") ? "CAPTURE_OPEN" : "CAPTURE_CLOSE";
      rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern(capture_op)));
      rb_hash_aset(action, ID2SYM(rb_intern("slot")), INT2NUM(kind == rb_intern("group_start") ? 2 : 3));
      rb_ary_push(rb_hash_aref(rb_ary_entry(edges, i), ID2SYM(rb_intern("actions"))), action);
    }
  }
  rb_hash_aset(graph, ID2SYM(rb_intern("states")), states);
  rb_hash_aset(graph, ID2SYM(rb_intern("edges")), edges);
  rb_hash_aset(graph, ID2SYM(rb_intern("start")), LONG2NUM(RARRAY_LEN(gir) == 0 ? 0 : (pipe >= 0 ? RARRAY_LEN(gir) + 1 : 0)));
  rb_hash_aset(out, ID2SYM(rb_intern("gir_graph")), graph);
  VALUE captures = rb_ary_new();
  int has_capture = 0;
  for (long i = 0; i < RARRAY_LEN(tokens); i++) {
    if (onibi_token_kind(rb_ary_entry(tokens, i)) == rb_intern("group_start")) {
      has_capture = 1;
      break;
    }
  }
  int class_repeat = 0;
  for (long i = 0; i + 1 < RARRAY_LEN(tokens); i++) {
    if (onibi_token_kind(rb_ary_entry(tokens, i)) == rb_intern("class_end") &&
        onibi_token_kind(rb_ary_entry(tokens, i + 1)) == rb_intern("quantifier") &&
        onibi_token_byte(rb_ary_entry(tokens, i + 1)) == '+') {
      class_repeat = 1;
      break;
    }
  }
  if (has_capture) {
    VALUE capture = rb_hash_new();
    rb_hash_aset(capture, ID2SYM(rb_intern("id")), INT2NUM(1));
    rb_hash_aset(capture, ID2SYM(rb_intern("use")), ID2SYM(rb_intern("CAPTURE_OUTPUT_ONLY")));
    VALUE slots = rb_ary_new(); rb_ary_push(slots, INT2NUM(2)); rb_ary_push(slots, INT2NUM(3));
    rb_hash_aset(capture, ID2SYM(rb_intern("slots")), slots); rb_ary_push(captures, capture);
  }
  rb_hash_aset(out, ID2SYM(rb_intern("captures")), captures);
  rb_hash_aset(out, ID2SYM(rb_intern("rseq")), gir);
  VALUE compact = rb_ary_new();
  int literal_only = RARRAY_LEN(tokens) > 0;
  for (long i = 0; i < RARRAY_LEN(tokens); i++) {
    VALUE token = rb_ary_entry(tokens, i);
    if (onibi_token_kind(token) != rb_intern("literal") ||
        NUM2LONG(rb_hash_aref(token, ID2SYM(rb_intern("end")))) -
        NUM2LONG(rb_hash_aref(token, ID2SYM(rb_intern("start")))) != 1) {
      literal_only = 0;
      break;
    }
  }
  if (literal_only) {
    VALUE op = rb_hash_new();
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("STRING")));
    rb_hash_aset(op, ID2SYM(rb_intern("arg")), src);
    rb_ary_push(compact, op);
  } else if (braced_quantifier) {
    VALUE op = rb_hash_new();
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("REPEAT")));
    rb_hash_aset(op, ID2SYM(rb_intern("atom")), rb_str_substr(src, 0, 1));
    rb_hash_aset(op, ID2SYM(rb_intern("bounds")), rb_str_substr(src, 2, RSTRING_LEN(src) - 3));
    rb_ary_push(compact, op);
  } else if (class_repeat) {
    VALUE op = rb_hash_new();
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("RUN_CLASS")));
    rb_hash_aset(op, ID2SYM(rb_intern("arg")), src);
    rb_ary_push(compact, op);
  } else if (class_expression) {
    VALUE op = rb_hash_new();
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("RUN_CLASS")));
    rb_hash_aset(op, ID2SYM(rb_intern("arg")), src);
    rb_ary_push(compact, op);
  } else if (any_expression) {
    VALUE op = rb_hash_new();
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("RUN_ANY")));
    rb_hash_aset(op, ID2SYM(rb_intern("arg")), INT2NUM(1));
    rb_ary_push(compact, op);
  } else if (is_alt) {
    VALUE op = rb_hash_new(), branches = rb_ary_new(); long begin = 0;
    for (long i = 0; i <= RARRAY_LEN(tokens); i++) if (i == RARRAY_LEN(tokens) ||
        onibi_token_kind(rb_ary_entry(tokens, i)) == rb_intern("alternation")) {
      if (begin < i) {
        VALUE first = rb_ary_entry(tokens, begin), last = rb_ary_entry(tokens, i - 1);
        long start = NUM2LONG(onibi_hash_value(first, "start"));
        long finish = NUM2LONG(onibi_hash_value(last, "end"));
        rb_ary_push(branches, rb_str_substr(src, start, finish - start));
      } else rb_ary_push(branches, rb_str_new_cstr(""));
      begin = i + 1;
    }
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("ALT")));
    rb_hash_aset(op, ID2SYM(rb_intern("branches")), branches);
    rb_ary_push(compact, op);
  } else if (capture_expression) {
    VALUE open = rb_hash_new(), string = rb_hash_new(), close = rb_hash_new();
    rb_hash_aset(open, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("CAPTURE_OPEN")));
    rb_hash_aset(open, ID2SYM(rb_intern("slot")), INT2NUM(2));
    rb_hash_aset(string, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("STRING")));
    VALUE first = rb_ary_entry(tokens, 0), last = rb_ary_entry(tokens, RARRAY_LEN(tokens) - 1);
    long body_start = NUM2LONG(onibi_hash_value(first, "end"));
    long body_end = NUM2LONG(onibi_hash_value(last, "start"));
    rb_hash_aset(string, ID2SYM(rb_intern("arg")), rb_str_substr(src, body_start, body_end - body_start));
    rb_hash_aset(close, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("CAPTURE_CLOSE")));
    rb_hash_aset(close, ID2SYM(rb_intern("slot")), INT2NUM(3));
    rb_ary_push(compact, open); rb_ary_push(compact, string); rb_ary_push(compact, close);
  } else compact = gir;
  rb_hash_aset(out, ID2SYM(rb_intern("rseq_compact")), compact);
  /* Dispatch follows the canonical compiler result. */
  int simple = !NIL_P(obj->rseq);
  rb_hash_aset(out, ID2SYM(rb_intern("vm")), ID2SYM(rb_intern(simple ? "RSEQ" : "MRI")));
  rb_hash_aset(out, ID2SYM(rb_intern("interpreter")), obj->execution_kind);
  /* Expose the immutable canonical stages built at initialize time.  The
     legacy display fields above remain for compatibility with old callers. */
  if (!NIL_P(obj->parsed) && !NIL_P(obj->compiled) && !NIL_P(obj->rseq)) {
    rb_hash_aset(out, ID2SYM(rb_intern("parsed")), obj->parsed);
    rb_hash_aset(out, ID2SYM(rb_intern("compiled")), obj->compiled);
    rb_hash_aset(out, ID2SYM(rb_intern("rseq_program")), obj->rseq);
    VALUE canonical = rb_hash_new();
    rb_hash_aset(canonical, ID2SYM(rb_intern("ast")), onibi_hash_value(obj->parsed, "ast"));
    rb_hash_aset(canonical, ID2SYM(rb_intern("gir")), onibi_hash_value(obj->compiled, "graph"));
    rb_hash_aset(canonical, ID2SYM(rb_intern("rseq")), obj->rseq);
    rb_hash_aset(canonical, ID2SYM(rb_intern("options")), onibi_hash_value(obj->compiled, "options"));
    rb_obj_freeze(canonical);
    rb_hash_aset(out, ID2SYM(rb_intern("canonical")), canonical);
  }
  return out;
}
#endif

static int onibi_vm_counter_actions_ok(VALUE actions, const OnibiCounterState *counters) {
  if (!counters || !counters->values) return 1;
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(action, id_key_action_code));
    if (code != ONIBI_GA_TEST_COUNTER_LT && code != ONIBI_GA_TEST_COUNTER_GE) continue;
    VALUE slot_value = onibi_hash_value_id(action, id_key_slot);
    if (NIL_P(slot_value)) continue;
    long slot = NUM2LONG(slot_value);
    long count = (slot >= 0 && (uint32_t)slot < counters->count) ? counters->values[slot] : 0;
    VALUE limit_value = onibi_hash_value_id(action, id_key_limit);
    if (NIL_P(limit_value)) return 0;
    long limit = NUM2LONG(limit_value);
    if ((code == ONIBI_GA_TEST_COUNTER_LT && !(count < limit)) ||
        (code == ONIBI_GA_TEST_COUNTER_GE && !(count >= limit))) return 0;
  }
  return 1;
}

static void onibi_vm_apply_counter_actions_c(VALUE actions, OnibiCounterState *counters) {
  if (!counters || !counters->values) return;
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(action, id_key_action_code));
    VALUE slot_value = onibi_hash_value_id(action, id_key_slot);
    if (NIL_P(slot_value)) continue;
    long slot = NUM2LONG(slot_value);
    if (slot < 0 || (uint32_t)slot >= counters->count) continue;
    if (code == ONIBI_GA_COUNTER_INIT) {
      VALUE value = onibi_hash_value_id(action, id_key_value);
      counters->values[slot] = NIL_P(value) ? 0 : NUM2LONG(value);
    }
    else if (code == ONIBI_GA_COUNTER_INCREMENT) counters->values[slot]++;
  }
}

static int onibi_vm_actions_ok(VALUE actions, VALUE subject, long pos, long length, VALUE counters, VALUE captures) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(action, id_key_action_code));
    if (code == ONIBI_GA_TEST_CAPTURE) {
      long capture = NUM2LONG(onibi_hash_value_id(action, id_key_slot));
      int set = !NIL_P(captures) && !NIL_P(rb_hash_aref(captures, LONG2NUM(2 * capture))) &&
        !NIL_P(rb_hash_aref(captures, LONG2NUM(2 * capture + 1)));
      if (!set && !NIL_P(captures)) {
        for (long event = 0; event < RARRAY_LEN(actions); event++) {
          VALUE event_action = rb_ary_entry(actions, event);
          if ((OnibiGActionOp)NUM2UINT(onibi_hash_value_id(event_action, id_key_action_code)) == ONIBI_GA_CAPTURE_CLOSE &&
              NUM2LONG(onibi_hash_value_id(event_action, id_key_slot)) == 2 * capture + 1 &&
              !NIL_P(rb_hash_aref(captures, LONG2NUM(2 * capture)))) { set = 1; break; }
        }
      }
      if (set != RTEST(onibi_hash_value_id(action, id_key_set))) return 0;
      continue;
    }
    if (code == ONIBI_GA_TEST_COUNTER_LT || code == ONIBI_GA_TEST_COUNTER_GE) {
      if (NIL_P(counters)) continue;
      VALUE value = rb_hash_aref(counters, onibi_hash_value_id(action, id_key_slot));
      long count = NIL_P(value) ? 0 : NUM2LONG(value);
      long limit = NUM2LONG(onibi_hash_value_id(action, id_key_limit));
      if ((code == ONIBI_GA_TEST_COUNTER_LT && !(count < limit)) ||
          (code == ONIBI_GA_TEST_COUNTER_GE && !(count >= limit))) return 0;
      continue;
    }
    VALUE assertion_value = onibi_hash_value_id(action, id_key_assert_kind);
    OnibiRAssertKind assertion = NIL_P(assertion_value) ? (OnibiRAssertKind)0 :
      (OnibiRAssertKind)NUM2ULONG(assertion_value);
    if (assertion == ONIBI_RAP_BEGIN_BUFFER && pos != 0) return 0;
    if (assertion == ONIBI_RAP_SEARCH_ORIGIN && pos != 0) return 0;
    if (assertion == ONIBI_RAP_END_BUFFER && pos != length) return 0;
    if (assertion == ONIBI_RAP_BEGIN_LINE && pos != 0 && RSTRING_PTR(subject)[pos - 1] != '\n') return 0;
    if (assertion == ONIBI_RAP_END_LINE && pos != length && RSTRING_PTR(subject)[pos] != '\n') return 0;
    if (assertion == ONIBI_RAP_WORD_BOUNDARY || assertion == ONIBI_RAP_NONWORD_BOUNDARY) {
      int before = pos > 0 && (isalnum((unsigned char)RSTRING_PTR(subject)[pos - 1]) || RSTRING_PTR(subject)[pos - 1] == '_');
      int after = pos < length && (isalnum((unsigned char)RSTRING_PTR(subject)[pos]) || RSTRING_PTR(subject)[pos] == '_');
      int boundary = before != after;
      if ((assertion == ONIBI_RAP_WORD_BOUNDARY && !boundary) ||
          (assertion == ONIBI_RAP_NONWORD_BOUNDARY && boundary)) return 0;
    }
    if (assertion == ONIBI_RAP_SEMI_END_BUFFER && pos != length &&
        !(pos + 1 == length && length > 0 && RSTRING_PTR(subject)[length - 1] == '\n')) return 0;
    if (assertion == ONIBI_RAP_LOOKAHEAD) {
      VALUE predicates = onibi_hash_value_id(action, id_key_predicates);
      if (RB_TYPE_P(predicates, T_ARRAY)) {
        int matched = 1;
        for (long i = 0; i < RARRAY_LEN(predicates); i++) {
          VALUE predicate = rb_ary_entry(predicates, i);
          long at = pos + i;
          if (at >= length) { matched = 0; break; }
          unsigned char byte = (unsigned char)RSTRING_PTR(subject)[at];
          OnibiPredicateKind kind = (OnibiPredicateKind)NUM2UINT(onibi_hash_value_id(predicate, id_key_predicate_code));
          if (kind == ONIBI_PRED_BYTE) {
            unsigned char expected = (unsigned char)NUM2INT(onibi_hash_value_id(predicate, id_key_byte));
            matched = matched && (RTEST(onibi_hash_value_id(predicate, id_key_ignorecase)) ?
              tolower(byte) == tolower(expected) : byte == expected);
          } else if (kind == ONIBI_PRED_ANY) {
            matched = matched && (byte != '\n' || RTEST(onibi_hash_value_id(predicate, id_key_multiline)));
          }
          else {
            VALUE bits = onibi_hash_value_id(predicate, id_key_bitmap);
            matched = matched && RB_TYPE_P(bits, T_STRING) && RSTRING_LEN(bits) == 32 &&
              (((unsigned char *)RSTRING_PTR(bits))[byte >> 3] & (1U << (byte & 7))) != 0;
          }
          if (!matched) break;
        }
        if (matched != RTEST(onibi_hash_value_id(action, id_key_positive))) return 0;
        continue;
      }
      VALUE bitmap = onibi_hash_value_id(action, id_key_bitmap);
      if (!NIL_P(bitmap)) {
        int hit = pos < length && RSTRING_LEN(bitmap) == 32 &&
          (((unsigned char *)RSTRING_PTR(bitmap))[(unsigned char)RSTRING_PTR(subject)[pos] >> 3] &
           (1U << ((unsigned char)RSTRING_PTR(subject)[pos] & 7))) != 0;
        if (hit != RTEST(onibi_hash_value_id(action, id_key_positive))) return 0;
        continue;
      }
      VALUE bytes = onibi_hash_value_id(action, id_key_bytes);
      long width = RSTRING_LEN(bytes);
      int hit = pos + width <= length && memcmp(RSTRING_PTR(subject) + pos, RSTRING_PTR(bytes), (size_t)width) == 0;
      if (hit != RTEST(onibi_hash_value_id(action, id_key_positive))) return 0;
    }
    if (assertion == ONIBI_RAP_LOOKBEHIND) {
      VALUE predicates = onibi_hash_value_id(action, id_key_predicates);
      if (RB_TYPE_P(predicates, T_ARRAY)) {
        long width = RARRAY_LEN(predicates);
        int matched = pos >= width;
        for (long i = 0; matched && i < width; i++) {
          VALUE predicate = rb_ary_entry(predicates, i);
          unsigned char byte = (unsigned char)RSTRING_PTR(subject)[pos - width + i];
          OnibiPredicateKind kind = (OnibiPredicateKind)NUM2UINT(onibi_hash_value_id(predicate, id_key_predicate_code));
          if (kind == ONIBI_PRED_BYTE) {
            unsigned char expected = (unsigned char)NUM2INT(onibi_hash_value_id(predicate, id_key_byte));
            matched = RTEST(onibi_hash_value_id(predicate, id_key_ignorecase)) ?
              tolower(byte) == tolower(expected) : byte == expected;
          } else if (kind == ONIBI_PRED_ANY) {
            matched = matched && (byte != '\n' || RTEST(onibi_hash_value_id(predicate, id_key_multiline)));
          }
          else {
            VALUE bits = onibi_hash_value_id(predicate, id_key_bitmap);
            matched = RB_TYPE_P(bits, T_STRING) && RSTRING_LEN(bits) == 32 &&
              (((unsigned char *)RSTRING_PTR(bits))[byte >> 3] & (1U << (byte & 7))) != 0;
          }
        }
        if (matched != RTEST(onibi_hash_value_id(action, id_key_positive))) return 0;
        continue;
      }
      VALUE bitmap = onibi_hash_value_id(action, id_key_bitmap);
      if (!NIL_P(bitmap)) {
        int hit = pos > 0 && RSTRING_LEN(bitmap) == 32 &&
          (((unsigned char *)RSTRING_PTR(bitmap))[(unsigned char)RSTRING_PTR(subject)[pos - 1] >> 3] &
           (1U << ((unsigned char)RSTRING_PTR(subject)[pos - 1] & 7))) != 0;
        if (hit != RTEST(onibi_hash_value_id(action, id_key_positive))) return 0;
        continue;
      }
      VALUE bytes = onibi_hash_value_id(action, id_key_bytes);
      long width = RSTRING_LEN(bytes);
      int hit = pos >= width && memcmp(RSTRING_PTR(subject) + pos - width, RSTRING_PTR(bytes), (size_t)width) == 0;
      if (hit != RTEST(onibi_hash_value_id(action, id_key_positive))) return 0;
    }
  }
  return 1;
}

static void onibi_vm_apply_counter_actions(VALUE actions, VALUE counters) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(action, id_key_action_code));
    VALUE slot = onibi_hash_value_id(action, id_key_slot);
    if (code == ONIBI_GA_COUNTER_INIT)
      rb_hash_aset(counters, slot, onibi_hash_value_id(action, id_key_value));
    else if (code == ONIBI_GA_COUNTER_INCREMENT) {
      VALUE prior = rb_hash_aref(counters, slot);
      rb_hash_aset(counters, slot, LONG2NUM((NIL_P(prior) ? 0 : NUM2LONG(prior)) + 1));
    }
  }
}

static int onibi_unicode_ctype_id(ID property) {
  static ID ids[26];
  static int ready = 0;
  if (!ready) {
    const char *names[] = {"Alpha", "alpha", "Letter", "Digit", "digit", "Alnum", "alnum",
                           "Lower", "lower", "Upper", "upper", "Space", "space", "Blank", "blank",
                           "Word", "word", "XDigit", "xdigit", "Cntrl", "Print", "Graph", "Punct"};
    for (size_t i = 0; i < 23; i++) ids[i] = rb_intern(names[i]);
    ready = 1;
  }
  if (property == ids[0] || property == ids[1] || property == ids[2]) return ONIGENC_CTYPE_ALPHA;
  if (property == ids[3] || property == ids[4]) return ONIGENC_CTYPE_DIGIT;
  if (property == ids[5] || property == ids[6]) return ONIGENC_CTYPE_ALNUM;
  if (property == ids[7] || property == ids[8]) return ONIGENC_CTYPE_LOWER;
  if (property == ids[9] || property == ids[10]) return ONIGENC_CTYPE_UPPER;
  if (property == ids[11] || property == ids[12]) return ONIGENC_CTYPE_SPACE;
  if (property == ids[13] || property == ids[14]) return ONIGENC_CTYPE_BLANK;
  if (property == ids[15] || property == ids[16]) return ONIGENC_CTYPE_WORD;
  if (property == ids[17] || property == ids[18]) return ONIGENC_CTYPE_XDIGIT;
  if (property == ids[19]) return ONIGENC_CTYPE_CNTRL;
  if (property == ids[20]) return ONIGENC_CTYPE_PRINT;
  if (property == ids[21]) return ONIGENC_CTYPE_GRAPH;
  if (property == ids[22]) return ONIGENC_CTYPE_PUNCT;
  return -1;
}

/* Property names are resolved while the AST is compiled.  VM payloads carry
   this integer, so matching never compares property strings. */
static VALUE onibi_class_payload_with_ctypes(VALUE payload) {
  VALUE copy = rb_hash_dup(payload);
  int fold = RTEST(onibi_hash_value_id(copy, id_key_ignorecase));
  VALUE name = onibi_hash_value_id(copy, id_key_name);
  VALUE name_id = onibi_hash_value_id(copy, id_key_name_id);
  ID property = NIL_P(name_id) ? (NIL_P(name) ? 0 : rb_intern_str(name)) : (ID)NUM2ULONG(name_id);
  int ctype = onibi_unicode_ctype_id(property);
  if (ctype >= 0) rb_hash_aset(copy, ID2SYM(id_key_ctype), INT2NUM(ctype));
  VALUE children = onibi_hash_value_id(copy, id_key_children);
  if (RB_TYPE_P(children, T_ARRAY)) {
    VALUE compiled = rb_ary_new_capa(RARRAY_LEN(children));
    for (long i = 0; i < RARRAY_LEN(children); i++) {
      VALUE child = rb_ary_entry(children, i);
      VALUE child_copy = RB_TYPE_P(child, T_HASH) ? rb_hash_dup(child) : child;
      if (RB_TYPE_P(child_copy, T_HASH) &&
          (onibi_hash_value_id(child_copy, id_key_kind_code) == UINT2NUM(ONIBI_TOKEN_ESCAPE) ||
           onibi_ast_kind(child_copy) == ONIBI_AST_ESCAPE)) {
        VALUE child_name = onibi_hash_value_id(child_copy, id_key_name);
        VALUE child_name_id = onibi_hash_value_id(child_copy, id_key_name_id);
        ID property = NIL_P(child_name_id) ? (NIL_P(child_name) ? 0 : rb_intern_str(child_name)) : (ID)NUM2ULONG(child_name_id);
        int child_ctype = onibi_unicode_ctype_id(property);
        if (child_ctype >= 0)
          rb_hash_aset(child_copy, ID2SYM(id_key_ctype), INT2NUM(child_ctype));
      }
      if (fold && RB_TYPE_P(child_copy, T_HASH))
        rb_hash_aset(child_copy, ID2SYM(id_key_ignorecase), Qtrue);
      rb_ary_push(compiled, child_copy);
    }
    rb_hash_aset(copy, ID2SYM(id_key_children), compiled);
  }
  VALUE operands = onibi_hash_value_id(copy, id_key_operands);
  if (RB_TYPE_P(operands, T_ARRAY)) {
    VALUE compiled_operands = rb_ary_new_capa(RARRAY_LEN(operands));
    for (long i = 0; i < RARRAY_LEN(operands); i++) {
      VALUE operand = onibi_class_payload_with_ctypes(rb_ary_entry(operands, i));
      if (fold) rb_hash_aset(operand, ID2SYM(id_key_ignorecase), Qtrue);
      OnibiAstKind operand_type = onibi_ast_kind(operand);
      if (operand_type == ONIBI_AST_CHARACTER_CLASS ||
          operand_type == ONIBI_AST_CLASS_INTERSECTION)
        rb_hash_aset(operand, ID2SYM(id_key_bitmap), onibi_class_bitmap(operand, 0));
      rb_ary_push(compiled_operands, operand);
    }
    rb_hash_aset(copy, ID2SYM(id_key_operands), compiled_operands);
  }
  return copy;
}

static int onibi_codepoint_at(VALUE str, long pos, OnigCodePoint *codepoint, long *width) {
  const char *ptr = RSTRING_PTR(str) + pos;
  const char *end = RSTRING_PTR(str) + RSTRING_LEN(str);
  int length = rb_enc_mbclen(ptr, end, rb_enc_get(str));
  if (length <= 0 || ptr + length > end) return 0;
  *codepoint = ONIGENC_MBC_TO_CODE(rb_enc_get(str), (const OnigUChar *)ptr, (const OnigUChar *)end);
  *width = length;
  return 1;
}

static int onibi_ctype_casefold_hit(VALUE str, long pos, OnigCodePoint code, int ctype,
                                    int hit) {
  if (hit) return 1;
  const OnigEncoding enc = rb_enc_get(str);
  const OnigUChar *ptr = (const OnigUChar *)RSTRING_PTR(str) + pos;
  const OnigUChar *end = (const OnigUChar *)RSTRING_PTR(str) + RSTRING_LEN(str);
  OnigCaseFoldCodeItem folds[ONIGENC_GET_CASE_FOLD_CODES_MAX_NUM];
  int count = ONIGENC_GET_CASE_FOLD_CODES_BY_STR(enc, ONIGENC_CASE_FOLD_DEFAULT,
                                                  ptr, end, folds);
  for (int i = 0; i < count; i++) {
    for (int j = 0; j < folds[i].code_len; j++)
      if (folds[i].code[j] != code && ONIGENC_IS_CODE_CTYPE(enc, folds[i].code[j], ctype)) return 1;
  }
  return 0;
}

static int onibi_vm_class_match(VALUE payload, VALUE str, long pos, unsigned char byte, long *width) {
  if (onibi_ast_kind(payload) == ONIBI_AST_CLASS_INTERSECTION &&
      rb_enc_get_index(str) == rb_utf8_encindex()) {
    VALUE operands = onibi_hash_value_id(payload, id_key_operands);
    if (!RB_TYPE_P(operands, T_ARRAY) || RARRAY_LEN(operands) == 0) return 0;
    long common_width = 0;
    int hit = 1;
    for (long i = 0; i < RARRAY_LEN(operands); i++) {
      long operand_width = 0;
      VALUE operand = rb_ary_entry(operands, i);
      /* Ignorecase is propagated to every operand by
       * onibi_class_payload_with_ctypes during compilation.  Do not copy
       * semantic payloads in this per-character VM path. */
      int operand_hit = onibi_vm_class_match(operand, str, pos, byte, &operand_width);
      if (i == 0) common_width = operand_width;
      else if (operand_width != common_width) operand_hit = 0;
      hit = hit && operand_hit;
    }
    *width = common_width;
    return hit;
  }
  VALUE name = onibi_hash_value_id(payload, id_key_name);
  VALUE ctype_value = onibi_hash_value_id(payload, id_key_ctype);
  int ctype = NIL_P(ctype_value) ? -1 : NUM2INT(ctype_value);
  if (ctype >= 0 && rb_enc_get_index(str) == rb_utf8_encindex()) {
    if (pos > 0 && ((unsigned char)RSTRING_PTR(str)[pos] & 0xc0) == 0x80 &&
        (((unsigned char)RSTRING_PTR(str)[pos - 1] & 0xc0) == 0x80 || (unsigned char)RSTRING_PTR(str)[pos - 1] >= 0xc0)) return 0;
    OnigCodePoint code; long length = 0;
    if (!onibi_codepoint_at(str, pos, &code, &length)) return 0;
    int hit = ONIGENC_IS_CODE_CTYPE(rb_enc_get(str), code, ctype);
    if (RTEST(onibi_hash_value_id(payload, id_key_ignorecase)))
      hit = onibi_ctype_casefold_hit(str, pos, code, ctype, hit);
    if (NUM2INT(onibi_hash_value_id(payload, id_key_byte)) == 'P') hit = !hit;
    *width = length;
    return hit;
  }
  if (NIL_P(name) && !rb_enc_str_asciionly_p(str) && rb_enc_get_index(str) != rb_ascii8bit_encindex()) {
    VALUE children = onibi_hash_value_id(payload, id_key_children);
    VALUE ranges = onibi_hash_value_id(payload, id_key_ranges);
    if (RB_TYPE_P(children, T_ARRAY) && RB_TYPE_P(ranges, T_ARRAY)) {
      OnigCodePoint code; long decoded_width = 0;
      if (!onibi_codepoint_at(str, pos, &code, &decoded_width)) return 0;
      int hit = 0;
      for (long i = 0; i < RARRAY_LEN(children); i++) {
        VALUE child = rb_ary_entry(children, i);
        VALUE kind_value = onibi_hash_value_id(child, id_key_kind_code);
        if (NIL_P(kind_value)) continue;
        OnibiTokenKind kind = (OnibiTokenKind)NUM2UINT(kind_value);
        if (kind == ONIBI_TOKEN_LITERAL) {
          VALUE bytes = onibi_hash_value_id(child, id_key_bytes);
          if (NIL_P(bytes)) bytes = rb_str_new((const char[]){(char)NUM2INT(onibi_hash_value_id(child, id_key_byte))}, 1);
          const char *child_ptr = RSTRING_PTR(bytes);
          const char *child_end = child_ptr + RSTRING_LEN(bytes);
          int child_len = rb_enc_mbclen(child_ptr, child_end, rb_enc_get(str));
          if (child_len > 0 && child_ptr + child_len <= child_end &&
              ONIGENC_MBC_TO_CODE(rb_enc_get(str), (const OnigUChar *)child_ptr,
                                   (const OnigUChar *)child_end) == code) hit = 1;
        } else if (kind == ONIBI_TOKEN_ESCAPE || kind == ONIBI_TOKEN_META_ESCAPE) {
          VALUE child_ctype_value = onibi_hash_value_id(child, id_key_ctype);
          int child_ctype = NIL_P(child_ctype_value) ? -1 : NUM2INT(child_ctype_value);
          if (child_ctype >= 0) {
            int child_hit = ONIGENC_IS_CODE_CTYPE(rb_enc_get(str), code, child_ctype);
            if (NUM2INT(onibi_hash_value_id(child, id_key_byte)) == 'P') child_hit = !child_hit;
            if (child_hit) hit = 1;
          }
        }
      }
      for (long i = 0; i < RARRAY_LEN(ranges); i++) {
        VALUE range = rb_ary_entry(ranges, i);
        if (RARRAY_LEN(range) != 2) continue;
        if (RB_INTEGER_TYPE_P(rb_ary_entry(range, 0)) && RB_INTEGER_TYPE_P(rb_ary_entry(range, 1))) {
          if (code >= (OnigCodePoint)NUM2ULONG(rb_ary_entry(range, 0)) &&
              code <= (OnigCodePoint)NUM2ULONG(rb_ary_entry(range, 1))) hit = 1;
          continue;
        }
        if (!RB_TYPE_P(rb_ary_entry(range, 0), T_STRING) || !RB_TYPE_P(rb_ary_entry(range, 1), T_STRING)) continue;
        uint32_t first = 0, last = 0;
        VALUE first_bytes = rb_ary_entry(range, 0), last_bytes = rb_ary_entry(range, 1);
        const char *first_ptr = RSTRING_PTR(first_bytes), *last_ptr = RSTRING_PTR(last_bytes);
        const char *first_end = first_ptr + RSTRING_LEN(first_bytes), *last_end = last_ptr + RSTRING_LEN(last_bytes);
        int first_len = rb_enc_mbclen(first_ptr, first_end, rb_enc_get(str));
        int last_len = rb_enc_mbclen(last_ptr, last_end, rb_enc_get(str));
        if (first_len > 0 && last_len > 0 && first_ptr + first_len <= first_end && last_ptr + last_len <= last_end) {
          first = ONIGENC_MBC_TO_CODE(rb_enc_get(str), (const OnigUChar *)first_ptr, (const OnigUChar *)first_end);
          last = ONIGENC_MBC_TO_CODE(rb_enc_get(str), (const OnigUChar *)last_ptr, (const OnigUChar *)last_end);
          if (code >= first && code <= last) hit = 1;
        }
      }
      if (RTEST(onibi_hash_value_id(payload, id_key_negated))) hit = !hit;
      *width = decoded_width;
      return hit;
    }
  }
  int fold = RTEST(onibi_hash_value_id(payload, id_key_ignorecase));
  if (fold) byte = (unsigned char)tolower(byte);
  VALUE bitmap = onibi_hash_value_id(payload, id_key_bitmap);
  if (NIL_P(bitmap) || !RB_TYPE_P(bitmap, T_STRING) || RSTRING_LEN(bitmap) != 32)
    rb_raise(eRegexpError, "class payload has no compiled bitmap");
  *width = 1;
  return (((unsigned char *)RSTRING_PTR(bitmap))[byte >> 3] & (1U << (byte & 7))) != 0;
}

static int onibi_gir_match_captures(VALUE graph, VALUE str, long start, long *matched_end,
                                    long *matched_start, VALUE *matched_captures);
static int onibi_gir_match_captures_seed(VALUE graph, VALUE str, long start,
                                         VALUE initial_captures, VALUE initial_tags,
                                         long *matched_end, long *matched_start,
                                         VALUE *matched_captures);
static int onibi_gir_match_captures_entry(VALUE states, VALUE outgoing, VALUE subprograms,
                                          VALUE str, long start, VALUE entry,
                                          VALUE entry_actions, VALUE initial_captures,
                                          VALUE initial_tags, int use_counters,
                                          long *matched_end,
                                          long *matched_start, VALUE *matched_captures);
static int onibi_hash_copy_i(VALUE key, VALUE value, VALUE arg) {
  rb_hash_aset(arg, key, value);
  return ST_CONTINUE;
}

static int onibi_grapheme_extend(OnigCodePoint code) {
  return (code >= 0x0300 && code <= 0x036f) ||
    (code >= 0x1ab0 && code <= 0x1aff) ||
    (code >= 0x1dc0 && code <= 0x1dff) ||
    (code >= 0x20d0 && code <= 0x20ff) ||
    (code >= 0xfe00 && code <= 0xfe0f) ||
    (code >= 0x1f3fb && code <= 0x1f3ff) ||
    (code >= 0x1f300 && code <= 0x1faff && code >= 0x1f7e0) ||
    (code >= 0x0903 && code <= 0x093c) ||
    (code >= 0x0a3e && code <= 0x0a42) ||
    (code >= 0x0bbe && code <= 0x0bce) ||
    (code >= 0x1d165 && code <= 0x1d169) ||
    (code >= 0xe0020 && code <= 0xe007f);
}

static int onibi_grapheme_ri(OnigCodePoint code) {
  return code >= 0x1f1e6 && code <= 0x1f1ff;
}

static int onibi_grapheme_hangul_l(OnigCodePoint code) {
  return (code >= 0x1100 && code <= 0x115f) || (code >= 0xa960 && code <= 0xa97c);
}

static int onibi_grapheme_hangul_v(OnigCodePoint code) {
  return (code >= 0x1160 && code <= 0x11a7) || (code >= 0xd7b0 && code <= 0xd7c6);
}

static int onibi_grapheme_hangul_t(OnigCodePoint code) {
  return (code >= 0x11a8 && code <= 0x11ff) || (code >= 0xd7cb && code <= 0xd7fb);
}

static int onibi_grapheme_prepend(OnigCodePoint code) {
  return (code >= 0x0600 && code <= 0x0605) ||
    (code >= 0x06dd && code <= 0x06dd) ||
    (code >= 0x070f && code <= 0x070f) ||
    (code >= 0x0890 && code <= 0x0891) ||
    (code >= 0x0d4e && code <= 0x0d4e) ||
    (code >= 0x110bd && code <= 0x110bd) ||
    (code >= 0x111c2 && code <= 0x111c3) ||
    (code >= 0x1193f && code <= 0x1193f) ||
    (code >= 0x11941 && code <= 0x11941) ||
    (code >= 0x11a3a && code <= 0x11a3a) ||
    (code >= 0x11a84 && code <= 0x11a89) ||
    (code >= 0x11d46 && code <= 0x11d46);
}

static long onibi_grapheme_width(VALUE str, long pos) {
  OnigCodePoint code; long width;
  if (!onibi_codepoint_at(str, pos, &code, &width)) return 0;
  long end = pos + width;
  if (code == '\r' && end < RSTRING_LEN(str) && RSTRING_PTR(str)[end] == '\n') return width + 1;
  if (onibi_grapheme_ri(code)) {
    OnigCodePoint next; long next_width;
    if (onibi_codepoint_at(str, end, &next, &next_width) && onibi_grapheme_ri(next)) end += next_width;
    return end - pos;
  }
  if (onibi_grapheme_hangul_l(code)) {
    OnigCodePoint next; long next_width;
    while (onibi_codepoint_at(str, end, &next, &next_width) &&
           (onibi_grapheme_hangul_l(next) || onibi_grapheme_hangul_v(next))) end += next_width;
    return end - pos;
  }
  if (onibi_grapheme_hangul_v(code)) {
    OnigCodePoint next; long next_width;
    while (onibi_codepoint_at(str, end, &next, &next_width) &&
           (onibi_grapheme_hangul_v(next) || onibi_grapheme_hangul_t(next))) end += next_width;
    return end - pos;
  }
  int join = onibi_grapheme_prepend(code);
  for (;;) {
    OnigCodePoint next; long next_width;
    if (!onibi_codepoint_at(str, end, &next, &next_width)) break;
    if (onibi_grapheme_extend(next)) { end += next_width; continue; }
    if (next == 0x200d) { join = 1; end += next_width; continue; }
    if (join) { join = 0; end += next_width; continue; }
    break;
  }
  return end - pos;
}

static int onibi_vm_walk(VALUE states, VALUE outgoing, VALUE str, long state_id, long pos, VALUE visited,
                         unsigned char *visited_bits, size_t visited_span,
                         long *initial_counters, uint32_t counter_count, int use_counters, long *matched_end) {
  typedef struct { long state_id, pos, next_edge; long *counters; } OnibiWalkFrame;
  /* Counter-bearing repeat paths can visit one state at many counter values.
   * Reserve a bounded workspace independent of graph state count. */
  long capacity = RARRAY_LEN(states) * 64 + 64;
  if (capacity > 65536) capacity = 65536;
  OnibiWalkFrame *stack = ALLOCA_N(OnibiWalkFrame, capacity);
  long *counter_pool = use_counters ? ALLOCA_N(long, (size_t)capacity * counter_count) : NULL;
  long depth = 0;
  if (use_counters && initial_counters) memcpy(counter_pool, initial_counters, sizeof(long) * counter_count);
  else if (use_counters) memset(counter_pool, 0, sizeof(long) * counter_count);
  stack[depth++] = (OnibiWalkFrame){state_id, pos, 0, use_counters ? counter_pool : NULL};
  while (depth > 0) {
    rb_thread_check_ints();
    onibi_check_deadline();
    OnibiWalkFrame *frame = &stack[depth - 1];
    if (frame->next_edge == 0) {
      if (!use_counters && visited_bits && frame->state_id >= 0 && frame->pos >= 0 &&
          (size_t)frame->state_id < (size_t)RARRAY_LEN(states) && (size_t)frame->pos < visited_span) {
        size_t mark = (size_t)frame->state_id * visited_span + (size_t)frame->pos;
        if (visited_bits[mark]) { depth--; continue; }
        visited_bits[mark] = 1;
      } else {
        VALUE key = rb_ary_new_from_args(3, LONG2NUM(frame->state_id), LONG2NUM(frame->pos),
                                         rb_str_new((const char *)frame->counters, (long)(sizeof(long) * counter_count)));
        if (RTEST(rb_hash_aref(visited, key))) { depth--; continue; }
        rb_hash_aset(visited, key, Qtrue);
      }
      VALUE state = rb_ary_entry(states, frame->state_id);
      unsigned int op = NUM2UINT(onibi_hash_value_id(state, id_key_opcode));
      if (op == 0) { *matched_end = frame->pos; return 1; }
      if (op == ONIBI_RS_GRAPHEME) {
        long consumed = onibi_grapheme_width(str, frame->pos);
        if (consumed <= 0) { depth--; continue; }
        frame->pos += consumed;
      } else if (op == ONIBI_RS_ATOMIC || op == ONIBI_RS_ABSENT) { depth--; continue; }
      else if (op == ONIBI_RS_CHAR || op == ONIBI_RS_CLASS || op == ONIBI_RS_ANY) {
        if (frame->pos >= RSTRING_LEN(str)) { depth--; continue; }
        unsigned char byte = (unsigned char)RSTRING_PTR(str)[frame->pos];
        VALUE payload = onibi_hash_value_id(state, id_key_payload);
        long consumed = 1;
        int hit = op == ONIBI_RS_ANY ? (byte != '\n' || RTEST(onibi_hash_value_id(payload, id_key_multiline))) :
          (op == ONIBI_RS_CHAR ?
            (RTEST(onibi_hash_value_id(payload, id_key_ignorecase)) ?
              tolower(byte) == tolower(NUM2INT(onibi_hash_value_id(payload, id_key_byte))) :
              byte == NUM2INT(onibi_hash_value_id(payload, id_key_byte))) : onibi_vm_class_match(payload, str, frame->pos, byte, &consumed));
        if (!hit) { depth--; continue; }
        frame->pos += consumed;
      }
    }
    VALUE state_edges = rb_ary_entry(outgoing, frame->state_id);
    if (frame->next_edge >= RARRAY_LEN(state_edges)) { depth--; continue; }
    if (depth >= capacity) onibi_vm_stack_overflow();
    VALUE edge = rb_ary_entry(state_edges, frame->next_edge++);
    VALUE edge_actions = onibi_hash_value_id(edge, id_key_actions);
    long *next_counters = frame->counters;
    if (use_counters) {
      next_counters = counter_pool + (size_t)depth * counter_count;
      memcpy(next_counters, frame->counters, sizeof(long) * counter_count);
      OnibiCounterState counter_state = {next_counters, counter_count};
      if (!onibi_vm_counter_actions_ok(edge_actions, &counter_state)) continue;
      onibi_vm_apply_counter_actions_c(edge_actions, &counter_state);
    }
    if (!onibi_vm_actions_ok(edge_actions, str, frame->pos, RSTRING_LEN(str), Qnil, Qnil)) continue;
    stack[depth++] = (OnibiWalkFrame){NUM2LONG(onibi_hash_value_id(edge, id_key_to)), frame->pos, 0, next_counters};
  }
  return 0;
}

static int onibi_gir_match(VALUE graph, VALUE str, long start, long *matched_end) {
  VALUE states = onibi_hash_value_id(graph, id_key_states);
  VALUE outgoing = onibi_hash_value_id(graph, id_key_outgoing);
  VALUE starts = onibi_hash_value_id(graph, id_key_start_edges);
  VALUE visited = rb_hash_new();
  unsigned char *visited_bits = NULL;
  size_t visited_span = (size_t)RSTRING_LEN(str) + 1U;
  size_t visited_size = 0;
  if (visited_span != 0 && (size_t)RARRAY_LEN(states) <= SIZE_MAX / visited_span)
    visited_size = (size_t)RARRAY_LEN(states) * visited_span;
  int visited_bits_owned = 0;
  if (visited_size != 0 && visited_size <= (size_t)64 << 20) {
    if (visited_size <= (size_t)1 << 20) visited_bits = ALLOCA_N(unsigned char, visited_size);
    else {
      visited_bits = ALLOC_N(unsigned char, visited_size);
      visited_bits_owned = 1;
    }
    memset(visited_bits, 0, visited_size);
  }
  VALUE counter_count = onibi_hash_value_id(graph, id_key_counter_count);
  int use_counters = !NIL_P(counter_count) && NUM2UINT(counter_count) != 0;
  uint32_t counter_slots = use_counters ? NUM2UINT(counter_count) : 0;
  for (long i = 0; i < RARRAY_LEN(starts); i++) {
    VALUE edge = rb_ary_entry(starts, i);
    VALUE edge_actions = onibi_hash_value_id(edge, id_key_actions);
    long *branch_counters = use_counters ? ALLOCA_N(long, counter_slots) : NULL;
    if (use_counters) {
      memset(branch_counters, 0, sizeof(long) * counter_slots);
      OnibiCounterState counter_state = {branch_counters, counter_slots};
      if (!onibi_vm_counter_actions_ok(edge_actions, &counter_state)) continue;
      onibi_vm_apply_counter_actions_c(edge_actions, &counter_state);
    }
    if (!onibi_vm_actions_ok(edge_actions, str, start, RSTRING_LEN(str), Qnil, Qnil)) continue;
    if (onibi_vm_walk(states, outgoing, str, NUM2LONG(onibi_hash_value_id(edge, id_key_to)), start, visited,
                      visited_bits, visited_span, branch_counters, counter_slots, use_counters, matched_end)) {
      if (visited_bits_owned) xfree(visited_bits);
      return 1;
    }
  }
  if (visited_bits_owned) xfree(visited_bits);
  return 0;
}

static VALUE onibi_capture_copy(VALUE captures) {
  VALUE copy = rb_hash_dup(captures);
  return copy;
}

static VALUE onibi_materialize_tags(VALUE tags, VALUE fallback) {
  if (NIL_P(tags)) return fallback;
  VALUE captures = rb_hash_new();
  VALUE cursor = tags;
  while (!NIL_P(cursor)) {
    VALUE slot = rb_ary_entry(cursor, 1);
    if (SYMBOL_P(slot) && SYM2ID(slot) == id_recursive_marker) {
      cursor = rb_ary_entry(cursor, 0);
      continue;
    }
    if (NIL_P(rb_hash_aref(captures, slot)))
      rb_hash_aset(captures, slot, rb_ary_entry(cursor, 2));
    cursor = rb_ary_entry(cursor, 0);
  }
  return captures;
}

static int onibi_has_capture_action(VALUE actions) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(rb_ary_entry(actions, i), id_key_action_code));
    if (code == ONIBI_GA_CAPTURE_OPEN || code == ONIBI_GA_CAPTURE_CLOSE) return 1;
  }
  return 0;
}

/* Capture output uses an append-only event chain.  Each branch shares the
   parent chain and allocates only the events that it adds. */
static VALUE onibi_apply_capture_actions(VALUE actions, long pos, VALUE captures,
                                         VALUE tags, long *reported_start) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    OnibiGActionOp code = (OnibiGActionOp)NUM2UINT(onibi_hash_value_id(action, id_key_action_code));
    if (code == ONIBI_GA_MATCH_RESET) { *reported_start = pos; continue; }
    if (code != ONIBI_GA_CAPTURE_OPEN && code != ONIBI_GA_CAPTURE_CLOSE) continue;
    VALUE slot = onibi_hash_value_id(action, id_key_slot);
    if (code == ONIBI_GA_CAPTURE_CLOSE && RTEST(onibi_hash_value_id(action, id_key_preserve_if_set)) &&
        RTEST(rb_hash_aref(captures, ID2SYM(id_recursive_marker)))) continue;
    rb_hash_aset(captures, slot, LONG2NUM(pos));
    VALUE event = rb_ary_new_from_args(3, tags, slot, LONG2NUM(pos));
    rb_obj_freeze(event);
    tags = event;
  }
  return tags;
}

static int onibi_vm_walk_captures(VALUE states, VALUE outgoing, VALUE subprograms, VALUE str, long state_id, long pos,
                                  VALUE visited, VALUE captures, VALUE counters, VALUE tags, long reported_start,
                                  int use_counters, long *matched_end, long *matched_start,
                                  VALUE *matched_captures) {
  typedef struct {
    long state_id, pos, next_edge, reported_start;
    VALUE captures, counters, tags;
    VALUE called_captures;
    long call_end, call_parent;
    int entered, waiting_call, call_status, call_kind;
  } OnibiCaptureFrame;
  long capacity = RARRAY_LEN(states) * 64 + 64;
  if (capacity > 65536) capacity = 65536;
  OnibiCaptureFrame *stack = ALLOCA_N(OnibiCaptureFrame, capacity);
  long depth = 0;
  stack[depth++] = (OnibiCaptureFrame){state_id, pos, 0, reported_start, captures, counters, tags,
                                      Qnil, 0, -1, 0, 0, 0, 0};
  while (depth > 0) {
    rb_thread_check_ints();
    onibi_check_deadline();
    OnibiCaptureFrame *frame = &stack[depth - 1];
    /* Pop a traversal frame and, when it is a subprogram root, its explicit
     * call frame as well. */
#define ONIBI_CAPTURE_POP_FRAME() do { \
      long parent_frame = frame->call_parent; \
      depth--; \
      if (parent_frame >= 0 && depth == parent_frame + 1) { \
        onibi_call_frame_pop(); \
        /* A failed call is an ordered-edge failure.  Atomic failure fails its
         * state; absence failure succeeds its zero-width state. */ \
        stack[parent_frame].call_status = stack[parent_frame].call_kind == 2 ? -1 : 0; \
        stack[parent_frame].waiting_call = stack[parent_frame].call_kind == 2 ? 1 : 0; \
      } \
    } while (0)
    if (frame->waiting_call) {
      if (frame->call_status < 0) { ONIBI_CAPTURE_POP_FRAME(); continue; }
      if (frame->call_status > 0) {
        if (RB_TYPE_P(frame->called_captures, T_HASH)) {
          frame->captures = rb_hash_dup(frame->captures);
          rb_hash_foreach(frame->called_captures, onibi_hash_copy_i, frame->captures);
          rb_hash_aset(frame->captures, ID2SYM(id_recursive_marker), Qtrue);
          frame->tags = Qnil;
        }
        frame->pos = frame->call_end;
        frame->waiting_call = 0;
        frame->call_status = 0;
      }
    }
    if (!frame->entered) {
      frame->entered = 1;
      VALUE key = rb_ary_new_from_args(6, LONG2NUM(frame->state_id), LONG2NUM(frame->pos),
                                       frame->captures, frame->counters, frame->tags,
                                       LONG2NUM(frame->reported_start));
      if (RTEST(rb_hash_aref(visited, key))) { ONIBI_CAPTURE_POP_FRAME(); continue; }
      rb_hash_aset(visited, key, Qtrue);
      VALUE state = rb_ary_entry(states, frame->state_id);
      unsigned int op = NUM2UINT(onibi_hash_value_id(state, id_key_opcode));
      if (op == 0) {
        if (frame->call_parent >= 0) {
          VALUE result = onibi_materialize_tags(frame->tags, frame->captures);
          long parent = frame->call_parent;
          while (depth > parent + 1) depth--;
          stack[parent].called_captures = result;
          stack[parent].call_end = frame->pos;
          stack[parent].call_status = stack[parent].call_kind == 3 ? -1 : 1;
          stack[parent].waiting_call = 1;
          onibi_call_frame_pop();
          continue;
        }
        *matched_end = frame->pos;
        *matched_start = frame->reported_start;
        *matched_captures = onibi_materialize_tags(frame->tags, frame->captures);
        return 1;
      }
      if (op == ONIBI_RS_GRAPHEME) {
        long consumed = onibi_grapheme_width(str, frame->pos);
        if (consumed <= 0) { ONIBI_CAPTURE_POP_FRAME(); continue; }
        frame->pos += consumed;
      }
      if (op == ONIBI_RS_CALL) {
        VALUE payload = onibi_hash_value_id(state, id_key_payload);
        long subprogram_id = NUM2LONG(onibi_hash_value_id(payload, id_key_subprogram));
        if (subprogram_id < 0 || subprogram_id >= RARRAY_LEN(subprograms)) { ONIBI_CAPTURE_POP_FRAME(); continue; }
        VALUE descriptor = rb_ary_entry(subprograms, subprogram_id);
        VALUE entry = onibi_hash_value_id(descriptor, id_key_entry);
        if (NIL_P(entry)) { ONIBI_CAPTURE_POP_FRAME(); continue; }
        OnibiCallFrame *call_frame = onibi_call_frame_push((OnibiSubprogramId)subprogram_id);
        call_frame->continuation = (OnibiStateId)frame->state_id;
        frame->waiting_call = 1;
        frame->call_status = 0;
        frame->call_parent = -1;
        VALUE entry_actions = onibi_hash_value_id(descriptor, id_key_entry_actions);
        VALUE call_counters = use_counters ? rb_hash_new() : Qnil;
        VALUE call_captures = RB_TYPE_P(frame->captures, T_HASH) ? rb_hash_dup(frame->captures) : rb_hash_new();
        VALUE call_tags = frame->tags;
        long call_reported_start = frame->reported_start;
        VALUE actions = RB_TYPE_P(entry_actions, T_ARRAY) ? entry_actions : rb_ary_new();
        if (!onibi_vm_actions_ok(actions, str, frame->pos, RSTRING_LEN(str), call_counters, call_captures)) {
          onibi_call_frame_pop(); ONIBI_CAPTURE_POP_FRAME(); continue;
        }
        if (use_counters) onibi_vm_apply_counter_actions(actions, call_counters);
        call_tags = onibi_apply_capture_actions(actions, frame->pos, call_captures, call_tags, &call_reported_start);
        if (depth >= capacity) onibi_vm_stack_overflow();
        long call_parent = depth - 1;
        stack[depth++] = (OnibiCaptureFrame){NUM2LONG(entry), frame->pos, 0, call_reported_start,
                                             call_captures, call_counters, call_tags, Qnil, 0,
                                             call_parent, 0, 0, 0};
        continue;
      } else if (op == ONIBI_RS_ATOMIC || op == ONIBI_RS_ABSENT) {
        VALUE payload = onibi_hash_value_id(state, id_key_payload);
        long subprogram_id = NUM2LONG(onibi_hash_value_id(payload, id_key_subprogram));
        if (subprogram_id < 0 || subprogram_id >= RARRAY_LEN(subprograms)) {
          if (op == ONIBI_RS_ABSENT) continue;
          ONIBI_CAPTURE_POP_FRAME(); continue;
        }
        VALUE descriptor = rb_ary_entry(subprograms, subprogram_id);
        VALUE entry = onibi_hash_value_id(descriptor, id_key_entry);
        if (NIL_P(entry)) {
          if (op == ONIBI_RS_ABSENT) continue;
          ONIBI_CAPTURE_POP_FRAME(); continue;
        }
        OnibiCallFrame *call_frame = onibi_call_frame_push((OnibiSubprogramId)subprogram_id);
        call_frame->continuation = (OnibiStateId)frame->state_id;
        frame->waiting_call = 1;
        frame->call_status = 0;
        frame->call_kind = op == ONIBI_RS_ABSENT ? 3 : 2;
        VALUE entry_actions = onibi_hash_value_id(descriptor, id_key_entry_actions);
        VALUE call_counters = use_counters ? rb_hash_new() : Qnil;
        VALUE call_captures = RB_TYPE_P(frame->captures, T_HASH) ? rb_hash_dup(frame->captures) : rb_hash_new();
        VALUE call_tags = frame->tags;
        long call_reported_start = frame->reported_start;
        VALUE actions = RB_TYPE_P(entry_actions, T_ARRAY) ? entry_actions : rb_ary_new();
        if (!onibi_vm_actions_ok(actions, str, frame->pos, RSTRING_LEN(str), call_counters, call_captures)) {
          onibi_call_frame_pop();
          if (op == id_g_absent) { frame->waiting_call = 0; continue; }
          ONIBI_CAPTURE_POP_FRAME(); continue;
        }
        if (use_counters) onibi_vm_apply_counter_actions(actions, call_counters);
        call_tags = onibi_apply_capture_actions(actions, frame->pos, call_captures, call_tags, &call_reported_start);
        if (depth >= capacity) onibi_vm_stack_overflow();
        long call_parent = depth - 1;
        stack[depth++] = (OnibiCaptureFrame){NUM2LONG(entry), frame->pos, 0, call_reported_start,
                                             call_captures, call_counters, call_tags, Qnil, 0,
                                             call_parent, 0, 0, 0, 0};
        continue;
      } else if (op == ONIBI_RS_CHAR || op == ONIBI_RS_CLASS || op == ONIBI_RS_ANY || op == ONIBI_RS_BACKREF) {
        if (frame->pos >= RSTRING_LEN(str)) { ONIBI_CAPTURE_POP_FRAME(); continue; }
        if (op == ONIBI_RS_BACKREF) {
          VALUE payload = onibi_hash_value_id(state, id_key_payload);
          long capture = NUM2LONG(onibi_hash_value_id(payload, id_key_capture));
          VALUE begin = rb_hash_aref(frame->captures, LONG2NUM(2 * (capture - 1)));
          VALUE finish = rb_hash_aref(frame->captures, LONG2NUM(2 * (capture - 1) + 1));
          if (NIL_P(begin) || NIL_P(finish)) { ONIBI_CAPTURE_POP_FRAME(); continue; }
          long length = NUM2LONG(finish) - NUM2LONG(begin);
          if (frame->pos + length > RSTRING_LEN(str)) { ONIBI_CAPTURE_POP_FRAME(); continue; }
          int fold = RTEST(onibi_hash_value_id(payload, id_key_ignorecase));
          if (!fold) {
            if (memcmp(RSTRING_PTR(str) + frame->pos, RSTRING_PTR(str) + NUM2LONG(begin), (size_t)length) != 0) { ONIBI_CAPTURE_POP_FRAME(); continue; }
          } else {
            int equal = 1;
            for (long i = 0; i < length; i++) {
              if (tolower((unsigned char)RSTRING_PTR(str)[frame->pos + i]) != tolower((unsigned char)RSTRING_PTR(str)[NUM2LONG(begin) + i])) { equal = 0; break; }
            }
            if (!equal) { ONIBI_CAPTURE_POP_FRAME(); continue; }
          }
          frame->pos += length;
        } else {
          unsigned char byte = (unsigned char)RSTRING_PTR(str)[frame->pos];
          VALUE payload = onibi_hash_value_id(state, id_key_payload);
          long consumed = 1;
          int hit = op == ONIBI_RS_ANY ? (byte != '\n' || RTEST(onibi_hash_value_id(payload, id_key_multiline))) :
            (op == ONIBI_RS_CHAR ?
              (RTEST(onibi_hash_value_id(payload, id_key_ignorecase)) ?
                tolower(byte) == tolower(NUM2INT(onibi_hash_value_id(payload, id_key_byte))) :
                byte == NUM2INT(onibi_hash_value_id(payload, id_key_byte))) : onibi_vm_class_match(payload, str, frame->pos, byte, &consumed));
          if (!hit) { ONIBI_CAPTURE_POP_FRAME(); continue; }
          frame->pos += consumed;
        }
      }
    }
    VALUE state_edges = rb_ary_entry(outgoing, frame->state_id);
    if (frame->next_edge >= RARRAY_LEN(state_edges)) { ONIBI_CAPTURE_POP_FRAME(); continue; }
    VALUE edge = rb_ary_entry(state_edges, frame->next_edge++);
    VALUE edge_actions = onibi_hash_value_id(edge, id_key_actions);
    VALUE next_counters = use_counters ? rb_hash_dup(frame->counters) : Qnil;
    if (!onibi_vm_actions_ok(edge_actions, str, frame->pos, RSTRING_LEN(str), next_counters, frame->captures)) continue;
    VALUE next_captures = onibi_has_capture_action(edge_actions) ? onibi_capture_copy(frame->captures) : frame->captures;
    long next_reported_start = frame->reported_start;
    if (use_counters) onibi_vm_apply_counter_actions(edge_actions, next_counters);
    VALUE next_tags = onibi_apply_capture_actions(edge_actions, frame->pos, next_captures, frame->tags, &next_reported_start);
    if (depth >= capacity) onibi_vm_stack_overflow();
    stack[depth++] = (OnibiCaptureFrame){NUM2LONG(onibi_hash_value_id(edge, id_key_to)), frame->pos, 0,
                                         next_reported_start, next_captures, next_counters,
                                         next_tags, Qnil, 0, frame->call_parent, 0, 0, 0, 0};
  }
#undef ONIBI_CAPTURE_POP_FRAME
  return 0;
}

static int onibi_gir_match_captures_entry(VALUE states, VALUE outgoing, VALUE subprograms,
                                          VALUE str, long start, VALUE entry,
                                          VALUE entry_actions, VALUE initial_captures,
                                          VALUE initial_tags, int use_counters,
                                          long *matched_end,
                                          long *matched_start, VALUE *matched_captures) {
  VALUE visited = rb_hash_new();
  VALUE captures = RB_TYPE_P(initial_captures, T_HASH) ? rb_hash_dup(initial_captures) : rb_hash_new();
  rb_hash_delete(captures, ID2SYM(id_recursive_marker));
  VALUE counters = use_counters ? rb_hash_new() : Qnil;
  VALUE tags = initial_tags;
  VALUE actions = RB_TYPE_P(entry_actions, T_ARRAY) ? entry_actions : rb_ary_new();
  VALUE branch_counters = use_counters ? rb_hash_dup(counters) : Qnil;
  if (!onibi_vm_actions_ok(actions, str, start, RSTRING_LEN(str), branch_counters, captures)) return 0;
  VALUE branch_captures = onibi_has_capture_action(actions) ? onibi_capture_copy(captures) : captures;
  long reported_start = start;
  if (use_counters) onibi_vm_apply_counter_actions(actions, branch_counters);
  VALUE branch_tags = onibi_apply_capture_actions(actions, start, branch_captures, tags, &reported_start);
  return onibi_vm_walk_captures(states, outgoing, subprograms, str, NUM2LONG(entry), start,
                                visited, branch_captures, branch_counters, branch_tags,
                                reported_start, use_counters, matched_end, matched_start, matched_captures);
}

static int onibi_gir_match_captures_seed(VALUE graph, VALUE str, long start,
                                         VALUE initial_captures, VALUE initial_tags,
                                         long *matched_end, long *matched_start,
                                         VALUE *matched_captures) {
  VALUE states = onibi_hash_value_id(graph, id_key_states);
  VALUE outgoing = onibi_hash_value_id(graph, id_key_outgoing);
  VALUE starts = onibi_hash_value_id(graph, id_key_start_edges);
  VALUE subprograms = onibi_hash_value_id(graph, id_key_subprograms);
  VALUE counter_count = onibi_hash_value_id(graph, id_key_counter_count);
  int use_counters = !NIL_P(counter_count) && NUM2UINT(counter_count) != 0;
  for (long i = 0; i < RARRAY_LEN(starts); i++) {
    VALUE edge = rb_ary_entry(starts, i);
    if (onibi_gir_match_captures_entry(states, outgoing, subprograms, str, start,
                                       onibi_hash_value_id(edge, id_key_to),
                                       onibi_hash_value_id(edge, id_key_actions),
                                       initial_captures, initial_tags, use_counters,
                                       matched_end, matched_start, matched_captures)) return 1;
  }
  return 0;
}

static int onibi_gir_match_captures(VALUE graph, VALUE str, long start, long *matched_end,
                                    long *matched_start, VALUE *matched_captures) {
  return onibi_gir_match_captures_seed(graph, str, start, Qnil, Qnil,
                                       matched_end, matched_start, matched_captures);
}

static void onibi_rseq_validate(VALUE rseq) {
  VALUE blob = onibi_hash_value_id(rseq, id_key_blob);
  VALUE physical_graph = rb_hash_aref(rseq, ID2SYM(id_key_physical_graph));
  VALUE semantic = onibi_hash_value_id(rseq, id_key_header);
  VALUE semantic_states = onibi_hash_value_id(rseq, id_key_states);
  VALUE semantic_edges = onibi_hash_value_id(rseq, id_key_edges);
  VALUE semantic_start_edges = onibi_hash_value_id(rseq, id_key_start_edges);
  VALUE semantic_actions = onibi_hash_value_id(rseq, id_key_actions);
  VALUE semantic_subprograms = onibi_hash_value_id(rseq, id_key_subprograms);
  if (NIL_P(blob) || RSTRING_LEN(blob) < (long)sizeof(OnibiRSeqHeader) ||
      !RTEST(rb_obj_frozen_p(rseq)) || !RTEST(rb_obj_frozen_p(blob)) ||
      !RTEST(rb_obj_frozen_p(semantic)) || !RTEST(rb_obj_frozen_p(semantic_states)) ||
      !RTEST(rb_obj_frozen_p(semantic_edges)) || !RTEST(rb_obj_frozen_p(semantic_actions)) ||
      !RB_TYPE_P(semantic_subprograms, T_ARRAY) || !RTEST(rb_obj_frozen_p(semantic_subprograms)) ||
      !RTEST(rb_obj_frozen_p(semantic_start_edges)) ||
      (!NIL_P(physical_graph) && !RTEST(rb_obj_frozen_p(physical_graph))))
    rb_raise(rb_eArgError, "invalid Onibi RSeq blob");
  if (!NIL_P(physical_graph)) {
    VALUE cached_states = RB_TYPE_P(physical_graph, T_HASH) ? onibi_hash_value_id(physical_graph, id_key_states) : Qnil;
    VALUE cached_edges = RB_TYPE_P(physical_graph, T_HASH) ? onibi_hash_value_id(physical_graph, id_key_edges) : Qnil;
    VALUE cached_starts = RB_TYPE_P(physical_graph, T_HASH) ? onibi_hash_value_id(physical_graph, id_key_start_edges) : Qnil;
    VALUE cached_outgoing = RB_TYPE_P(physical_graph, T_HASH) ? onibi_hash_value_id(physical_graph, id_key_outgoing) : Qnil;
    if (!RB_TYPE_P(physical_graph, T_HASH) || !RB_TYPE_P(cached_states, T_ARRAY) ||
        !RB_TYPE_P(cached_edges, T_ARRAY) || !RB_TYPE_P(cached_starts, T_ARRAY) ||
        !RB_TYPE_P(cached_outgoing, T_ARRAY) ||
        !RTEST(rb_obj_frozen_p(cached_states)) || !RTEST(rb_obj_frozen_p(cached_edges)) ||
        !RTEST(rb_obj_frozen_p(cached_starts)) || !RTEST(rb_obj_frozen_p(cached_outgoing)) ||
        RARRAY_LEN(cached_states) != RARRAY_LEN(semantic_states) ||
        RARRAY_LEN(cached_outgoing) != RARRAY_LEN(cached_states) ||
        RARRAY_LEN(cached_edges) != RARRAY_LEN(semantic_edges) ||
        RARRAY_LEN(cached_starts) != RARRAY_LEN(semantic_start_edges))
      rb_raise(rb_eArgError, "invalid cached RSeq execution view");
    for (long state_id = 0; state_id < RARRAY_LEN(cached_outgoing); state_id++) {
      VALUE state_edges = rb_ary_entry(cached_outgoing, state_id);
      if (!RB_TYPE_P(state_edges, T_ARRAY) || !RTEST(rb_obj_frozen_p(state_edges)))
        rb_raise(rb_eArgError, "invalid cached RSeq outgoing edge index");
      for (long edge_id = 0; edge_id < RARRAY_LEN(state_edges); edge_id++) {
        VALUE edge = rb_ary_entry(state_edges, edge_id);
        if (!RB_TYPE_P(edge, T_HASH) || NUM2LONG(onibi_hash_value_id(edge, id_key_from)) != state_id ||
            !RB_TYPE_P(onibi_hash_value_id(edge, id_key_actions), T_ARRAY))
          rb_raise(rb_eArgError, "invalid cached RSeq outgoing edge");
      }
    }
  }
  OnibiRSeqHeader header;
  memcpy(&header, RSTRING_PTR(blob), sizeof(header));
  if (NIL_P(semantic) || NIL_P(semantic_states) || !RB_TYPE_P(semantic_states, T_ARRAY) ||
      NIL_P(semantic_edges) || !RB_TYPE_P(semantic_edges, T_ARRAY) ||
      NIL_P(semantic_actions) || !RB_TYPE_P(semantic_actions, T_ARRAY) ||
      RARRAY_LEN(semantic_states) != header.state_count ||
      RARRAY_LEN(semantic_edges) != header.edge_count - header.start_edge_count ||
      RARRAY_LEN(semantic_actions) != header.action_count ||
      header.start_edge_count > header.edge_count ||
      NUM2UINT(onibi_hash_value_id(semantic, id_key_state_count)) != header.state_count ||
      NUM2UINT(onibi_hash_value_id(semantic, id_key_features)) != header.features ||
      NUM2UINT(onibi_hash_value_id(semantic, id_key_edge_count)) != header.edge_count - header.start_edge_count ||
      NUM2UINT(onibi_hash_value_id(semantic, id_key_action_count)) != header.action_count ||
      NUM2UINT(onibi_hash_value_id(semantic, id_key_class_count)) != header.class_count ||
      NUM2UINT(onibi_hash_value_id(semantic, id_key_capture_count)) != header.capture_count ||
      NUM2UINT(onibi_hash_value_id(semantic, id_key_counter_count)) != header.counter_count ||
      RARRAY_LEN(semantic_subprograms) != header.subprogram_count ||
      NUM2UINT(onibi_hash_value_id(semantic, id_key_subprogram_count)) != header.subprogram_count ||
      NUM2UINT(onibi_hash_value_id(semantic, id_key_start_edge_base)) != header.start_edge_base ||
      NUM2UINT(onibi_hash_value_id(semantic, id_key_start_edge_count)) != header.start_edge_count ||
      NUM2UINT(onibi_hash_value_id(semantic, id_key_blob_size)) != header.blob_size)
    rb_raise(rb_eArgError, "RSeq semantic and physical headers disagree");
  if (header.magic != ONIBI_RSEQ_MAGIC || header.version != ONIBI_RSEQ_VERSION ||
      header.exec_kind > 2 ||
      ((header.flags & 1U) != (RTEST(onibi_hash_value_id(semantic, id_key_ignorecase)) ? 1U : 0U)) ||
      ((header.flags & 2U) != (RTEST(onibi_hash_value_id(semantic, id_key_multiline)) ? 2U : 0U)) ||
      header.blob_size != (uint32_t)RSTRING_LEN(blob) ||
      header.states_offset < sizeof(OnibiRSeqHeader) ||
      (header.states_offset & 3U) != 0 || (header.edges_offset & 3U) != 0 ||
      (header.actions_offset & 3U) != 0 || (header.blob_size & 3U) != 0 ||
      header.edges_offset < header.states_offset ||
      header.states_offset + header.state_count * sizeof(OnibiRState) > header.edges_offset ||
      header.edges_offset + header.edge_count * sizeof(OnibiREdge) > header.actions_offset ||
      header.start_edge_count > header.edge_count ||
      (uint64_t)header.start_edge_base + (uint64_t)header.start_edge_count > header.edge_count ||
      header.start_edge_base != header.edge_count - header.start_edge_count ||
      header.actions_offset + header.action_count * sizeof(OnibiRAction) > header.blob_size ||
      (header.classes_offset & 3U) != 0 || (header.literals_offset & 3U) != 0 ||
      (header.descriptors_offset & 3U) != 0 ||
      (header.subprograms_offset & 3U) != 0 ||
      (header.classes_offset && header.classes_offset < header.actions_offset) ||
      (header.literals_offset && header.literals_offset < header.classes_offset) ||
      (header.descriptors_offset && header.descriptors_offset < header.literals_offset) ||
      (header.subprograms_offset && header.subprograms_offset < header.descriptors_offset) ||
      header.classes_offset > header.blob_size || header.literals_offset > header.blob_size ||
      header.descriptors_offset > header.blob_size || header.subprograms_offset > header.blob_size ||
      header.classes_offset + (uint64_t)header.class_count * (sizeof(OnibiClassDesc) + 32U) > header.literals_offset ||
      header.descriptors_offset + (uint64_t)NUM2UINT(onibi_hash_value_id(semantic, id_key_literal_count)) * sizeof(OnibiLiteralDesc) > header.subprograms_offset ||
      header.subprograms_offset + (uint64_t)header.subprogram_count * sizeof(OnibiSubprogramDesc) > header.blob_size)
    rb_raise(rb_eArgError, "invalid Onibi RSeq blob");
  for (long i = 0; i < RARRAY_LEN(semantic_subprograms); i++) {
    VALUE descriptor = rb_ary_entry(semantic_subprograms, i);
    VALUE entry_state = RB_TYPE_P(descriptor, T_HASH) ? onibi_hash_value_id(descriptor, id_key_entry) : Qnil;
    VALUE accept_state = RB_TYPE_P(descriptor, T_HASH) ? onibi_hash_value_id(descriptor, id_key_accept) : Qnil;
    VALUE flags = RB_TYPE_P(descriptor, T_HASH) ? onibi_hash_value_id(descriptor, id_key_flags) : Qnil;
    if (NIL_P(entry_state) || NIL_P(accept_state) || NIL_P(flags) ||
        NUM2LONG(entry_state) < 0 || NUM2LONG(entry_state) >= (long)header.state_count ||
        NUM2LONG(accept_state) < 0 || NUM2LONG(accept_state) >= (long)header.state_count ||
        NUM2LONG(flags) < 0)
      rb_raise(rb_eArgError, "invalid RSeq subprogram descriptor");
    const OnibiSubprogramDesc *physical = (const OnibiSubprogramDesc *)
      (RSTRING_PTR(blob) + header.subprograms_offset) + i;
    if (physical->entry != (OnibiStateId)NUM2ULONG(entry_state) ||
        physical->accept != (OnibiStateId)NUM2ULONG(accept_state) ||
        physical->flags != (uint32_t)NUM2ULONG(flags))
      rb_raise(rb_eArgError, "RSeq subprogram descriptor disagrees with semantic table");
  }
  const OnibiRState *states = (const OnibiRState *)(RSTRING_PTR(blob) + header.states_offset);
  for (uint32_t i = 0; i < header.state_count; i++) {
    VALUE semantic_state = rb_ary_entry(semantic_states, i);
    if (!RB_TYPE_P(semantic_state, T_HASH) || !RTEST(rb_obj_frozen_p(semantic_state)) ||
        !RTEST(rb_obj_frozen_p(onibi_hash_value_id(semantic_state, id_key_payload))))
      rb_raise(rb_eArgError, "invalid semantic RSeq state");
    ID semantic_op = SYM2ID(onibi_hash_value_id(semantic_state, id_key_op));
    uint8_t expected_op = semantic_op == id_g_accept ? 0 :
      semantic_op == id_g_char ? ONIBI_RS_CHAR : semantic_op == id_g_class ? ONIBI_RS_CLASS :
      semantic_op == id_g_any ? ONIBI_RS_ANY : semantic_op == id_g_grapheme ? ONIBI_RS_GRAPHEME :
      semantic_op == id_g_backref ? ONIBI_RS_BACKREF : semantic_op == id_g_call ? ONIBI_RS_CALL :
      semantic_op == id_g_atomic ? ONIBI_RS_ATOMIC : semantic_op == id_g_absent ? ONIBI_RS_ABSENT : 0xff;
    if (expected_op == 0xff || states[i].op != expected_op)
      rb_raise(rb_eArgError, "RSeq semantic and physical states disagree");
    if (!NIL_P(physical_graph)) {
      VALUE cached_state = rb_ary_entry(onibi_hash_value_id(physical_graph, id_key_states), i);
      if (!RB_TYPE_P(cached_state, T_HASH) ||
          SYM2ID(onibi_hash_value_id(cached_state, id_key_op)) != semantic_op ||
          !rb_equal(onibi_hash_value_id(cached_state, id_key_payload), onibi_hash_value_id(semantic_state, id_key_payload)))
        rb_raise(rb_eArgError, "cached RSeq state disagrees with semantic state");
    }
    if (semantic_op == id_g_class) {
      VALUE bitmap = onibi_hash_value_id(onibi_hash_value_id(semantic_state, id_key_payload), id_key_bitmap);
      if (!RB_TYPE_P(bitmap, T_STRING) || RSTRING_LEN(bitmap) != 32)
        rb_raise(rb_eArgError, "RSeq class state has no compiled bitmap");
    }
    if (semantic_op == id_g_char) {
      VALUE byte = onibi_hash_value_id(onibi_hash_value_id(semantic_state, id_key_payload), id_key_byte);
      if (NIL_P(byte) || NUM2LONG(byte) < 0 || NUM2LONG(byte) > 255)
        rb_raise(rb_eArgError, "RSeq character state has an invalid byte");
    }
    if (states[i].op > ONIBI_RS_RUN_ANY)
      rb_raise(rb_eArgError, "invalid Onibi RSeq state opcode");
    if ((uint64_t)states[i].edge_base + states[i].edge_count > header.edge_count - header.start_edge_count)
      rb_raise(rb_eArgError, "invalid Onibi RSeq state edge range");
    if (states[i].op == ONIBI_RS_CLASS && states[i].payload >= header.class_count)
      rb_raise(rb_eArgError, "invalid Onibi RSeq class descriptor id");
    if (states[i].op == ONIBI_RS_CHAR && states[i].payload >= NUM2UINT(onibi_hash_value_id(semantic, id_key_literal_count)))
      rb_raise(rb_eArgError, "invalid Onibi RSeq literal descriptor id");
  }
  const OnibiREdge *edges = (const OnibiREdge *)(RSTRING_PTR(blob) + header.edges_offset);
  uint32_t edge_total = header.edge_count;
  for (uint32_t i = 0; i < edge_total; i++) {
    if (edges[i].destination != ONIBI_ACCEPT_STATE && edges[i].destination >= header.state_count)
      rb_raise(rb_eArgError, "invalid Onibi RSeq edge destination");
    if (edges[i].action_offset != 0 &&
        (edges[i].action_offset < sizeof(OnibiRAction) ||
         edges[i].action_offset % sizeof(OnibiRAction) != 0 ||
         edges[i].action_offset >= header.blob_size - header.actions_offset))
      rb_raise(rb_eArgError, "invalid Onibi RSeq edge action offset");
  }
  for (uint32_t i = 0; i < header.edge_count - header.start_edge_count; i++) {
    VALUE semantic_edge = rb_ary_entry(semantic_edges, i);
    if (!RB_TYPE_P(semantic_edge, T_HASH) || !RTEST(rb_obj_frozen_p(semantic_edge)) ||
        !RTEST(rb_obj_frozen_p(onibi_hash_value_id(semantic_edge, id_key_actions))))
      rb_raise(rb_eArgError, "invalid semantic RSeq edge");
    VALUE semantic_edge_actions = onibi_hash_value_id(semantic_edge, id_key_actions);
    if (RARRAY_LEN(semantic_edge_actions) > 0) {
      VALUE terminator = rb_ary_entry(semantic_edge_actions, RARRAY_LEN(semantic_edge_actions) - 1);
      VALUE terminator_op = RB_TYPE_P(terminator, T_HASH) ? onibi_hash_value_id(terminator, id_key_op) : Qnil;
      if (!SYMBOL_P(terminator_op) || SYM2ID(terminator_op) != id_a_end)
        rb_raise(rb_eArgError, "RSeq edge action program is not terminated");
    }
    uint32_t destination = (uint32_t)NUM2ULONG(onibi_hash_value_id(semantic_edge, id_key_to));
    if (destination == header.state_count - 1) destination = ONIBI_ACCEPT_STATE;
    uint32_t action_index = (uint32_t)NUM2ULONG(onibi_hash_value_id(semantic_edge, id_key_action_offset));
    uint32_t expected_offset = action_index == 0 && RARRAY_LEN(semantic_edge_actions) == 0 ? 0 :
      (uint32_t)(sizeof(OnibiRAction) * (action_index + 1));
    if (edges[i].destination != destination || edges[i].action_offset != expected_offset)
      rb_raise(rb_eArgError, "RSeq edge disagrees with semantic edge");
    if (!NIL_P(physical_graph)) {
      VALUE cached_edge = rb_ary_entry(onibi_hash_value_id(physical_graph, id_key_edges), i);
      uint32_t cached_to = RB_TYPE_P(cached_edge, T_HASH) ? (uint32_t)NUM2ULONG(onibi_hash_value_id(cached_edge, id_key_to)) : UINT32_MAX;
      VALUE cached_actions = RB_TYPE_P(cached_edge, T_HASH) ? onibi_hash_value_id(cached_edge, id_key_actions) : Qnil;
      if (!RB_TYPE_P(cached_edge, T_HASH) || cached_to != (destination == ONIBI_ACCEPT_STATE ? header.state_count - 1 : destination) ||
          !RB_TYPE_P(cached_actions, T_ARRAY) || RARRAY_LEN(cached_actions) != RARRAY_LEN(semantic_edge_actions))
        rb_raise(rb_eArgError, "cached RSeq edge disagrees with physical edge");
      for (long a = 0; a < RARRAY_LEN(semantic_edge_actions); a++) {
        if (!rb_equal(rb_ary_entry(cached_actions, a), rb_ary_entry(semantic_edge_actions, a)))
          rb_raise(rb_eArgError, "cached RSeq action program disagrees with semantic edge");
      }
    }
  }
  if (NIL_P(semantic_start_edges) || !RB_TYPE_P(semantic_start_edges, T_ARRAY) ||
      RARRAY_LEN(semantic_start_edges) != header.start_edge_count)
    rb_raise(rb_eArgError, "RSeq start edges are invalid");
  for (uint32_t i = 0; i < header.start_edge_count; i++) {
    VALUE semantic_edge = rb_ary_entry(semantic_start_edges, i);
    if (!RB_TYPE_P(semantic_edge, T_HASH) || !RTEST(rb_obj_frozen_p(semantic_edge)) ||
        !RTEST(rb_obj_frozen_p(onibi_hash_value_id(semantic_edge, id_key_actions))))
      rb_raise(rb_eArgError, "invalid semantic RSeq start edge");
    VALUE semantic_edge_actions = onibi_hash_value_id(semantic_edge, id_key_actions);
    if (RARRAY_LEN(semantic_edge_actions) > 0) {
      VALUE terminator = rb_ary_entry(semantic_edge_actions, RARRAY_LEN(semantic_edge_actions) - 1);
      VALUE terminator_op = RB_TYPE_P(terminator, T_HASH) ? onibi_hash_value_id(terminator, id_key_op) : Qnil;
      if (!SYMBOL_P(terminator_op) || SYM2ID(terminator_op) != id_a_end)
        rb_raise(rb_eArgError, "RSeq start-edge action program is not terminated");
    }
    uint32_t destination = (uint32_t)NUM2ULONG(onibi_hash_value_id(semantic_edge, id_key_to));
    uint32_t action_index = (uint32_t)NUM2ULONG(onibi_hash_value_id(semantic_edge, id_key_action_offset));
    uint32_t expected_offset = RARRAY_LEN(semantic_edge_actions) == 0 ? 0 :
      (uint32_t)(sizeof(OnibiRAction) * (action_index + 1));
    if (edges[header.edge_count - header.start_edge_count + i].destination != destination ||
        edges[header.edge_count - header.start_edge_count + i].action_offset != expected_offset)
      rb_raise(rb_eArgError, "RSeq edge disagrees with semantic start edge");
    if (!NIL_P(physical_graph)) {
      VALUE cached_edge = rb_ary_entry(onibi_hash_value_id(physical_graph, id_key_start_edges), i);
      VALUE cached_actions = RB_TYPE_P(cached_edge, T_HASH) ? onibi_hash_value_id(cached_edge, id_key_actions) : Qnil;
      uint32_t cached_to = RB_TYPE_P(cached_edge, T_HASH) ? (uint32_t)NUM2ULONG(onibi_hash_value_id(cached_edge, id_key_to)) : UINT32_MAX;
      if (!RB_TYPE_P(cached_edge, T_HASH) || cached_to != destination || !RB_TYPE_P(cached_actions, T_ARRAY) ||
          RARRAY_LEN(cached_actions) != RARRAY_LEN(semantic_edge_actions))
        rb_raise(rb_eArgError, "cached RSeq start edge disagrees with physical edge");
      for (long a = 0; a < RARRAY_LEN(semantic_edge_actions); a++) {
        if (!rb_equal(rb_ary_entry(cached_actions, a), rb_ary_entry(semantic_edge_actions, a)))
          rb_raise(rb_eArgError, "cached RSeq start action program disagrees with semantic edge");
      }
    }
  }
  const OnibiRAction *actions = (const OnibiRAction *)(RSTRING_PTR(blob) + header.actions_offset);
  for (uint32_t i = 0; i < header.action_count; i++) {
    VALUE semantic_action = rb_ary_entry(semantic_actions, i);
    if (!RB_TYPE_P(semantic_action, T_HASH) || !RTEST(rb_obj_frozen_p(semantic_action)))
      rb_raise(rb_eArgError, "invalid semantic RSeq action");
    ID op = SYM2ID(onibi_hash_value_id(semantic_action, id_key_op));
    uint8_t expected_op = (op == id_capture_open || op == id_capture_close) ? ONIBI_RA_CAPTURE :
      op == id_match_reset ? ONIBI_RA_MATCH_RESET :
      (op == id_a_assert_begin_buffer || op == id_a_assert_end_buffer || op == id_a_assert_begin_line ||
       op == id_a_assert_end_line || op == id_a_assert_semi_end_buffer || op == id_a_assert_search_origin ||
       op == id_a_assert_word_boundary || op == id_a_assert_nonword_boundary ||
       op == id_a_assert_lookahead || op == id_a_assert_lookbehind) ? ONIBI_RA_ASSERT_POSITION :
      op == id_a_test_capture ? ONIBI_RA_TEST_CAPTURE : op == id_a_counter_init ? ONIBI_RA_COUNTER_SET :
      op == id_a_counter_increment ? ONIBI_RA_COUNTER_ADD :
      (op == id_a_test_counter_lt || op == id_a_test_counter_ge) ? ONIBI_RA_COUNTER_TEST :
      op == id_a_end ? ONIBI_RA_END : 0xff;
    VALUE slot = onibi_hash_value_id(semantic_action, id_key_slot);
    VALUE limit = onibi_hash_value_id(semantic_action, id_key_limit);
    VALUE value = onibi_hash_value_id(semantic_action, id_key_value);
    VALUE width = onibi_hash_value_id(semantic_action, id_key_width);
    if (op == id_a_assert_lookahead || op == id_a_assert_lookbehind) {
      VALUE predicates = onibi_hash_value_id(semantic_action, id_key_predicates);
      if (!RB_TYPE_P(predicates, T_ARRAY) || !RTEST(rb_obj_frozen_p(predicates)) ||
          NIL_P(width) || NUM2LONG(width) != RARRAY_LEN(predicates))
        rb_raise(rb_eArgError, "RSeq lookaround predicates are invalid");
      for (long p = 0; p < RARRAY_LEN(predicates); p++) {
        VALUE predicate = rb_ary_entry(predicates, p);
        VALUE kind_code = onibi_hash_value_id(predicate, id_key_predicate_code);
        if (!RB_TYPE_P(predicate, T_HASH) || !RTEST(rb_obj_frozen_p(predicate)) ||
            NIL_P(kind_code) || NUM2UINT(kind_code) > ONIBI_PRED_ANY)
          rb_raise(rb_eArgError, "RSeq lookaround predicate has an invalid kind");
        if (NUM2UINT(kind_code) == ONIBI_PRED_BYTE) {
          VALUE byte = onibi_hash_value_id(predicate, id_key_byte);
          if (NIL_P(byte) || NUM2LONG(byte) < 0 || NUM2LONG(byte) > 255)
            rb_raise(rb_eArgError, "RSeq lookaround byte predicate is invalid");
        } else if (NUM2UINT(kind_code) == ONIBI_PRED_BITMAP) {
          VALUE bitmap = onibi_hash_value_id(predicate, id_key_bitmap);
          if (!RB_TYPE_P(bitmap, T_STRING) || RSTRING_LEN(bitmap) != 32 || !RTEST(rb_obj_frozen_p(bitmap)))
            rb_raise(rb_eArgError, "RSeq lookaround bitmap predicate is invalid");
        }
      }
    }
    uint32_t expected_arg32 = !NIL_P(width) ? (uint32_t)NUM2ULONG(width) :
      (!NIL_P(limit) ? (uint32_t)NUM2ULONG(limit) :
       (!NIL_P(value) ? (uint32_t)NUM2ULONG(value) : 0));
    uint8_t expected_flags = onibi_rseq_action_flags(op);
    if (op == id_a_test_capture && !RTEST(onibi_hash_value_id(semantic_action, id_key_set)))
      expected_flags = ONIBI_RA_TEST_CAPTURE_UNSET;
    VALUE assert_kind = onibi_hash_value_id(semantic_action, id_key_assert_kind);
    uint16_t expected_arg16 = !NIL_P(slot) ? (uint16_t)NUM2ULONG(slot) :
      (NIL_P(assert_kind) ? onibi_rseq_assert_kind(op) : (uint16_t)NUM2ULONG(assert_kind));
    if (op == id_a_assert_lookahead || op == id_a_assert_lookbehind) {
      int positive = RTEST(onibi_hash_value_id(semantic_action, id_key_positive));
      expected_flags = op == id_a_assert_lookahead ? (positive ? 1 : 2) : (positive ? 5 : 6);
    }
    if (expected_op == 0xff || actions[i].op != expected_op || actions[i].flags != expected_flags || actions[i].arg16 != expected_arg16 ||
        ((!NIL_P(width) || !NIL_P(limit) || !NIL_P(value)) && actions[i].arg32 != expected_arg32))
      rb_raise(rb_eArgError, "RSeq action disagrees with semantic action");
    if (actions[i].op > ONIBI_RA_PROGRESS)
      rb_raise(rb_eArgError, "invalid Onibi RSeq action opcode");
  }
  const OnibiClassDesc *classes = (const OnibiClassDesc *)(RSTRING_PTR(blob) + header.classes_offset);
  uint64_t class_data_start = (uint64_t)header.classes_offset +
    (uint64_t)header.class_count * sizeof(OnibiClassDesc);
  for (uint32_t i = 0; i < header.class_count; i++) {
    if (classes[i].data_length != 32 || classes[i].kind != 0 || (classes[i].flags & ~1U) != 0)
      rb_raise(rb_eArgError, "invalid Onibi RSeq class descriptor");
    if (classes[i].data_offset < class_data_start ||
        (uint64_t)classes[i].data_offset + classes[i].data_length > header.literals_offset)
      rb_raise(rb_eArgError, "invalid Onibi RSeq class descriptor range");
  }
  const OnibiLiteralDesc *literals = (const OnibiLiteralDesc *)(RSTRING_PTR(blob) + header.descriptors_offset);
  for (uint32_t i = 0; i < NUM2UINT(onibi_hash_value_id(semantic, id_key_literal_count)); i++) {
    if (literals[i].data_length != 1 || (literals[i].flags & ~1U) != 0)
      rb_raise(rb_eArgError, "invalid Onibi RSeq literal descriptor");
    if (literals[i].data_offset < header.literals_offset ||
        (uint64_t)literals[i].data_offset + literals[i].data_length > header.descriptors_offset)
      rb_raise(rb_eArgError, "invalid Onibi RSeq literal descriptor range");
  }
  for (uint32_t i = 0; i < header.state_count; i++) {
    VALUE state = rb_ary_entry(semantic_states, i);
    ID op = SYM2ID(onibi_hash_value_id(state, id_key_op));
    VALUE payload = onibi_hash_value_id(state, id_key_payload);
    if (op == id_g_class) {
      uint32_t id = ((const OnibiRState *)(RSTRING_PTR(blob) + header.states_offset))[i].payload;
      VALUE bitmap = onibi_hash_value_id(payload, id_key_bitmap);
      if (id >= header.class_count || memcmp(RSTRING_PTR(bitmap),
          RSTRING_PTR(blob) + classes[id].data_offset, 32) != 0 ||
          ((classes[id].flags & 1U) != (RTEST(onibi_hash_value_id(payload, id_key_negated)) ? 1U : 0U)))
        rb_raise(rb_eArgError, "RSeq class descriptor disagrees with semantic payload");
    } else if (op == id_g_char) {
      uint32_t id = ((const OnibiRState *)(RSTRING_PTR(blob) + header.states_offset))[i].payload;
      VALUE byte = onibi_hash_value_id(payload, id_key_byte);
      if (id >= NUM2UINT(onibi_hash_value_id(semantic, id_key_literal_count)) ||
          (unsigned char)RSTRING_PTR(blob)[literals[id].data_offset] != (unsigned char)NUM2INT(byte) ||
          ((literals[id].flags & 1U) != (RTEST(onibi_hash_value_id(payload, id_key_ignorecase)) ? 1U : 0U)))
        rb_raise(rb_eArgError, "RSeq literal descriptor disagrees with semantic payload");
    }
  }
}

/* Build the regular execution view from the published RSeq blob.  Semantic
   payloads remain Ruby values, but state operations and edge destinations
   come from the physical layout.  This keeps the VM on the RSeq contract. */
static VALUE onibi_rseq_physical_graph(VALUE rseq) {
  VALUE cached = rb_hash_aref(rseq, ID2SYM(id_key_physical_graph));
  if (!NIL_P(cached)) return cached;
  VALUE blob = onibi_hash_value_id(rseq, id_key_blob);
  VALUE semantic_states = onibi_hash_value_id(rseq, id_key_states);
  VALUE semantic_edges = onibi_hash_value_id(rseq, id_key_edges);
  VALUE semantic_start_edges = onibi_hash_value_id(rseq, id_key_start_edges);
  VALUE semantic_actions = onibi_hash_value_id(rseq, id_key_actions);
  VALUE graph = rb_hash_new();
  VALUE states = rb_ary_new_capa(RARRAY_LEN(semantic_states));
  VALUE edges = rb_ary_new_capa(RARRAY_LEN(semantic_edges));
  VALUE start_edges = rb_ary_new_capa(RARRAY_LEN(semantic_start_edges));
  VALUE outgoing = rb_ary_new_capa(RARRAY_LEN(semantic_states));
  for (long i = 0; i < RARRAY_LEN(semantic_states); i++) rb_ary_push(outgoing, rb_ary_new());
  OnibiRSeqHeader header;
  memcpy(&header, RSTRING_PTR(blob), sizeof(header));
  const OnibiRState *physical_states = (const OnibiRState *)(RSTRING_PTR(blob) + header.states_offset);
  const OnibiREdge *physical_edges = (const OnibiREdge *)(RSTRING_PTR(blob) + header.edges_offset);
  for (long i = 0; i < RARRAY_LEN(semantic_states); i++) {
    VALUE state = rb_hash_dup(rb_ary_entry(semantic_states, i));
    ID op = physical_states[i].op == ONIBI_RS_CHAR ? id_g_char :
      physical_states[i].op == ONIBI_RS_CLASS ? id_g_class : physical_states[i].op == ONIBI_RS_ANY ? id_g_any :
      physical_states[i].op == ONIBI_RS_GRAPHEME ? id_g_grapheme : physical_states[i].op == ONIBI_RS_BACKREF ? id_g_backref :
      physical_states[i].op == ONIBI_RS_CALL ? id_g_call : physical_states[i].op == ONIBI_RS_ATOMIC ? id_g_atomic :
      physical_states[i].op == ONIBI_RS_ABSENT ? id_g_absent : id_g_accept;
    rb_hash_aset(state, ID2SYM(id_key_op), ID2SYM(op));
    rb_hash_aset(state, ID2SYM(id_key_opcode), UINT2NUM(physical_states[i].op));
    rb_ary_push(states, state);
  }
  for (long i = 0; i < RARRAY_LEN(semantic_edges); i++) {
    VALUE edge = rb_hash_dup(rb_ary_entry(semantic_edges, i));
    uint32_t destination = physical_edges[i].destination;
    if (destination == ONIBI_ACCEPT_STATE) destination = (uint32_t)(RARRAY_LEN(states) - 1);
    rb_hash_aset(edge, ID2SYM(id_key_to), UINT2NUM(destination));
    VALUE physical_program = rb_ary_new();
    uint32_t action_offset = physical_edges[i].action_offset;
    if (action_offset != 0) {
      uint32_t action_index = action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
      for (uint32_t a = action_index; a < (uint32_t)RARRAY_LEN(semantic_actions); a++) {
        VALUE action = rb_ary_entry(semantic_actions, a);
        rb_ary_push(physical_program, action);
        if ((OnibiGActionOp)NUM2UINT(onibi_hash_value_id(action, id_key_action_code)) == ONIBI_GA_END) break;
      }
    }
    rb_hash_aset(edge, ID2SYM(id_key_actions), physical_program);
    rb_ary_push(edges, edge);
    long from = NUM2LONG(onibi_hash_value_id(edge, id_key_from));
    if (from >= 0 && from < RARRAY_LEN(outgoing)) rb_ary_push(rb_ary_entry(outgoing, from), edge);
  }
  for (long i = 0; i < RARRAY_LEN(semantic_start_edges); i++) {
    VALUE edge = rb_hash_dup(rb_ary_entry(semantic_start_edges, i));
    const OnibiREdge *physical_edge = &physical_edges[header.start_edge_base + i];
    rb_hash_aset(edge, ID2SYM(id_key_to), UINT2NUM(physical_edge->destination));
    VALUE physical_program = rb_ary_new();
    if (physical_edge->action_offset != 0) {
      uint32_t action_index = physical_edge->action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
      for (uint32_t a = action_index; a < (uint32_t)RARRAY_LEN(semantic_actions); a++) {
        VALUE action = rb_ary_entry(semantic_actions, a);
        rb_ary_push(physical_program, action);
        if ((OnibiGActionOp)NUM2UINT(onibi_hash_value_id(action, id_key_action_code)) == ONIBI_GA_END) break;
      }
    }
    rb_hash_aset(edge, ID2SYM(id_key_actions), physical_program);
    rb_ary_push(start_edges, edge);
  }
  rb_hash_aset(graph, ID2SYM(id_key_states), states);
  rb_hash_aset(graph, ID2SYM(id_key_edges), edges);
  rb_hash_aset(graph, ID2SYM(id_key_start_edges), start_edges);
  rb_hash_aset(graph, ID2SYM(id_key_outgoing), outgoing);
  rb_hash_aset(graph, ID2SYM(id_key_subprograms), onibi_hash_value_id(rseq, id_key_subprograms));
  rb_hash_aset(graph, ID2SYM(id_key_counter_count), UINT2NUM(header.counter_count));
  return graph;
}

typedef struct { uint32_t state; long pos; } onibi_simple_frame_t;

static int onibi_rseq_view_init(VALUE blob, OnibiRSeqView *view) {
  if (!RB_TYPE_P(blob, T_STRING) || RSTRING_LEN(blob) < (long)sizeof(OnibiRSeqHeader)) return 0;
  view->blob = (const unsigned char *)RSTRING_PTR(blob);
  view->header = (const OnibiRSeqHeader *)view->blob;
  if (view->header->magic != ONIBI_RSEQ_MAGIC || view->header->version != ONIBI_RSEQ_VERSION ||
      view->header->blob_size > (uint32_t)RSTRING_LEN(blob)) return 0;
  view->states = (const OnibiRState *)(view->blob + view->header->states_offset);
  view->edges = (const OnibiREdge *)(view->blob + view->header->edges_offset);
  view->actions = (const OnibiRAction *)(view->blob + view->header->actions_offset);
  view->classes = (const OnibiClassDesc *)(view->blob + view->header->classes_offset);
  view->literals = (const OnibiLiteralDesc *)(view->blob + view->header->descriptors_offset);
  return 1;
}

/* Execute the action-free regular subset directly from the immutable RSeq
   blob.  This path does not materialize semantic states, edges, or visited
   Ruby objects for each candidate start. */
static int onibi_rseq_simple_match(VALUE rseq, VALUE str, long start, long *matched_end) {
  VALUE blob = onibi_hash_value_id(rseq, id_key_blob);
  OnibiRSeqView view;
  if (!onibi_rseq_view_init(blob, &view)) return -1;
  const OnibiRSeqHeader *header = view.header;
  if (header->counter_count != 0 || header->subprogram_count != 1) return -1;
  if (header->action_count != 0) {
    for (uint32_t i = 0; i < header->action_count; i++) {
      /* Capture boundaries and MATCH_RESET do not change match? acceptance.
       * Position assertions and all dynamic actions still require GIR. */
      if (view.actions[i].op != ONIBI_RA_END && view.actions[i].op != ONIBI_RA_CAPTURE &&
          view.actions[i].op != ONIBI_RA_MATCH_RESET) return -1;
    }
  }
  if (header->state_count == 0 || header->start_edge_count == 0) return -1;
  VALUE semantic_states = onibi_hash_value_id(rseq, id_key_states);
  VALUE semantic_header = onibi_hash_value_id(rseq, id_key_header);
  if (RTEST(onibi_hash_value_id(semantic_header, id_key_ignorecase)) ||
      RTEST(onibi_hash_value_id(semantic_header, id_key_multiline))) return -1;
  for (long i = 0; i < RARRAY_LEN(semantic_states); i++) {
    VALUE payload = onibi_hash_value_id(rb_ary_entry(semantic_states, i), id_key_payload);
    if (RB_TYPE_P(payload, T_HASH) &&
        (RTEST(onibi_hash_value_id(payload, id_key_ignorecase)) || RTEST(onibi_hash_value_id(payload, id_key_multiline)))) return -1;
  }
  const OnibiRState *states = view.states;
  const OnibiREdge *edges = view.edges;
  const unsigned char *bytes = (const unsigned char *)RSTRING_PTR(str);
  if (!rb_enc_str_asciionly_p(str) && rb_enc_get_index(str) != rb_ascii8bit_encindex()) return -1;
  for (uint32_t i = 0; i < header->state_count; i++) {
    /* Keep branching and repeat cycles on the established ordered walker
       until their physical edge priority has a dedicated direct lowering. */
    if (states[i].edge_count > 1) return -1;
    if (states[i].flags != 0) return -1;
    if (states[i].op == ONIBI_RS_CLASS || states[i].op == ONIBI_RS_ANY) return -1;
    if (states[i].op != 0 && states[i].op != ONIBI_RS_CHAR &&
        states[i].op != ONIBI_RS_CLASS && states[i].op != ONIBI_RS_ANY) return -1;
    if (states[i].op == ONIBI_RS_CHAR) {
      if (view.literals[states[i].payload].flags != 0) return -1;
    } else if (states[i].op == ONIBI_RS_CLASS) {
      if (view.classes[states[i].payload].flags != 0) return -1;
    }
  }
  size_t span = (size_t)RSTRING_LEN(str) + 1U;
  if ((size_t)header->state_count > SIZE_MAX / span) return -1;
  size_t visited_size = (size_t)header->state_count * span;
  if (visited_size > (size_t)1 << 20) return -1;
  if (visited_size > SIZE_MAX / sizeof(onibi_simple_frame_t)) return -1;
  unsigned char *visited = (unsigned char *)alloca(visited_size);
  memset(visited, 0, visited_size);
  size_t stack_capacity = visited_size;
  onibi_simple_frame_t *stack = (onibi_simple_frame_t *)alloca(stack_capacity * sizeof(*stack));
  size_t stack_size = 0;
  for (uint32_t i = 0; i < header->start_edge_count; i++) {
    const OnibiREdge *edge = &edges[header->start_edge_base + i];
    if (edge->destination == ONIBI_ACCEPT_STATE) { *matched_end = start; return 1; }
    if (edge->destination < header->state_count)
      stack[stack_size++] = (onibi_simple_frame_t){edge->destination, start};
  }
  while (stack_size > 0) {
    onibi_simple_frame_t frame = stack[--stack_size];
    if (frame.pos < 0 || frame.pos > RSTRING_LEN(str)) continue;
    size_t mark = (size_t)frame.state * span + (size_t)frame.pos;
    if (visited[mark]) continue;
    visited[mark] = 1;
    const OnibiRState *state = &states[frame.state];
    long next_pos = frame.pos;
    int hit = 1;
    if (state->op == 0) { *matched_end = frame.pos; return 1; }
    if (state->op == ONIBI_RS_CHAR || state->op == ONIBI_RS_CLASS || state->op == ONIBI_RS_ANY) {
      if (frame.pos >= RSTRING_LEN(str)) hit = 0;
      else if (state->op == ONIBI_RS_CHAR) {
        const OnibiLiteralDesc *literal = &view.literals[state->payload];
        hit = bytes[frame.pos] == view.blob[literal->data_offset];
      } else if (state->op == ONIBI_RS_CLASS) {
        const OnibiClassDesc *klass = &view.classes[state->payload];
        const unsigned char *bitmap = view.blob + klass->data_offset;
        hit = (bitmap[bytes[frame.pos] >> 3] & (1U << (bytes[frame.pos] & 7))) != 0;
      } else hit = bytes[frame.pos] != '\n';
      if (hit) next_pos++;
    } else hit = 0;
    if (!hit) continue;
    uint32_t begin = state->edge_base;
    for (uint32_t e = 0; e < state->edge_count; e++) {
      uint32_t destination = edges[begin + e].destination;
      if (destination == ONIBI_ACCEPT_STATE) { *matched_end = next_pos; return 1; }
      if (destination < header->state_count && stack_size < stack_capacity)
        stack[stack_size++] = (onibi_simple_frame_t){destination, next_pos};
    }
  }
  return 0;
}

static VALUE onibi_vm_regular_fast(VALUE rseq, VALUE str) {
  onibi_call_stack_reset();
  for (long start = 0; start <= RSTRING_LEN(str); start++) {
    if (!onibi_character_boundary(str, start)) continue;
    rb_thread_check_ints();
    onibi_check_deadline();
    long end = 0;
    int simple = onibi_rseq_simple_match(rseq, str, start, &end);
    if (simple > 0) return Qtrue;
    if (simple < 0) {
      VALUE graph = onibi_rseq_physical_graph(rseq);
      if (onibi_gir_match(graph, str, start, &end)) return Qtrue;
    }
  }
  return Qfalse;
}

static VALUE onibi_vm_tagged_ordered(VALUE rseq, VALUE str, int need_captures) {
  onibi_call_stack_reset();
  VALUE graph = onibi_rseq_physical_graph(rseq);
  for (long start = 0; start <= RSTRING_LEN(str); start++) {
    if (!onibi_character_boundary(str, start)) continue;
    rb_thread_check_ints();
    onibi_check_deadline();
    long end = 0;
    if (!need_captures) {
      int simple = onibi_rseq_simple_match(rseq, str, start, &end);
      if (simple > 0) return Qtrue;
      if (simple == 0) continue;
    }
    if (need_captures) {
      long reported_start = start;
      VALUE captures = rb_hash_new();
      if (onibi_gir_match_captures(graph, str, start, &end, &reported_start, &captures)) return Qtrue;
    } else if (onibi_gir_match(graph, str, start, &end)) {
      return Qtrue;
    }
  }
  return Qfalse;
}

static VALUE onibi_vm_dynamic(VALUE rseq, VALUE str) {
  onibi_call_stack_reset();
  /* Dynamic execution owns its dispatch loop.  The capture walker resolves
     backreferences and counters; this loop adds the dynamic deadline and
     interrupt boundary without routing through TAGGED_ORDERED. */
  VALUE graph = onibi_rseq_physical_graph(rseq);
  for (long start = 0; start <= RSTRING_LEN(str); start++) {
    if (!onibi_character_boundary(str, start)) continue;
    rb_thread_check_ints();
    onibi_check_deadline();
    long end = 0;
    long reported_start = start;
    VALUE captures = rb_hash_new();
    if (onibi_gir_match_captures(graph, str, start, &end, &reported_start, &captures)) return Qtrue;
  }
  return Qfalse;
}

static VALUE onibi_vm_match_p(VALUE self, VALUE str) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  StringValue(str);
  onibi_call_stack_reset();
  onibi_set_deadline(obj->timeout_seconds);
  if (!onibi_mri_compat_path_p(obj) && !(obj->options & 32) && (!onibi_regexp_fixed_p(obj) || onibi_encoded_literal_program_p(obj)) &&
      !NIL_P(obj->rseq) &&
      onibi_vm_input_eligible(obj, str) &&
      (!obj->has_ascii_property || rb_enc_str_asciionly_p(str) ||
       (obj->has_unicode_property &&
        (rb_enc_get_index(str) == rb_utf8_encindex() ||
         rb_enc_get_index(str) == rb_enc_get_index(obj->source)))) &&
      (rb_enc_str_asciionly_p(str) || onibi_valid_encoding(str)))
    {
      /* The immutable RSeq was validated and its physical execution view was
         built during initialize.  Do not rescan the program on each match. */
      VALUE result = obj->execution_kind == ONIBI_EXEC_REGULAR ?
        onibi_vm_regular_fast(obj->rseq, str) :
        (obj->execution_kind == ONIBI_EXEC_TAGGED ?
          onibi_vm_tagged_ordered(obj->rseq, str,
            obj->has_conditional || obj->has_backref || obj->has_subroutine) :
          onibi_vm_dynamic(obj->rseq, str));
      onibi_deadline_ns = 0;
      return result;
    }
  onibi_deadline_ns = 0;
  return rb_funcall(obj->regexp, id_match_p, 1, str);
}

static VALUE onibi_scan(VALUE self, VALUE str) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(str, id_scan, 1, obj->regexp);
}
static VALUE onibi_case_equal(VALUE self, VALUE other) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(obj->regexp, id_case_equal, 1, other);
}
static VALUE onibi_last_match(int argc, VALUE *argv, VALUE klass) {
  return rb_funcallv(rb_cRegexp, id_last_match, argc, argv);
}
static VALUE onibi_tilde(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(obj->regexp, id_tilde, 0);
}
static VALUE onibi_gsub_yield(VALUE value, VALUE data, int argc, const VALUE *argv, VALUE blockarg) {
  (void)data;
  (void)blockarg;
  return argc == 0 ? rb_yield(value) : rb_yield_values2(argc, argv);
}
static VALUE onibi_gsub(int argc, VALUE *argv, VALUE self) {
  VALUE str, replacement = Qnil;
  rb_scan_args(argc, argv, "11", &str, &replacement);
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  StringValue(str);
  if (rb_block_given_p()) {
    VALUE regexp = obj->regexp;
    return rb_block_call(str, id_gsub, 1, &regexp, onibi_gsub_yield, Qnil);
  }
  return rb_funcall(str, id_gsub, 2, obj->regexp, replacement);
}

void Init_onibi(void) {
  id_initialize = rb_intern("initialize"); id_match = rb_intern("match");
  id_new = rb_intern("new");
  id_instance_method = rb_intern("instance_method"); id_bind = rb_intern("bind"); id_call = rb_intern("call");
  id_bytebegin = rb_intern("bytebegin"); id_byteend = rb_intern("byteend"); id_length = rb_intern("length");
  id_case_equal = rb_intern("==="); id_last_match = rb_intern("last_match"); id_tilde = rb_intern("~");
  id_match_p = rb_intern("match?"); id_source = rb_intern("source");
  id_options = rb_intern("options"); id_inspect = rb_intern("inspect"); id_to_s = rb_intern("to_s");
  id_scan = rb_intern("scan"); id_gsub = rb_intern("gsub");
  id_encoding = rb_intern("encoding");
  id_index = rb_intern("index");
  id_g_accept = rb_intern("G_ACCEPT"); id_g_grapheme = rb_intern("G_GRAPHEME");
  id_g_atomic = rb_intern("G_ATOMIC"); id_g_absent = rb_intern("G_ABSENT");
  id_g_call = rb_intern("G_CALL"); id_g_char = rb_intern("G_CHAR");
  id_g_class = rb_intern("G_CLASS"); id_g_any = rb_intern("G_ANY");
  id_g_backref = rb_intern("G_BACKREF");
  id_capture_open = rb_intern("CAPTURE_OPEN"); id_capture_close = rb_intern("CAPTURE_CLOSE");
  id_match_reset = rb_intern("MATCH_RESET");
  id_a_test_capture = rb_intern("TEST_CAPTURE");
  id_a_test_counter_lt = rb_intern("TEST_COUNTER_LT"); id_a_test_counter_ge = rb_intern("TEST_COUNTER_GE");
  id_a_counter_init = rb_intern("COUNTER_INIT"); id_a_counter_increment = rb_intern("COUNTER_INCREMENT");
  id_a_assert_begin_buffer = rb_intern("ASSERT_BEGIN_BUFFER");
  id_a_assert_search_origin = rb_intern("ASSERT_SEARCH_ORIGIN"); id_a_assert_end_buffer = rb_intern("ASSERT_END_BUFFER");
  id_a_assert_begin_line = rb_intern("ASSERT_BEGIN_LINE"); id_a_assert_end_line = rb_intern("ASSERT_END_LINE");
  id_a_assert_word_boundary = rb_intern("ASSERT_WORD_BOUNDARY"); id_a_assert_nonword_boundary = rb_intern("ASSERT_NONWORD_BOUNDARY");
  id_a_assert_semi_end_buffer = rb_intern("ASSERT_SEMI_END_BUFFER");
  id_a_assert_lookahead = rb_intern("ASSERT_LOOKAHEAD"); id_a_assert_lookbehind = rb_intern("ASSERT_LOOKBEHIND");
  id_pred_byte = rb_intern("byte"); id_pred_bitmap = rb_intern("bitmap"); id_pred_any = rb_intern("any");
  id_a_end = rb_intern("END"); id_key_physical_graph = rb_intern("physical_graph");
  id_opt_ignorecase = rb_intern("ignorecase"); id_opt_multiline = rb_intern("multiline");
  id_opt_extended = rb_intern("extended"); id_opt_fixedencoding = rb_intern("fixedencoding");
  id_opt_noencoding = rb_intern("noencoding");
  id_prop_ascii = rb_intern("ASCII"); id_prop_ascii_hex = rb_intern("ASCII_Hex_Digit");
  id_key_op = rb_intern("op"); id_key_payload = rb_intern("payload");
  id_key_actions = rb_intern("actions"); id_key_to = rb_intern("to");
  id_key_multiline = rb_intern("multiline"); id_key_ignorecase = rb_intern("ignorecase");
  id_key_kind = rb_intern("kind"); id_key_kind_code = rb_intern("kind_code"); id_key_opcode = rb_intern("opcode");
  id_key_action_code = rb_intern("action_code"); id_key_assert_kind = rb_intern("assert_kind");
  id_key_predicate_code = rb_intern("predicate_code");
  id_key_byte = rb_intern("byte"); id_key_capture = rb_intern("capture");
  id_key_start = rb_intern("start"); id_key_end = rb_intern("end"); id_key_captures = rb_intern("captures");
  id_key_subprogram = rb_intern("subprogram"); id_key_entry = rb_intern("entry");
  id_key_entry_actions = rb_intern("entry_actions"); id_key_slot = rb_intern("slot");
  id_key_set = rb_intern("set"); id_key_value = rb_intern("value");
  id_key_type_code = rb_intern("type_code"); id_key_name = rb_intern("name"); id_key_name_id = rb_intern("name_id");
  id_key_ctype = rb_intern("ctype"); id_key_ranges = rb_intern("ranges");
  id_key_children = rb_intern("children"); id_key_operands = rb_intern("operands");
  id_key_body = rb_intern("body"); id_key_options = rb_intern("options");
  id_key_negative_options = rb_intern("negative_options"); id_key_capturing = rb_intern("capturing");
  id_key_condition = rb_intern("condition"); id_key_branches = rb_intern("branches");
  id_key_yes = rb_intern("yes"); id_key_no = rb_intern("no"); id_key_atom = rb_intern("atom");
  id_key_min = rb_intern("min"); id_key_max = rb_intern("max"); id_key_width = rb_intern("width");
  id_key_greedy = rb_intern("greedy"); id_key_possessive = rb_intern("possessive");
  id_key_negated = rb_intern("negated"); id_key_bitmap = rb_intern("bitmap");
  id_key_preserve_if_set = rb_intern("preserve_if_set");
  id_key_limit = rb_intern("limit"); id_key_positive = rb_intern("positive");
  id_key_predicates = rb_intern("predicates");
  id_key_states = rb_intern("states"); id_key_outgoing = rb_intern("outgoing");
  id_key_start_edges = rb_intern("start_edges"); id_key_subprograms = rb_intern("subprograms");
  id_key_bytes = rb_intern("bytes"); id_key_blob = rb_intern("blob"); id_key_header = rb_intern("header");
  id_key_edges = rb_intern("edges"); id_key_from = rb_intern("from");
  id_key_accept = rb_intern("accept"); id_key_action_offset = rb_intern("action_offset");
  id_key_flags = rb_intern("flags");
  id_key_id = rb_intern("id");
  id_key_capture_count = rb_intern("capture_count");
  id_key_counter_count = rb_intern("counter_count");
  id_key_state_count = rb_intern("state_count"); id_key_features = rb_intern("features");
  id_key_edge_count = rb_intern("edge_count"); id_key_action_count = rb_intern("action_count");
  id_key_class_count = rb_intern("class_count"); id_key_subprogram_count = rb_intern("subprogram_count");
  id_key_start_edge_base = rb_intern("start_edge_base"); id_key_start_edge_count = rb_intern("start_edge_count");
  id_key_blob_size = rb_intern("blob_size"); id_key_literal_count = rb_intern("literal_count");
  id_key_version = rb_intern("version"); id_key_semantic_capture_count = rb_intern("semantic_capture_count");
  id_key_states_offset = rb_intern("states_offset"); id_key_edges_offset = rb_intern("edges_offset");
  id_key_actions_offset = rb_intern("actions_offset"); id_key_classes_offset = rb_intern("classes_offset");
  id_key_literals_offset = rb_intern("literals_offset"); id_key_descriptors_offset = rb_intern("descriptors_offset");
  id_key_subprograms_offset = rb_intern("subprograms_offset");
  id_key_negative_name = rb_intern("negative_name"); id_key_negative = rb_intern("negative");
  id_anchor = rb_intern("anchor"); id_anchor_start = rb_intern("anchor_start");
  id_anchor_end = rb_intern("anchor_end");
  id_insert = rb_intern("insert");
  id_timeout = rb_intern("timeout");
  id_encode = rb_intern("encode"); id_message = rb_intern("message");
  id_names = rb_intern("names"); id_named_captures = rb_intern("named_captures");
  id_escape = rb_intern("escape"); id_union = rb_intern("union"); id_to_regexp = rb_intern("to_regexp");
  id_kind_literal = rb_intern("literal");
  id_recursive_marker = rb_intern("__onibi_recursive_call__");
  mOnibi = rb_define_module("Onibi");
  eRegexpError = rb_define_class_under(mOnibi, "RegexpError", rb_eRegexpError);
  /* Lexer, parser, compiler, RSeq, and VM are implementation objects.
   * Keep their methods available to the C pipeline, but do not publish
  * Ruby constants for them.  Only Onibi::Regexp is public. */
  cRegexp = rb_define_class_under(mOnibi, "Regexp", rb_cObject);
  eTimeoutError = rb_define_class_under(cRegexp, "TimeoutError", eRegexpError);
  rb_define_singleton_method(cRegexp, "timeout=", onibi_timeout_set, 1);
  rb_define_singleton_method(cRegexp, "timeout", onibi_timeout_default, 0);
  rb_define_singleton_method(cRegexp, "escape", onibi_regexp_escape, 1);
  rb_define_singleton_method(cRegexp, "quote", onibi_regexp_escape, 1);
  rb_define_singleton_method(cRegexp, "union", onibi_regexp_union, -1);
  rb_define_singleton_method(cRegexp, "try_convert", onibi_regexp_try_convert, 1);
  rb_define_singleton_method(cRegexp, "linear_time?", onibi_regexp_linear_time_p, 1);
  rb_define_singleton_method(cRegexp, "last_match", onibi_last_match, -1);
  rb_define_alloc_func(cRegexp, onibi_alloc);
  rb_define_method(cRegexp, "initialize", onibi_initialize, -1);
  rb_define_method(cRegexp, "match", onibi_match, -1);
  rb_define_method(cRegexp, "===", onibi_case_equal, 1);
  rb_define_method(cRegexp, "~", onibi_tilde, 0);
  rb_define_method(cRegexp, "match?", onibi_match_p, -1);
  rb_define_method(cRegexp, "source", onibi_source, 0);
  rb_define_method(cRegexp, "names", onibi_names, 0);
  rb_define_method(cRegexp, "named_captures", onibi_named_captures, 0);
  rb_define_method(cRegexp, "casefold?", onibi_casefold_p, 0);
  rb_define_method(cRegexp, "==", onibi_equal, 1);
  rb_define_method(cRegexp, "eql?", onibi_equal, 1);
  rb_define_method(cRegexp, "hash", onibi_hash, 0);
  rb_define_method(cRegexp, "options", onibi_options, 0);
  rb_define_method(cRegexp, "fixed_encoding?", onibi_fixed_encoding_p, 0);
  rb_define_method(cRegexp, "no_encoding?", onibi_no_encoding_p, 0);
  rb_define_method(cRegexp, "inspect", onibi_inspect, 0);
  rb_define_method(cRegexp, "to_s", onibi_to_s, 0);
  rb_define_method(cRegexp, "encoding", onibi_encoding, 0);
  rb_define_method(cRegexp, "timeout", onibi_timeout, 0);
  rb_define_method(cRegexp, "scan", onibi_scan, 1);
  rb_define_method(cRegexp, "gsub", onibi_gsub, -1);
  rb_define_const(cRegexp, "IGNORECASE", INT2NUM(1));
  rb_define_const(cRegexp, "EXTENDED", INT2NUM(2));
  rb_define_const(cRegexp, "MULTILINE", INT2NUM(4));
  rb_define_const(cRegexp, "FIXEDENCODING", INT2NUM(16));
  rb_define_const(cRegexp, "NOENCODING", INT2NUM(32));
}
