#include "ruby.h"
#include "ruby/encoding.h"
#include "ruby/thread.h"
#include "ruby/onigmo.h"
#include "onibi_ir.h"
#include <string.h>
#include <stdio.h>
#include <ctype.h>
#include <time.h>
#include <math.h>
#include <float.h>
#include <errno.h>

#define ONIBI_RSEQ_REPEAT_UNROLL_LIMIT 4096L

static VALUE mOnibi, cRegexp, cLexer, eRegexpError, eTimeoutError;
static double onibi_default_timeout = 0.0;
static _Thread_local uint64_t onibi_deadline_ns = 0;
static ID id_initialize, id_match, id_match_p, id_source, id_options, id_inspect, id_to_s, id_new, id_trusted_rseq;
static VALUE onibi_rseq_physical_graph(VALUE rseq);
static ID id_scan, id_gsub, id_encoding, id_index;
static VALUE onibi_vm_match_p(VALUE self, VALUE str);
static VALUE onibi_vm_match_result(VALUE self, VALUE str);
static VALUE onibi_pipeline_build(VALUE self);
static void onibi_rseq_validate(VALUE rseq);
static VALUE onibi_hash_value(VALUE hash, const char *name);
static int onibi_ascii_property_name_p(VALUE name);
static int onibi_valid_encoding(VALUE str);
static int onibi_unicode_ctype(VALUE name);

static VALUE onibi_rseq_trusted_marker(VALUE self) {
  (void)self;
  return Qtrue;
}

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

typedef struct { VALUE regexp; VALUE source; VALUE tokens; VALUE execution_class; VALUE execution_kind; VALUE parsed; VALUE compiled; VALUE rseq; VALUE pipeline; int options; long program_size; double timeout_seconds; int has_class_intersection; int has_nested_class; int has_large_repeat; int has_absence; int has_conditional; int has_atomic; int has_backref; int has_ascii_property; int has_unicode_property; int has_unicode_property_in_class; int has_nullable_capture; int has_grapheme; int has_property_escape; int has_unicode_escape; int has_non_ascii_literal; int has_non_ascii_class; int has_safe_multibyte_class; int has_wildcard; int has_anchor; int has_meta_escape; int has_subroutine; int has_dynamic; int has_tagged; } onibi_regexp_t;
typedef struct { VALUE source; VALUE tokens; } onibi_lexer_t;

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

static void onibi_free(void *ptr) { xfree(ptr); }
static void onibi_mark(void *ptr) {
  onibi_regexp_t *obj = (onibi_regexp_t *)ptr;
  if (!obj) return;
  rb_gc_mark(obj->regexp);
  rb_gc_mark(obj->source);
  rb_gc_mark(obj->tokens);
  rb_gc_mark(obj->execution_class);
  rb_gc_mark(obj->execution_kind);
  rb_gc_mark(obj->parsed);
  rb_gc_mark(obj->compiled);
  rb_gc_mark(obj->rseq);
  rb_gc_mark(obj->pipeline);
}
static size_t onibi_memsize(const void *ptr) { return ptr ? sizeof(onibi_regexp_t) : 0; }
static const rb_data_type_t onibi_type = {
  "Onibi::Regexp", { onibi_mark, onibi_free, onibi_memsize, NULL, { NULL } }, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY
};

static void onibi_lexer_free(void *ptr) { xfree(ptr); }
static void onibi_lexer_mark(void *ptr) {
  onibi_lexer_t *obj = (onibi_lexer_t *)ptr;
  if (!obj) return;
  rb_gc_mark(obj->source);
  rb_gc_mark(obj->tokens);
}
static size_t onibi_lexer_memsize(const void *ptr) { return ptr ? sizeof(onibi_lexer_t) : 0; }
static const rb_data_type_t onibi_lexer_type = {
  "Onibi::Lexer", { onibi_lexer_mark, onibi_lexer_free, onibi_lexer_memsize, NULL, { NULL } }, 0, 0,
  RUBY_TYPED_FREE_IMMEDIATELY
};

static VALUE onibi_lexer_alloc(VALUE klass) {
  onibi_lexer_t *obj;
  return TypedData_Make_Struct(klass, onibi_lexer_t, &onibi_lexer_type, obj);
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
    const char *kind = "literal";
    unsigned char byte = (unsigned char)RSTRING_PTR(src)[i];
    if (extended && !in_class && byte == '#') {
      while (i + 1 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] != '\n') i++;
      continue;
    }
    if (extended && !in_class && (byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n')) continue;
    VALUE backref_name = Qnil;
    VALUE group_name = Qnil;
    VALUE posix_name = Qnil;
    VALUE literal_bytes = Qnil;
    VALUE option_negative_name = Qnil;
    VALUE escape_name = Qnil;
    int option_negative = 0;
    int option_scope_x = -1;
    if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' &&
        (RSTRING_PTR(src)[i + 2] == '=' || RSTRING_PTR(src)[i + 2] == '!')) {
      kind = "lookahead_start";
      byte = (unsigned char)RSTRING_PTR(src)[i + 2];
      i += 2;
    } else if (!in_class && byte == '(' && i + 3 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' &&
               RSTRING_PTR(src)[i + 2] == '<' && (RSTRING_PTR(src)[i + 3] == '=' || RSTRING_PTR(src)[i + 3] == '!')) {
      kind = "lookbehind_start";
      byte = (unsigned char)RSTRING_PTR(src)[i + 3];
      i += 3;
    } else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) &&
               RSTRING_PTR(src)[i + 1] == '?' &&
               (RSTRING_PTR(src)[i + 2] == '-' ||
                strchr("imx", RSTRING_PTR(src)[i + 2]) != NULL)) {
      long option_end = i + 2;
      int valid = 1;
      if (RSTRING_PTR(src)[option_end] == '-') { option_negative = 1; option_end++; }
      long option_count = option_end;
      while (option_end < RSTRING_LEN(src) &&
             strchr("imx", RSTRING_PTR(src)[option_end]) != NULL) option_end++;
      long positive_end = option_end;
      long negative_start = -1;
      if (!option_negative && option_end < RSTRING_LEN(src) && RSTRING_PTR(src)[option_end] == '-') {
        negative_start = ++option_end;
        while (option_end < RSTRING_LEN(src) &&
               strchr("imx", RSTRING_PTR(src)[option_end]) != NULL) option_end++;
        if (option_end == negative_start) valid = 0;
      }
      int global_modifier = 0;
      if (option_end == option_count || option_end >= RSTRING_LEN(src)) valid = 0;
      else if (RSTRING_PTR(src)[option_end] == ')') global_modifier = 1;
      else if (RSTRING_PTR(src)[option_end] != ':') valid = 0;
      if (valid) {
        kind = global_modifier ? "option_global" : "option_scope_start";
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
      kind = "noncapture_start";
      byte = ':';
      i += 2;
    } else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' &&
               RSTRING_PTR(src)[i + 2] == '>') {
      kind = "atomic_start";
      byte = '>';
      i += 2;
    } else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' &&
               RSTRING_PTR(src)[i + 2] == '~') {
      kind = "absence_start";
      byte = '~';
      i += 2;
    } else if (!in_class && byte == '(' && i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' &&
               RSTRING_PTR(src)[i + 2] == '(') {
      long close = i + 3;
      while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != ')') close++;
      if (close < RSTRING_LEN(src)) {
        kind = "conditional_start";
        byte = '(';
        group_name = rb_str_substr(src, i + 3, close - (i + 3));
        i = close;
      }
    } else if (!in_class && byte == '(' && i + 3 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == '?' && RSTRING_PTR(src)[i + 2] == '<') {
      long close = i + 3;
      while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != '>') close++;
      if (close < RSTRING_LEN(src)) {
        kind = "group_start";
        group_name = rb_str_substr(src, i + 3, close - (i + 3));
        i = close;
      }
    }
    if (in_class && byte == '[' && i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == ':') {
      long close = i + 2;
      while (close + 1 < RSTRING_LEN(src) && !(RSTRING_PTR(src)[close] == ':' && RSTRING_PTR(src)[close + 1] == ']')) close++;
      if (close + 1 < RSTRING_LEN(src)) {
        kind = "posix_class";
        posix_name = rb_str_substr(src, i + 2, close - (i + 2));
        i = close + 1;
      }
    }
    if (!in_class && byte == '\\' && i + 3 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == 'k' && RSTRING_PTR(src)[i + 2] == '<') {
      long close = i + 3;
      while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != '>') close++;
      if (close < RSTRING_LEN(src)) {
        kind = "backref";
        byte = 'k';
        backref_name = rb_str_substr(src, i + 3, close - (i + 3));
        i = close;
        }
    }
    if (strcmp(kind, "literal") == 0 && !in_class && byte == '\\' &&
        i + 2 < RSTRING_LEN(src) && RSTRING_PTR(src)[i + 1] == 'g' && RSTRING_PTR(src)[i + 2] == '<') {
      long close = i + 3;
      while (close < RSTRING_LEN(src) && RSTRING_PTR(src)[close] != '>') close++;
      if (close < RSTRING_LEN(src)) {
        kind = "subroutine";
        byte = 'g';
        backref_name = rb_str_substr(src, i + 3, close - (i + 3));
        i = close;
      }
    }
    if (strcmp(kind, "literal") == 0 && byte == '\\' && i + 2 < RSTRING_LEN(src) &&
        (RSTRING_PTR(src)[i + 1] == 'M' || RSTRING_PTR(src)[i + 1] == 'C') &&
        RSTRING_PTR(src)[i + 2] == '-') {
      kind = "meta_escape";
      byte = (unsigned char)RSTRING_PTR(src)[i + 1];
      i += 2;
    }
    if (strcmp(kind, "literal") == 0 && byte == '\\' && i + 1 < RSTRING_LEN(src)) {
      unsigned char escaped = (unsigned char)RSTRING_PTR(src)[i + 1];
      int hex_literal = 0;
      int octal_literal = 0;
      byte = escaped;
      if (escaped == 'x' && i + 3 < RSTRING_LEN(src)) {
        int hi = onibi_hex_digit((unsigned char)RSTRING_PTR(src)[i + 2]);
        int lo = onibi_hex_digit((unsigned char)RSTRING_PTR(src)[i + 3]);
        if (hi >= 0 && lo >= 0) { byte = (unsigned char)((hi << 4) | lo); i += 3; hex_literal = 1; }
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
    if (hex_literal || octal_literal) kind = "literal";
    else if (!in_class && strchr("AzZGbB", escaped) != NULL) kind = "anchor";
      else if (!in_class && escaped == 'K') kind = "match_reset";
      else if (!in_class && escaped >= '1' && escaped <= '9') kind = "backref";
      else if (strchr("dDsSwWhHRXpPu", escaped) != NULL) kind = "escape";
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
      kind = "class_start";
      in_class = 1;
      class_depth = 1;
      class_body_start = i + 1;
    } else if (strcmp(kind, "literal") == 0 && byte == '[' && in_class) {
      kind = "class_start";
      if (class_depth >= (long)(sizeof(class_body_starts) / sizeof(class_body_starts[0])))
        rb_raise(eRegexpError, "regexp character class nesting is too deep");
      class_body_starts[class_depth - 1] = class_body_start;
      class_depth++;
      class_body_start = i + 1;
    } else if (byte == ']' && in_class && class_depth > 1) {
      kind = "class_end";
      class_depth--;
      class_body_start = class_body_starts[class_depth - 1];
    } else if (byte == ']' && in_class) {
      kind = "class_end";
      in_class = 0;
      class_depth = 0;
    } else if (in_class) {
      if (byte == '-' && i > class_body_start) kind = "class_range";
      else if (byte == '^' && i == class_body_start) kind = "class_negate";
    } else if (byte == '|') kind = "alternation";
    else if (strcmp(kind, "literal") == 0 && byte == '(') kind = "group_start";
    else if (strcmp(kind, "literal") == 0 && byte == ')') kind = "group_end";
    else if (strcmp(kind, "literal") == 0 && strchr("*+?{}", byte) != NULL) kind = "quantifier";
    else if (strcmp(kind, "literal") == 0 && byte == '.') kind = "wildcard";
    else if (strcmp(kind, "literal") == 0 && (byte == '^' || byte == '$')) kind = "anchor";
    if (strcmp(kind, "literal") == 0 && byte >= 0x80) {
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
    if (strcmp(kind, "group_start") == 0 || strcmp(kind, "noncapture_start") == 0 ||
        strcmp(kind, "atomic_start") == 0 || strcmp(kind, "absence_start") == 0 || strcmp(kind, "conditional_start") == 0 || strcmp(kind, "lookahead_start") == 0 ||
        strcmp(kind, "lookbehind_start") == 0 || strcmp(kind, "option_scope_start") == 0) {
      if (extended_depth >= (long)(sizeof(extended_stack) / sizeof(extended_stack[0])))
        rb_raise(eRegexpError, "regexp nesting is too deep");
      extended_stack[extended_depth++] = -1;
      if (strcmp(kind, "option_scope_start") == 0) {
        extended_stack[extended_depth - 1] = extended;
        if (option_scope_x >= 0) extended = option_negative ? 0 : 1;
      }
    }
    if (strcmp(kind, "option_global") == 0 && option_scope_x >= 0)
      extended = option_scope_x;
    rb_hash_aset(token, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern(kind)));
    rb_hash_aset(token, ID2SYM(rb_intern("byte")), INT2NUM(byte));
    rb_hash_aset(token, ID2SYM(rb_intern("start")), LONG2NUM(start));
    rb_hash_aset(token, ID2SYM(rb_intern("end")), LONG2NUM(i + 1));
    if (!NIL_P(backref_name)) { rb_obj_freeze(backref_name); rb_hash_aset(token, ID2SYM(rb_intern("name")), backref_name); }
    if (!NIL_P(group_name)) { rb_obj_freeze(group_name); rb_hash_aset(token, ID2SYM(rb_intern("name")), group_name); }
    if (!NIL_P(option_negative_name)) { rb_obj_freeze(option_negative_name); rb_hash_aset(token, ID2SYM(rb_intern("negative_name")), option_negative_name); }
    if (!NIL_P(posix_name)) { rb_obj_freeze(posix_name); rb_hash_aset(token, ID2SYM(rb_intern("name")), posix_name); }
    if (!NIL_P(escape_name)) { rb_obj_freeze(escape_name); rb_hash_aset(token, ID2SYM(rb_intern("name")), escape_name); }
    if (!NIL_P(literal_bytes)) { rb_obj_freeze(literal_bytes); rb_hash_aset(token, ID2SYM(rb_intern("bytes")), literal_bytes); }
    if (strcmp(kind, "option_scope_start") == 0 || strcmp(kind, "option_global") == 0)
      rb_hash_aset(token, ID2SYM(rb_intern("negative")), option_negative ? Qtrue : Qfalse);
    rb_obj_freeze(token);
    rb_ary_push(tokens, token);
    if (strcmp(kind, "group_end") == 0 && extended_depth > 0) {
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
      VALUE name = SYMBOL_P(item) ? rb_sym2str(item) : StringValue(item);
      if (rb_str_cmp(name, rb_str_new_cstr("extended")) == 0) return 1;
    }
    return 0;
  }
  return (NUM2INT(options) & 2) != 0;
}

static VALUE onibi_lexer_initialize(int argc, VALUE *argv, VALUE self) {
  onibi_lexer_t *obj;
  TypedData_Get_Struct(self, onibi_lexer_t, &onibi_lexer_type, obj);
  VALUE source, options = Qnil;
  rb_scan_args(argc, argv, "11", &source, &options);
  source = StringValue(source);
  obj->source = rb_str_dup(source);
  rb_obj_freeze(obj->source);
  obj->tokens = onibi_tokenize_internal(obj->source, onibi_extended_option_p(options));
  rb_obj_freeze(self);
  return self;
}

static VALUE onibi_lexer_tokens(VALUE self) {
  onibi_lexer_t *obj;
  TypedData_Get_Struct(self, onibi_lexer_t, &onibi_lexer_type, obj);
  return obj->tokens;
}

static ID onibi_token_kind(VALUE token) {
  return SYM2ID(rb_hash_aref(token, ID2SYM(rb_intern("kind"))));
}

static long onibi_token_byte(VALUE token) {
  return NUM2LONG(rb_hash_aref(token, ID2SYM(rb_intern("byte"))));
}

static VALUE onibi_ast_node(const char *type, VALUE token) {
  VALUE node = rb_hash_new();
  rb_hash_aset(node, ID2SYM(rb_intern("type")), ID2SYM(rb_intern(type)));
  if (!NIL_P(token)) {
    rb_hash_aset(node, ID2SYM(rb_intern("start")),
                 rb_hash_aref(token, ID2SYM(rb_intern("start"))));
    rb_hash_aset(node, ID2SYM(rb_intern("end")),
                 rb_hash_aref(token, ID2SYM(rb_intern("end"))));
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

static long onibi_find_close(VALUE tokens, long begin, long end, ID open, ID close) {
  long depth = 0;
  for (long i = begin; i < end; i++) {
    ID kind = onibi_token_kind(rb_ary_entry(tokens, i));
    if (kind == open || kind == rb_intern("group_start") || kind == rb_intern("noncapture_start") ||
        kind == rb_intern("atomic_start") || kind == rb_intern("lookahead_start") ||
        kind == rb_intern("lookbehind_start") || kind == rb_intern("option_scope_start") ||
        kind == rb_intern("absence_start") || kind == rb_intern("conditional_start")) depth++;
    else if (kind == close && --depth == 0) return i;
  }
  return -1;
}

static VALUE onibi_parse_class(VALUE tokens, long begin, long close) {
  VALUE node = onibi_ast_node("character_class", rb_ary_entry(tokens, begin));
  VALUE children = rb_ary_new(), ranges = rb_ary_new();
  int negated = 0;
  long intersection = -1;
  long depth = 0;
  for (long i = begin + 1; i + 1 < close; i++) {
    ID kind = onibi_token_kind(rb_ary_entry(tokens, i));
    if (kind == rb_intern("class_start")) { depth++; continue; }
    if (kind == rb_intern("class_end")) { if (depth > 0) depth--; continue; }
    if (depth == 0 && kind == rb_intern("literal") && onibi_token_byte(rb_ary_entry(tokens, i)) == '&' &&
        onibi_token_kind(rb_ary_entry(tokens, i + 1)) == rb_intern("literal") &&
        onibi_token_byte(rb_ary_entry(tokens, i + 1)) == '&') { intersection = i; break; }
  }
  if (intersection >= 0) {
    VALUE result = onibi_ast_node("class_intersection", rb_ary_entry(tokens, begin));
    VALUE operands = rb_ary_new();
    for (int side = 0; side < 2; side++) {
      long part_begin = side == 0 ? begin + 1 : intersection + 2;
      long part_end = side == 0 ? intersection : close;
      VALUE slice = rb_ary_new();
      VALUE open = rb_hash_dup(rb_ary_entry(tokens, part_begin));
      VALUE finish = rb_hash_dup(rb_ary_entry(tokens, part_end - 1));
      rb_hash_aset(open, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern("class_start")));
      rb_hash_aset(open, ID2SYM(rb_intern("byte")), INT2NUM('['));
      rb_hash_aset(finish, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern("class_end")));
      rb_hash_aset(finish, ID2SYM(rb_intern("byte")), INT2NUM(']'));
      rb_ary_push(slice, open);
      for (long i = part_begin; i < part_end; i++) rb_ary_push(slice, rb_ary_entry(tokens, i));
      rb_ary_push(slice, finish);
      rb_ary_push(operands, onibi_parse_class(slice, 0, RARRAY_LEN(slice) - 1));
    }
    rb_hash_aset(result, ID2SYM(rb_intern("operands")), operands);
    rb_obj_freeze(operands);
    return result;
  }
  for (long i = begin + 1; i < close; i++) {
    VALUE token = rb_ary_entry(tokens, i);
    ID kind = onibi_token_kind(token);
    if (kind == rb_intern("class_start")) {
      long nested_close = onibi_find_close(tokens, i, close, rb_intern("class_start"), rb_intern("class_end"));
      if (nested_close < 0) rb_raise(eRegexpError, "unterminated nested character class");
      VALUE nested = onibi_parse_class(tokens, i, nested_close);
      rb_hash_aset(nested, ID2SYM(rb_intern("end")),
                   rb_hash_aref(rb_ary_entry(tokens, nested_close), ID2SYM(rb_intern("end"))));
      rb_obj_freeze(nested);
      rb_ary_push(children, nested);
      i = nested_close;
      continue;
    }
    if (kind == rb_intern("class_negate")) { negated = 1; continue; }
    if (kind == rb_intern("posix_class")) {
      VALUE name = rb_hash_aref(token, ID2SYM(rb_intern("name")));
      const char *posix = StringValueCStr(name);
      if (strcmp(posix, "alpha") != 0 && strcmp(posix, "digit") != 0 && strcmp(posix, "alnum") != 0 &&
          strcmp(posix, "space") != 0 && strcmp(posix, "blank") != 0 && strcmp(posix, "lower") != 0 &&
          strcmp(posix, "upper") != 0 && strcmp(posix, "word") != 0 && strcmp(posix, "xdigit") != 0)
        rb_raise(eRegexpError, "unknown POSIX character class");
      rb_ary_push(children, token);
      continue;
    }
    if (kind == rb_intern("class_range") && i > begin + 1 && i + 1 < close) {
      ID first_kind = onibi_token_kind(rb_ary_entry(tokens, i - 1));
      ID last_kind = onibi_token_kind(rb_ary_entry(tokens, i + 1));
      if (first_kind != rb_intern("literal") || last_kind != rb_intern("literal"))
        rb_raise(eRegexpError, "invalid range endpoint in character class");
      VALUE first_token = rb_ary_entry(tokens, i - 1);
      VALUE last_token = rb_ary_entry(tokens, i + 1);
      VALUE first_bytes = onibi_hash_value(first_token, "bytes");
      VALUE last_bytes = onibi_hash_value(last_token, "bytes");
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
  rb_hash_aset(node, ID2SYM(rb_intern("children")), children);
  rb_hash_aset(node, ID2SYM(rb_intern("ranges")), ranges);
  rb_hash_aset(node, ID2SYM(rb_intern("negated")), negated ? Qtrue : Qfalse);
  rb_obj_freeze(children); rb_obj_freeze(ranges);
  return node;
}

static VALUE onibi_parse_atom(VALUE tokens, long *index, long end) {
  VALUE token = rb_ary_entry(tokens, *index);
  ID kind = onibi_token_kind(token);
  if (kind == rb_intern("lookahead_start") || kind == rb_intern("lookbehind_start")) {
    long close = onibi_find_close(tokens, *index, end, kind, rb_intern("group_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated lookaround");
    int behind = kind == rb_intern("lookbehind_start");
    VALUE node = onibi_ast_node(behind ? "lookbehind" : "lookahead", token);
    rb_hash_aset(node, ID2SYM(rb_intern("body")), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(rb_intern("positive")), onibi_token_byte(token) == '=' ? Qtrue : Qfalse);
    rb_hash_aset(node, ID2SYM(rb_intern("end")), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(rb_intern("end"))));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind == rb_intern("option_scope_start")) {
    long close = onibi_find_close(tokens, *index, end, rb_intern("option_scope_start"), rb_intern("group_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated option scope");
    VALUE node = onibi_ast_node("option_scope", token);
    rb_hash_aset(node, ID2SYM(rb_intern("body")), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(rb_intern("options")), rb_hash_aref(token, ID2SYM(rb_intern("name"))));
    VALUE negative_options = rb_hash_aref(token, ID2SYM(rb_intern("negative_name")));
    if (!NIL_P(negative_options))
      rb_hash_aset(node, ID2SYM(rb_intern("negative_options")), negative_options);
    rb_hash_aset(node, ID2SYM(rb_intern("negative")), rb_hash_aref(token, ID2SYM(rb_intern("negative"))));
    rb_hash_aset(node, ID2SYM(rb_intern("end")), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(rb_intern("end"))));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind == rb_intern("option_global")) {
    VALUE node = onibi_ast_node("option_global", token);
    rb_hash_aset(node, ID2SYM(rb_intern("options")), rb_hash_aref(token, ID2SYM(rb_intern("name"))));
    VALUE negative_options = rb_hash_aref(token, ID2SYM(rb_intern("negative_name")));
    if (!NIL_P(negative_options))
      rb_hash_aset(node, ID2SYM(rb_intern("negative_options")), negative_options);
    rb_hash_aset(node, ID2SYM(rb_intern("negative")), rb_hash_aref(token, ID2SYM(rb_intern("negative"))));
    rb_obj_freeze(node);
    *index = *index + 1;
    return node;
  }
  if (kind == rb_intern("noncapture_start")) {
    long close = onibi_find_close(tokens, *index, end, rb_intern("noncapture_start"), rb_intern("group_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated group");
    VALUE node = onibi_ast_node("group", token);
    rb_hash_aset(node, ID2SYM(rb_intern("body")), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(rb_intern("capturing")), Qfalse);
    rb_hash_aset(node, ID2SYM(rb_intern("end")), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(rb_intern("end"))));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind == rb_intern("atomic_start")) {
    long close = onibi_find_close(tokens, *index, end, rb_intern("atomic_start"), rb_intern("group_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated atomic group");
    VALUE node = onibi_ast_node("atomic", token);
    rb_hash_aset(node, ID2SYM(rb_intern("body")), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(rb_intern("end")), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(rb_intern("end"))));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind == rb_intern("absence_start")) {
    long close = onibi_find_close(tokens, *index, end, rb_intern("absence_start"), rb_intern("group_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated absence operator");
    VALUE node = onibi_ast_node("absence", token);
    rb_hash_aset(node, ID2SYM(rb_intern("body")), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(rb_intern("end")), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(rb_intern("end"))));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind == rb_intern("conditional_start")) {
    long close = onibi_find_close(tokens, *index, end, rb_intern("conditional_start"), rb_intern("group_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated conditional group");
    VALUE node = onibi_ast_node("conditional", token);
    VALUE condition = rb_hash_aref(token, ID2SYM(rb_intern("name")));
    if (!NIL_P(condition)) rb_hash_aset(node, ID2SYM(rb_intern("condition")), condition);
    VALUE body = onibi_parse_range(tokens, *index + 1, close);
    VALUE branches = rb_hash_aref(body, ID2SYM(rb_intern("branches")));
    if (RB_TYPE_P(branches, T_ARRAY) && RARRAY_LEN(branches) == 2) {
      rb_hash_aset(node, ID2SYM(rb_intern("yes")), rb_ary_entry(branches, 0));
      rb_hash_aset(node, ID2SYM(rb_intern("no")), rb_ary_entry(branches, 1));
    } else {
      rb_hash_aset(node, ID2SYM(rb_intern("yes")), body);
      rb_hash_aset(node, ID2SYM(rb_intern("no")), onibi_parse_range(tokens, close, close));
    }
    rb_hash_aset(node, ID2SYM(rb_intern("end")), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(rb_intern("end"))));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind == rb_intern("group_start")) {
    long close = onibi_find_close(tokens, *index, end, rb_intern("group_start"), rb_intern("group_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated group");
    VALUE node = onibi_ast_node("capture", token);
    rb_hash_aset(node, ID2SYM(rb_intern("body")), onibi_parse_range(tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(rb_intern("capturing")), Qtrue);
    VALUE name = rb_hash_aref(token, ID2SYM(rb_intern("name")));
    if (!NIL_P(name)) {
      if (RSTRING_LEN(name) == 0 || !isalpha((unsigned char)RSTRING_PTR(name)[0]))
        rb_raise(eRegexpError, "invalid capture name");
      for (long n = 1; n < RSTRING_LEN(name); n++)
        if (!isalnum((unsigned char)RSTRING_PTR(name)[n]) && RSTRING_PTR(name)[n] != '_')
          rb_raise(eRegexpError, "invalid capture name");
      rb_hash_aset(node, ID2SYM(rb_intern("name")), name);
    }
    rb_hash_aset(node, ID2SYM(rb_intern("end")),
                 rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(rb_intern("end"))));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind == rb_intern("class_start")) {
    long close = onibi_find_close(tokens, *index, end, rb_intern("class_start"), rb_intern("class_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated character class");
    VALUE node = onibi_parse_class(tokens, *index, close);
    rb_hash_aset(node, ID2SYM(rb_intern("end")),
                 rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(rb_intern("end"))));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind == rb_intern("subroutine")) {
    VALUE node = onibi_ast_node("subroutine", token);
    VALUE name = rb_hash_aref(token, ID2SYM(rb_intern("name")));
    if (!NIL_P(name)) rb_hash_aset(node, ID2SYM(rb_intern("name")), name);
    rb_hash_aset(node, ID2SYM(rb_intern("byte")), LONG2NUM(onibi_token_byte(token)));
    rb_obj_freeze(node);
    *index = *index + 1;
    return node;
  }
  VALUE node = NIL_P(token) ? Qnil :
    (kind == rb_intern("wildcard") ? onibi_ast_node("any", token) :
     (kind == rb_intern("anchor") ? onibi_ast_node("anchor", token) :
     (kind == rb_intern("escape") || kind == rb_intern("meta_escape") ? onibi_ast_node("escape", token) :
       (kind == rb_intern("match_reset") ? onibi_ast_node("match_reset", token) :
       (kind == rb_intern("backref") ? onibi_ast_node("backref", token) :
       (kind == rb_intern("literal") ? onibi_ast_node("literal", token) : Qnil))))));
  if (NIL_P(node)) rb_raise(eRegexpError, "unexpected token in expression");
  rb_hash_aset(node, ID2SYM(rb_intern("byte")), LONG2NUM(onibi_token_byte(token)));
  VALUE token_bytes = rb_hash_aref(token, ID2SYM(rb_intern("bytes")));
  if (!NIL_P(token_bytes)) rb_hash_aset(node, ID2SYM(rb_intern("bytes")), token_bytes);
  if (kind == rb_intern("anchor")) {
    long marker = onibi_token_byte(token);
    const char *anchor = (marker == '^' || marker == 'A' || marker == 'G') ?
      "anchor_start" : ((marker == '$' || marker == 'z' || marker == 'Z') ?
      "anchor_end" : "anchor");
    rb_hash_aset(node, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern(anchor)));
  }
  if (kind == rb_intern("escape") || kind == rb_intern("meta_escape")) {
    VALUE token_name = rb_hash_aref(token, ID2SYM(rb_intern("name")));
    rb_hash_aset(node, ID2SYM(rb_intern("name")), NIL_P(token_name) ?
                rb_str_new((const char[]){(char)onibi_token_byte(token)}, 1) : token_name);
  }
  if (kind == rb_intern("backref")) {
    VALUE name = rb_hash_aref(token, ID2SYM(rb_intern("name")));
    if (NIL_P(name)) rb_hash_aset(node, ID2SYM(rb_intern("capture")), LONG2NUM(onibi_token_byte(token) - '0'));
    else rb_hash_aset(node, ID2SYM(rb_intern("name")), name);
  }
  rb_obj_freeze(node);
  *index = *index + 1;
  return node;
}

static VALUE onibi_parse_range(VALUE tokens, long begin, long end) {
  VALUE branches = rb_ary_new();
  long part = begin, depth = 0;
  for (long i = begin; i < end; i++) {
    ID kind = onibi_token_kind(rb_ary_entry(tokens, i));
    if (kind == rb_intern("group_start") || kind == rb_intern("noncapture_start") || kind == rb_intern("atomic_start") || kind == rb_intern("absence_start") || kind == rb_intern("conditional_start") || kind == rb_intern("lookahead_start") || kind == rb_intern("lookbehind_start") || kind == rb_intern("option_scope_start") || kind == rb_intern("class_start")) depth++;
    else if (kind == rb_intern("group_end") || kind == rb_intern("class_end")) depth--;
    else if (kind == rb_intern("alternation") && depth == 0) {
      rb_ary_push(branches, onibi_parse_range(tokens, part, i));
      part = i + 1;
    }
  }
  if (RARRAY_LEN(branches) > 0) {
    rb_ary_push(branches, onibi_parse_range(tokens, part, end));
    VALUE node = onibi_ast_node("alternative", Qnil);
    rb_hash_aset(node, ID2SYM(rb_intern("branches")), branches);
    rb_obj_freeze(branches); rb_obj_freeze(node);
    return node;
  }

  VALUE children = rb_ary_new();
  for (long i = begin; i < end;) {
    VALUE node = onibi_parse_atom(tokens, &i, end);
    if (i < end && onibi_token_kind(rb_ary_entry(tokens, i)) == rb_intern("quantifier")) {
      VALUE modifier = rb_ary_entry(tokens, i);
      long marker = onibi_token_byte(modifier);
      if (marker == '*' || marker == '+' || marker == '?') {
        VALUE node_type = rb_hash_aref(node, ID2SYM(rb_intern("type")));
        if (node_type == ID2SYM(rb_intern("quantifier")))
          rb_raise(eRegexpError, "nested quantifier");
        long min = marker == '+' ? 1 : 0;
        VALUE max = marker == '?' ? LONG2NUM(1) : Qnil;
        i++;
        int greedy = 1, possessive = 0;
        if (i < end && onibi_token_kind(rb_ary_entry(tokens, i)) == rb_intern("quantifier")) {
          long suffix = onibi_token_byte(rb_ary_entry(tokens, i));
          if (suffix == '?') { greedy = 0; i++; }
          else if (suffix == '+') { possessive = 1; i++; }
        }
        VALUE quantifier = onibi_ast_node("quantifier", modifier);
        rb_hash_aset(quantifier, ID2SYM(rb_intern("atom")), node);
        rb_hash_aset(quantifier, ID2SYM(rb_intern("min")), LONG2NUM(min));
        rb_hash_aset(quantifier, ID2SYM(rb_intern("max")), max);
        rb_hash_aset(quantifier, ID2SYM(rb_intern("greedy")), greedy ? Qtrue : Qfalse);
        rb_hash_aset(quantifier, ID2SYM(rb_intern("possessive")), possessive ? Qtrue : Qfalse);
        rb_obj_freeze(quantifier); node = quantifier;
      } else if (marker == '{') {
        VALUE node_type = rb_hash_aref(node, ID2SYM(rb_intern("type")));
        if (node_type == ID2SYM(rb_intern("quantifier")))
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
            VALUE literal = onibi_ast_node("literal", literal_token);
            rb_hash_aset(literal, ID2SYM(rb_intern("byte")), LONG2NUM(onibi_token_byte(literal_token)));
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
        VALUE quantifier = onibi_ast_node("quantifier", modifier);
        rb_hash_aset(quantifier, ID2SYM(rb_intern("atom")), node);
        rb_hash_aset(quantifier, ID2SYM(rb_intern("min")), LONG2NUM(min));
        rb_hash_aset(quantifier, ID2SYM(rb_intern("max")), has_max ? LONG2NUM(max_value) : Qnil);
        i = close + 1;
        int greedy = 1, possessive = 0;
        if (i < end && onibi_token_kind(rb_ary_entry(tokens, i)) == rb_intern("quantifier")) {
          long suffix = onibi_token_byte(rb_ary_entry(tokens, i));
          if (suffix == '?') { greedy = 0; i++; }
          else if (suffix == '+') { possessive = 1; i++; }
        }
        rb_hash_aset(quantifier, ID2SYM(rb_intern("greedy")), greedy ? Qtrue : Qfalse);
        rb_hash_aset(quantifier, ID2SYM(rb_intern("possessive")), possessive ? Qtrue : Qfalse);
        rb_obj_freeze(quantifier); node = quantifier;
      }
    }
    rb_ary_push(children, node);
  }
  VALUE sequence = onibi_ast_node("sequence", Qnil);
  rb_hash_aset(sequence, ID2SYM(rb_intern("children")), children);
  rb_obj_freeze(children); rb_obj_freeze(sequence);
  return sequence;
}

static VALUE onibi_parser_options(VALUE options) {
  VALUE result = rb_ary_new();
  if (NIL_P(options) || options == Qfalse) { rb_obj_freeze(result); return result; }
  if (options == Qtrue) { VALUE name = rb_str_new_cstr("ignorecase"); rb_obj_freeze(name); rb_ary_push(result, name); }
  else if (RB_TYPE_P(options, T_ARRAY)) {
    for (long i = 0; i < RARRAY_LEN(options); i++) {
      VALUE item = rb_ary_entry(options, i);
      VALUE name = SYMBOL_P(item) ? rb_sym2str(item) : StringValue(item);
      if (rb_str_cmp(name, rb_str_new_cstr("ignorecase")) == 0 ||
          rb_str_cmp(name, rb_str_new_cstr("multiline")) == 0 ||
          rb_str_cmp(name, rb_str_new_cstr("extended")) == 0 ||
          rb_str_cmp(name, rb_str_new_cstr("fixedencoding")) == 0 ||
          rb_str_cmp(name, rb_str_new_cstr("noencoding")) == 0) {
        VALUE copy = rb_str_dup(name); rb_obj_freeze(copy); rb_ary_push(result, copy);
      } else rb_raise(rb_eArgError, "unknown regexp option");
    }
  }
  else if (RB_TYPE_P(options, T_STRING)) {
    const char *p = RSTRING_PTR(options);
    for (long i = 0; i < RSTRING_LEN(options); i++) {
      const char *name = p[i] == 'i' ? "ignorecase" :
                         (p[i] == 'm' ? "multiline" :
                         (p[i] == 'x' ? "extended" :
                         (p[i] == 'n' ? "noencoding" : NULL)));
      if (name != NULL) { VALUE value = rb_str_new_cstr(name); rb_obj_freeze(value); rb_ary_push(result, value); }
      else rb_raise(rb_eArgError, "unknown regexp option");
    }
  } else {
    int mask = NUM2INT(options);
    if (mask & ~(1 | 2 | 4 | 16 | 32)) rb_raise(rb_eArgError, "unknown regexp option");
      if (mask & 1) { VALUE name = rb_str_new_cstr("ignorecase"); rb_obj_freeze(name); rb_ary_push(result, name); }
      if (mask & 4) { VALUE name = rb_str_new_cstr("multiline"); rb_obj_freeze(name); rb_ary_push(result, name); }
      if (mask & 2) { VALUE name = rb_str_new_cstr("extended"); rb_obj_freeze(name); rb_ary_push(result, name); }
      if (mask & 16) { VALUE name = rb_str_new_cstr("fixedencoding"); rb_obj_freeze(name); rb_ary_push(result, name); }
      if (mask & 32) { VALUE name = rb_str_new_cstr("noencoding"); rb_obj_freeze(name); rb_ary_push(result, name); }
  }
  VALUE unique = rb_ary_new();
  for (long i = 0; i < RARRAY_LEN(result); i++) {
    VALUE name = rb_ary_entry(result, i);
    if (!RTEST(rb_ary_includes(unique, name))) rb_ary_push(unique, name);
  }
  rb_obj_freeze(unique);
  return unique;
}

static VALUE onibi_parser_parse_internal(VALUE source, VALUE options, VALUE supplied_tokens) {
  source = StringValue(source);
  VALUE tokens = supplied_tokens;
  if (NIL_P(tokens)) {
    tokens = onibi_tokenize_internal(source, onibi_extended_option_p(options));
  }
  VALUE result = rb_hash_new();
  VALUE source_copy = rb_str_dup(source);
  rb_obj_freeze(source_copy);
  rb_hash_aset(result, ID2SYM(rb_intern("source")), source_copy);
  rb_hash_aset(result, ID2SYM(rb_intern("options")), onibi_parser_options(options));
  rb_hash_aset(result, ID2SYM(rb_intern("tokens")), tokens);
  rb_hash_aset(result, ID2SYM(rb_intern("ast")), onibi_deep_freeze(onibi_parse_range(tokens, 0, RARRAY_LEN(tokens))));
  rb_obj_freeze(result);
  return result;
}

static VALUE onibi_parser_parse(int argc, VALUE *argv, VALUE self) {
  (void)self;
  VALUE source, options = Qnil;
  rb_scan_args(argc, argv, "11", &source, &options);
  return onibi_parser_parse_internal(source, options, Qnil);
}

typedef struct { VALUE starts; VALUE exits; VALUE start_actions; VALUE pending_actions; int nullable; int lazy; } onibi_fragment_t;
typedef struct { VALUE states; VALUE edges; long next_id; long capture_count; long counter_count; VALUE capture_names; VALUE capture_bodies; VALUE capture_ids; VALUE capture_guards; VALUE exit_guards; VALUE active_subroutines; int ignorecase; int multiline; int optional_seen; } onibi_gir_builder_t;
static VALUE onibi_hash_value(VALUE hash, const char *name);
static void onibi_append_values(VALUE destination, VALUE values);

static void onibi_bitmap_set(unsigned char *bits, unsigned char value, int fold) {
  bits[value >> 3] |= (unsigned char)(1U << (value & 7));
  if (fold) {
    unsigned char lower = (unsigned char)tolower(value);
    unsigned char upper = (unsigned char)toupper(value);
    bits[lower >> 3] |= (unsigned char)(1U << (lower & 7));
    bits[upper >> 3] |= (unsigned char)(1U << (upper & 7));
  }
}

static int onibi_ascii_property_hit(VALUE name, int c) {
  const char *property = StringValueCStr(name);
  if (strcmp(property, "ASCII") == 0) return c < 128;
  if (strcmp(property, "ASCII_Hex_Digit") == 0) return isxdigit(c);
  if (strcmp(property, "Digit") == 0) return isdigit(c);
  if (strcmp(property, "Alpha") == 0) return isalpha(c);
  if (strcmp(property, "Alnum") == 0) return isalnum(c);
  if (strcmp(property, "Lower") == 0) return islower(c);
  if (strcmp(property, "Upper") == 0) return isupper(c);
  if (strcmp(property, "Space") == 0) return isspace(c);
  if (strcmp(property, "Blank") == 0) return c == ' ' || c == '\t';
  if (strcmp(property, "Word") == 0) return isalnum(c) || c == '_';
  if (strcmp(property, "XDigit") == 0) return isxdigit(c);
  if (strcmp(property, "Cntrl") == 0) return iscntrl(c);
  if (strcmp(property, "Print") == 0) return isprint(c);
  if (strcmp(property, "Graph") == 0) return isgraph(c);
  if (strcmp(property, "Punct") == 0) return ispunct(c);
  return -1;
}

static int onibi_ascii_property_name_p(VALUE name) {
  if (NIL_P(name)) return 0;
  const char *property = StringValueCStr(name);
  return onibi_ascii_property_hit(name, 0) >= 0 || strcmp(property, "ASCII") == 0;
}

static VALUE onibi_class_bitmap(VALUE payload, int fold) {
  unsigned char bits[32];
  memset(bits, 0, sizeof(bits));
  if (onibi_hash_value(payload, "type") == ID2SYM(rb_intern("class_intersection"))) {
    VALUE operands = onibi_hash_value(payload, "operands");
    if (!RB_TYPE_P(operands, T_ARRAY) || RARRAY_LEN(operands) < 2)
      rb_raise(eRegexpError, "class intersection has no operands");
    VALUE first = onibi_class_bitmap(rb_ary_entry(operands, 0), fold);
    memcpy(bits, RSTRING_PTR(first), sizeof(bits));
    for (long i = 1; i < RARRAY_LEN(operands); i++) {
      VALUE next = onibi_class_bitmap(rb_ary_entry(operands, i), fold);
      for (long byte = 0; byte < 32; byte++)
        bits[byte] &= (unsigned char)RSTRING_PTR(next)[byte];
    }
    VALUE result = rb_str_new((const char *)bits, sizeof(bits));
    rb_obj_freeze(result);
    return result;
  }
  VALUE ranges = onibi_hash_value(payload, "ranges");
  VALUE escape_name = onibi_hash_value(payload, "name");
  if (!NIL_P(escape_name) && RSTRING_LEN(escape_name) == 1) {
    int upper = isupper((unsigned char)RSTRING_PTR(escape_name)[0]);
    int code = tolower((unsigned char)RSTRING_PTR(escape_name)[0]);
    for (int c = 0; c < 256; c++) {
      int hit = code == 'd' ? isdigit(c) : (code == 's' ? isspace(c) :
        (code == 'w' ? (isalnum(c) || c == '_') : (code == 'h' ? isxdigit(c) : 0)));
      if (upper ? !hit : hit) onibi_bitmap_set(bits, (unsigned char)c, fold);
    }
  } else if (onibi_ascii_property_name_p(escape_name)) {
    for (int c = 0; c < 256; c++) {
      int hit = onibi_ascii_property_hit(escape_name, c);
      if (hit > 0) onibi_bitmap_set(bits, (unsigned char)c, fold);
    }
    if (NUM2INT(onibi_hash_value(payload, "byte")) == 'P')
      for (long i = 0; i < 32; i++) bits[i] = (unsigned char)~bits[i];
  }
  for (long i = 0; i < RARRAY_LEN(ranges); i++) {
    VALUE range = rb_ary_entry(ranges, i);
    if (RARRAY_LEN(range) != 2) continue;
    if (!RB_INTEGER_TYPE_P(rb_ary_entry(range, 0)) || !RB_INTEGER_TYPE_P(rb_ary_entry(range, 1))) continue;
    int first = NUM2INT(rb_ary_entry(range, 0));
    int last = NUM2INT(rb_ary_entry(range, 1));
    if (first < 0) first = 0; if (last > 255) last = 255;
    for (int c = first; c <= last; c++) onibi_bitmap_set(bits, (unsigned char)c, fold);
  }
  VALUE children = onibi_hash_value(payload, "children");
  for (long i = 0; i < RARRAY_LEN(children); i++) {
    VALUE child = rb_ary_entry(children, i);
    VALUE kind_value = onibi_hash_value(child, "kind");
    if (NIL_P(kind_value)) kind_value = onibi_hash_value(child, "type");
    ID kind = NIL_P(kind_value) ? 0 : SYM2ID(kind_value);
    if (kind == rb_intern("literal")) {
      onibi_bitmap_set(bits, (unsigned char)NUM2INT(onibi_hash_value(child, "byte")), fold);
    } else if (kind == rb_intern("escape")) {
      VALUE name = onibi_hash_value(child, "name");
      if (onibi_ascii_property_name_p(name)) {
        for (int c = 0; c < 256; c++) {
          int hit = onibi_ascii_property_hit(name, c);
          if (hit > 0) onibi_bitmap_set(bits, (unsigned char)c, fold);
        }
        if (NUM2INT(onibi_hash_value(child, "byte")) == 'P')
          for (long byte = 0; byte < 32; byte++) bits[byte] = (unsigned char)~bits[byte];
        continue;
      }
      int escape_code = NIL_P(name) ? tolower((unsigned char)NUM2INT(onibi_hash_value(child, "byte"))) :
        (RSTRING_LEN(name) == 1 ? tolower((unsigned char)RSTRING_PTR(name)[0]) : 0);
      if (escape_code == 'r' || escape_code == 'p' || escape_code == 'x' || escape_code == 'u')
        rb_raise(eRegexpError, "escape is not supported in RSeq class");
      int upper = NIL_P(name) ? isupper((unsigned char)NUM2INT(onibi_hash_value(child, "byte"))) :
        (RSTRING_LEN(name) == 1 && isupper((unsigned char)RSTRING_PTR(name)[0]));
      int code = escape_code;
      for (int c = 0; c < 256; c++) {
        int hit = code == 'd' ? isdigit(c) : (code == 's' ? isspace(c) :
          (code == 'w' ? (isalnum(c) || c == '_') : (code == 'h' ? isxdigit(c) : 0)));
        if (upper ? !hit : hit) onibi_bitmap_set(bits, (unsigned char)c, fold);
      }
    } else if (kind == rb_intern("posix_class")) {
      VALUE name = onibi_hash_value(child, "name");
      const char *n = StringValueCStr(name);
      for (int c = 0; c < 256; c++) {
        int hit = (strcmp(n, "alpha") == 0) ? isalpha(c) :
          (strcmp(n, "digit") == 0) ? isdigit(c) :
          (strcmp(n, "alnum") == 0) ? isalnum(c) :
          (strcmp(n, "space") == 0) ? isspace(c) :
          (strcmp(n, "blank") == 0) ? (c == ' ' || c == '\t') :
          (strcmp(n, "lower") == 0) ? islower(c) :
          (strcmp(n, "upper") == 0) ? isupper(c) :
          (strcmp(n, "word") == 0) ? (isalnum(c) || c == '_') :
          (strcmp(n, "xdigit") == 0) ? isxdigit(c) : 0;
        if (hit) onibi_bitmap_set(bits, (unsigned char)c, fold);
      }
    } else if (kind == rb_intern("character_class")) {
      VALUE nested = onibi_class_bitmap(child, fold);
      for (long byte = 0; byte < 32; byte++)
        bits[byte] |= (unsigned char)RSTRING_PTR(nested)[byte];
    }
  }
  if (RTEST(onibi_hash_value(payload, "negated")))
    for (long i = 0; i < 32; i++) bits[i] = (unsigned char)~bits[i];
  VALUE bitmap = rb_str_new((const char *)bits, sizeof(bits));
  rb_obj_freeze(bitmap);
  return bitmap;
}

static VALUE onibi_hash_value(VALUE hash, const char *name) {
  return rb_hash_aref(hash, ID2SYM(rb_intern(name)));
}

static VALUE onibi_symbol_value(VALUE hash, const char *name) {
  return onibi_hash_value(hash, name);
}

static int onibi_ast_has_capture(VALUE ast) {
  if (NIL_P(ast)) return 0;
  if (RB_TYPE_P(ast, T_ARRAY)) {
    for (long i = 0; i < RARRAY_LEN(ast); i++)
      if (onibi_ast_has_capture(rb_ary_entry(ast, i))) return 1;
    return 0;
  }
  if (!RB_TYPE_P(ast, T_HASH)) return 0;
  if (onibi_symbol_value(ast, "type") == ID2SYM(rb_intern("capture"))) return 1;
  const char *keys[] = { "body", "children", "branches", "atom" };
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
    if (onibi_ast_has_capture(onibi_hash_value(ast, keys[i]))) return 1;
  return 0;
}

static int onibi_ast_atomic_simple(VALUE ast) {
  VALUE type = onibi_symbol_value(ast, "type");
  if (type == ID2SYM(rb_intern("literal")) || type == ID2SYM(rb_intern("escape")) ||
      type == ID2SYM(rb_intern("character_class")) || type == ID2SYM(rb_intern("class_intersection")) ||
      type == ID2SYM(rb_intern("any"))) return 1;
  if (type == ID2SYM(rb_intern("group")) || type == ID2SYM(rb_intern("option_scope")))
    return onibi_ast_atomic_simple(onibi_hash_value(ast, "body"));
  if (type == ID2SYM(rb_intern("sequence"))) {
    VALUE children = onibi_hash_value(ast, "children");
    for (long i = 0; i < RARRAY_LEN(children); i++)
      if (!onibi_ast_atomic_simple(rb_ary_entry(children, i))) return 0;
    return 1;
  }
  return 0;
}

static void onibi_gir_state(onibi_gir_builder_t *builder, long id, ID op, VALUE payload) {
  VALUE state = rb_hash_new();
  rb_hash_aset(state, ID2SYM(rb_intern("id")), LONG2NUM(id));
  rb_hash_aset(state, ID2SYM(rb_intern("op")), ID2SYM(op));
  rb_hash_aset(state, ID2SYM(rb_intern("payload")), payload);
  rb_ary_push(builder->states, state);
}

static void onibi_gir_edge(onibi_gir_builder_t *builder, long from, long to) {
  VALUE actions = rb_ary_new();
  VALUE edge = rb_hash_new();
  rb_hash_aset(edge, ID2SYM(rb_intern("from")), LONG2NUM(from));
  rb_hash_aset(edge, ID2SYM(rb_intern("to")), LONG2NUM(to));
  VALUE guards = rb_hash_aref(builder->capture_guards, LONG2NUM(to));
  if (!NIL_P(guards)) { VALUE merged = rb_ary_dup(guards); onibi_append_values(merged, actions); actions = merged; }
  VALUE guard = rb_hash_aref(builder->capture_guards, LONG2NUM(to));
  VALUE exit_guard = rb_hash_aref(builder->exit_guards, LONG2NUM(from));
  if (!NIL_P(exit_guard)) { VALUE merged = rb_ary_dup(exit_guard); onibi_append_values(merged, actions); actions = merged; }
  if (!NIL_P(guard)) { VALUE merged = rb_ary_dup(actions); onibi_append_values(merged, guard); actions = merged; }
  rb_hash_aset(edge, ID2SYM(rb_intern("actions")), actions);
  rb_ary_push(builder->edges, edge);
}

static void onibi_gir_edge_actions(onibi_gir_builder_t *builder, long from, long to, VALUE actions) {
  for (long i = 0; i < RARRAY_LEN(builder->edges); i++) {
    VALUE prior = rb_ary_entry(builder->edges, i);
    if (NUM2LONG(onibi_hash_value(prior, "from")) == from &&
      NUM2LONG(onibi_hash_value(prior, "to")) == to) {
      VALUE prior_actions = onibi_hash_value(prior, "actions");
      VALUE merged_actions = rb_ary_dup(actions);
      onibi_append_values(merged_actions, prior_actions);
      rb_hash_aset(prior, ID2SYM(rb_intern("actions")), merged_actions);
      return;
    }
  }
  VALUE edge = rb_hash_new();
  rb_hash_aset(edge, ID2SYM(rb_intern("from")), LONG2NUM(from));
  rb_hash_aset(edge, ID2SYM(rb_intern("to")), LONG2NUM(to));
  VALUE guards = rb_hash_aref(builder->capture_guards, LONG2NUM(to));
  if (!NIL_P(guards)) { VALUE merged = rb_ary_dup(guards); onibi_append_values(merged, actions); actions = merged; }
  VALUE guard = rb_hash_aref(builder->capture_guards, LONG2NUM(to));
  VALUE exit_guard = rb_hash_aref(builder->exit_guards, LONG2NUM(from));
  if (!NIL_P(exit_guard)) { VALUE merged = rb_ary_dup(exit_guard); onibi_append_values(merged, actions); actions = merged; }
  if (!NIL_P(guard)) { VALUE merged = rb_ary_dup(actions); onibi_append_values(merged, guard); actions = merged; }
  rb_hash_aset(edge, ID2SYM(rb_intern("actions")), actions);
  rb_ary_push(builder->edges, edge);
}

static onibi_fragment_t onibi_fragment_empty(void) {
  onibi_fragment_t fragment;
  fragment.starts = rb_ary_new(); fragment.exits = rb_ary_new();
  fragment.start_actions = rb_ary_new(); fragment.pending_actions = rb_ary_new(); fragment.nullable = 1; fragment.lazy = 0;
  return fragment;
}

static void onibi_connect(onibi_gir_builder_t *builder, VALUE exits, VALUE starts) {
  for (long i = 0; i < RARRAY_LEN(exits); i++)
    for (long j = 0; j < RARRAY_LEN(starts); j++)
      onibi_gir_edge(builder, NUM2LONG(rb_ary_entry(exits, i)), NUM2LONG(rb_ary_entry(starts, j)));
}

static void onibi_connect_actions(onibi_gir_builder_t *builder, VALUE exits, VALUE starts, VALUE actions) {
  for (long i = 0; i < RARRAY_LEN(exits); i++)
    for (long j = 0; j < RARRAY_LEN(starts); j++)
      onibi_gir_edge_actions(builder, NUM2LONG(rb_ary_entry(exits, i)), NUM2LONG(rb_ary_entry(starts, j)), actions);
}

static void onibi_connect_prepend_actions(onibi_gir_builder_t *builder, VALUE exits, VALUE starts, VALUE actions) {
  for (long i = 0; i < RARRAY_LEN(exits); i++) {
    long from = NUM2LONG(rb_ary_entry(exits, i));
    for (long j = 0; j < RARRAY_LEN(starts); j++) {
      VALUE edge = rb_hash_new();
      rb_hash_aset(edge, ID2SYM(rb_intern("from")), LONG2NUM(from));
      rb_hash_aset(edge, ID2SYM(rb_intern("to")), rb_ary_entry(starts, j));
      rb_hash_aset(edge, ID2SYM(rb_intern("actions")), actions);
      long insert_at = RARRAY_LEN(builder->edges);
      for (long k = 0; k < RARRAY_LEN(builder->edges); k++) {
        VALUE prior = rb_ary_entry(builder->edges, k);
        if (NUM2LONG(onibi_hash_value(prior, "from")) == from) { insert_at = k; break; }
      }
      rb_funcall(builder->edges, rb_intern("insert"), 2, LONG2NUM(insert_at), edge);
    }
  }
}

static void onibi_append_values(VALUE destination, VALUE values) {
  for (long i = 0; i < RARRAY_LEN(values); i++) rb_ary_push(destination, rb_ary_entry(values, i));
}

static void onibi_add_capture_guard(onibi_gir_builder_t *builder, VALUE starts, VALUE guard) {
  for (long i = 0; i < RARRAY_LEN(starts); i++) {
    VALUE key = rb_ary_entry(starts, i);
    VALUE prior = rb_hash_aref(builder->capture_guards, key);
    VALUE merged = NIL_P(prior) ? rb_ary_new() : rb_ary_dup(prior);
    onibi_append_values(merged, guard);
    rb_hash_aset(builder->capture_guards, key, merged);
  }
}

static void onibi_add_exit_guard(onibi_gir_builder_t *builder, VALUE exits, VALUE actions) {
  for (long i = 0; i < RARRAY_LEN(exits); i++) {
    VALUE key = rb_ary_entry(exits, i);
    VALUE prior = rb_hash_aref(builder->exit_guards, key);
    VALUE merged = NIL_P(prior) ? rb_ary_new() : rb_ary_dup(prior);
    onibi_append_values(merged, actions);
    rb_hash_aset(builder->exit_guards, key, merged);
  }
}

static VALUE onibi_capture_test_action(long slot, int set) {
  VALUE action = rb_hash_new();
  rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("TEST_CAPTURE")));
  rb_hash_aset(action, ID2SYM(rb_intern("slot")), LONG2NUM(slot));
  rb_hash_aset(action, ID2SYM(rb_intern("set")), set ? Qtrue : Qfalse);
  return action;
}

static VALUE onibi_counter_action(const char *op, long slot, VALUE limit) {
  VALUE action = rb_hash_new();
  rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern(op)));
  rb_hash_aset(action, ID2SYM(rb_intern("slot")), LONG2NUM(slot));
  if (!NIL_P(limit)) rb_hash_aset(action, ID2SYM(rb_intern("limit")), limit);
  if (strcmp(op, "COUNTER_INIT") == 0)
    rb_hash_aset(action, ID2SYM(rb_intern("value")), INT2NUM(1));
  return action;
}

static void onibi_freeze_gir_arrays(onibi_gir_builder_t *builder) {
  for (long i = 0; i < RARRAY_LEN(builder->states); i++) rb_obj_freeze(rb_ary_entry(builder->states, i));
  for (long i = 0; i < RARRAY_LEN(builder->edges); i++) {
    VALUE edge = rb_ary_entry(builder->edges, i);
    rb_obj_freeze(onibi_hash_value(edge, "actions"));
    rb_obj_freeze(edge);
  }
  rb_obj_freeze(builder->states);
  rb_obj_freeze(builder->edges);
}

static onibi_fragment_t onibi_compile_node(VALUE ast, onibi_gir_builder_t *builder);

static int onibi_gir_action_valid(ID action) {
  return action == rb_intern("CAPTURE_OPEN") || action == rb_intern("CAPTURE_CLOSE") ||
    action == rb_intern("MATCH_RESET") || action == rb_intern("ASSERT_BEGIN_BUFFER") ||
    action == rb_intern("ASSERT_END_BUFFER") || action == rb_intern("ASSERT_BEGIN_LINE") ||
    action == rb_intern("ASSERT_END_LINE") || action == rb_intern("ASSERT_SEMI_END_BUFFER") ||
    action == rb_intern("ASSERT_SEARCH_ORIGIN") || action == rb_intern("ASSERT_WORD_BOUNDARY") ||
    action == rb_intern("ASSERT_NONWORD_BOUNDARY") || action == rb_intern("ASSERT_LOOKAHEAD") ||
    action == rb_intern("ASSERT_LOOKBEHIND") || action == rb_intern("COUNTER_INIT") ||
    action == rb_intern("TEST_CAPTURE") ||
    action == rb_intern("COUNTER_INCREMENT") || action == rb_intern("TEST_COUNTER_LT") ||
    action == rb_intern("TEST_COUNTER_GE");
}

static void onibi_gir_validate_action_operands(VALUE action) {
  ID op = SYM2ID(onibi_hash_value(action, "op"));
  VALUE slot = onibi_hash_value(action, "slot");
  if (op == rb_intern("CAPTURE_OPEN") || op == rb_intern("CAPTURE_CLOSE")) {
    if (NIL_P(slot) || NUM2LONG(slot) < 0)
      rb_raise(eRegexpError, "invalid GIR capture slot");
  } else if (op == rb_intern("TEST_CAPTURE") || op == rb_intern("COUNTER_INIT") || op == rb_intern("COUNTER_INCREMENT") ||
             op == rb_intern("TEST_COUNTER_LT") || op == rb_intern("TEST_COUNTER_GE")) {
    if (NIL_P(slot) || NUM2LONG(slot) < 0)
      rb_raise(eRegexpError, "invalid GIR counter slot");
  }
  if (op == rb_intern("TEST_COUNTER_LT") || op == rb_intern("TEST_COUNTER_GE")) {
    VALUE limit = onibi_hash_value(action, "limit");
    if (NIL_P(limit) || NUM2LONG(limit) < 0)
      rb_raise(eRegexpError, "invalid GIR counter limit");
  }
}

static void onibi_gir_validate(VALUE graph) {
  VALUE states = onibi_hash_value(graph, "states");
  VALUE edges = onibi_hash_value(graph, "edges");
  VALUE starts = onibi_hash_value(graph, "start_edges");
  VALUE subprograms = onibi_hash_value(graph, "subprograms");
  long capture_count = NUM2LONG(onibi_hash_value(graph, "capture_count"));
  long counter_count = NUM2LONG(onibi_hash_value(graph, "counter_count"));
  if (!RB_TYPE_P(subprograms, T_ARRAY) || !RTEST(rb_obj_frozen_p(subprograms)))
    rb_raise(eRegexpError, "GIR subprogram table is not immutable");
  long state_count = RARRAY_LEN(states);
  VALUE accept_value = onibi_hash_value(graph, "accept");
  if (NIL_P(accept_value)) rb_raise(eRegexpError, "GIR accept state is missing");
  long accept = NUM2LONG(accept_value);
  if (accept < 0 || accept >= state_count)
    rb_raise(eRegexpError, "GIR accept state is out of range");
  for (long i = 0; i < state_count; i++) {
    VALUE state = rb_ary_entry(states, i);
    if (NUM2LONG(onibi_hash_value(state, "id")) != i)
      rb_raise(eRegexpError, "GIR state ids are not contiguous");
    ID op = SYM2ID(onibi_hash_value(state, "op"));
    if (op != rb_intern("G_ACCEPT") && op != rb_intern("G_CHAR") &&
        op != rb_intern("G_CLASS") && op != rb_intern("G_ANY") &&
        op != rb_intern("G_GRAPHEME") &&
        op != rb_intern("G_BACKREF") && op != rb_intern("G_CALL") &&
        op != rb_intern("G_ATOMIC") && op != rb_intern("G_ABSENT"))
      rb_raise(eRegexpError, "unknown GIR state opcode");
    if (i == accept && op != rb_intern("G_ACCEPT"))
      rb_raise(eRegexpError, "GIR accept state has a non-accept opcode");
    if (op == rb_intern("G_BACKREF")) {
      VALUE capture = onibi_hash_value(onibi_hash_value(state, "payload"), "capture");
      if (NIL_P(capture) || NUM2LONG(capture) < 1 || NUM2LONG(capture) > capture_count)
        rb_raise(eRegexpError, "GIR backreference capture is out of range");
    }
  }
  for (long i = 0; i < RARRAY_LEN(edges); i++) {
    VALUE edge = rb_ary_entry(edges, i);
    long from = NUM2LONG(onibi_hash_value(edge, "from"));
    long to = NUM2LONG(onibi_hash_value(edge, "to"));
    if (from < 0 || from >= state_count || to < 0 || to >= state_count)
      rb_raise(eRegexpError, "GIR edge is out of range");
    if (!RB_TYPE_P(onibi_hash_value(edge, "actions"), T_ARRAY))
      rb_raise(eRegexpError, "GIR edge actions are not an array");
    VALUE actions = onibi_hash_value(edge, "actions");
    for (long j = 0; j < RARRAY_LEN(actions); j++) {
      ID action = SYM2ID(onibi_hash_value(rb_ary_entry(actions, j), "op"));
      if (!onibi_gir_action_valid(action))
        rb_raise(eRegexpError, "unknown GIR edge action opcode");
      onibi_gir_validate_action_operands(rb_ary_entry(actions, j));
      VALUE slot = onibi_hash_value(rb_ary_entry(actions, j), "slot");
      if ((action == rb_intern("CAPTURE_OPEN") || action == rb_intern("CAPTURE_CLOSE")) &&
          NUM2LONG(slot) >= capture_count * 2)
        rb_raise(eRegexpError, "GIR capture slot is out of range");
      if ((action == rb_intern("COUNTER_INIT") || action == rb_intern("COUNTER_INCREMENT") ||
           action == rb_intern("TEST_COUNTER_LT") || action == rb_intern("TEST_COUNTER_GE")) &&
          NUM2LONG(slot) >= counter_count)
        rb_raise(eRegexpError, "GIR counter slot is out of range");
    }
  }
  for (long i = 0; i < RARRAY_LEN(starts); i++) {
    VALUE edge = rb_ary_entry(starts, i);
    long to = NUM2LONG(onibi_hash_value(edge, "to"));
    if (to < 0 || to >= state_count)
      rb_raise(eRegexpError, "GIR start edge is out of range");
    if (!RB_TYPE_P(onibi_hash_value(edge, "actions"), T_ARRAY))
      rb_raise(eRegexpError, "GIR start actions are not an array");
    VALUE actions = onibi_hash_value(edge, "actions");
    for (long j = 0; j < RARRAY_LEN(actions); j++) {
      ID action = SYM2ID(onibi_hash_value(rb_ary_entry(actions, j), "op"));
      if (!onibi_gir_action_valid(action)) rb_raise(eRegexpError, "unknown GIR start action opcode");
      onibi_gir_validate_action_operands(rb_ary_entry(actions, j));
      VALUE slot = onibi_hash_value(rb_ary_entry(actions, j), "slot");
      if ((action == rb_intern("CAPTURE_OPEN") || action == rb_intern("CAPTURE_CLOSE")) &&
          NUM2LONG(slot) >= capture_count * 2)
        rb_raise(eRegexpError, "GIR capture slot is out of range");
      if ((action == rb_intern("COUNTER_INIT") || action == rb_intern("COUNTER_INCREMENT") ||
           action == rb_intern("TEST_COUNTER_LT") || action == rb_intern("TEST_COUNTER_GE")) &&
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
    if (RARRAY_LEN(part.starts) == 0) {
      if (have_consuming) {
        onibi_append_values(result.pending_actions, part.start_actions);
        onibi_append_values(result.pending_actions, part.pending_actions);
      } else {
        onibi_append_values(result.start_actions, part.start_actions);
        onibi_append_values(result.start_actions, part.pending_actions);
      }
      result.nullable = result.nullable && part.nullable;
      continue;
    }
    if (!have_consuming) {
      result.starts = part.starts;
      result.exits = part.exits;
      onibi_append_values(result.start_actions, part.start_actions);
      result.lazy = part.lazy;
      have_consuming = 1;
    } else {
      VALUE old_exits = result.exits;
      if (result.nullable) {
        if (result.lazy) {
          VALUE reordered = rb_ary_dup(part.starts);
          onibi_append_values(reordered, result.starts);
          result.starts = reordered;
        } else onibi_append_values(result.starts, part.starts);
      }
      VALUE transition_actions = rb_ary_dup(result.pending_actions);
      onibi_append_values(transition_actions, part.start_actions);
      if (result.lazy) onibi_connect_prepend_actions(builder, old_exits, part.starts, transition_actions);
      else onibi_connect_actions(builder, old_exits, part.starts, transition_actions);
      result.exits = rb_ary_dup(part.exits);
      /* A prior exit can bypass this part only when this part is nullable. */
      if (part.nullable) onibi_append_values(result.exits, old_exits);
      result.pending_actions = rb_ary_new();
      result.lazy = part.lazy;
    }
    onibi_append_values(result.pending_actions, part.pending_actions);
    result.nullable = result.nullable && part.nullable;
  }
  return result;
}

static onibi_fragment_t onibi_compile_node(VALUE ast, onibi_gir_builder_t *builder) {
  VALUE type = onibi_symbol_value(ast, "type");
  if (type == ID2SYM(rb_intern("character_class"))) {
    VALUE children = onibi_hash_value(ast, "children");
    VALUE ranges = onibi_hash_value(ast, "ranges");
    if (!RTEST(onibi_hash_value(ast, "negated")) && RB_TYPE_P(children, T_ARRAY) &&
        RARRAY_LEN(ranges) == 0 && RARRAY_LEN(children) > 0) {
      int literal_only = 1;
      for (long i = 0; i < RARRAY_LEN(children); i++) {
        VALUE child = rb_ary_entry(children, i);
        if (onibi_hash_value(child, "kind") != ID2SYM(rb_intern("literal"))) {
          literal_only = 0;
          break;
        }
      }
      int has_multibyte = 0;
      for (long i = 0; literal_only && i < RARRAY_LEN(children); i++) {
        VALUE bytes = onibi_hash_value(rb_ary_entry(children, i), "bytes");
        if (!NIL_P(bytes) && RSTRING_LEN(bytes) > 1) has_multibyte = 1;
      }
      if (literal_only && has_multibyte) {
        /* A literal-only class is an ordered union of encoded literals.
           Each branch lowers to one or more G_CHAR states. */
        onibi_fragment_t result = onibi_fragment_empty();
        result.starts = rb_ary_new(); result.exits = rb_ary_new(); result.nullable = 0;
        for (long i = 0; i < RARRAY_LEN(children); i++) {
          VALUE child = rb_hash_dup(rb_ary_entry(children, i));
          rb_hash_aset(child, ID2SYM(rb_intern("type")), ID2SYM(rb_intern("literal")));
          onibi_fragment_t branch = onibi_compile_node(child, builder);
          onibi_append_values(result.starts, branch.starts);
          onibi_append_values(result.exits, branch.exits);
        }
        return result;
      }
    }
    if (!RTEST(onibi_hash_value(ast, "negated")) && RB_TYPE_P(children, T_ARRAY) &&
        RB_TYPE_P(ranges, T_ARRAY) && RARRAY_LEN(ranges) > 0 && RARRAY_LEN(ranges) <= 4) {
      int literal_children = 1;
      for (long i = 0; i < RARRAY_LEN(children); i++)
        if (onibi_hash_value(rb_ary_entry(children, i), "kind") != ID2SYM(rb_intern("literal"))) literal_children = 0;
      if (!literal_children) goto skip_utf8_range_expansion;
      onibi_fragment_t result = onibi_fragment_empty();
      result.starts = rb_ary_new(); result.exits = rb_ary_new(); result.nullable = 0;
      int expandable = 1; long expanded = 0;
      for (long i = 0; i < RARRAY_LEN(children); i++) {
        VALUE child = rb_hash_dup(rb_ary_entry(children, i));
        rb_hash_aset(child, ID2SYM(rb_intern("type")), ID2SYM(rb_intern("literal")));
        onibi_fragment_t branch = onibi_compile_node(child, builder);
        onibi_append_values(result.starts, branch.starts);
        onibi_append_values(result.exits, branch.exits);
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
          rb_hash_aset(literal, ID2SYM(rb_intern("type")), ID2SYM(rb_intern("literal")));
          rb_hash_aset(literal, ID2SYM(rb_intern("byte")), INT2NUM((unsigned char)RSTRING_PTR(bytes)[0]));
          rb_hash_aset(literal, ID2SYM(rb_intern("bytes")), bytes);
          onibi_fragment_t branch = onibi_compile_node(literal, builder);
          onibi_append_values(result.starts, branch.starts);
          onibi_append_values(result.exits, branch.exits);
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
  if (type == ID2SYM(rb_intern("literal"))) {
    VALUE literal_bytes = onibi_hash_value(ast, "bytes");
    if (!NIL_P(literal_bytes) && RSTRING_LEN(literal_bytes) > 1) {
      onibi_fragment_t result = onibi_fragment_empty();
      result.starts = rb_ary_new(); result.exits = rb_ary_new(); result.nullable = 0;
      for (long i = 0; i < RSTRING_LEN(literal_bytes); i++) {
        VALUE byte_ast = rb_hash_dup(ast);
        rb_hash_aset(byte_ast, ID2SYM(rb_intern("byte")),
                     INT2NUM((unsigned char)RSTRING_PTR(literal_bytes)[i]));
        rb_hash_aset(byte_ast, ID2SYM(rb_intern("bytes")),
                     rb_str_new(RSTRING_PTR(literal_bytes) + i, 1));
        onibi_fragment_t part = onibi_compile_node(byte_ast, builder);
        if (i == 0) result.starts = part.starts;
        else onibi_connect(builder, result.exits, part.starts);
        result.exits = part.exits;
      }
      return result;
    }
  }
  if (type == ID2SYM(rb_intern("sequence")))
    return onibi_compile_sequence(onibi_hash_value(ast, "children"), builder);
  if (type == ID2SYM(rb_intern("alternative"))) {
    onibi_fragment_t result = onibi_fragment_empty();
    result.starts = rb_ary_new(); result.exits = rb_ary_new(); result.nullable = 0;
    VALUE branches = onibi_hash_value(ast, "branches");
    for (long i = 0; i < RARRAY_LEN(branches); i++) {
      onibi_fragment_t branch = onibi_compile_node(rb_ary_entry(branches, i), builder);
      for (long j = 0; j < RARRAY_LEN(branch.starts); j++) rb_ary_push(result.starts, rb_ary_entry(branch.starts, j));
      for (long j = 0; j < RARRAY_LEN(branch.exits); j++) rb_ary_push(result.exits, rb_ary_entry(branch.exits, j));
      if (RARRAY_LEN(branch.start_actions) > 0 || RARRAY_LEN(branch.pending_actions) > 0)
        rb_raise(eRegexpError, "branch-specific anchor actions are not implemented");
      result.nullable = result.nullable || branch.nullable;
    }
    return result;
  }
  if (type == ID2SYM(rb_intern("literal")) || type == ID2SYM(rb_intern("escape")) ||
      type == ID2SYM(rb_intern("backref")) || type == ID2SYM(rb_intern("character_class")) ||
      type == ID2SYM(rb_intern("class_intersection")) || type == ID2SYM(rb_intern("any"))) {
    VALUE literal_bytes = onibi_hash_value(ast, "bytes");
    if (type == ID2SYM(rb_intern("literal")) && !NIL_P(literal_bytes) && RSTRING_LEN(literal_bytes) != 1)
      rb_raise(eRegexpError, "multibyte literals require encoded GIR states");
    if (type == ID2SYM(rb_intern("escape"))) {
      VALUE name = onibi_hash_value(ast, "name");
      if (!NIL_P(name) && RSTRING_LEN(name) > 1 && !onibi_ascii_property_name_p(name))
        rb_raise(eRegexpError, "Unicode property escapes require encoded GIR classes");
      int code = NIL_P(name) ? 0 : (RSTRING_LEN(name) == 1 ?
        tolower((unsigned char)RSTRING_PTR(name)[0]) : 0);
      if ((NIL_P(name) || RSTRING_LEN(name) <= 1) &&
          (code == 'r' || code == 'p' || code == 'x' || code == 'u'))
        rb_raise(eRegexpError, "escape is not supported in RSeq");
    }
    VALUE payload = ast;
    if (type == ID2SYM(rb_intern("backref")) && !NIL_P(onibi_hash_value(ast, "name"))) {
      VALUE id_value = rb_hash_aref(builder->capture_names, onibi_hash_value(ast, "name"));
      if (NIL_P(id_value)) rb_raise(eRegexpError, "undefined named backreference");
      payload = rb_hash_dup(ast);
      rb_hash_aset(payload, ID2SYM(rb_intern("capture")), LONG2NUM(NUM2LONG(id_value) + 1));
      rb_obj_freeze(payload);
    }
    if (builder->ignorecase && type == ID2SYM(rb_intern("backref"))) {
      payload = rb_hash_dup(payload);
      rb_hash_aset(payload, ID2SYM(rb_intern("ignorecase")), Qtrue);
      rb_obj_freeze(payload);
    }
    long id = builder->next_id++;
    ID op = type == ID2SYM(rb_intern("literal")) ? rb_intern("G_CHAR") :
      ((type == ID2SYM(rb_intern("any"))) ? rb_intern("G_ANY") :
       ((type == ID2SYM(rb_intern("backref"))) ? rb_intern("G_BACKREF") : rb_intern("G_CLASS")));
    if (builder->ignorecase && type == ID2SYM(rb_intern("literal"))) {
      payload = rb_hash_dup(payload);
      rb_hash_aset(payload, ID2SYM(rb_intern("byte")), INT2NUM(tolower(NUM2INT(onibi_hash_value(payload, "byte")))));
      rb_hash_aset(payload, ID2SYM(rb_intern("ignorecase")), Qtrue);
      rb_obj_freeze(payload);
    }
    if (builder->ignorecase && type == ID2SYM(rb_intern("character_class"))) {
      payload = rb_hash_dup(payload);
      rb_hash_aset(payload, ID2SYM(rb_intern("ignorecase")), Qtrue);
      rb_obj_freeze(payload);
    }
    if (type == ID2SYM(rb_intern("character_class")) || type == ID2SYM(rb_intern("class_intersection"))) {
      payload = rb_hash_dup(payload);
      rb_hash_aset(payload, ID2SYM(rb_intern("bitmap")),
                   onibi_class_bitmap(payload, builder->ignorecase));
      rb_obj_freeze(payload);
    }
    if (type == ID2SYM(rb_intern("escape"))) {
      payload = rb_hash_dup(payload);
      rb_hash_aset(payload, ID2SYM(rb_intern("ranges")), rb_ary_new());
      rb_hash_aset(payload, ID2SYM(rb_intern("children")), rb_ary_new());
      rb_hash_aset(payload, ID2SYM(rb_intern("bitmap")),
                   onibi_class_bitmap(payload, builder->ignorecase));
      rb_obj_freeze(payload);
    }
    if (builder->multiline && type == ID2SYM(rb_intern("any"))) {
      payload = rb_hash_dup(payload);
      rb_hash_aset(payload, ID2SYM(rb_intern("multiline")), Qtrue);
      rb_obj_freeze(payload);
    }
    onibi_gir_state(builder, id, op, payload);
    onibi_fragment_t result = onibi_fragment_empty();
    result.starts = rb_ary_new(); result.exits = rb_ary_new(); result.nullable = 0;
    rb_ary_push(result.starts, LONG2NUM(id)); rb_ary_push(result.exits, LONG2NUM(id));
    return result;
  }
  if (type == ID2SYM(rb_intern("subroutine")))
  {
    VALUE name = onibi_hash_value(ast, "name");
    VALUE body = NIL_P(name) ? Qnil : rb_hash_aref(builder->capture_bodies, name);
    if (NIL_P(body)) rb_raise(eRegexpError, "undefined subroutine call");
    if (RTEST(rb_hash_aref(builder->active_subroutines, name)))
      rb_raise(eRegexpError, "recursive subroutine requires dynamic call state");
    if (onibi_ast_has_capture(body)) rb_raise(eRegexpError, "capturing subroutine requires dynamic call state");
    rb_hash_aset(builder->active_subroutines, name, Qtrue);
    onibi_fragment_t result = onibi_compile_node(body, builder);
    rb_hash_delete(builder->active_subroutines, name);
    return result;
  }
  if (type == ID2SYM(rb_intern("option_global"))) {
    VALUE option_names = onibi_hash_value(ast, "options");
    int negative = RTEST(onibi_hash_value(ast, "negative"));
    if (NIL_P(option_names) || !RB_TYPE_P(option_names, T_STRING))
      rb_raise(eRegexpError, "global option modifier has no flags");
    for (long i = 0; i < RSTRING_LEN(option_names); i++) {
      int enabled = negative ? 0 : 1;
      if (RSTRING_PTR(option_names)[i] == 'i') builder->ignorecase = enabled;
      else if (RSTRING_PTR(option_names)[i] == 'm') builder->multiline = enabled;
      else if (RSTRING_PTR(option_names)[i] == 'x') continue;
      else rb_raise(eRegexpError, "unknown global option flag");
    }
    VALUE negative_options = onibi_hash_value(ast, "negative_options");
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
  if (type == ID2SYM(rb_intern("option_scope"))) {
    VALUE option_names = onibi_hash_value(ast, "options");
    if (NIL_P(option_names) || !RB_TYPE_P(option_names, T_STRING))
      rb_raise(eRegexpError, "option scope has no flags");
    int saved_ignorecase = builder->ignorecase;
    int saved_multiline = builder->multiline;
    int negative = RTEST(onibi_hash_value(ast, "negative"));
    for (long i = 0; i < RSTRING_LEN(option_names); i++) {
      int enabled = negative ? 0 : 1;
      if (RSTRING_PTR(option_names)[i] == 'i') builder->ignorecase = enabled;
      else if (RSTRING_PTR(option_names)[i] == 'm') builder->multiline = enabled;
      else if (RSTRING_PTR(option_names)[i] == 'x') continue;
      else rb_raise(eRegexpError, "unknown option scope flag");
    }
    VALUE negative_options = onibi_hash_value(ast, "negative_options");
    if (!NIL_P(negative_options)) {
      for (long i = 0; i < RSTRING_LEN(negative_options); i++) {
        if (RSTRING_PTR(negative_options)[i] == 'i') builder->ignorecase = 0;
        else if (RSTRING_PTR(negative_options)[i] == 'm') builder->multiline = 0;
        else if (RSTRING_PTR(negative_options)[i] == 'x') continue;
        else rb_raise(eRegexpError, "unknown option scope flag");
      }
    }
    onibi_fragment_t result = onibi_compile_node(onibi_hash_value(ast, "body"), builder);
    builder->ignorecase = saved_ignorecase;
    builder->multiline = saved_multiline;
    return result;
  }
  if (type == ID2SYM(rb_intern("anchor")))
  {
    onibi_fragment_t result = onibi_fragment_empty();
    VALUE action = rb_hash_new();
    long marker = NUM2LONG(onibi_hash_value(ast, "byte"));
    const char *op = "ASSERT_END_BUFFER";
    /* Ruby keeps ^ and $ line anchors independent of the m option.  The
       option changes dot-newline matching only. */
    if (marker == '^') op = "ASSERT_BEGIN_LINE";
    else if (marker == '$') op = "ASSERT_END_LINE";
    else if (marker == 'b') op = "ASSERT_WORD_BOUNDARY";
    else if (marker == 'B') op = "ASSERT_NONWORD_BOUNDARY";
    else if (marker == 'A') op = "ASSERT_BEGIN_BUFFER";
    else if (marker == 'G') op = "ASSERT_SEARCH_ORIGIN";
    else if (marker == 'Z') op = "ASSERT_SEMI_END_BUFFER";
    rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern(op)));
    rb_ary_push(result.pending_actions, action);
    return result;
  }
  if (type == ID2SYM(rb_intern("match_reset"))) {
    onibi_fragment_t result = onibi_fragment_empty();
    VALUE action = rb_hash_new();
    rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("MATCH_RESET")));
    rb_ary_push(result.pending_actions, action);
    return result;
  }
  if (type == ID2SYM(rb_intern("conditional"))) {
    VALUE condition = onibi_hash_value(ast, "condition");
    char *endptr = NULL;
    long capture_id = strtol(StringValueCStr(condition), &endptr, 10) - 1;
    if (endptr == StringValueCStr(condition) || *endptr != '\0') {
      VALUE named_condition = condition;
      if (RSTRING_LEN(condition) >= 2 && RSTRING_PTR(condition)[0] == '<' &&
          RSTRING_PTR(condition)[RSTRING_LEN(condition) - 1] == '>')
        named_condition = rb_str_substr(condition, 1, RSTRING_LEN(condition) - 2);
      VALUE named = rb_hash_aref(builder->capture_names, named_condition);
      if (NIL_P(named)) rb_raise(eRegexpError, "conditional capture is undefined");
      capture_id = NUM2LONG(named);
    }
    if (capture_id < 0) rb_raise(eRegexpError, "conditional capture is invalid");
    onibi_fragment_t yes = onibi_compile_node(onibi_hash_value(ast, "yes"), builder);
    onibi_fragment_t no = onibi_compile_node(onibi_hash_value(ast, "no"), builder);
    VALUE yes_guard = rb_ary_new();
    rb_ary_push(yes_guard, onibi_capture_test_action(capture_id, 1));
    onibi_append_values(yes_guard, yes.start_actions);
    VALUE no_guard = rb_ary_new();
    rb_ary_push(no_guard, onibi_capture_test_action(capture_id, 0));
    onibi_append_values(no_guard, no.start_actions);
    onibi_add_capture_guard(builder, yes.starts, yes_guard);
    onibi_add_capture_guard(builder, no.starts, no_guard);
    onibi_add_exit_guard(builder, yes.exits, yes.pending_actions);
    onibi_add_exit_guard(builder, no.exits, no.pending_actions);
    onibi_fragment_t result = onibi_fragment_empty();
    result.starts = rb_ary_dup(yes.starts);
    onibi_append_values(result.starts, no.starts);
    result.exits = rb_ary_dup(yes.exits);
    onibi_append_values(result.exits, no.exits);
    result.nullable = yes.nullable || no.nullable;
    result.lazy = yes.lazy;
    return result;
  }
  if (type == ID2SYM(rb_intern("atomic"))) {
    VALUE body = onibi_hash_value(ast, "body");
    if (!onibi_ast_atomic_simple(body))
      rb_raise(eRegexpError, "atomic subprogram requires dynamic call state");
    return onibi_compile_node(body, builder);
  }
  if (type == ID2SYM(rb_intern("lookahead")) || type == ID2SYM(rb_intern("lookbehind"))) {
    VALUE body = onibi_hash_value(ast, "body");
    if (!RB_TYPE_P(body, T_HASH))
      rb_raise(eRegexpError, "lookaround body has no literal sequence");
    VALUE children = onibi_hash_value(body, "children");
    if (!RB_TYPE_P(children, T_ARRAY))
      rb_raise(eRegexpError, "lookaround body has no literal sequence");
    VALUE bytes = rb_str_new(NULL, 0);
    VALUE predicates = rb_ary_new();
    for (long i = 0; i < RARRAY_LEN(children); i++) {
      VALUE child = rb_ary_entry(children, i);
      VALUE child_type = onibi_symbol_value(child, "type");
      if (child_type == ID2SYM(rb_intern("character_class")) ||
          child_type == ID2SYM(rb_intern("class_intersection"))) {
        VALUE predicate = rb_hash_new();
        rb_hash_aset(predicate, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern("bitmap")));
        rb_hash_aset(predicate, ID2SYM(rb_intern("bitmap")), onibi_class_bitmap(child, builder->ignorecase));
        rb_ary_push(predicates, predicate);
        continue;
      }
      if (child_type == ID2SYM(rb_intern("any"))) {
        VALUE predicate = rb_hash_new();
        rb_hash_aset(predicate, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern("any")));
        rb_hash_aset(predicate, ID2SYM(rb_intern("multiline")), builder->multiline ? Qtrue : Qfalse);
        rb_ary_push(predicates, predicate);
        continue;
      }
      if (child_type == ID2SYM(rb_intern("escape"))) {
        VALUE name = onibi_hash_value(child, "name");
        int simple = !NIL_P(name) &&
          (onibi_ascii_property_name_p(name) ||
           (RSTRING_LEN(name) == 1 && strchr("dDsSwWhH", RSTRING_PTR(name)[0]) != NULL));
        if (!simple) rb_raise(eRegexpError, "lookaround body has an unsupported escape");
        VALUE payload = rb_hash_dup(child);
        rb_hash_aset(payload, ID2SYM(rb_intern("ranges")), rb_ary_new());
        rb_hash_aset(payload, ID2SYM(rb_intern("children")), rb_ary_new());
        VALUE predicate = rb_hash_new();
        rb_hash_aset(predicate, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern("bitmap")));
        rb_hash_aset(predicate, ID2SYM(rb_intern("bitmap")), onibi_class_bitmap(payload, builder->ignorecase));
        rb_ary_push(predicates, predicate);
        continue;
      }
      if (child_type != ID2SYM(rb_intern("literal")))
        rb_raise(eRegexpError, "lookaround body is not a fixed literal/class sequence");
      VALUE predicate = rb_hash_new();
      rb_hash_aset(predicate, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern("byte")));
      rb_hash_aset(predicate, ID2SYM(rb_intern("byte")), onibi_hash_value(child, "byte"));
      rb_hash_aset(predicate, ID2SYM(rb_intern("ignorecase")), builder->ignorecase ? Qtrue : Qfalse);
      rb_ary_push(predicates, predicate);
      rb_str_cat(bytes, (const char[]){(char)NUM2INT(onibi_hash_value(child, "byte"))}, 1);
    }
    rb_obj_freeze(bytes);
    rb_obj_freeze(predicates);
    VALUE action = rb_hash_new();
    const char *assertion_op = type == ID2SYM(rb_intern("lookbehind")) ?
      "ASSERT_LOOKBEHIND" : "ASSERT_LOOKAHEAD";
    rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern(assertion_op)));
    rb_hash_aset(action, ID2SYM(rb_intern("positive")), onibi_hash_value(ast, "positive"));
    rb_hash_aset(action, ID2SYM(rb_intern("bytes")), bytes);
    if (RARRAY_LEN(predicates) > 0) rb_hash_aset(action, ID2SYM(rb_intern("predicates")), predicates);
    rb_hash_aset(action, ID2SYM(rb_intern("width")), LONG2NUM(RARRAY_LEN(predicates)));
    onibi_fragment_t result = onibi_fragment_empty();
    result.nullable = 1;
    rb_ary_push(result.start_actions, action);
    return result;
  }
  if (type == ID2SYM(rb_intern("capture"))) {
    VALUE capture_ast_key = onibi_hash_value(ast, "start");
    VALUE capture_id_value = rb_hash_aref(builder->capture_ids, capture_ast_key);
    long capture_id;
    if (NIL_P(capture_id_value)) {
      capture_id = builder->capture_count++;
      rb_hash_aset(builder->capture_ids, capture_ast_key, LONG2NUM(capture_id));
    } else capture_id = NUM2LONG(capture_id_value);
    onibi_fragment_t result = onibi_compile_node(onibi_hash_value(ast, "body"), builder);
    VALUE open = rb_hash_new(), close = rb_hash_new();
    rb_hash_aset(open, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("CAPTURE_OPEN")));
    rb_hash_aset(open, ID2SYM(rb_intern("slot")), LONG2NUM(2 * capture_id));
    rb_hash_aset(close, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("CAPTURE_CLOSE")));
    rb_hash_aset(close, ID2SYM(rb_intern("slot")), LONG2NUM(2 * capture_id + 1));
    VALUE capture_name = onibi_hash_value(ast, "name");
    char capture_name_key[32];
    snprintf(capture_name_key, sizeof(capture_name_key), "%ld", capture_id + 1);
    rb_hash_aset(builder->capture_bodies, rb_str_new_cstr(capture_name_key), onibi_hash_value(ast, "body"));
    if (!NIL_P(capture_name)) {
      rb_hash_aset(builder->capture_names, capture_name, LONG2NUM(capture_id));
      rb_hash_aset(builder->capture_bodies, capture_name, onibi_hash_value(ast, "body"));
    }
    rb_ary_push(result.start_actions, open);
    rb_ary_push(result.pending_actions, close);
    if (result.nullable) onibi_append_values(result.start_actions, result.pending_actions);
    return result;
  }
  if (type == ID2SYM(rb_intern("group")))
    return onibi_compile_node(onibi_hash_value(ast, "body"), builder);
  if (type == ID2SYM(rb_intern("quantifier"))) {
    VALUE min_value = onibi_hash_value(ast, "min"), max_value = onibi_hash_value(ast, "max");
    long min = NUM2LONG(min_value);
    VALUE atom = onibi_hash_value(ast, "atom");
    if (min == 0) builder->optional_seen = 1;
    if (RTEST(onibi_hash_value(ast, "possessive")) &&
        (NIL_P(max_value) || NUM2LONG(max_value) != min))
      rb_raise(eRegexpError, "variable possessive quantifier is not supported in RSeq");
    if (RTEST(onibi_hash_value(ast, "possessive")) && onibi_ast_has_capture(atom))
      rb_raise(eRegexpError, "possessive capture repeat is not supported in RSeq");
    if (!NIL_P(max_value) && min == 0 && NUM2LONG(max_value) == 0)
      return onibi_fragment_empty();
    if (!NIL_P(max_value) && min == 0 && NUM2LONG(max_value) == 1) {
      onibi_fragment_t result = onibi_compile_node(onibi_hash_value(ast, "atom"), builder);
      result.nullable = 1;
      result.lazy = !RTEST(onibi_hash_value(ast, "greedy"));
      return result;
    }
    long counter_slot = -1;
    if (!NIL_P(max_value) && NUM2LONG(max_value) != min)
      counter_slot = builder->counter_count++;
    onibi_fragment_t result = onibi_fragment_empty();
    result.starts = rb_ary_new(); result.exits = rb_ary_new(); result.nullable = min == 0;
    if (!NIL_P(max_value) && NUM2LONG(max_value) < min)
      rb_raise(eRegexpError, "invalid quantifier range");
    long max = NIL_P(max_value) ? -1 : NUM2LONG(max_value);
    if (max > ONIBI_RSEQ_REPEAT_UNROLL_LIMIT)
      rb_raise(eRegexpError, "quantifier exceeds RSeq representation limit");
    if (max >= 0 && max != min) {
      /* Counted repeats use one counter slot.  The first start edge
         initializes it.  Optional bodies use ordered test edges. */
      VALUE init = onibi_counter_action("COUNTER_INIT", counter_slot, Qnil);
      rb_hash_aset(init, ID2SYM(rb_intern("value")), INT2NUM(min > 0 ? 1 : 0));
      rb_ary_push(result.start_actions, init);
    }
    for (long i = 0; i < min; i++) {
      onibi_fragment_t part = onibi_compile_node(atom, builder);
      if (i == 0) result.starts = part.starts;
      else {
        VALUE actions = rb_ary_new();
        if (counter_slot >= 0)
          rb_ary_push(actions, onibi_counter_action("COUNTER_INCREMENT", counter_slot, Qnil));
        onibi_connect_actions(builder, result.exits, part.starts, actions);
      }
      result.exits = part.exits;
    }
    if (max >= 0 && max > min) {
      long optional = max - min;
      for (long i = 0; i < optional; i++) {
        onibi_fragment_t part = onibi_compile_node(atom, builder);
        if (RARRAY_LEN(result.starts) == 0) result.starts = part.starts;
        VALUE repeat_actions = rb_ary_new();
        rb_ary_push(repeat_actions, onibi_counter_action("TEST_COUNTER_LT", counter_slot, LONG2NUM(max)));
        rb_ary_push(repeat_actions, onibi_counter_action("COUNTER_INCREMENT", counter_slot, Qnil));
        if (RARRAY_LEN(result.exits) > 0)
          onibi_connect_actions(builder, result.exits, part.starts, repeat_actions);
        VALUE next_exits = rb_ary_dup(result.exits);
        onibi_append_values(next_exits, part.exits);
        result.exits = next_exits;
      }
      rb_ary_push(result.pending_actions, onibi_counter_action("TEST_COUNTER_GE", counter_slot, LONG2NUM(min)));
    } else if (NIL_P(max_value)) {
      onibi_fragment_t repeat = onibi_compile_node(atom, builder);
      if (RARRAY_LEN(result.starts) == 0) result.starts = repeat.starts;
      if (!repeat.nullable) onibi_append_values(result.start_actions, repeat.start_actions);
      if (RARRAY_LEN(result.exits) > 0) {
        if (repeat.nullable) {
          onibi_connect(builder, result.exits, repeat.starts);
        } else {
          VALUE next_actions = rb_ary_dup(repeat.pending_actions);
          onibi_append_values(next_actions, repeat.start_actions);
          onibi_connect_actions(builder, result.exits, repeat.starts, next_actions);
        }
      }
      if (repeat.nullable) {
        onibi_connect(builder, repeat.exits, repeat.starts);
      } else {
        VALUE loop_actions = rb_ary_dup(repeat.pending_actions);
        onibi_append_values(loop_actions, repeat.start_actions);
        onibi_connect_actions(builder, repeat.exits, repeat.starts, loop_actions);
      }
      onibi_append_values(result.pending_actions, repeat.pending_actions);
      for (long i = 0; i < RARRAY_LEN(repeat.exits); i++) rb_ary_push(result.exits, rb_ary_entry(repeat.exits, i));
    }
    result.lazy = !RTEST(onibi_hash_value(ast, "greedy"));
    return result;
  }
  rb_raise(eRegexpError, "unsupported AST node");
  return onibi_fragment_empty();
}

static VALUE onibi_compiler_compile(VALUE self, VALUE parsed) {
  (void)self;
  VALUE ast = onibi_hash_value(parsed, "ast");
  if (NIL_P(ast)) rb_raise(rb_eArgError, "compiler requires parser output");
  VALUE parsed_options = onibi_hash_value(parsed, "options");
  int ignorecase = 0;
  int multiline = 0;
  for (long i = 0; i < RARRAY_LEN(parsed_options); i++)
    if (rb_str_equal(rb_ary_entry(parsed_options, i), rb_str_new_cstr("ignorecase"))) ignorecase = 1;
    else if (rb_str_equal(rb_ary_entry(parsed_options, i), rb_str_new_cstr("multiline"))) multiline = 1;
  onibi_gir_builder_t builder = { rb_ary_new(), rb_ary_new(), 0, 0, 0, rb_hash_new(), rb_hash_new(), rb_hash_new(), rb_hash_new(), rb_hash_new(), rb_hash_new(), ignorecase, multiline, 0 };
  onibi_fragment_t fragment = onibi_compile_node(ast, &builder);
  long accept = builder.next_id++;
  onibi_gir_state(&builder, accept, rb_intern("G_ACCEPT"), Qnil);
  VALUE accept_starts = rb_ary_new();
  rb_ary_push(accept_starts, LONG2NUM(accept));
  if (fragment.lazy) onibi_connect_prepend_actions(&builder, fragment.exits, accept_starts, fragment.pending_actions);
  else onibi_connect_actions(&builder, fragment.exits, accept_starts, fragment.pending_actions);
  VALUE start_edges = rb_ary_new();
  if (fragment.nullable && fragment.lazy) {
    VALUE edge = rb_hash_new();
    rb_hash_aset(edge, ID2SYM(rb_intern("to")), LONG2NUM(accept));
    VALUE actions = rb_ary_dup(fragment.start_actions);
    onibi_append_values(actions, fragment.pending_actions);
    rb_hash_aset(edge, ID2SYM(rb_intern("actions")), actions);
    rb_ary_push(start_edges, edge);
  }
  for (long i = 0; i < RARRAY_LEN(fragment.starts); i++) {
    VALUE edge = rb_hash_new();
    VALUE destination = rb_ary_entry(fragment.starts, i);
    VALUE actions = rb_ary_new();
    VALUE guard = rb_hash_aref(builder.capture_guards, destination);
    onibi_append_values(actions, fragment.start_actions);
    if (!NIL_P(guard)) onibi_append_values(actions, guard);
    rb_hash_aset(edge, ID2SYM(rb_intern("to")), destination);
    rb_hash_aset(edge, ID2SYM(rb_intern("actions")), actions);
    rb_ary_push(start_edges, edge);
  }
  if (fragment.nullable && !fragment.lazy) {
    VALUE edge = rb_hash_new();
    rb_hash_aset(edge, ID2SYM(rb_intern("to")), LONG2NUM(accept));
    VALUE actions = rb_ary_dup(fragment.start_actions);
    onibi_append_values(actions, fragment.pending_actions);
    rb_hash_aset(edge, ID2SYM(rb_intern("actions")), actions);
    rb_ary_push(start_edges, edge);
  }
  for (long i = 0; i < RARRAY_LEN(start_edges); i++) {
    VALUE edge = rb_ary_entry(start_edges, i);
    rb_obj_freeze(onibi_hash_value(edge, "actions"));
    rb_obj_freeze(edge);
  }
  rb_obj_freeze(start_edges);
  onibi_freeze_gir_arrays(&builder);
  VALUE graph = rb_hash_new();
  rb_hash_aset(graph, ID2SYM(rb_intern("states")), builder.states);
  rb_hash_aset(graph, ID2SYM(rb_intern("edges")), builder.edges);
  rb_hash_aset(graph, ID2SYM(rb_intern("start_edges")), start_edges);
  rb_hash_aset(graph, ID2SYM(rb_intern("accept")), LONG2NUM(accept));
  VALUE subprograms = rb_ary_new();
  rb_obj_freeze(subprograms);
  rb_hash_aset(graph, ID2SYM(rb_intern("subprograms")), subprograms);
  rb_hash_aset(graph, ID2SYM(rb_intern("capture_count")), LONG2NUM(builder.capture_count));
  long counter_count = builder.counter_count;
  for (long i = 0; i < RARRAY_LEN(builder.edges); i++) {
    VALUE actions = onibi_hash_value(rb_ary_entry(builder.edges, i), "actions");
    for (long j = 0; j < RARRAY_LEN(actions); j++) {
      ID op = SYM2ID(onibi_hash_value(rb_ary_entry(actions, j), "op"));
      if (op == rb_intern("COUNTER_INIT") || op == rb_intern("COUNTER_INCREMENT") ||
          op == rb_intern("TEST_COUNTER_LT") || op == rb_intern("TEST_COUNTER_GE")) {
        long slot = NUM2LONG(onibi_hash_value(rb_ary_entry(actions, j), "slot"));
        if (slot + 1 > counter_count) counter_count = slot + 1;
      }
    }
  }
  for (long i = 0; i < RARRAY_LEN(start_edges); i++) {
    VALUE actions = onibi_hash_value(rb_ary_entry(start_edges, i), "actions");
    for (long j = 0; j < RARRAY_LEN(actions); j++) {
      ID op = SYM2ID(onibi_hash_value(rb_ary_entry(actions, j), "op"));
      if (op == rb_intern("COUNTER_INIT") || op == rb_intern("COUNTER_INCREMENT") ||
          op == rb_intern("TEST_COUNTER_LT") || op == rb_intern("TEST_COUNTER_GE")) {
        long slot = NUM2LONG(onibi_hash_value(rb_ary_entry(actions, j), "slot"));
        if (slot + 1 > counter_count) counter_count = slot + 1;
      }
    }
  }
  rb_hash_aset(graph, ID2SYM(rb_intern("counter_count")), LONG2NUM(counter_count));
  rb_hash_aset(graph, ID2SYM(rb_intern("subprogram_count")), LONG2NUM(RARRAY_LEN(subprograms)));
  rb_hash_aset(graph, ID2SYM(rb_intern("options")), onibi_hash_value(parsed, "options"));
  onibi_gir_validate(graph);
  rb_obj_freeze(graph);
  VALUE result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("ast")), ast);
  rb_hash_aset(result, ID2SYM(rb_intern("options")), onibi_hash_value(parsed, "options"));
  rb_hash_aset(result, ID2SYM(rb_intern("graph")), graph);
  rb_obj_freeze(result);
  return result;
}

static uint8_t onibi_rseq_action_flags(ID op) {
  if (op == rb_intern("CAPTURE_CLOSE")) return ONIBI_RA_CAPTURE_CLOSE;
  if (op == rb_intern("TEST_CAPTURE")) return ONIBI_RA_TEST_CAPTURE_SET;
  if (op == rb_intern("TEST_COUNTER_GE")) return ONIBI_RA_COUNTER_GE;
  return 0;
}

static uint16_t onibi_rseq_assert_kind(ID op) {
  if (op == rb_intern("ASSERT_BEGIN_BUFFER")) return ONIBI_RAP_BEGIN_BUFFER;
  if (op == rb_intern("ASSERT_END_BUFFER")) return ONIBI_RAP_END_BUFFER;
  if (op == rb_intern("ASSERT_BEGIN_LINE")) return ONIBI_RAP_BEGIN_LINE;
  if (op == rb_intern("ASSERT_END_LINE")) return ONIBI_RAP_END_LINE;
  if (op == rb_intern("ASSERT_SEMI_END_BUFFER")) return ONIBI_RAP_SEMI_END_BUFFER;
  if (op == rb_intern("ASSERT_SEARCH_ORIGIN")) return ONIBI_RAP_SEARCH_ORIGIN;
  if (op == rb_intern("ASSERT_WORD_BOUNDARY")) return ONIBI_RAP_WORD_BOUNDARY;
  if (op == rb_intern("ASSERT_NONWORD_BOUNDARY")) return ONIBI_RAP_NONWORD_BOUNDARY;
  if (op == rb_intern("ASSERT_LOOKAHEAD")) return ONIBI_RAP_LOOKAHEAD;
  if (op == rb_intern("ASSERT_LOOKBEHIND")) return ONIBI_RAP_LOOKBEHIND;
  return 0;
}

static VALUE onibi_rseq_lower(VALUE self, VALUE compiled) {
  (void)self;
  VALUE graph = onibi_hash_value(compiled, "graph");
  if (NIL_P(graph)) rb_raise(rb_eArgError, "RSeq lowering requires compiler output");
  VALUE states = onibi_hash_value(graph, "states");
  VALUE edges = onibi_hash_value(graph, "edges");
  VALUE start_edges = onibi_hash_value(graph, "start_edges");
  VALUE subprograms = onibi_hash_value(graph, "subprograms");
  if (!RTEST(rb_obj_frozen_p(compiled)) || !RTEST(rb_obj_frozen_p(graph)) ||
      !RTEST(rb_obj_frozen_p(states)) || !RTEST(rb_obj_frozen_p(edges)) ||
      !RTEST(rb_obj_frozen_p(start_edges)) || !RB_TYPE_P(subprograms, T_ARRAY) ||
      !RTEST(rb_obj_frozen_p(subprograms)))
    rb_raise(rb_eArgError, "RSeq lowering requires immutable GIR");
  long state_count = RARRAY_LEN(states);
  long accept_state = NUM2LONG(onibi_hash_value(graph, "accept"));
  if (accept_state < 0 || accept_state >= state_count)
    rb_raise(rb_eArgError, "RSeq lowering received an invalid accept state");
  for (long i = 0; i < RARRAY_LEN(edges); i++) {
    VALUE edge = rb_ary_entry(edges, i);
    long from = NUM2LONG(onibi_hash_value(edge, "from"));
    long to = NUM2LONG(onibi_hash_value(edge, "to"));
    if (from < 0 || from >= state_count || to < 0 || to >= state_count)
      rb_raise(rb_eArgError, "RSeq lowering received an invalid edge");
  }
  for (long i = 0; i < RARRAY_LEN(start_edges); i++) {
    long to = NUM2LONG(onibi_hash_value(rb_ary_entry(start_edges, i), "to"));
    if (to < 0 || to >= state_count)
      rb_raise(rb_eArgError, "RSeq lowering received an invalid start edge");
  }
  VALUE class_payloads = rb_ary_new();
  for (long i = 0; i < RARRAY_LEN(states); i++) {
    VALUE state = rb_ary_entry(states, i);
    if (SYM2ID(onibi_hash_value(state, "op")) != rb_intern("G_CLASS")) continue;
    VALUE payload = onibi_hash_value(state, "payload");
    int found = 0;
    for (long j = 0; j < RARRAY_LEN(class_payloads); j++) {
      VALUE prior = rb_ary_entry(class_payloads, j);
      if (rb_equal(onibi_hash_value(prior, "bitmap"), onibi_hash_value(payload, "bitmap")) &&
          rb_equal(onibi_hash_value(prior, "negated"), onibi_hash_value(payload, "negated"))) {
        found = 1;
        break;
      }
    }
    if (!found) rb_ary_push(class_payloads, payload);
  }
  uint32_t class_count = (uint32_t)RARRAY_LEN(class_payloads);
  VALUE actions = rb_ary_new();
  VALUE r_edges = rb_ary_new();
  for (long i = 0; i < RARRAY_LEN(edges); i++) {
    VALUE edge = rb_ary_entry(edges, i);
    VALUE edge_actions = onibi_hash_value(edge, "actions");
    if (!RTEST(rb_obj_frozen_p(edge)) || !RTEST(rb_obj_frozen_p(edge_actions)))
      rb_raise(rb_eArgError, "RSeq lowering requires immutable GIR edges");
    VALUE out = rb_hash_new();
    rb_hash_aset(out, ID2SYM(rb_intern("from")), onibi_hash_value(edge, "from"));
    rb_hash_aset(out, ID2SYM(rb_intern("to")), onibi_hash_value(edge, "to"));
    rb_hash_aset(out, ID2SYM(rb_intern("action_offset")),
                 RARRAY_LEN(edge_actions) == 0 ? INT2NUM(0) : LONG2NUM(RARRAY_LEN(actions)));
    VALUE copied_actions = rb_ary_new();
    for (long j = 0; j < RARRAY_LEN(edge_actions); j++) {
      VALUE action = rb_ary_entry(edge_actions, j);
      VALUE copy = onibi_deep_freeze(rb_hash_dup(action));
      rb_ary_push(copied_actions, copy);
      rb_ary_push(actions, copy);
    }
    if (RARRAY_LEN(edge_actions) > 0) {
      VALUE terminator = rb_hash_new();
      rb_hash_aset(terminator, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("END")));
      terminator = onibi_deep_freeze(terminator);
      rb_ary_push(copied_actions, terminator);
      rb_ary_push(actions, terminator);
    }
    rb_obj_freeze(copied_actions);
    rb_hash_aset(out, ID2SYM(rb_intern("actions")), copied_actions);
    rb_obj_freeze(out);
    rb_ary_push(r_edges, out);
  }
  VALUE r_start_edges = rb_ary_new();
  for (long i = 0; i < RARRAY_LEN(start_edges); i++) {
    VALUE edge = rb_ary_entry(start_edges, i);
    VALUE edge_actions = onibi_hash_value(edge, "actions");
    if (!RTEST(rb_obj_frozen_p(edge)) || !RTEST(rb_obj_frozen_p(edge_actions)))
      rb_raise(rb_eArgError, "RSeq lowering requires immutable GIR start edges");
    VALUE out = rb_hash_new();
    rb_hash_aset(out, ID2SYM(rb_intern("to")), onibi_hash_value(edge, "to"));
    rb_hash_aset(out, ID2SYM(rb_intern("action_offset")),
                 RARRAY_LEN(edge_actions) == 0 ? INT2NUM(0) : LONG2NUM(RARRAY_LEN(actions)));
    VALUE copied_actions = rb_ary_new();
    for (long j = 0; j < RARRAY_LEN(edge_actions); j++) {
      VALUE action = rb_ary_entry(edge_actions, j);
      VALUE copy = onibi_deep_freeze(rb_hash_dup(action));
      rb_ary_push(copied_actions, copy);
      rb_ary_push(actions, copy);
    }
    if (RARRAY_LEN(edge_actions) > 0) {
      VALUE terminator = rb_hash_new();
      rb_hash_aset(terminator, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("END")));
      terminator = onibi_deep_freeze(terminator);
      rb_ary_push(copied_actions, terminator);
      rb_ary_push(actions, terminator);
    }
    rb_obj_freeze(copied_actions);
    rb_hash_aset(out, ID2SYM(rb_intern("actions")), copied_actions);
    rb_obj_freeze(out);
    rb_ary_push(r_start_edges, out);
  }
  VALUE header = rb_hash_new();
  VALUE options = onibi_hash_value(compiled, "options");
  int ignorecase = 0;
  int multiline = 0;
  for (long i = 0; i < RARRAY_LEN(options); i++)
    if (rb_str_equal(rb_ary_entry(options, i), rb_str_new_cstr("ignorecase"))) ignorecase = 1;
    else if (rb_str_equal(rb_ary_entry(options, i), rb_str_new_cstr("multiline"))) multiline = 1;
  uint64_t physical_edge_count = (uint64_t)RARRAY_LEN(r_edges) + (uint64_t)RARRAY_LEN(start_edges);
  VALUE literal_payloads = rb_ary_new();
  for (long i = 0; i < RARRAY_LEN(states); i++) {
    ID op = SYM2ID(onibi_hash_value(rb_ary_entry(states, i), "op"));
    if (op != rb_intern("G_CHAR")) continue;
    VALUE payload = onibi_hash_value(rb_ary_entry(states, i), "payload");
    int found = 0;
    for (long j = 0; j < RARRAY_LEN(literal_payloads); j++) {
      VALUE prior = rb_ary_entry(literal_payloads, j);
      if (rb_equal(onibi_hash_value(prior, "byte"), onibi_hash_value(payload, "byte")) &&
          rb_equal(onibi_hash_value(prior, "ignorecase"), onibi_hash_value(payload, "ignorecase"))) {
        found = 1;
        break;
      }
    }
    if (!found) rb_ary_push(literal_payloads, payload);
  }
  uint32_t literal_count = (uint32_t)RARRAY_LEN(literal_payloads);
  uint64_t class_section_size = (uint64_t)class_count * (sizeof(OnibiClassDesc) + 32U);
  uint64_t literal_desc_size = (uint64_t)literal_count * sizeof(OnibiLiteralDesc);
  uint64_t literal_data_size = ((uint64_t)literal_count + 3U) & ~UINT64_C(3);
  uint64_t physical_size = sizeof(OnibiRSeqHeader) +
    (uint64_t)sizeof(OnibiRState) * (uint64_t)RARRAY_LEN(states) +
    (uint64_t)sizeof(OnibiREdge) * physical_edge_count +
    (uint64_t)sizeof(OnibiRAction) * (uint64_t)RARRAY_LEN(actions) +
    class_section_size + literal_desc_size + literal_data_size;
  if (RARRAY_LEN(states) > UINT32_MAX || physical_edge_count > UINT32_MAX ||
      RARRAY_LEN(actions) > UINT32_MAX || physical_size > UINT32_MAX)
    rb_raise(eRegexpError, "RSeq program exceeds the v1 size limit");
  uint32_t features = 0, capture_count = 0, counter_count = 0;
  for (long i = 0; i < RARRAY_LEN(states); i++) {
    ID op = SYM2ID(onibi_hash_value(rb_ary_entry(states, i), "op"));
    if (op == rb_intern("G_BACKREF")) features |= 1U;
  }
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    ID op = SYM2ID(onibi_hash_value(rb_ary_entry(actions, i), "op"));
    if (op == rb_intern("CAPTURE_OPEN")) { capture_count++; features |= 2U; }
    if (op == rb_intern("COUNTER_INIT")) { counter_count++; features |= 4U; }
    if (op == rb_intern("MATCH_RESET")) features |= 8U;
    if (op == rb_intern("ASSERT_BEGIN_BUFFER") || op == rb_intern("ASSERT_END_BUFFER") ||
        op == rb_intern("ASSERT_BEGIN_LINE") || op == rb_intern("ASSERT_END_LINE") ||
        op == rb_intern("ASSERT_SEMI_END_BUFFER") || op == rb_intern("ASSERT_SEARCH_ORIGIN") || op == rb_intern("ASSERT_WORD_BOUNDARY") ||
        op == rb_intern("ASSERT_NONWORD_BOUNDARY") || op == rb_intern("ASSERT_LOOKAHEAD") ||
        op == rb_intern("ASSERT_LOOKBEHIND")) features |= 16U;
  }
  rb_hash_aset(header, ID2SYM(rb_intern("features")), UINT2NUM(features));
  rb_hash_aset(header, ID2SYM(rb_intern("class_count")), UINT2NUM(class_count));
  rb_hash_aset(header, ID2SYM(rb_intern("capture_count")), UINT2NUM(capture_count));
  rb_hash_aset(header, ID2SYM(rb_intern("semantic_capture_count")), UINT2NUM(capture_count));
  rb_hash_aset(header, ID2SYM(rb_intern("subprogram_count")), UINT2NUM((uint32_t)RARRAY_LEN(subprograms)));
  rb_hash_aset(header, ID2SYM(rb_intern("counter_count")), UINT2NUM(counter_count));
  rb_hash_aset(header, ID2SYM(rb_intern("literal_count")), UINT2NUM(literal_count));
  rb_hash_aset(header, ID2SYM(rb_intern("version")), INT2NUM(1));
  rb_hash_aset(header, ID2SYM(rb_intern("ignorecase")), ignorecase ? Qtrue : Qfalse);
  rb_hash_aset(header, ID2SYM(rb_intern("multiline")), multiline ? Qtrue : Qfalse);
  rb_hash_aset(header, ID2SYM(rb_intern("state_count")), LONG2NUM(RARRAY_LEN(states)));
  rb_hash_aset(header, ID2SYM(rb_intern("edge_count")), LONG2NUM(RARRAY_LEN(r_edges)));
  rb_hash_aset(header, ID2SYM(rb_intern("action_count")), LONG2NUM(RARRAY_LEN(actions)));
  rb_hash_aset(header, ID2SYM(rb_intern("start_edge_base")), LONG2NUM(RARRAY_LEN(r_edges)));
  rb_hash_aset(header, ID2SYM(rb_intern("start_edge_count")), LONG2NUM(RARRAY_LEN(start_edges)));
  OnibiRSeqHeader physical;
  memset(&physical, 0, sizeof(physical));
  physical.magic = ONIBI_RSEQ_MAGIC;
  physical.version = ONIBI_RSEQ_VERSION;
  physical.flags = (ignorecase ? 1 : 0) | (multiline ? 2 : 0);
  physical.features = features;
  physical.class_count = class_count;
  physical.capture_count = capture_count;
  physical.semantic_capture_count = capture_count;
  physical.counter_count = counter_count;
  physical.start_edge_base = (uint32_t)RARRAY_LEN(r_edges);
  for (long i = 0; i < RARRAY_LEN(states); i++) {
    ID op = SYM2ID(onibi_hash_value(rb_ary_entry(states, i), "op"));
    if (op == rb_intern("G_GRAPHEME") || op == rb_intern("G_BACKREF") || op == rb_intern("G_CALL") ||
        op == rb_intern("G_ATOMIC") || op == rb_intern("G_ABSENT")) {
      physical.exec_kind = 2;
      break;
    }
    if (op == rb_intern("G_ACCEPT")) continue;
  }
  if (physical.exec_kind == 0) {
    for (long i = 0; i < RARRAY_LEN(actions); i++) {
      ID op = SYM2ID(onibi_hash_value(rb_ary_entry(actions, i), "op"));
      if (op == rb_intern("CAPTURE_OPEN") || op == rb_intern("CAPTURE_CLOSE") ||
          op == rb_intern("COUNTER_INIT") || op == rb_intern("COUNTER_INCREMENT") ||
          op == rb_intern("TEST_COUNTER_LT") || op == rb_intern("TEST_COUNTER_GE")) {
        physical.exec_kind = 1;
        break;
      }
    }
    for (long i = 0; i < RARRAY_LEN(start_edges) && physical.exec_kind == 0; i++) {
      VALUE edge_actions = onibi_hash_value(rb_ary_entry(start_edges, i), "actions");
      for (long j = 0; j < RARRAY_LEN(edge_actions); j++) {
        ID op = SYM2ID(onibi_hash_value(rb_ary_entry(edge_actions, j), "op"));
        if (op == rb_intern("CAPTURE_OPEN") || op == rb_intern("COUNTER_INIT")) {
          physical.exec_kind = 1;
          break;
        }
      }
    }
  }
  physical.state_count = (uint32_t)RARRAY_LEN(states);
  physical.edge_count = (uint32_t)(RARRAY_LEN(r_edges) + RARRAY_LEN(start_edges));
  physical.action_count = (uint32_t)RARRAY_LEN(actions);
  physical.start_edge_count = (uint32_t)RARRAY_LEN(r_start_edges);
  uint64_t offset = sizeof(OnibiRSeqHeader);
  physical.states_offset = (uint32_t)offset;
  offset += (uint64_t)sizeof(OnibiRState) * (uint64_t)RARRAY_LEN(states);
  physical.edges_offset = (uint32_t)offset;
  offset += (uint64_t)sizeof(OnibiREdge) * (uint64_t)physical.edge_count;
  physical.actions_offset = (uint32_t)offset;
  offset += (uint64_t)sizeof(OnibiRAction) * (uint64_t)RARRAY_LEN(actions);
  physical.classes_offset = (uint32_t)offset;
  offset += class_section_size;
  physical.literals_offset = (uint32_t)offset;
  offset += literal_data_size;
  physical.descriptors_offset = (uint32_t)offset;
  offset += literal_desc_size;
  physical.subprograms_offset = (uint32_t)offset;
  physical.blob_size = (uint32_t)offset;
  rb_hash_aset(header, ID2SYM(rb_intern("states_offset")), UINT2NUM(physical.states_offset));
  rb_hash_aset(header, ID2SYM(rb_intern("edges_offset")), UINT2NUM(physical.edges_offset));
  rb_hash_aset(header, ID2SYM(rb_intern("actions_offset")), UINT2NUM(physical.actions_offset));
  rb_hash_aset(header, ID2SYM(rb_intern("classes_offset")), UINT2NUM(physical.classes_offset));
  rb_hash_aset(header, ID2SYM(rb_intern("literals_offset")), UINT2NUM(physical.literals_offset));
  rb_hash_aset(header, ID2SYM(rb_intern("descriptors_offset")), UINT2NUM(physical.descriptors_offset));
  rb_hash_aset(header, ID2SYM(rb_intern("subprograms_offset")), UINT2NUM(physical.subprograms_offset));
  rb_hash_aset(header, ID2SYM(rb_intern("blob_size")), UINT2NUM(physical.blob_size));
  VALUE blob = rb_str_new(NULL, (long)offset);
  memset(RSTRING_PTR(blob), 0, (size_t)offset);
  memcpy(RSTRING_PTR(blob), &physical, sizeof(physical));
  OnibiRState *physical_states = (OnibiRState *)(RSTRING_PTR(blob) + physical.states_offset);
  uint32_t class_index = 0, literal_index = 0;
  for (long i = 0; i < RARRAY_LEN(states); i++) {
    VALUE state = rb_ary_entry(states, i);
    ID op = SYM2ID(onibi_hash_value(state, "op"));
    physical_states[i].op = (uint8_t)(op == rb_intern("G_CHAR") ? ONIBI_RS_CHAR :
      op == rb_intern("G_CLASS") ? ONIBI_RS_CLASS : op == rb_intern("G_ANY") ? ONIBI_RS_ANY :
      op == rb_intern("G_GRAPHEME") ? ONIBI_RS_GRAPHEME :
      op == rb_intern("G_BACKREF") ? ONIBI_RS_BACKREF : op == rb_intern("G_CALL") ? ONIBI_RS_CALL :
      op == rb_intern("G_ATOMIC") ? ONIBI_RS_ATOMIC : op == rb_intern("G_ABSENT") ? ONIBI_RS_ABSENT :
      op == rb_intern("G_ACCEPT") ? 0 : 0xff);
    uint32_t edge_base = 0;
    uint16_t edge_count = 0;
    for (long e = 0; e < RARRAY_LEN(r_edges); e++) {
      VALUE edge = rb_ary_entry(r_edges, e);
      if (NUM2LONG(onibi_hash_value(edge, "from")) != i) continue;
      if (edge_count == 0) edge_base = (uint32_t)e;
      edge_count++;
    }
    physical_states[i].edge_base = edge_base;
    physical_states[i].edge_count = edge_count;
    if (op == rb_intern("G_CLASS")) {
      VALUE payload = onibi_hash_value(rb_ary_entry(states, i), "payload");
      class_index = 0;
      for (long j = 0; j < RARRAY_LEN(class_payloads); j++) {
        VALUE prior = rb_ary_entry(class_payloads, j);
        if (rb_equal(onibi_hash_value(prior, "bitmap"), onibi_hash_value(payload, "bitmap")) &&
            rb_equal(onibi_hash_value(prior, "negated"), onibi_hash_value(payload, "negated"))) break;
        class_index++;
      }
      physical_states[i].payload = class_index;
    }
    else if (op == rb_intern("G_CHAR")) {
      VALUE payload = onibi_hash_value(rb_ary_entry(states, i), "payload");
      literal_index = 0;
      for (long j = 0; j < RARRAY_LEN(literal_payloads); j++) {
        VALUE prior = rb_ary_entry(literal_payloads, j);
        if (rb_equal(onibi_hash_value(prior, "byte"), onibi_hash_value(payload, "byte")) &&
            rb_equal(onibi_hash_value(prior, "ignorecase"), onibi_hash_value(payload, "ignorecase"))) break;
        literal_index++;
      }
      physical_states[i].payload = literal_index;
    }
  }
  OnibiREdge *physical_edges = (OnibiREdge *)(RSTRING_PTR(blob) + physical.edges_offset);
  for (long i = 0; i < RARRAY_LEN(r_edges); i++) {
    VALUE edge = rb_ary_entry(r_edges, i);
    uint32_t destination = (uint32_t)NUM2ULONG(onibi_hash_value(edge, "to"));
    if (destination == (uint32_t)(RARRAY_LEN(states) - 1)) destination = ONIBI_ACCEPT_STATE;
    physical_edges[i].destination = destination;
    uint32_t action_index = (uint32_t)NUM2ULONG(onibi_hash_value(edge, "action_offset"));
    physical_edges[i].action_offset = action_index == 0 && RARRAY_LEN(onibi_hash_value(edge, "actions")) == 0 ? 0 :
      (uint32_t)(sizeof(OnibiRAction) * (action_index + 1));
  }
  for (long i = 0; i < RARRAY_LEN(r_start_edges); i++) {
    VALUE edge = rb_ary_entry(r_start_edges, i);
    physical_edges[RARRAY_LEN(r_edges) + i].destination = (uint32_t)NUM2ULONG(onibi_hash_value(edge, "to"));
    uint32_t action_index = (uint32_t)NUM2ULONG(onibi_hash_value(edge, "action_offset"));
    physical_edges[RARRAY_LEN(r_edges) + i].action_offset = RARRAY_LEN(onibi_hash_value(edge, "actions")) == 0 ? 0 :
      (uint32_t)(sizeof(OnibiRAction) * (action_index + 1));
  }
  OnibiRAction *physical_actions = (OnibiRAction *)(RSTRING_PTR(blob) + physical.actions_offset);
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    ID op = SYM2ID(onibi_hash_value(rb_ary_entry(actions, i), "op"));
    physical_actions[i].op = (uint8_t)(op == rb_intern("CAPTURE_OPEN") || op == rb_intern("CAPTURE_CLOSE") ? ONIBI_RA_CAPTURE :
      op == rb_intern("MATCH_RESET") ? ONIBI_RA_MATCH_RESET :
      op == rb_intern("ASSERT_BEGIN_BUFFER") || op == rb_intern("ASSERT_END_BUFFER") ||
      op == rb_intern("ASSERT_BEGIN_LINE") || op == rb_intern("ASSERT_END_LINE") ||
      op == rb_intern("ASSERT_SEMI_END_BUFFER") || op == rb_intern("ASSERT_SEARCH_ORIGIN") ||
      op == rb_intern("ASSERT_WORD_BOUNDARY") || op == rb_intern("ASSERT_NONWORD_BOUNDARY") ||
      op == rb_intern("ASSERT_LOOKAHEAD") || op == rb_intern("ASSERT_LOOKBEHIND") ? ONIBI_RA_ASSERT_POSITION :
      op == rb_intern("TEST_CAPTURE") ? ONIBI_RA_TEST_CAPTURE :
      op == rb_intern("COUNTER_INIT") ? ONIBI_RA_COUNTER_SET :
      op == rb_intern("COUNTER_INCREMENT") ? ONIBI_RA_COUNTER_ADD :
      op == rb_intern("TEST_COUNTER_LT") || op == rb_intern("TEST_COUNTER_GE") ? ONIBI_RA_COUNTER_TEST : ONIBI_RA_END);
    physical_actions[i].flags = onibi_rseq_action_flags(op);
    if (op == rb_intern("TEST_CAPTURE") && !RTEST(onibi_hash_value(rb_ary_entry(actions, i), "set")))
      physical_actions[i].flags = ONIBI_RA_TEST_CAPTURE_UNSET;
    physical_actions[i].arg16 = onibi_rseq_assert_kind(op);
    if (op == rb_intern("ASSERT_LOOKAHEAD") || op == rb_intern("ASSERT_LOOKBEHIND")) {
      int positive = RTEST(onibi_hash_value(rb_ary_entry(actions, i), "positive"));
      physical_actions[i].flags = op == rb_intern("ASSERT_LOOKAHEAD") ?
        (positive ? 1 : 2) : (positive ? 5 : 6);
    }
    VALUE slot = rb_hash_aref(rb_ary_entry(actions, i), ID2SYM(rb_intern("slot")));
    if (!NIL_P(slot)) physical_actions[i].arg16 = (uint16_t)NUM2ULONG(slot);
    VALUE limit = rb_hash_aref(rb_ary_entry(actions, i), ID2SYM(rb_intern("limit")));
    if (!NIL_P(limit)) physical_actions[i].arg32 = (uint32_t)NUM2ULONG(limit);
    VALUE value = rb_hash_aref(rb_ary_entry(actions, i), ID2SYM(rb_intern("value")));
    if (!NIL_P(value)) physical_actions[i].arg32 = (uint32_t)NUM2ULONG(value);
    VALUE width = rb_hash_aref(rb_ary_entry(actions, i), ID2SYM(rb_intern("width")));
    if (!NIL_P(width)) physical_actions[i].arg32 = (uint32_t)NUM2ULONG(width);
  }
  OnibiClassDesc *class_descs = (OnibiClassDesc *)(RSTRING_PTR(blob) + physical.classes_offset);
  unsigned char *class_data = (unsigned char *)(class_descs + class_count);
  class_index = 0;
  for (long i = 0; i < RARRAY_LEN(class_payloads); i++) {
    VALUE payload = rb_ary_entry(class_payloads, i);
    VALUE bitmap = onibi_hash_value(payload, "bitmap");
    class_descs[class_index].data_offset = (uint32_t)(physical.classes_offset + class_count * sizeof(OnibiClassDesc) + class_index * 32U);
    class_descs[class_index].data_length = 32;
    class_descs[class_index].kind = 0;
    class_descs[class_index].flags = RTEST(onibi_hash_value(payload, "negated")) ? 1 : 0;
    if (!NIL_P(bitmap) && RSTRING_LEN(bitmap) == 32) memcpy(class_data + class_index * 32U, RSTRING_PTR(bitmap), 32);
    class_index++;
  }
  unsigned char *literal_data = (unsigned char *)(RSTRING_PTR(blob) + physical.literals_offset);
  OnibiLiteralDesc *literal_descs = (OnibiLiteralDesc *)(RSTRING_PTR(blob) + physical.descriptors_offset);
  literal_index = 0;
  for (long i = 0; i < RARRAY_LEN(literal_payloads); i++) {
    VALUE payload = rb_ary_entry(literal_payloads, i);
    literal_descs[literal_index].data_offset = physical.literals_offset + literal_index;
    literal_descs[literal_index].data_length = 1;
    literal_descs[literal_index].flags = RTEST(onibi_hash_value(payload, "ignorecase")) ? 1 : 0;
    literal_data[literal_index] = (unsigned char)NUM2INT(onibi_hash_value(payload, "byte"));
    literal_index++;
  }
  rb_obj_freeze(blob);
  VALUE result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("header")), header);
  rb_hash_aset(result, ID2SYM(rb_intern("states")), states);
  rb_hash_aset(result, ID2SYM(rb_intern("edges")), r_edges);
  rb_hash_aset(result, ID2SYM(rb_intern("start_edges")), r_start_edges);
  rb_hash_aset(result, ID2SYM(rb_intern("actions")), actions);
  rb_hash_aset(result, ID2SYM(rb_intern("subprograms")), subprograms);
  rb_hash_aset(result, ID2SYM(rb_intern("blob")), blob);
  rb_hash_aset(result, ID2SYM(rb_intern("physical_graph")),
               onibi_deep_freeze(onibi_rseq_physical_graph(result)));
  rb_obj_freeze(header); rb_obj_freeze(r_edges); rb_obj_freeze(r_start_edges); rb_obj_freeze(actions);
  rb_define_singleton_method(result, "__onibi_trusted_rseq__", onibi_rseq_trusted_marker, 0);
  rb_obj_freeze(result);
  /* Validate once, before publication.  Match calls use this immutable
     validated representation without repeating structural scans. */
  onibi_rseq_validate(result);
  return result;
}

static VALUE onibi_alloc(VALUE klass) {
  onibi_regexp_t *obj;
  return TypedData_Make_Struct(klass, onibi_regexp_t, &onibi_type, obj);
}

static VALUE onibi_build_program(VALUE argument) {
  VALUE source = rb_ary_entry(argument, 0);
  VALUE options = rb_ary_entry(argument, 1);
  VALUE tokens = rb_ary_entry(argument, 2);
  VALUE parsed = onibi_parser_parse_internal(source, options, tokens);
  VALUE compiled = onibi_compiler_compile(Qnil, parsed);
  VALUE rseq = onibi_rseq_lower(Qnil, compiled);
  return rb_ary_new_from_args(3, parsed, compiled, rseq);
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

static int onibi_ascii_property_token_p(VALUE token) {
  if (onibi_token_byte(token) != 'p' && onibi_token_byte(token) != 'P') return 0;
  VALUE name = onibi_hash_value(token, "name");
  return onibi_ascii_property_name_p(name);
}

/* Compute all dispatch/compiler feature bits in one pass over the immutable
   token stream.  Runtime entry points use these bits and never rescan source. */
static void onibi_token_features(VALUE tokens, onibi_regexp_t *obj) {
  int in_class = 0;
  long class_depth = 0;
  int repeat_active = 0;
  uint64_t repeat_value = 0;
  int repeat_have_digit = 0;
  int repeat_over_limit = 0;
  VALUE previous = Qnil;
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
  for (long i = 0; i < RARRAY_LEN(tokens); i++) {
    VALUE token = rb_ary_entry(tokens, i);
    ID kind = onibi_token_kind(token);
    if (kind == rb_intern("literal") && onibi_token_byte(token) > 127) {
      obj->has_non_ascii_literal = 1;
      if (in_class) obj->has_non_ascii_class = 1;
    }
    if (kind == rb_intern("wildcard")) obj->has_wildcard = 1;
    if (kind == rb_intern("anchor")) obj->has_anchor = 1;
    if (kind == rb_intern("class_start")) {
      if (in_class) obj->has_nested_class = 1;
      in_class = 1;
      class_depth++;
      previous = Qnil;
      continue;
    }
    if (kind == rb_intern("class_end")) {
      if (class_depth > 0) class_depth--;
      in_class = class_depth > 0;
      previous = Qnil;
      continue;
    }
    if (repeat_active) {
      long value = onibi_token_byte(token);
      if (kind == rb_intern("quantifier") && value == '}') {
        if (repeat_have_digit && repeat_over_limit) obj->has_large_repeat = 1;
        repeat_active = 0;
      } else if (kind == rb_intern("quantifier") && value == ',') {
        if (repeat_have_digit && repeat_over_limit) obj->has_large_repeat = 1;
        repeat_value = 0; repeat_have_digit = 0; repeat_over_limit = 0;
      } else if (kind == rb_intern("literal") && value >= '0' && value <= '9') {
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
    if (in_class && kind == rb_intern("literal") && onibi_token_byte(token) == '[')
      obj->has_nested_class = 1;
    if (!in_class && kind == rb_intern("quantifier") && onibi_token_byte(token) == '{') {
      repeat_active = 1;
      repeat_value = 0; repeat_have_digit = 0; repeat_over_limit = 0;
    }
    if (in_class && !NIL_P(previous) && onibi_token_kind(previous) == rb_intern("literal") &&
        kind == rb_intern("literal") && onibi_token_byte(previous) == '&' &&
        onibi_token_byte(token) == '&') obj->has_class_intersection = 1;
    if (kind == rb_intern("subroutine")) {
      obj->has_subroutine = 1;
      obj->has_dynamic = 1;
    } else if (kind == rb_intern("backref") || kind == rb_intern("atomic_start") ||
               kind == rb_intern("absence_start")) {
      obj->has_dynamic = 1;
      if (kind == rb_intern("backref")) obj->has_backref = 1;
      if (kind == rb_intern("atomic_start")) obj->has_atomic = 1;
      if (kind == rb_intern("absence_start")) obj->has_absence = 1;
    } else if (kind == rb_intern("conditional_start")) {
      /* Simple capture conditionals lower to guarded GIR edges.  Mark the
         construct only for diagnostics; compile failure selects MRI. */
      obj->has_conditional = 1;
    } else if (kind == rb_intern("escape")) {
      if (onibi_token_byte(token) == 'X') { obj->has_grapheme = 1; obj->has_dynamic = 1; }
      if ((onibi_token_byte(token) == 'p' || onibi_token_byte(token) == 'P')) {
        if (onibi_ascii_property_token_p(token)) {
          obj->has_ascii_property = 1;
          VALUE property_name = onibi_hash_value(token, "name");
          if (!NIL_P(property_name) &&
              rb_str_cmp(property_name, rb_str_new_cstr("ASCII")) != 0 &&
              rb_str_cmp(property_name, rb_str_new_cstr("ASCII_Hex_Digit")) != 0)
            obj->has_unicode_property = 1;
          if (in_class) obj->has_unicode_property_in_class = 1;
        }
        else { obj->has_property_escape = 1; obj->has_dynamic = 1; }
      }
      if (onibi_token_byte(token) == 'u') obj->has_unicode_escape = 1;
    } else if (kind == rb_intern("meta_escape")) {
      obj->has_meta_escape = 1;
      obj->has_dynamic = 1;
    } else if (kind == rb_intern("group_start") ||
               (kind == rb_intern("quantifier") && onibi_token_byte(token) == '{')) {
      obj->has_tagged = 1;
    }
    previous = token;
  }
}

static int onibi_ast_safe_multibyte_class(VALUE ast) {
  if (!RB_TYPE_P(ast, T_HASH)) return 0;
  ID type = onibi_symbol_value(ast, "type");
  if (type == ID2SYM(rb_intern("character_class"))) {
    VALUE children = onibi_hash_value(ast, "children");
    VALUE ranges = onibi_hash_value(ast, "ranges");
    if (RTEST(onibi_hash_value(ast, "negated")) || !RB_TYPE_P(children, T_ARRAY) ||
        !RB_TYPE_P(ranges, T_ARRAY) || RARRAY_LEN(children) == 0) return 0;
    for (long i = 0; i < RARRAY_LEN(children); i++) {
      VALUE child = rb_ary_entry(children, i);
      VALUE kind = onibi_hash_value(child, "kind");
      if (kind == ID2SYM(rb_intern("literal"))) continue;
      VALUE child_name = onibi_hash_value(child, "name");
      if (kind == ID2SYM(rb_intern("escape")) && !NIL_P(child_name) &&
          onibi_unicode_ctype(child_name) >= 0) continue;
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
  if (type == ID2SYM(rb_intern("sequence"))) {
    VALUE children = onibi_hash_value(ast, "children");
    if (!RB_TYPE_P(children, T_ARRAY)) return 0;
    for (long i = 0; i < RARRAY_LEN(children); i++)
      if (!onibi_ast_safe_multibyte_class(rb_ary_entry(children, i))) return 0;
    return 1;
  }
  if (type == ID2SYM(rb_intern("literal")) || type == ID2SYM(rb_intern("anchor"))) return 1;
  return 0;
}

static int onibi_ast_nullable(VALUE ast, int *nullable_capture) {
  if (!RB_TYPE_P(ast, T_HASH)) return 1;
  ID type = onibi_symbol_value(ast, "type");
  if (type == ID2SYM(rb_intern("capture"))) {
    int body_nullable = onibi_ast_nullable(onibi_hash_value(ast, "body"), nullable_capture);
    if (body_nullable) *nullable_capture = 1;
    return body_nullable;
  }
  if (type == ID2SYM(rb_intern("quantifier"))) {
    VALUE min = onibi_hash_value(ast, "min");
    if (!NIL_P(min) && NUM2LONG(min) == 0) {
      if (onibi_ast_has_capture(onibi_hash_value(ast, "atom"))) *nullable_capture = 1;
      (void)onibi_ast_nullable(onibi_hash_value(ast, "atom"), nullable_capture);
      return 1;
    }
    return onibi_ast_nullable(onibi_hash_value(ast, "atom"), nullable_capture);
  }
  if (type == ID2SYM(rb_intern("sequence"))) {
    int result = 1;
    VALUE children = onibi_hash_value(ast, "children");
    for (long i = 0; i < RARRAY_LEN(children); i++)
      if (!onibi_ast_nullable(rb_ary_entry(children, i), nullable_capture)) result = 0;
    return result;
  }
  if (type == ID2SYM(rb_intern("alternative"))) {
    int result = 0;
    VALUE branches = onibi_hash_value(ast, "branches");
    for (long i = 0; i < RARRAY_LEN(branches); i++)
      if (onibi_ast_nullable(rb_ary_entry(branches, i), nullable_capture)) result = 1;
    return result;
  }
  if (type == ID2SYM(rb_intern("group")) || type == ID2SYM(rb_intern("option_scope")) ||
      type == ID2SYM(rb_intern("atomic")))
    return onibi_ast_nullable(onibi_hash_value(ast, "body"), nullable_capture);
  if (type == ID2SYM(rb_intern("lookahead")) || type == ID2SYM(rb_intern("lookbehind")) ||
      type == ID2SYM(rb_intern("anchor")) || type == ID2SYM(rb_intern("match_reset"))) return 1;
  return 0;
}

static int onibi_option_mask(VALUE options) {
  if (NIL_P(options)) return 0;
  if (options == Qtrue) return 1;
  if (options == Qfalse) return 0;
  if (RB_TYPE_P(options, T_STRING)) {
    int mask = 0;
    const char *text = RSTRING_PTR(options);
    for (long i = 0; i < RSTRING_LEN(options); i++) {
      if (text[i] == 'i') mask |= 1;
      else if (text[i] == 'x') mask |= 2;
      else if (text[i] == 'm') mask |= 4;
      else if (text[i] == 'n') mask |= 32;
      else rb_raise(rb_eArgError, "unknown regexp option");
    }
    return mask;
  }
  if (RB_TYPE_P(options, T_ARRAY)) {
    int mask = 0;
    for (long i = 0; i < RARRAY_LEN(options); i++) {
      VALUE item = rb_ary_entry(options, i);
      VALUE name = SYMBOL_P(item) ? rb_sym2str(item) : StringValue(item);
      if (rb_str_cmp(name, rb_str_new_cstr("ignorecase")) == 0) mask |= 1;
      else if (rb_str_cmp(name, rb_str_new_cstr("multiline")) == 0) mask |= 4;
      else if (rb_str_cmp(name, rb_str_new_cstr("extended")) == 0) mask |= 2;
      else if (rb_str_cmp(name, rb_str_new_cstr("fixedencoding")) == 0) mask |= 16;
      else if (rb_str_cmp(name, rb_str_new_cstr("noencoding")) == 0) mask |= 32;
      else rb_raise(rb_eArgError, "unknown regexp option");
    }
    return mask;
  }
  return NUM2INT(options);
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
    timeout = rb_hash_aref(options, ID2SYM(rb_intern("timeout")));
    options = rb_hash_aref(options, ID2SYM(rb_intern("options")));
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
  obj->parsed = obj->compiled = obj->rseq = Qnil;
  obj->tokens = Qnil;
  obj->has_nullable_capture = 0;
  VALUE tokens = onibi_tokenize_internal(source, (opts & 2) != 0);
  onibi_token_features(tokens, obj);
  if (((opts & 32) && rb_enc_str_asciionly_p(source) &&
       (obj->has_non_ascii_literal || obj->has_property_escape)) ||
      (!(opts & 32) && rb_enc_get_index(source) != rb_utf8_encindex() &&
       rb_enc_get_index(source) != rb_usascii_encindex() &&
       (obj->has_non_ascii_literal || obj->has_property_escape))) opts |= 16;
  obj->options = opts;
  VALUE regexp_source = source;
  if (rb_enc_get_index(source) != rb_utf8_encindex() && obj->has_unicode_escape) {
    regexp_source = rb_funcall(source, rb_intern("encode"), 1, rb_enc_from_encoding(rb_utf8_encoding()));
    opts |= 16;
    obj->options = opts;
  }
  VALUE regexp_args = rb_ary_new_from_args(2, regexp_source, INT2NUM(opts));
  int regexp_state = 0;
  obj->regexp = rb_protect(onibi_make_mri_regexp, regexp_args, &regexp_state);
  if (regexp_state) {
    VALUE error = rb_errinfo();
    VALUE message = rb_funcall(error, rb_intern("message"), 0);
    rb_set_errinfo(Qnil);
    rb_raise(eRegexpError, "%s", StringValueCStr(message));
  }
  VALUE program_args = rb_ary_new_from_args(3, source, options, tokens);
  int program_state = 0;
  VALUE program = (obj->has_large_repeat || obj->has_absence ||
                   obj->has_grapheme || obj->has_property_escape || obj->has_meta_escape) ?
    rb_protect(onibi_parse_program, program_args, &program_state) :
    rb_protect(onibi_build_program, program_args, &program_state);
  if (!program_state) {
    obj->parsed = (obj->has_large_repeat || obj->has_absence ||
                   obj->has_grapheme || obj->has_property_escape || obj->has_meta_escape) ? program : rb_ary_entry(program, 0);
    obj->compiled = (obj->has_large_repeat || obj->has_absence ||
                     obj->has_grapheme || obj->has_property_escape || obj->has_meta_escape) ? Qnil : rb_ary_entry(program, 1);
    obj->rseq = (obj->has_large_repeat || obj->has_absence ||
                 obj->has_grapheme || obj->has_property_escape || obj->has_meta_escape) ? Qnil : rb_ary_entry(program, 2);
    obj->tokens = tokens;
    if (!NIL_P(obj->parsed)) {
      VALUE parsed_ast = onibi_hash_value(obj->parsed, "ast");
      obj->has_safe_multibyte_class = onibi_ast_safe_multibyte_class(parsed_ast);
      (void)onibi_ast_nullable(parsed_ast, &obj->has_nullable_capture);
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
      obj->parsed = obj->compiled = obj->rseq = Qnil;
    }
  } else {
    rb_set_errinfo(Qnil);
    /* Keep a failed lowering on the dynamic MRI boundary. */
    obj->has_dynamic = 1;
    obj->tokens = tokens;
  }
  obj->program_size = NIL_P(obj->rseq) ? RSTRING_LEN(source) + 1 :
    RSTRING_LEN(onibi_hash_value(obj->rseq, "blob"));
  if (obj->has_subroutine && !NIL_P(obj->rseq)) obj->has_dynamic = 0;
  if (obj->has_atomic && !obj->has_backref && !obj->has_subroutine &&
      !obj->has_absence && !obj->has_conditional && !obj->has_grapheme &&
      !obj->has_property_escape && !obj->has_meta_escape && !NIL_P(obj->rseq))
    obj->has_dynamic = 0;
  obj->execution_class = rb_str_new_cstr("REGULAR_FAST");
  rb_obj_freeze(obj->execution_class);
  if (obj->has_dynamic) obj->execution_class = rb_str_new_cstr("DYNAMIC");
  else if (obj->has_tagged) obj->execution_class = rb_str_new_cstr("TAGGED_ORDERED");
  rb_obj_freeze(obj->execution_class);
  obj->execution_kind = rb_str_cmp(obj->execution_class, rb_str_new_cstr("DYNAMIC")) == 0 ? ID2SYM(rb_intern("DYNAMIC")) :
    (rb_str_cmp(obj->execution_class, rb_str_new_cstr("TAGGED_ORDERED")) == 0 ? ID2SYM(rb_intern("TAGGED_ORDERED")) : ID2SYM(rb_intern("REGULAR_FAST")));
  obj->pipeline = onibi_pipeline_build(self);
  rb_obj_freeze(obj->pipeline);
  rb_obj_freeze(self);
  return self;
}

static VALUE onibi_match(int argc, VALUE *argv, VALUE self) {
  VALUE str, pos = Qnil;
  rb_scan_args(argc, argv, "11", &str, &pos);
  onibi_regexp_t *obj;
  TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return NIL_P(pos) ? rb_funcall(obj->regexp, id_match, 1, str)
                    : rb_funcall(obj->regexp, id_match, 2, str, pos);
}

static VALUE onibi_match_p(int argc, VALUE *argv, VALUE self) {
  VALUE str, pos = Qnil;
  rb_scan_args(argc, argv, "11", &str, &pos);
  onibi_regexp_t *obj;
  TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  if (NIL_P(pos) && !NIL_P(obj->rseq) && RB_TYPE_P(str, T_STRING) &&
      !(obj->options & 32) && (!(obj->options & 16) || onibi_encoded_literal_program_p(obj)) &&
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
  return obj->source;
}
static VALUE onibi_options(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return INT2NUM(obj->options);
}
static VALUE onibi_fixed_encoding_p(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  /* MRI fixes NOENCODING only when syntax forces a binary property mode. */
  return (obj->options & 16) || ((obj->options & 32) && obj->has_ascii_property) ? Qtrue : Qfalse;
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
static VALUE onibi_execution_class(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return obj->execution_class;
}
static VALUE onibi_encoding(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(obj->regexp, id_encoding, 0);
}
static VALUE onibi_program_size(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return LONG2NUM(obj->program_size);
}
static VALUE onibi_program_frozen(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return !NIL_P(obj->rseq) && RTEST(rb_obj_frozen_p(obj->rseq)) ? Qtrue : Qfalse;
}
static VALUE onibi_program_cached(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return NIL_P(obj->rseq) ? Qfalse : Qtrue;
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
  return rb_funcall(rb_cRegexp, rb_intern("escape"), 1, string);
}

static VALUE onibi_regexp_union(int argc, VALUE *argv, VALUE klass) {
  VALUE mri_regexp = rb_funcallv(rb_cRegexp, rb_intern("union"), argc, argv);
  return rb_funcall(klass, id_new, 1, mri_regexp);
}

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
             strchr("*+?", (int)onibi_token_byte(rb_ary_entry(tokens, 1))) != NULL) {
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
  VALUE klass = obj->execution_class;
  rb_hash_aset(out, ID2SYM(rb_intern("interpreter")), rb_equal(klass, rb_str_new_cstr("DYNAMIC")) ?
    ID2SYM(rb_intern("DYNAMIC")) : (rb_equal(klass, rb_str_new_cstr("TAGGED_ORDERED")) ?
      ID2SYM(rb_intern("TAGGED_ORDERED")) : ID2SYM(rb_intern("REGULAR_FAST"))));
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

static VALUE onibi_pipeline(VALUE self) {
  onibi_regexp_t *obj;
  TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return obj->pipeline;
}

static int onibi_vm_actions_ok(VALUE actions, VALUE subject, long pos, long length, VALUE counters, VALUE captures) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    ID op = SYM2ID(onibi_hash_value(action, "op"));
    if (op == rb_intern("TEST_CAPTURE")) {
      long capture = NUM2LONG(onibi_hash_value(action, "slot"));
      int set = !NIL_P(captures) && !NIL_P(rb_hash_aref(captures, LONG2NUM(2 * capture))) &&
        !NIL_P(rb_hash_aref(captures, LONG2NUM(2 * capture + 1)));
      if (!set && !NIL_P(captures)) {
        for (long event = 0; event < RARRAY_LEN(actions); event++) {
          VALUE event_action = rb_ary_entry(actions, event);
          if (SYM2ID(onibi_hash_value(event_action, "op")) == rb_intern("CAPTURE_CLOSE") &&
              NUM2LONG(onibi_hash_value(event_action, "slot")) == 2 * capture + 1 &&
              !NIL_P(rb_hash_aref(captures, LONG2NUM(2 * capture)))) { set = 1; break; }
        }
      }
      if (set != RTEST(onibi_hash_value(action, "set"))) return 0;
      continue;
    }
    if (op == rb_intern("TEST_COUNTER_LT") || op == rb_intern("TEST_COUNTER_GE")) {
      VALUE value = rb_hash_aref(counters, onibi_hash_value(action, "slot"));
      long count = NIL_P(value) ? 0 : NUM2LONG(value);
      long limit = NUM2LONG(onibi_hash_value(action, "limit"));
      if ((op == rb_intern("TEST_COUNTER_LT") && !(count < limit)) ||
          (op == rb_intern("TEST_COUNTER_GE") && !(count >= limit))) return 0;
    }
    if (op == rb_intern("ASSERT_BEGIN_BUFFER") && pos != 0) return 0;
    if (op == rb_intern("ASSERT_SEARCH_ORIGIN") && pos != 0) return 0;
    if (op == rb_intern("ASSERT_END_BUFFER") && pos != length) return 0;
    if (op == rb_intern("ASSERT_BEGIN_LINE") && pos != 0 && RSTRING_PTR(subject)[pos - 1] != '\n') return 0;
    if (op == rb_intern("ASSERT_END_LINE") && pos != length && RSTRING_PTR(subject)[pos] != '\n') return 0;
    if (op == rb_intern("ASSERT_WORD_BOUNDARY") || op == rb_intern("ASSERT_NONWORD_BOUNDARY")) {
      int before = pos > 0 && (isalnum((unsigned char)RSTRING_PTR(subject)[pos - 1]) || RSTRING_PTR(subject)[pos - 1] == '_');
      int after = pos < length && (isalnum((unsigned char)RSTRING_PTR(subject)[pos]) || RSTRING_PTR(subject)[pos] == '_');
      int boundary = before != after;
      if ((op == rb_intern("ASSERT_WORD_BOUNDARY") && !boundary) ||
          (op == rb_intern("ASSERT_NONWORD_BOUNDARY") && boundary)) return 0;
    }
    if (op == rb_intern("ASSERT_SEMI_END_BUFFER") && pos != length &&
        !(pos + 1 == length && length > 0 && RSTRING_PTR(subject)[length - 1] == '\n')) return 0;
    if (op == rb_intern("ASSERT_LOOKAHEAD")) {
      VALUE predicates = onibi_hash_value(action, "predicates");
      if (RB_TYPE_P(predicates, T_ARRAY)) {
        int matched = 1;
        for (long i = 0; i < RARRAY_LEN(predicates); i++) {
          VALUE predicate = rb_ary_entry(predicates, i);
          long at = pos + i;
          if (at >= length) { matched = 0; break; }
          unsigned char byte = (unsigned char)RSTRING_PTR(subject)[at];
          ID kind = SYM2ID(onibi_hash_value(predicate, "kind"));
          if (kind == rb_intern("byte")) {
            unsigned char expected = (unsigned char)NUM2INT(onibi_hash_value(predicate, "byte"));
            matched = matched && (RTEST(onibi_hash_value(predicate, "ignorecase")) ?
              tolower(byte) == tolower(expected) : byte == expected);
          } else if (kind == rb_intern("any")) {
            matched = matched && (byte != '\n' || RTEST(onibi_hash_value(predicate, "multiline")));
          }
          else {
            VALUE bits = onibi_hash_value(predicate, "bitmap");
            matched = matched && RB_TYPE_P(bits, T_STRING) && RSTRING_LEN(bits) == 32 &&
              (((unsigned char *)RSTRING_PTR(bits))[byte >> 3] & (1U << (byte & 7))) != 0;
          }
          if (!matched) break;
        }
        if (matched != RTEST(onibi_hash_value(action, "positive"))) return 0;
        continue;
      }
      VALUE bitmap = onibi_hash_value(action, "bitmap");
      if (!NIL_P(bitmap)) {
        int hit = pos < length && RSTRING_LEN(bitmap) == 32 &&
          (((unsigned char *)RSTRING_PTR(bitmap))[(unsigned char)RSTRING_PTR(subject)[pos] >> 3] &
           (1U << ((unsigned char)RSTRING_PTR(subject)[pos] & 7))) != 0;
        if (hit != RTEST(onibi_hash_value(action, "positive"))) return 0;
        continue;
      }
      VALUE bytes = onibi_hash_value(action, "bytes");
      long width = RSTRING_LEN(bytes);
      int hit = pos + width <= length && memcmp(RSTRING_PTR(subject) + pos, RSTRING_PTR(bytes), (size_t)width) == 0;
      if (hit != RTEST(onibi_hash_value(action, "positive"))) return 0;
    }
    if (op == rb_intern("ASSERT_LOOKBEHIND")) {
      VALUE predicates = onibi_hash_value(action, "predicates");
      if (RB_TYPE_P(predicates, T_ARRAY)) {
        long width = RARRAY_LEN(predicates);
        int matched = pos >= width;
        for (long i = 0; matched && i < width; i++) {
          VALUE predicate = rb_ary_entry(predicates, i);
          unsigned char byte = (unsigned char)RSTRING_PTR(subject)[pos - width + i];
          ID kind = SYM2ID(onibi_hash_value(predicate, "kind"));
          if (kind == rb_intern("byte")) {
            unsigned char expected = (unsigned char)NUM2INT(onibi_hash_value(predicate, "byte"));
            matched = RTEST(onibi_hash_value(predicate, "ignorecase")) ?
              tolower(byte) == tolower(expected) : byte == expected;
          } else if (kind == rb_intern("any")) {
            matched = matched && (byte != '\n' || RTEST(onibi_hash_value(predicate, "multiline")));
          }
          else {
            VALUE bits = onibi_hash_value(predicate, "bitmap");
            matched = RB_TYPE_P(bits, T_STRING) && RSTRING_LEN(bits) == 32 &&
              (((unsigned char *)RSTRING_PTR(bits))[byte >> 3] & (1U << (byte & 7))) != 0;
          }
        }
        if (matched != RTEST(onibi_hash_value(action, "positive"))) return 0;
        continue;
      }
      VALUE bitmap = onibi_hash_value(action, "bitmap");
      if (!NIL_P(bitmap)) {
        int hit = pos > 0 && RSTRING_LEN(bitmap) == 32 &&
          (((unsigned char *)RSTRING_PTR(bitmap))[(unsigned char)RSTRING_PTR(subject)[pos - 1] >> 3] &
           (1U << ((unsigned char)RSTRING_PTR(subject)[pos - 1] & 7))) != 0;
        if (hit != RTEST(onibi_hash_value(action, "positive"))) return 0;
        continue;
      }
      VALUE bytes = onibi_hash_value(action, "bytes");
      long width = RSTRING_LEN(bytes);
      int hit = pos >= width && memcmp(RSTRING_PTR(subject) + pos - width, RSTRING_PTR(bytes), (size_t)width) == 0;
      if (hit != RTEST(onibi_hash_value(action, "positive"))) return 0;
    }
  }
  return 1;
}

static void onibi_vm_apply_counter_actions(VALUE actions, VALUE counters) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    ID op = SYM2ID(onibi_hash_value(action, "op"));
    VALUE slot = onibi_hash_value(action, "slot");
    if (op == rb_intern("COUNTER_INIT"))
      rb_hash_aset(counters, slot, onibi_hash_value(action, "value"));
    else if (op == rb_intern("COUNTER_INCREMENT")) {
      VALUE prior = rb_hash_aref(counters, slot);
      rb_hash_aset(counters, slot, LONG2NUM((NIL_P(prior) ? 0 : NUM2LONG(prior)) + 1));
    }
  }
}

static int onibi_unicode_ctype(VALUE name) {
  const char *property = StringValueCStr(name);
  if (strcmp(property, "Alpha") == 0 || strcmp(property, "alpha") == 0 || strcmp(property, "Letter") == 0) return ONIGENC_CTYPE_ALPHA;
  if (strcmp(property, "Digit") == 0 || strcmp(property, "digit") == 0) return ONIGENC_CTYPE_DIGIT;
  if (strcmp(property, "Alnum") == 0 || strcmp(property, "alnum") == 0) return ONIGENC_CTYPE_ALNUM;
  if (strcmp(property, "Lower") == 0 || strcmp(property, "lower") == 0) return ONIGENC_CTYPE_LOWER;
  if (strcmp(property, "Upper") == 0 || strcmp(property, "upper") == 0) return ONIGENC_CTYPE_UPPER;
  if (strcmp(property, "Space") == 0 || strcmp(property, "space") == 0) return ONIGENC_CTYPE_SPACE;
  if (strcmp(property, "Blank") == 0 || strcmp(property, "blank") == 0) return ONIGENC_CTYPE_BLANK;
  if (strcmp(property, "Word") == 0 || strcmp(property, "word") == 0) return ONIGENC_CTYPE_WORD;
  if (strcmp(property, "XDigit") == 0 || strcmp(property, "xdigit") == 0) return ONIGENC_CTYPE_XDIGIT;
  if (strcmp(property, "Cntrl") == 0) return ONIGENC_CTYPE_CNTRL;
  if (strcmp(property, "Print") == 0) return ONIGENC_CTYPE_PRINT;
  if (strcmp(property, "Graph") == 0) return ONIGENC_CTYPE_GRAPH;
  if (strcmp(property, "Punct") == 0) return ONIGENC_CTYPE_PUNCT;
  return -1;
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

static int onibi_vm_class_match(VALUE payload, VALUE str, long pos, unsigned char byte, long *width) {
  VALUE name = onibi_hash_value(payload, "name");
  int ctype = NIL_P(name) ? -1 : onibi_unicode_ctype(name);
  if (ctype >= 0 && rb_enc_get_index(str) == rb_utf8_encindex()) {
    if (pos > 0 && ((unsigned char)RSTRING_PTR(str)[pos] & 0xc0) == 0x80 &&
        (((unsigned char)RSTRING_PTR(str)[pos - 1] & 0xc0) == 0x80 || (unsigned char)RSTRING_PTR(str)[pos - 1] >= 0xc0)) return 0;
    OnigCodePoint code; long length = 0;
    if (!onibi_codepoint_at(str, pos, &code, &length)) return 0;
    int hit = ONIGENC_IS_CODE_CTYPE(rb_enc_get(str), code, ctype);
    if (NUM2INT(onibi_hash_value(payload, "byte")) == 'P') hit = !hit;
    *width = length;
    return hit;
  }
  if (NIL_P(name) && !rb_enc_str_asciionly_p(str) && rb_enc_get_index(str) != rb_ascii8bit_encindex()) {
    VALUE children = onibi_hash_value(payload, "children");
    VALUE ranges = onibi_hash_value(payload, "ranges");
    if (RB_TYPE_P(children, T_ARRAY) && RB_TYPE_P(ranges, T_ARRAY)) {
      OnigCodePoint code; long decoded_width = 0;
      if (!onibi_codepoint_at(str, pos, &code, &decoded_width)) return 0;
      int hit = 0;
      for (long i = 0; i < RARRAY_LEN(children); i++) {
        VALUE child = rb_ary_entry(children, i);
        VALUE kind_value = onibi_hash_value(child, "kind");
        if (!SYMBOL_P(kind_value)) continue;
        ID kind = SYM2ID(kind_value);
        if (kind == rb_intern("literal")) {
          VALUE bytes = onibi_hash_value(child, "bytes");
          if (NIL_P(bytes)) bytes = rb_str_new((const char[]){(char)NUM2INT(onibi_hash_value(child, "byte"))}, 1);
          const char *child_ptr = RSTRING_PTR(bytes);
          const char *child_end = child_ptr + RSTRING_LEN(bytes);
          int child_len = rb_enc_mbclen(child_ptr, child_end, rb_enc_get(str));
          if (child_len > 0 && child_ptr + child_len <= child_end &&
              ONIGENC_MBC_TO_CODE(rb_enc_get(str), (const OnigUChar *)child_ptr,
                                   (const OnigUChar *)child_end) == code) hit = 1;
        } else if (kind == rb_intern("escape")) {
          VALUE child_name = onibi_hash_value(child, "name");
          int child_ctype = NIL_P(child_name) ? -1 : onibi_unicode_ctype(child_name);
          if (child_ctype >= 0) {
            int child_hit = ONIGENC_IS_CODE_CTYPE(rb_enc_get(str), code, child_ctype);
            if (NUM2INT(onibi_hash_value(child, "byte")) == 'P') child_hit = !child_hit;
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
      if (RTEST(onibi_hash_value(payload, "negated"))) hit = !hit;
      *width = decoded_width;
      return hit;
    }
  }
  int fold = RTEST(onibi_hash_value(payload, "ignorecase"));
  if (fold) byte = (unsigned char)tolower(byte);
  VALUE bitmap = onibi_hash_value(payload, "bitmap");
  if (NIL_P(bitmap) || !RB_TYPE_P(bitmap, T_STRING) || RSTRING_LEN(bitmap) != 32)
    rb_raise(eRegexpError, "class payload has no compiled bitmap");
  *width = 1;
  return (((unsigned char *)RSTRING_PTR(bitmap))[byte >> 3] & (1U << (byte & 7))) != 0;
}

static int onibi_vm_walk(VALUE states, VALUE outgoing, VALUE str, long state_id, long pos, VALUE visited, VALUE counters, long *matched_end) {
  rb_thread_check_ints();
  onibi_check_deadline();
  VALUE key = rb_ary_new_from_args(3, LONG2NUM(state_id), LONG2NUM(pos), counters);
  if (RTEST(rb_hash_aref(visited, key))) return 0;
  rb_hash_aset(visited, key, Qtrue);
  VALUE state = rb_ary_entry(states, state_id);
  ID op = SYM2ID(onibi_hash_value(state, "op"));
  if (op == rb_intern("G_ACCEPT")) { *matched_end = pos; return 1; }
  /* Dynamic subprogram states are not valid in the flat graph walker. */
  if (op == rb_intern("G_GRAPHEME") || op == rb_intern("G_CALL") || op == rb_intern("G_ATOMIC") || op == rb_intern("G_ABSENT")) return 0;
  if (op == rb_intern("G_CHAR") || op == rb_intern("G_CLASS") || op == rb_intern("G_ANY")) {
    if (pos >= RSTRING_LEN(str)) return 0;
    unsigned char byte = (unsigned char)RSTRING_PTR(str)[pos];
    VALUE payload = onibi_hash_value(state, "payload");
    long consumed = 1;
    int hit = op == rb_intern("G_ANY") ? (byte != '\n' || RTEST(onibi_hash_value(payload, "multiline"))) :
      (op == rb_intern("G_CHAR") ?
        (RTEST(onibi_hash_value(payload, "ignorecase")) ?
          tolower(byte) == tolower(NUM2INT(onibi_hash_value(payload, "byte"))) :
          byte == NUM2INT(onibi_hash_value(payload, "byte"))) : onibi_vm_class_match(payload, str, pos, byte, &consumed));
    if (!hit) return 0;
    pos += consumed;
  }
  VALUE state_edges = rb_ary_entry(outgoing, state_id);
  for (long i = 0; i < RARRAY_LEN(state_edges); i++) {
    VALUE edge = rb_ary_entry(state_edges, i);
    VALUE edge_actions = onibi_hash_value(edge, "actions");
    VALUE next_counters = rb_hash_dup(counters);
    if (!onibi_vm_actions_ok(edge_actions, str, pos, RSTRING_LEN(str), next_counters, Qnil)) continue;
    onibi_vm_apply_counter_actions(edge_actions, next_counters);
    if (onibi_vm_walk(states, outgoing, str, NUM2LONG(onibi_hash_value(edge, "to")), pos, visited, next_counters, matched_end)) return 1;
  }
  return 0;
}

static int onibi_gir_match(VALUE graph, VALUE str, long start, long *matched_end) {
  VALUE states = onibi_hash_value(graph, "states");
  VALUE outgoing = onibi_hash_value(graph, "outgoing");
  VALUE starts = onibi_hash_value(graph, "start_edges");
  VALUE visited = rb_hash_new();
  VALUE counters = rb_hash_new();
  for (long i = 0; i < RARRAY_LEN(starts); i++) {
    VALUE edge = rb_ary_entry(starts, i);
    VALUE edge_actions = onibi_hash_value(edge, "actions");
    VALUE branch_counters = rb_hash_dup(counters);
    if (!onibi_vm_actions_ok(edge_actions, str, start, RSTRING_LEN(str), branch_counters, Qnil)) continue;
    onibi_vm_apply_counter_actions(edge_actions, branch_counters);
    if (onibi_vm_walk(states, outgoing, str, NUM2LONG(onibi_hash_value(edge, "to")), start, visited, branch_counters, matched_end)) return 1;
  }
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
    if (NIL_P(rb_hash_aref(captures, slot)))
      rb_hash_aset(captures, slot, rb_ary_entry(cursor, 2));
    cursor = rb_ary_entry(cursor, 0);
  }
  return captures;
}

static int onibi_has_capture_action(VALUE actions) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    ID op = SYM2ID(onibi_hash_value(rb_ary_entry(actions, i), "op"));
    if (op == rb_intern("CAPTURE_OPEN") || op == rb_intern("CAPTURE_CLOSE")) return 1;
  }
  return 0;
}

/* Capture output uses an append-only event chain.  Each branch shares the
   parent chain and allocates only the events that it adds. */
static VALUE onibi_apply_capture_actions(VALUE actions, long pos, VALUE captures,
                                         VALUE tags, long *reported_start) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    ID op = SYM2ID(onibi_hash_value(action, "op"));
    if (op == rb_intern("MATCH_RESET")) { *reported_start = pos; continue; }
    if (op != rb_intern("CAPTURE_OPEN") && op != rb_intern("CAPTURE_CLOSE")) continue;
    VALUE slot = onibi_hash_value(action, "slot");
    rb_hash_aset(captures, slot, LONG2NUM(pos));
    VALUE event = rb_ary_new_from_args(3, tags, slot, LONG2NUM(pos));
    rb_obj_freeze(event);
    tags = event;
  }
  return tags;
}

static int onibi_vm_walk_captures(VALUE states, VALUE outgoing, VALUE str, long state_id, long pos,
                                  VALUE visited, VALUE captures, VALUE counters, VALUE tags, long reported_start,
                                  long *matched_end, long *matched_start, VALUE *matched_captures) {
  rb_thread_check_ints();
  onibi_check_deadline();
  VALUE key = rb_ary_new_from_args(6, LONG2NUM(state_id), LONG2NUM(pos), captures, counters, tags, LONG2NUM(reported_start));
  if (RTEST(rb_hash_aref(visited, key))) return 0;
  rb_hash_aset(visited, key, Qtrue);
  VALUE state = rb_ary_entry(states, state_id);
  ID op = SYM2ID(onibi_hash_value(state, "op"));
  if (op == rb_intern("G_ACCEPT")) {
    *matched_end = pos;
    *matched_start = reported_start;
    *matched_captures = onibi_materialize_tags(tags, captures);
    return 1;
  }
  /* Dynamic subprogram states require a call frame and must not fall through
     as epsilon transitions in the ordinary graph walker. */
  if (op == rb_intern("G_GRAPHEME") || op == rb_intern("G_CALL") || op == rb_intern("G_ATOMIC") || op == rb_intern("G_ABSENT")) return 0;
  if (op == rb_intern("G_CHAR") || op == rb_intern("G_CLASS") || op == rb_intern("G_ANY") || op == rb_intern("G_BACKREF")) {
    if (pos >= RSTRING_LEN(str)) return 0;
    if (op == rb_intern("G_BACKREF")) {
      VALUE payload = onibi_hash_value(state, "payload");
      long capture = NUM2LONG(onibi_hash_value(payload, "capture"));
      VALUE begin = rb_hash_aref(captures, LONG2NUM(2 * (capture - 1)));
      VALUE finish = rb_hash_aref(captures, LONG2NUM(2 * (capture - 1) + 1));
      if (NIL_P(begin) || NIL_P(finish)) return 0;
      long length = NUM2LONG(finish) - NUM2LONG(begin);
      if (pos + length > RSTRING_LEN(str)) return 0;
      int fold = RTEST(onibi_hash_value(payload, "ignorecase"));
      if (!fold) {
        if (memcmp(RSTRING_PTR(str) + pos, RSTRING_PTR(str) + NUM2LONG(begin), (size_t)length) != 0) return 0;
      } else {
        for (long i = 0; i < length; i++) {
          unsigned char left = (unsigned char)RSTRING_PTR(str)[pos + i];
          unsigned char right = (unsigned char)RSTRING_PTR(str)[NUM2LONG(begin) + i];
          if (tolower(left) != tolower(right)) return 0;
        }
      }
      pos += length;
    } else {
      unsigned char byte = (unsigned char)RSTRING_PTR(str)[pos];
      VALUE payload = onibi_hash_value(state, "payload");
      long consumed = 1;
      int hit = op == rb_intern("G_ANY") ? (byte != '\n' || RTEST(onibi_hash_value(payload, "multiline"))) :
        (op == rb_intern("G_CHAR") ?
          (RTEST(onibi_hash_value(payload, "ignorecase")) ?
            tolower(byte) == tolower(NUM2INT(onibi_hash_value(payload, "byte"))) :
            byte == NUM2INT(onibi_hash_value(payload, "byte"))) : onibi_vm_class_match(payload, str, pos, byte, &consumed));
      if (!hit) return 0;
      pos += consumed;
    }
  }
  VALUE state_edges = rb_ary_entry(outgoing, state_id);
  for (long i = 0; i < RARRAY_LEN(state_edges); i++) {
    VALUE edge = rb_ary_entry(state_edges, i);
    VALUE edge_actions = onibi_hash_value(edge, "actions");
    VALUE next_counters = rb_hash_dup(counters);
    if (!onibi_vm_actions_ok(edge_actions, str, pos, RSTRING_LEN(str), next_counters, captures)) continue;
    VALUE next_captures = onibi_has_capture_action(edge_actions) ? onibi_capture_copy(captures) : captures;
    VALUE next_tags = tags;
    long next_reported_start = reported_start;
    onibi_vm_apply_counter_actions(edge_actions, next_counters);
    next_tags = onibi_apply_capture_actions(edge_actions, pos, next_captures, next_tags, &next_reported_start);
    if (onibi_vm_walk_captures(states, outgoing, str, NUM2LONG(onibi_hash_value(edge, "to")), pos,
                               visited, next_captures, next_counters, next_tags, next_reported_start,
                               matched_end, matched_start, matched_captures)) return 1;
  }
  return 0;
}

static int onibi_gir_match_captures(VALUE graph, VALUE str, long start, long *matched_end,
                                    long *matched_start, VALUE *matched_captures) {
  VALUE states = onibi_hash_value(graph, "states");
  VALUE outgoing = onibi_hash_value(graph, "outgoing");
  VALUE starts = onibi_hash_value(graph, "start_edges");
  VALUE visited = rb_hash_new();
  VALUE captures = rb_hash_new();
  VALUE counters = rb_hash_new();
  VALUE tags = Qnil;
  for (long i = 0; i < RARRAY_LEN(starts); i++) {
    VALUE edge = rb_ary_entry(starts, i);
    VALUE edge_actions = onibi_hash_value(edge, "actions");
    VALUE branch_counters = rb_hash_dup(counters);
    if (!onibi_vm_actions_ok(edge_actions, str, start, RSTRING_LEN(str), branch_counters, captures)) continue;
    VALUE branch_captures = onibi_has_capture_action(edge_actions) ? onibi_capture_copy(captures) : captures;
    long reported_start = start;
    onibi_vm_apply_counter_actions(edge_actions, branch_counters);
    VALUE branch_tags = onibi_apply_capture_actions(edge_actions, start, branch_captures, tags, &reported_start);
    if (onibi_vm_walk_captures(states, outgoing, str, NUM2LONG(onibi_hash_value(edge, "to")), start,
                               visited, branch_captures, branch_counters, branch_tags, reported_start,
                               matched_end, matched_start, matched_captures)) return 1;
  }
  return 0;
}

static void onibi_rseq_validate(VALUE rseq) {
  VALUE blob = onibi_hash_value(rseq, "blob");
  VALUE physical_graph = rb_hash_aref(rseq, ID2SYM(rb_intern("physical_graph")));
  VALUE semantic = onibi_hash_value(rseq, "header");
  VALUE semantic_states = onibi_hash_value(rseq, "states");
  VALUE semantic_edges = onibi_hash_value(rseq, "edges");
  VALUE semantic_start_edges = onibi_hash_value(rseq, "start_edges");
  VALUE semantic_actions = onibi_hash_value(rseq, "actions");
  VALUE semantic_subprograms = onibi_hash_value(rseq, "subprograms");
  if (NIL_P(blob) || RSTRING_LEN(blob) < (long)sizeof(OnibiRSeqHeader) ||
      !RTEST(rb_obj_frozen_p(rseq)) || !RTEST(rb_obj_frozen_p(blob)) ||
      !RTEST(rb_obj_frozen_p(semantic)) || !RTEST(rb_obj_frozen_p(semantic_states)) ||
      !RTEST(rb_obj_frozen_p(semantic_edges)) || !RTEST(rb_obj_frozen_p(semantic_actions)) ||
      !RB_TYPE_P(semantic_subprograms, T_ARRAY) || !RTEST(rb_obj_frozen_p(semantic_subprograms)) ||
      !RTEST(rb_obj_frozen_p(semantic_start_edges)) ||
      (!NIL_P(physical_graph) && !RTEST(rb_obj_frozen_p(physical_graph))))
    rb_raise(rb_eArgError, "invalid Onibi RSeq blob");
  if (!NIL_P(physical_graph)) {
    VALUE cached_states = RB_TYPE_P(physical_graph, T_HASH) ? onibi_hash_value(physical_graph, "states") : Qnil;
    VALUE cached_edges = RB_TYPE_P(physical_graph, T_HASH) ? onibi_hash_value(physical_graph, "edges") : Qnil;
    VALUE cached_starts = RB_TYPE_P(physical_graph, T_HASH) ? onibi_hash_value(physical_graph, "start_edges") : Qnil;
    VALUE cached_outgoing = RB_TYPE_P(physical_graph, T_HASH) ? onibi_hash_value(physical_graph, "outgoing") : Qnil;
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
        if (!RB_TYPE_P(edge, T_HASH) || NUM2LONG(onibi_hash_value(edge, "from")) != state_id ||
            !RB_TYPE_P(onibi_hash_value(edge, "actions"), T_ARRAY))
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
      NUM2UINT(onibi_hash_value(semantic, "state_count")) != header.state_count ||
      NUM2UINT(onibi_hash_value(semantic, "features")) != header.features ||
      NUM2UINT(onibi_hash_value(semantic, "edge_count")) != header.edge_count - header.start_edge_count ||
      NUM2UINT(onibi_hash_value(semantic, "action_count")) != header.action_count ||
      NUM2UINT(onibi_hash_value(semantic, "class_count")) != header.class_count ||
      NUM2UINT(onibi_hash_value(semantic, "capture_count")) != header.capture_count ||
      NUM2UINT(onibi_hash_value(semantic, "counter_count")) != header.counter_count ||
      RARRAY_LEN(semantic_subprograms) != header.subprogram_count ||
      NUM2UINT(onibi_hash_value(semantic, "subprogram_count")) != header.subprogram_count ||
      NUM2UINT(onibi_hash_value(semantic, "start_edge_base")) != header.start_edge_base ||
      NUM2UINT(onibi_hash_value(semantic, "start_edge_count")) != header.start_edge_count ||
      NUM2UINT(onibi_hash_value(semantic, "blob_size")) != header.blob_size)
    rb_raise(rb_eArgError, "RSeq semantic and physical headers disagree");
  if (header.magic != ONIBI_RSEQ_MAGIC || header.version != ONIBI_RSEQ_VERSION ||
      header.exec_kind > 2 ||
      ((header.flags & 1U) != (RTEST(onibi_hash_value(semantic, "ignorecase")) ? 1U : 0U)) ||
      ((header.flags & 2U) != (RTEST(onibi_hash_value(semantic, "multiline")) ? 2U : 0U)) ||
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
      header.descriptors_offset + (uint64_t)NUM2UINT(onibi_hash_value(semantic, "literal_count")) * sizeof(OnibiLiteralDesc) > header.blob_size)
    rb_raise(rb_eArgError, "invalid Onibi RSeq blob");
  const OnibiRState *states = (const OnibiRState *)(RSTRING_PTR(blob) + header.states_offset);
  for (uint32_t i = 0; i < header.state_count; i++) {
    VALUE semantic_state = rb_ary_entry(semantic_states, i);
    if (!RB_TYPE_P(semantic_state, T_HASH) || !RTEST(rb_obj_frozen_p(semantic_state)) ||
        !RTEST(rb_obj_frozen_p(onibi_hash_value(semantic_state, "payload"))))
      rb_raise(rb_eArgError, "invalid semantic RSeq state");
    ID semantic_op = SYM2ID(onibi_hash_value(semantic_state, "op"));
    uint8_t expected_op = semantic_op == rb_intern("G_ACCEPT") ? 0 :
      semantic_op == rb_intern("G_CHAR") ? ONIBI_RS_CHAR :
      semantic_op == rb_intern("G_CLASS") ? ONIBI_RS_CLASS :
      semantic_op == rb_intern("G_ANY") ? ONIBI_RS_ANY :
      semantic_op == rb_intern("G_GRAPHEME") ? ONIBI_RS_GRAPHEME :
      semantic_op == rb_intern("G_BACKREF") ? ONIBI_RS_BACKREF :
      semantic_op == rb_intern("G_CALL") ? ONIBI_RS_CALL :
      semantic_op == rb_intern("G_ATOMIC") ? ONIBI_RS_ATOMIC :
      semantic_op == rb_intern("G_ABSENT") ? ONIBI_RS_ABSENT : 0xff;
    if (expected_op == 0xff || states[i].op != expected_op)
      rb_raise(rb_eArgError, "RSeq semantic and physical states disagree");
    if (!NIL_P(physical_graph)) {
      VALUE cached_state = rb_ary_entry(onibi_hash_value(physical_graph, "states"), i);
      if (!RB_TYPE_P(cached_state, T_HASH) ||
          SYM2ID(onibi_hash_value(cached_state, "op")) != semantic_op ||
          !rb_equal(onibi_hash_value(cached_state, "payload"), onibi_hash_value(semantic_state, "payload")))
        rb_raise(rb_eArgError, "cached RSeq state disagrees with semantic state");
    }
    if (semantic_op == rb_intern("G_CLASS")) {
      VALUE bitmap = onibi_hash_value(onibi_hash_value(semantic_state, "payload"), "bitmap");
      if (!RB_TYPE_P(bitmap, T_STRING) || RSTRING_LEN(bitmap) != 32)
        rb_raise(rb_eArgError, "RSeq class state has no compiled bitmap");
    }
    if (semantic_op == rb_intern("G_CHAR")) {
      VALUE byte = onibi_hash_value(onibi_hash_value(semantic_state, "payload"), "byte");
      if (NIL_P(byte) || NUM2LONG(byte) < 0 || NUM2LONG(byte) > 255)
        rb_raise(rb_eArgError, "RSeq character state has an invalid byte");
    }
    if (states[i].op > ONIBI_RS_RUN_ANY)
      rb_raise(rb_eArgError, "invalid Onibi RSeq state opcode");
    if ((uint64_t)states[i].edge_base + states[i].edge_count > header.edge_count - header.start_edge_count)
      rb_raise(rb_eArgError, "invalid Onibi RSeq state edge range");
    if (states[i].op == ONIBI_RS_CLASS && states[i].payload >= header.class_count)
      rb_raise(rb_eArgError, "invalid Onibi RSeq class descriptor id");
    if (states[i].op == ONIBI_RS_CHAR && states[i].payload >= NUM2UINT(onibi_hash_value(semantic, "literal_count")))
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
        !RTEST(rb_obj_frozen_p(onibi_hash_value(semantic_edge, "actions"))))
      rb_raise(rb_eArgError, "invalid semantic RSeq edge");
    VALUE semantic_edge_actions = onibi_hash_value(semantic_edge, "actions");
    if (RARRAY_LEN(semantic_edge_actions) > 0) {
      VALUE terminator = rb_ary_entry(semantic_edge_actions, RARRAY_LEN(semantic_edge_actions) - 1);
      VALUE terminator_op = RB_TYPE_P(terminator, T_HASH) ? onibi_hash_value(terminator, "op") : Qnil;
      if (!SYMBOL_P(terminator_op) || SYM2ID(terminator_op) != rb_intern("END"))
        rb_raise(rb_eArgError, "RSeq edge action program is not terminated");
    }
    uint32_t destination = (uint32_t)NUM2ULONG(onibi_hash_value(semantic_edge, "to"));
    if (destination == header.state_count - 1) destination = ONIBI_ACCEPT_STATE;
    uint32_t action_index = (uint32_t)NUM2ULONG(onibi_hash_value(semantic_edge, "action_offset"));
    uint32_t expected_offset = action_index == 0 && RARRAY_LEN(onibi_hash_value(semantic_edge, "actions")) == 0 ? 0 :
      (uint32_t)(sizeof(OnibiRAction) * (action_index + 1));
    if (edges[i].destination != destination || edges[i].action_offset != expected_offset)
      rb_raise(rb_eArgError, "RSeq edge disagrees with semantic edge");
    if (!NIL_P(physical_graph)) {
      VALUE cached_edge = rb_ary_entry(onibi_hash_value(physical_graph, "edges"), i);
      uint32_t cached_to = RB_TYPE_P(cached_edge, T_HASH) ? (uint32_t)NUM2ULONG(onibi_hash_value(cached_edge, "to")) : UINT32_MAX;
      VALUE cached_actions = RB_TYPE_P(cached_edge, T_HASH) ? onibi_hash_value(cached_edge, "actions") : Qnil;
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
        !RTEST(rb_obj_frozen_p(onibi_hash_value(semantic_edge, "actions"))))
      rb_raise(rb_eArgError, "invalid semantic RSeq start edge");
    VALUE semantic_edge_actions = onibi_hash_value(semantic_edge, "actions");
    if (RARRAY_LEN(semantic_edge_actions) > 0) {
      VALUE terminator = rb_ary_entry(semantic_edge_actions, RARRAY_LEN(semantic_edge_actions) - 1);
      VALUE terminator_op = RB_TYPE_P(terminator, T_HASH) ? onibi_hash_value(terminator, "op") : Qnil;
      if (!SYMBOL_P(terminator_op) || SYM2ID(terminator_op) != rb_intern("END"))
        rb_raise(rb_eArgError, "RSeq start-edge action program is not terminated");
    }
    uint32_t destination = (uint32_t)NUM2ULONG(onibi_hash_value(semantic_edge, "to"));
    uint32_t action_index = (uint32_t)NUM2ULONG(onibi_hash_value(semantic_edge, "action_offset"));
    uint32_t expected_offset = RARRAY_LEN(onibi_hash_value(semantic_edge, "actions")) == 0 ? 0 :
      (uint32_t)(sizeof(OnibiRAction) * (action_index + 1));
    if (edges[header.edge_count - header.start_edge_count + i].destination != destination ||
        edges[header.edge_count - header.start_edge_count + i].action_offset != expected_offset)
      rb_raise(rb_eArgError, "RSeq edge disagrees with semantic start edge");
    if (!NIL_P(physical_graph)) {
      VALUE cached_edge = rb_ary_entry(onibi_hash_value(physical_graph, "start_edges"), i);
      VALUE cached_actions = RB_TYPE_P(cached_edge, T_HASH) ? onibi_hash_value(cached_edge, "actions") : Qnil;
      uint32_t cached_to = RB_TYPE_P(cached_edge, T_HASH) ? (uint32_t)NUM2ULONG(onibi_hash_value(cached_edge, "to")) : UINT32_MAX;
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
    ID op = SYM2ID(onibi_hash_value(semantic_action, "op"));
    uint8_t expected_op = (op == rb_intern("CAPTURE_OPEN") || op == rb_intern("CAPTURE_CLOSE")) ? ONIBI_RA_CAPTURE :
      op == rb_intern("MATCH_RESET") ? ONIBI_RA_MATCH_RESET :
      (op == rb_intern("ASSERT_BEGIN_BUFFER") || op == rb_intern("ASSERT_END_BUFFER") ||
       op == rb_intern("ASSERT_BEGIN_LINE") || op == rb_intern("ASSERT_END_LINE") ||
       op == rb_intern("ASSERT_SEMI_END_BUFFER") || op == rb_intern("ASSERT_SEARCH_ORIGIN") ||
       op == rb_intern("ASSERT_WORD_BOUNDARY") || op == rb_intern("ASSERT_NONWORD_BOUNDARY") ||
       op == rb_intern("ASSERT_LOOKAHEAD") || op == rb_intern("ASSERT_LOOKBEHIND")) ? ONIBI_RA_ASSERT_POSITION :
      op == rb_intern("TEST_CAPTURE") ? ONIBI_RA_TEST_CAPTURE :
      op == rb_intern("COUNTER_INIT") ? ONIBI_RA_COUNTER_SET :
      op == rb_intern("COUNTER_INCREMENT") ? ONIBI_RA_COUNTER_ADD :
      (op == rb_intern("TEST_COUNTER_LT") || op == rb_intern("TEST_COUNTER_GE")) ? ONIBI_RA_COUNTER_TEST :
      op == rb_intern("END") ? ONIBI_RA_END : 0xff;
    VALUE slot = onibi_hash_value(semantic_action, "slot");
    VALUE limit = onibi_hash_value(semantic_action, "limit");
    VALUE value = onibi_hash_value(semantic_action, "value");
    VALUE width = onibi_hash_value(semantic_action, "width");
    if (op == rb_intern("ASSERT_LOOKAHEAD") || op == rb_intern("ASSERT_LOOKBEHIND")) {
      VALUE predicates = onibi_hash_value(semantic_action, "predicates");
      if (!RB_TYPE_P(predicates, T_ARRAY) || !RTEST(rb_obj_frozen_p(predicates)) ||
          NIL_P(width) || NUM2LONG(width) != RARRAY_LEN(predicates))
        rb_raise(rb_eArgError, "RSeq lookaround predicates are invalid");
      for (long p = 0; p < RARRAY_LEN(predicates); p++) {
        VALUE predicate = rb_ary_entry(predicates, p);
        VALUE kind = onibi_hash_value(predicate, "kind");
        if (!RB_TYPE_P(predicate, T_HASH) || !RTEST(rb_obj_frozen_p(predicate)) ||
            (kind != ID2SYM(rb_intern("byte")) && kind != ID2SYM(rb_intern("bitmap")) &&
             kind != ID2SYM(rb_intern("any"))))
          rb_raise(rb_eArgError, "RSeq lookaround predicate has an invalid kind");
        if (kind == ID2SYM(rb_intern("byte"))) {
          VALUE byte = onibi_hash_value(predicate, "byte");
          if (NIL_P(byte) || NUM2LONG(byte) < 0 || NUM2LONG(byte) > 255)
            rb_raise(rb_eArgError, "RSeq lookaround byte predicate is invalid");
        } else if (kind == ID2SYM(rb_intern("bitmap"))) {
          VALUE bitmap = onibi_hash_value(predicate, "bitmap");
          if (!RB_TYPE_P(bitmap, T_STRING) || RSTRING_LEN(bitmap) != 32 || !RTEST(rb_obj_frozen_p(bitmap)))
            rb_raise(rb_eArgError, "RSeq lookaround bitmap predicate is invalid");
        }
      }
    }
    uint32_t expected_arg32 = !NIL_P(width) ? (uint32_t)NUM2ULONG(width) :
      (!NIL_P(limit) ? (uint32_t)NUM2ULONG(limit) :
       (!NIL_P(value) ? (uint32_t)NUM2ULONG(value) : 0));
    uint8_t expected_flags = onibi_rseq_action_flags(op);
    if (op == rb_intern("TEST_CAPTURE") && !RTEST(onibi_hash_value(semantic_action, "set")))
      expected_flags = ONIBI_RA_TEST_CAPTURE_UNSET;
    uint16_t expected_arg16 = !NIL_P(slot) ? (uint16_t)NUM2ULONG(slot) : onibi_rseq_assert_kind(op);
    if (op == rb_intern("ASSERT_LOOKAHEAD") || op == rb_intern("ASSERT_LOOKBEHIND")) {
      int positive = RTEST(onibi_hash_value(semantic_action, "positive"));
      expected_flags = op == rb_intern("ASSERT_LOOKAHEAD") ? (positive ? 1 : 2) : (positive ? 5 : 6);
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
  for (uint32_t i = 0; i < NUM2UINT(onibi_hash_value(semantic, "literal_count")); i++) {
    if (literals[i].data_length != 1 || (literals[i].flags & ~1U) != 0)
      rb_raise(rb_eArgError, "invalid Onibi RSeq literal descriptor");
    if (literals[i].data_offset < header.literals_offset ||
        (uint64_t)literals[i].data_offset + literals[i].data_length > header.descriptors_offset)
      rb_raise(rb_eArgError, "invalid Onibi RSeq literal descriptor range");
  }
  for (uint32_t i = 0; i < header.state_count; i++) {
    VALUE state = rb_ary_entry(semantic_states, i);
    ID op = SYM2ID(onibi_hash_value(state, "op"));
    VALUE payload = onibi_hash_value(state, "payload");
    if (op == rb_intern("G_CLASS")) {
      uint32_t id = ((const OnibiRState *)(RSTRING_PTR(blob) + header.states_offset))[i].payload;
      VALUE bitmap = onibi_hash_value(payload, "bitmap");
      if (id >= header.class_count || memcmp(RSTRING_PTR(bitmap),
          RSTRING_PTR(blob) + classes[id].data_offset, 32) != 0 ||
          ((classes[id].flags & 1U) != (RTEST(onibi_hash_value(payload, "negated")) ? 1U : 0U)))
        rb_raise(rb_eArgError, "RSeq class descriptor disagrees with semantic payload");
    } else if (op == rb_intern("G_CHAR")) {
      uint32_t id = ((const OnibiRState *)(RSTRING_PTR(blob) + header.states_offset))[i].payload;
      VALUE byte = onibi_hash_value(payload, "byte");
      if (id >= NUM2UINT(onibi_hash_value(semantic, "literal_count")) ||
          (unsigned char)RSTRING_PTR(blob)[literals[id].data_offset] != (unsigned char)NUM2INT(byte) ||
          ((literals[id].flags & 1U) != (RTEST(onibi_hash_value(payload, "ignorecase")) ? 1U : 0U)))
        rb_raise(rb_eArgError, "RSeq literal descriptor disagrees with semantic payload");
    }
  }
}

/* Build the regular execution view from the published RSeq blob.  Semantic
   payloads remain Ruby values, but state operations and edge destinations
   come from the physical layout.  This keeps the VM on the RSeq contract. */
static VALUE onibi_rseq_physical_graph(VALUE rseq) {
  VALUE cached = rb_hash_aref(rseq, ID2SYM(rb_intern("physical_graph")));
  if (!NIL_P(cached)) return cached;
  VALUE blob = onibi_hash_value(rseq, "blob");
  VALUE semantic_states = onibi_hash_value(rseq, "states");
  VALUE semantic_edges = onibi_hash_value(rseq, "edges");
  VALUE semantic_start_edges = onibi_hash_value(rseq, "start_edges");
  VALUE semantic_actions = onibi_hash_value(rseq, "actions");
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
    ID op = physical_states[i].op == ONIBI_RS_CHAR ? rb_intern("G_CHAR") :
      physical_states[i].op == ONIBI_RS_CLASS ? rb_intern("G_CLASS") :
      physical_states[i].op == ONIBI_RS_ANY ? rb_intern("G_ANY") :
      physical_states[i].op == ONIBI_RS_GRAPHEME ? rb_intern("G_GRAPHEME") :
      physical_states[i].op == ONIBI_RS_BACKREF ? rb_intern("G_BACKREF") :
      physical_states[i].op == ONIBI_RS_CALL ? rb_intern("G_CALL") :
      physical_states[i].op == ONIBI_RS_ATOMIC ? rb_intern("G_ATOMIC") :
      physical_states[i].op == ONIBI_RS_ABSENT ? rb_intern("G_ABSENT") : rb_intern("G_ACCEPT");
    rb_hash_aset(state, ID2SYM(rb_intern("op")), ID2SYM(op));
    rb_ary_push(states, state);
  }
  for (long i = 0; i < RARRAY_LEN(semantic_edges); i++) {
    VALUE edge = rb_hash_dup(rb_ary_entry(semantic_edges, i));
    uint32_t destination = physical_edges[i].destination;
    if (destination == ONIBI_ACCEPT_STATE) destination = (uint32_t)(RARRAY_LEN(states) - 1);
    rb_hash_aset(edge, ID2SYM(rb_intern("to")), UINT2NUM(destination));
    VALUE physical_program = rb_ary_new();
    uint32_t action_offset = physical_edges[i].action_offset;
    if (action_offset != 0) {
      uint32_t action_index = action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
      for (uint32_t a = action_index; a < (uint32_t)RARRAY_LEN(semantic_actions); a++) {
        VALUE action = rb_ary_entry(semantic_actions, a);
        rb_ary_push(physical_program, action);
        if (SYM2ID(onibi_hash_value(action, "op")) == rb_intern("END")) break;
      }
    }
    rb_hash_aset(edge, ID2SYM(rb_intern("actions")), physical_program);
    rb_ary_push(edges, edge);
    long from = NUM2LONG(onibi_hash_value(edge, "from"));
    if (from >= 0 && from < RARRAY_LEN(outgoing)) rb_ary_push(rb_ary_entry(outgoing, from), edge);
  }
  for (long i = 0; i < RARRAY_LEN(semantic_start_edges); i++) {
    VALUE edge = rb_hash_dup(rb_ary_entry(semantic_start_edges, i));
    const OnibiREdge *physical_edge = &physical_edges[header.start_edge_base + i];
    rb_hash_aset(edge, ID2SYM(rb_intern("to")), UINT2NUM(physical_edge->destination));
    VALUE physical_program = rb_ary_new();
    if (physical_edge->action_offset != 0) {
      uint32_t action_index = physical_edge->action_offset / (uint32_t)sizeof(OnibiRAction) - 1U;
      for (uint32_t a = action_index; a < (uint32_t)RARRAY_LEN(semantic_actions); a++) {
        VALUE action = rb_ary_entry(semantic_actions, a);
        rb_ary_push(physical_program, action);
        if (SYM2ID(onibi_hash_value(action, "op")) == rb_intern("END")) break;
      }
    }
    rb_hash_aset(edge, ID2SYM(rb_intern("actions")), physical_program);
    rb_ary_push(start_edges, edge);
  }
  rb_hash_aset(graph, ID2SYM(rb_intern("states")), states);
  rb_hash_aset(graph, ID2SYM(rb_intern("edges")), edges);
  rb_hash_aset(graph, ID2SYM(rb_intern("start_edges")), start_edges);
  rb_hash_aset(graph, ID2SYM(rb_intern("outgoing")), outgoing);
  rb_hash_aset(graph, ID2SYM(rb_intern("subprograms")), onibi_hash_value(rseq, "subprograms"));
  return graph;
}

static VALUE onibi_vm_regular_fast(VALUE rseq, VALUE str) {
  VALUE graph = onibi_rseq_physical_graph(rseq);
  for (long start = 0; start <= RSTRING_LEN(str); start++) {
    if (!onibi_character_boundary(str, start)) continue;
    rb_thread_check_ints();
    onibi_check_deadline();
    long end = 0;
    if (onibi_gir_match(graph, str, start, &end)) return Qtrue;
  }
  return Qfalse;
}

static VALUE onibi_vm_tagged_ordered(VALUE rseq, VALUE str) {
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

static VALUE onibi_vm_dynamic(VALUE rseq, VALUE str) {
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

static VALUE onibi_vm_execute(VALUE self, VALUE rseq, VALUE str, VALUE execution_class) {
  (void)self;
  StringValue(str);
  if (!rb_respond_to(rseq, id_trusted_rseq)) onibi_rseq_validate(rseq);
  if (execution_class != ID2SYM(rb_intern("REGULAR_FAST")) &&
      execution_class != ID2SYM(rb_intern("TAGGED_ORDERED")) &&
      execution_class != ID2SYM(rb_intern("DYNAMIC")))
    rb_raise(rb_eArgError, "unknown Onibi execution class");
  VALUE physical_blob = onibi_hash_value(rseq, "blob");
  OnibiRSeqHeader physical_header;
  memcpy(&physical_header, RSTRING_PTR(physical_blob), sizeof(physical_header));
  uint8_t expected_kind = execution_class == ID2SYM(rb_intern("DYNAMIC")) ? 2 :
    (execution_class == ID2SYM(rb_intern("TAGGED_ORDERED")) ? 1 : 0);
  if (physical_header.exec_kind != expected_kind)
    rb_raise(rb_eArgError, "RSeq execution class does not match blob");
  if (execution_class == ID2SYM(rb_intern("REGULAR_FAST"))) return onibi_vm_regular_fast(rseq, str);
  if (execution_class == ID2SYM(rb_intern("TAGGED_ORDERED"))) return onibi_vm_tagged_ordered(rseq, str);
  return onibi_vm_dynamic(rseq, str);
}

static VALUE onibi_vm_match_p(VALUE self, VALUE str) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  StringValue(str);
  onibi_set_deadline(obj->timeout_seconds);
  if (!(obj->options & 32) && (!(obj->options & 16) || onibi_encoded_literal_program_p(obj)) &&
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
      VALUE result = obj->execution_kind == ID2SYM(rb_intern("REGULAR_FAST")) ?
        onibi_vm_regular_fast(obj->rseq, str) :
        (obj->execution_kind == ID2SYM(rb_intern("TAGGED_ORDERED")) ?
          onibi_vm_tagged_ordered(obj->rseq, str) : onibi_vm_dynamic(obj->rseq, str));
      onibi_deadline_ns = 0;
      return result;
    }
  onibi_deadline_ns = 0;
  return rb_funcall(obj->regexp, id_match_p, 1, str);
}

static VALUE onibi_mri_match_result(VALUE match) {
  VALUE result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("start")), rb_funcall(match, rb_intern("bytebegin"), 1, INT2NUM(0)));
  rb_hash_aset(result, ID2SYM(rb_intern("end")), rb_funcall(match, rb_intern("byteend"), 1, INT2NUM(0)));
  VALUE captures = rb_hash_new();
  long capture_count = NUM2LONG(rb_funcall(match, rb_intern("length"), 0)) - 1;
  for (long group_id = 1; group_id <= capture_count; group_id++) {
    VALUE begin = rb_funcall(match, rb_intern("bytebegin"), 1, LONG2NUM(group_id));
    VALUE finish = rb_funcall(match, rb_intern("byteend"), 1, LONG2NUM(group_id));
    if (NIL_P(begin) || NIL_P(finish) || NUM2LONG(begin) < 0 || NUM2LONG(finish) < 0) continue;
    VALUE group = rb_hash_new();
    rb_hash_aset(group, ID2SYM(rb_intern("start")), begin);
    rb_hash_aset(group, ID2SYM(rb_intern("end")), finish);
    rb_hash_aset(captures, LONG2NUM(group_id), group);
  }
  if (RHASH_SIZE(captures) > 0) rb_hash_aset(result, ID2SYM(rb_intern("captures")), captures);
  return result;
}

static VALUE onibi_vm_match_result(VALUE self, VALUE str) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  StringValue(str);
  if (obj->has_nullable_capture) {
    VALUE match = rb_funcall(obj->regexp, id_match, 1, str);
    return NIL_P(match) ? Qnil : onibi_mri_match_result(match);
  }
  int graph_ok = !(obj->options & 32) && (!(obj->options & 16) || onibi_encoded_literal_program_p(obj)) && !NIL_P(obj->rseq) &&
    onibi_vm_input_eligible(obj, str) &&
    (!obj->has_ascii_property || rb_enc_str_asciionly_p(str) ||
     (obj->has_unicode_property &&
      (rb_enc_get_index(str) == rb_utf8_encindex() ||
       rb_enc_get_index(str) == rb_enc_get_index(obj->source)))) &&
    (rb_enc_str_asciionly_p(str) || onibi_valid_encoding(str));
  if (!graph_ok) {
    if (!RTEST(onibi_vm_match_p(self, str))) return Qnil;
  }
  if (NIL_P(obj->rseq)) {
    VALUE match = rb_funcall(obj->regexp, id_match, 1, str);
    return NIL_P(match) ? Qnil : onibi_mri_match_result(match);
  }
  if (graph_ok) {
    onibi_set_deadline(obj->timeout_seconds);
    VALUE rseq = obj->rseq;
    VALUE graph = onibi_rseq_physical_graph(rseq);
    for (long pos = 0; pos <= RSTRING_LEN(str); pos++) {
      if (!onibi_character_boundary(str, pos)) continue;
      long end = 0;
      long reported_start = pos;
      VALUE capture_state = rb_hash_new();
      if (!onibi_gir_match_captures(graph, str, pos, &end, &reported_start, &capture_state)) continue;
      VALUE result = rb_hash_new();
      rb_hash_aset(result, ID2SYM(rb_intern("start")), LONG2NUM(reported_start));
      rb_hash_aset(result, ID2SYM(rb_intern("end")), LONG2NUM(end));
      VALUE captures = rb_hash_new();
      VALUE header = onibi_hash_value(rseq, "header");
      long capture_count = NUM2LONG(onibi_hash_value(header, "capture_count"));
      for (long group_id = 1; group_id <= capture_count; group_id++) {
        VALUE begin = rb_hash_aref(capture_state, LONG2NUM(2 * (group_id - 1)));
        VALUE finish = rb_hash_aref(capture_state, LONG2NUM(2 * (group_id - 1) + 1));
        if (!NIL_P(begin) && !NIL_P(finish)) {
          VALUE group = rb_hash_new();
          rb_hash_aset(group, ID2SYM(rb_intern("start")), begin);
          rb_hash_aset(group, ID2SYM(rb_intern("end")), finish);
          rb_hash_aset(captures, LONG2NUM(group_id), group);
        }
      }
      if (RHASH_SIZE(captures) > 0) rb_hash_aset(result, ID2SYM(rb_intern("captures")), captures);
      onibi_deadline_ns = 0;
      return result;
    }
    onibi_deadline_ns = 0;
    return Qnil;
  }
  VALUE match = rb_funcall(obj->regexp, id_match, 1, str);
  if (NIL_P(match)) return Qnil;
  return onibi_mri_match_result(match);
}

static VALUE onibi_scan(VALUE self, VALUE str) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(str, id_scan, 1, obj->regexp);
}
static VALUE onibi_gsub(VALUE self, VALUE str, VALUE replacement) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(str, id_gsub, 2, obj->regexp, replacement);
}

void Init_onibi(void) {
  id_initialize = rb_intern("initialize"); id_match = rb_intern("match");
  id_new = rb_intern("new");
  id_match_p = rb_intern("match?"); id_source = rb_intern("source");
  id_options = rb_intern("options"); id_inspect = rb_intern("inspect"); id_to_s = rb_intern("to_s");
  id_trusted_rseq = rb_intern("__onibi_trusted_rseq__");
  id_scan = rb_intern("scan"); id_gsub = rb_intern("gsub");
  id_encoding = rb_intern("encoding");
  id_index = rb_intern("index");
  mOnibi = rb_define_module("Onibi");
  eRegexpError = rb_define_class_under(mOnibi, "RegexpError", rb_eRegexpError);
  rb_define_const(mOnibi, "Error", rb_eStandardError);
  cLexer = rb_define_class_under(mOnibi, "Lexer", rb_cObject);
  rb_define_alloc_func(cLexer, onibi_lexer_alloc);
  rb_define_method(cLexer, "initialize", onibi_lexer_initialize, -1);
  rb_define_method(cLexer, "tokens", onibi_lexer_tokens, 0);
  VALUE parser = rb_define_module_under(mOnibi, "Parser");
  rb_define_singleton_method(parser, "parse", onibi_parser_parse, -1);
  VALUE compiler = rb_define_module_under(mOnibi, "Compiler");
  rb_define_singleton_method(compiler, "compile", onibi_compiler_compile, 1);
  VALUE rseq = rb_define_module_under(mOnibi, "RSeq");
  rb_define_singleton_method(rseq, "lower", onibi_rseq_lower, 1);
  VALUE vm = rb_define_module_under(mOnibi, "VM");
  rb_define_singleton_method(vm, "execute", onibi_vm_execute, 3);
  cRegexp = rb_define_class_under(mOnibi, "Regexp", rb_cObject);
  eTimeoutError = rb_define_class_under(cRegexp, "TimeoutError", eRegexpError);
  rb_define_singleton_method(cRegexp, "timeout=", onibi_timeout_set, 1);
  rb_define_singleton_method(cRegexp, "timeout", onibi_timeout_default, 0);
  rb_define_singleton_method(cRegexp, "escape", onibi_regexp_escape, 1);
  rb_define_singleton_method(cRegexp, "union", onibi_regexp_union, -1);
  rb_define_alloc_func(cRegexp, onibi_alloc);
  rb_define_method(cRegexp, "initialize", onibi_initialize, -1);
  rb_define_method(cRegexp, "match", onibi_match, -1);
  rb_define_method(cRegexp, "match?", onibi_match_p, -1);
  rb_define_method(cRegexp, "source", onibi_source, 0);
  rb_define_method(cRegexp, "options", onibi_options, 0);
  rb_define_method(cRegexp, "fixed_encoding?", onibi_fixed_encoding_p, 0);
  rb_define_method(cRegexp, "no_encoding?", onibi_no_encoding_p, 0);
  rb_define_method(cRegexp, "inspect", onibi_inspect, 0);
  rb_define_method(cRegexp, "to_s", onibi_to_s, 0);
  rb_define_method(cRegexp, "execution_class", onibi_execution_class, 0);
  rb_define_method(cRegexp, "encoding", onibi_encoding, 0);
  rb_define_method(cRegexp, "program_size", onibi_program_size, 0);
  rb_define_method(cRegexp, "program_frozen?", onibi_program_frozen, 0);
  rb_define_method(cRegexp, "program_cached?", onibi_program_cached, 0);
  rb_define_method(cRegexp, "timeout", onibi_timeout, 0);
  rb_define_method(cRegexp, "pipeline", onibi_pipeline, 0);
  rb_define_method(cRegexp, "vm_match?", onibi_vm_match_p, 1);
  rb_define_method(cRegexp, "vm_match_result", onibi_vm_match_result, 1);
  rb_define_method(cRegexp, "scan", onibi_scan, 1);
  rb_define_method(cRegexp, "gsub", onibi_gsub, 2);
  rb_define_const(cRegexp, "IGNORECASE", INT2NUM(1));
  rb_define_const(cRegexp, "EXTENDED", INT2NUM(2));
  rb_define_const(cRegexp, "MULTILINE", INT2NUM(4));
  rb_define_const(cRegexp, "FIXEDENCODING", INT2NUM(16));
  rb_define_const(cRegexp, "NOENCODING", INT2NUM(32));
}
