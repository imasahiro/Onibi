#include "ruby.h"
#include "ruby/encoding.h"
#include "ruby/thread.h"
#include "onibi_ir.h"
#include <string.h>
#include <stdio.h>
#include <ctype.h>
#include <time.h>
#include <math.h>
#include <float.h>
#include <errno.h>

static VALUE mOnibi, cRegexp, cLexer, eRegexpError, eTimeoutError;
static double onibi_default_timeout = 0.0;
static _Thread_local uint64_t onibi_deadline_ns = 0;
static ID id_initialize, id_match, id_match_p, id_source, id_options, id_inspect, id_new;
static ID id_scan, id_gsub, id_encoding, id_index;
static VALUE onibi_vm_match_p(VALUE self, VALUE str);
static VALUE onibi_vm_match_result(VALUE self, VALUE str);
static VALUE onibi_pipeline_build(VALUE self);

static int onibi_ascii_pattern(VALUE source) {
  return rb_enc_str_asciionly_p(source);
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

typedef struct { VALUE regexp; VALUE source; VALUE tokens; VALUE execution_class; VALUE execution_kind; VALUE parsed; VALUE compiled; VALUE rseq; VALUE pipeline; int options; long program_size; double timeout_seconds; int has_class_intersection; int has_subroutine; int has_dynamic; int has_tagged; } onibi_regexp_t;
typedef struct { VALUE source; VALUE tokens; } onibi_lexer_t;

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
  "Onibi::Regexp", { onibi_mark, onibi_free, onibi_memsize }, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY
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
  "Onibi::Lexer", { onibi_lexer_mark, onibi_lexer_free, onibi_lexer_memsize }, 0, 0,
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
  long class_body_start = -1;
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
    } else if (byte == '[' && !in_class) {
      kind = "class_start";
      in_class = 1;
      class_body_start = i + 1;
    } else if (byte == ']' && in_class) {
      kind = "class_end";
      in_class = 0;
    } else if (in_class) {
      if (byte == '-' && i > class_body_start) kind = "class_range";
      else if (byte == '^' && i == class_body_start) kind = "class_negate";
    } else if (byte == '|') kind = "alternation";
    else if (byte == '(') kind = "group_start";
    else if (byte == ')') kind = "group_end";
    else if (strchr("*+?{} ,", byte) != NULL) kind = "quantifier";
    else if (byte == '.') kind = "wildcard";
    else if (byte == '^' || byte == '$') kind = "anchor";
    rb_hash_aset(token, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern(kind)));
    rb_hash_aset(token, ID2SYM(rb_intern("byte")), INT2NUM(byte));
    rb_hash_aset(token, ID2SYM(rb_intern("start")), LONG2NUM(start));
    rb_hash_aset(token, ID2SYM(rb_intern("end")), LONG2NUM(i + 1));
    if (!NIL_P(backref_name)) { rb_obj_freeze(backref_name); rb_hash_aset(token, ID2SYM(rb_intern("name")), backref_name); }
    if (!NIL_P(group_name)) { rb_obj_freeze(group_name); rb_hash_aset(token, ID2SYM(rb_intern("name")), group_name); }
    if (!NIL_P(posix_name)) { rb_obj_freeze(posix_name); rb_hash_aset(token, ID2SYM(rb_intern("name")), posix_name); }
    rb_obj_freeze(token);
    rb_ary_push(tokens, token);
  }
  rb_obj_freeze(tokens);
  return tokens;
}

static VALUE onibi_tokenize(VALUE src) {
  return onibi_tokenize_internal(src, 0);
}

static VALUE onibi_lexer_initialize(VALUE self, VALUE source) {
  onibi_lexer_t *obj;
  TypedData_Get_Struct(self, onibi_lexer_t, &onibi_lexer_type, obj);
  source = StringValue(source);
  obj->source = rb_str_dup(source);
  rb_obj_freeze(obj->source);
  obj->tokens = onibi_tokenize(obj->source);
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

static VALUE onibi_parse_range(VALUE src, VALUE tokens, long begin, long end);
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
        kind == rb_intern("lookbehind_start")) depth++;
    else if (kind == close && --depth == 0) return i;
  }
  return -1;
}

static VALUE onibi_parse_class(VALUE tokens, long begin, long close) {
  VALUE node = onibi_ast_node("character_class", rb_ary_entry(tokens, begin));
  VALUE children = rb_ary_new(), ranges = rb_ary_new();
  int negated = 0;
  for (long i = begin + 1; i < close; i++) {
    VALUE token = rb_ary_entry(tokens, i);
    ID kind = onibi_token_kind(token);
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
      if (onibi_token_byte(rb_ary_entry(tokens, i - 1)) > onibi_token_byte(rb_ary_entry(tokens, i + 1)))
        rb_raise(eRegexpError, "empty range in character class");
      VALUE range = rb_ary_new();
      rb_ary_push(range, LONG2NUM(onibi_token_byte(rb_ary_entry(tokens, i - 1))));
      rb_ary_push(range, LONG2NUM(onibi_token_byte(rb_ary_entry(tokens, i + 1))));
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

static VALUE onibi_parse_atom(VALUE src, VALUE tokens, long *index, long end) {
  VALUE token = rb_ary_entry(tokens, *index);
  ID kind = onibi_token_kind(token);
  if (kind == rb_intern("lookahead_start") || kind == rb_intern("lookbehind_start")) {
    long close = onibi_find_close(tokens, *index, end, kind, rb_intern("group_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated lookaround");
    int behind = kind == rb_intern("lookbehind_start");
    VALUE node = onibi_ast_node(behind ? "lookbehind" : "lookahead", token);
    rb_hash_aset(node, ID2SYM(rb_intern("body")), onibi_parse_range(src, tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(rb_intern("positive")), onibi_token_byte(token) == '=' ? Qtrue : Qfalse);
    rb_hash_aset(node, ID2SYM(rb_intern("end")), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(rb_intern("end"))));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind == rb_intern("noncapture_start")) {
    long close = onibi_find_close(tokens, *index, end, rb_intern("noncapture_start"), rb_intern("group_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated group");
    VALUE node = onibi_ast_node("group", token);
    rb_hash_aset(node, ID2SYM(rb_intern("body")), onibi_parse_range(src, tokens, *index + 1, close));
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
    rb_hash_aset(node, ID2SYM(rb_intern("body")), onibi_parse_range(src, tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(rb_intern("end")), rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(rb_intern("end"))));
    rb_obj_freeze(node);
    *index = close + 1;
    return node;
  }
  if (kind == rb_intern("group_start")) {
    long close = onibi_find_close(tokens, *index, end, rb_intern("group_start"), rb_intern("group_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated group");
    VALUE node = onibi_ast_node("capture", token);
    rb_hash_aset(node, ID2SYM(rb_intern("body")), onibi_parse_range(src, tokens, *index + 1, close));
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
     (kind == rb_intern("escape") ? onibi_ast_node("escape", token) :
       (kind == rb_intern("match_reset") ? onibi_ast_node("match_reset", token) :
       (kind == rb_intern("backref") ? onibi_ast_node("backref", token) :
       (kind == rb_intern("literal") ? onibi_ast_node("literal", token) : Qnil))))));
  if (NIL_P(node)) rb_raise(eRegexpError, "unexpected token in expression");
  rb_hash_aset(node, ID2SYM(rb_intern("byte")), LONG2NUM(onibi_token_byte(token)));
  if (kind == rb_intern("anchor")) {
    long marker = onibi_token_byte(token);
    const char *anchor = (marker == '^' || marker == 'A' || marker == 'G') ?
      "anchor_start" : ((marker == '$' || marker == 'z' || marker == 'Z') ?
      "anchor_end" : "anchor");
    rb_hash_aset(node, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern(anchor)));
  }
  if (kind == rb_intern("escape"))
    rb_hash_aset(node, ID2SYM(rb_intern("name")), rb_str_new((const char[]){(char)onibi_token_byte(token)}, 1));
  if (kind == rb_intern("backref")) {
    VALUE name = rb_hash_aref(token, ID2SYM(rb_intern("name")));
    if (NIL_P(name)) rb_hash_aset(node, ID2SYM(rb_intern("capture")), LONG2NUM(onibi_token_byte(token) - '0'));
    else rb_hash_aset(node, ID2SYM(rb_intern("name")), name);
  }
  rb_obj_freeze(node);
  *index = *index + 1;
  return node;
}

static VALUE onibi_parse_range(VALUE src, VALUE tokens, long begin, long end) {
  VALUE branches = rb_ary_new();
  long part = begin, depth = 0;
  for (long i = begin; i < end; i++) {
    ID kind = onibi_token_kind(rb_ary_entry(tokens, i));
    if (kind == rb_intern("group_start") || kind == rb_intern("noncapture_start") || kind == rb_intern("atomic_start") || kind == rb_intern("lookahead_start") || kind == rb_intern("lookbehind_start") || kind == rb_intern("class_start")) depth++;
    else if (kind == rb_intern("group_end") || kind == rb_intern("class_end")) depth--;
    else if (kind == rb_intern("alternation") && depth == 0) {
      rb_ary_push(branches, onibi_parse_range(src, tokens, part, i));
      part = i + 1;
    }
  }
  if (RARRAY_LEN(branches) > 0) {
    rb_ary_push(branches, onibi_parse_range(src, tokens, part, end));
    VALUE node = onibi_ast_node("alternative", Qnil);
    rb_hash_aset(node, ID2SYM(rb_intern("branches")), branches);
    rb_obj_freeze(branches); rb_obj_freeze(node);
    return node;
  }

  VALUE children = rb_ary_new();
  for (long i = begin; i < end;) {
    VALUE node = onibi_parse_atom(src, tokens, &i, end);
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
        long spec_start = NUM2LONG(rb_hash_aref(rb_ary_entry(tokens, i), ID2SYM(rb_intern("start"))));
        long spec_end = NUM2LONG(rb_hash_aref(rb_ary_entry(tokens, close), ID2SYM(rb_intern("start"))));
        VALUE spec = rb_str_substr(src, spec_start, spec_end - spec_start);
        long min = 0, max_value = 0;
        const char *body = RSTRING_PTR(spec) + 1;
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
  else if (RB_TYPE_P(options, T_STRING)) {
    const char *p = RSTRING_PTR(options);
    for (long i = 0; i < RSTRING_LEN(options); i++) {
      const char *name = p[i] == 'i' ? "ignorecase" : (p[i] == 'm' ? "multiline" : (p[i] == 'x' ? "extended" : NULL));
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
    int extended = 0;
    if (!NIL_P(options)) {
      if (RB_TYPE_P(options, T_STRING)) extended = memchr(RSTRING_PTR(options), 'x', (size_t)RSTRING_LEN(options)) != NULL;
      else extended = (NUM2INT(options) & 2) != 0;
    }
    tokens = onibi_tokenize_internal(source, extended);
  }
  VALUE result = rb_hash_new();
  VALUE source_copy = rb_str_dup(source);
  rb_obj_freeze(source_copy);
  rb_hash_aset(result, ID2SYM(rb_intern("source")), source_copy);
  rb_hash_aset(result, ID2SYM(rb_intern("options")), onibi_parser_options(options));
  rb_hash_aset(result, ID2SYM(rb_intern("tokens")), tokens);
  rb_hash_aset(result, ID2SYM(rb_intern("ast")), onibi_deep_freeze(onibi_parse_range(source, tokens, 0, RARRAY_LEN(tokens))));
  rb_obj_freeze(result);
  return result;
}

static VALUE onibi_parser_parse(int argc, VALUE *argv, VALUE self) {
  VALUE source, options = Qnil;
  rb_scan_args(argc, argv, "11", &source, &options);
  return onibi_parser_parse_internal(source, options, Qnil);
}

typedef struct { VALUE starts; VALUE exits; VALUE start_actions; VALUE pending_actions; int nullable; } onibi_fragment_t;
typedef struct { VALUE states; VALUE edges; long next_id; long capture_count; VALUE capture_names; int ignorecase; int multiline; } onibi_gir_builder_t;
static VALUE onibi_hash_value(VALUE hash, const char *name);

static void onibi_bitmap_set(unsigned char *bits, unsigned char value, int fold) {
  bits[value >> 3] |= (unsigned char)(1U << (value & 7));
  if (fold) {
    unsigned char lower = (unsigned char)tolower(value);
    unsigned char upper = (unsigned char)toupper(value);
    bits[lower >> 3] |= (unsigned char)(1U << (lower & 7));
    bits[upper >> 3] |= (unsigned char)(1U << (upper & 7));
  }
}

static VALUE onibi_class_bitmap(VALUE payload, int fold) {
  unsigned char bits[32];
  memset(bits, 0, sizeof(bits));
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
  }
  for (long i = 0; i < RARRAY_LEN(ranges); i++) {
    VALUE range = rb_ary_entry(ranges, i);
    if (RARRAY_LEN(range) != 2) continue;
    int first = NUM2INT(rb_ary_entry(range, 0));
    int last = NUM2INT(rb_ary_entry(range, 1));
    if (first < 0) first = 0; if (last > 255) last = 255;
    for (int c = first; c <= last; c++) onibi_bitmap_set(bits, (unsigned char)c, fold);
  }
  VALUE children = onibi_hash_value(payload, "children");
  for (long i = 0; i < RARRAY_LEN(children); i++) {
    VALUE child = rb_ary_entry(children, i);
    ID kind = SYM2ID(onibi_hash_value(child, "kind"));
    if (kind == rb_intern("literal")) {
      onibi_bitmap_set(bits, (unsigned char)NUM2INT(onibi_hash_value(child, "byte")), fold);
    } else if (kind == rb_intern("escape")) {
      VALUE name = onibi_hash_value(child, "name");
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
  rb_hash_aset(edge, ID2SYM(rb_intern("actions")), actions);
  rb_ary_push(builder->edges, edge);
}

static void onibi_gir_edge_actions(onibi_gir_builder_t *builder, long from, long to, VALUE actions) {
  VALUE edge = rb_hash_new();
  rb_hash_aset(edge, ID2SYM(rb_intern("from")), LONG2NUM(from));
  rb_hash_aset(edge, ID2SYM(rb_intern("to")), LONG2NUM(to));
  rb_hash_aset(edge, ID2SYM(rb_intern("actions")), actions);
  rb_ary_push(builder->edges, edge);
}

static onibi_fragment_t onibi_fragment_empty(void) {
  onibi_fragment_t fragment;
  fragment.starts = rb_ary_new(); fragment.exits = rb_ary_new();
  fragment.start_actions = rb_ary_new(); fragment.pending_actions = rb_ary_new(); fragment.nullable = 1;
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

static void onibi_append_values(VALUE destination, VALUE values) {
  for (long i = 0; i < RARRAY_LEN(values); i++) rb_ary_push(destination, rb_ary_entry(values, i));
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
    action == rb_intern("COUNTER_INCREMENT") || action == rb_intern("TEST_COUNTER_LT") ||
    action == rb_intern("TEST_COUNTER_GE");
}

static void onibi_gir_validate_action_operands(VALUE action) {
  ID op = SYM2ID(onibi_hash_value(action, "op"));
  VALUE slot = onibi_hash_value(action, "slot");
  if (op == rb_intern("CAPTURE_OPEN") || op == rb_intern("CAPTURE_CLOSE")) {
    if (NIL_P(slot) || NUM2LONG(slot) < 0)
      rb_raise(eRegexpError, "invalid GIR capture slot");
  } else if (op == rb_intern("COUNTER_INIT") || op == rb_intern("COUNTER_INCREMENT") ||
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
  long capture_count = NUM2LONG(onibi_hash_value(graph, "capture_count"));
  long counter_count = NUM2LONG(onibi_hash_value(graph, "counter_count"));
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
      have_consuming = 1;
    } else {
      VALUE old_exits = result.exits;
      if (result.nullable) onibi_append_values(result.starts, part.starts);
      VALUE transition_actions = rb_ary_dup(result.pending_actions);
      onibi_append_values(transition_actions, part.start_actions);
      onibi_connect_actions(builder, old_exits, part.starts, transition_actions);
      result.exits = rb_ary_dup(part.exits);
      if (result.nullable) onibi_append_values(result.exits, old_exits);
      result.pending_actions = rb_ary_new();
    }
    onibi_append_values(result.pending_actions, part.pending_actions);
    result.nullable = result.nullable && part.nullable;
  }
  return result;
}

static onibi_fragment_t onibi_compile_node(VALUE ast, onibi_gir_builder_t *builder) {
  VALUE type = onibi_symbol_value(ast, "type");
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
      type == ID2SYM(rb_intern("backref")) || type == ID2SYM(rb_intern("character_class")) || type == ID2SYM(rb_intern("any"))) {
    if (type == ID2SYM(rb_intern("escape"))) {
      VALUE name = onibi_hash_value(ast, "name");
      int code = NIL_P(name) ? 0 : tolower((unsigned char)RSTRING_PTR(name)[0]);
      if (code == 'r' || code == 'p' || code == 'x' || code == 'u')
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
    if (type == ID2SYM(rb_intern("character_class"))) {
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
    rb_raise(eRegexpError, "subroutine calls require the dynamic interpreter");
  if (type == ID2SYM(rb_intern("anchor")))
  {
    onibi_fragment_t result = onibi_fragment_empty();
    VALUE action = rb_hash_new();
    long marker = NUM2LONG(onibi_hash_value(ast, "byte"));
    const char *op = "ASSERT_END_BUFFER";
    if (marker == '^') op = builder->multiline ? "ASSERT_BEGIN_LINE" : "ASSERT_BEGIN_BUFFER";
    else if (marker == '$') op = builder->multiline ? "ASSERT_END_LINE" : "ASSERT_END_BUFFER";
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
  if (type == ID2SYM(rb_intern("lookahead")) || type == ID2SYM(rb_intern("lookbehind"))) {
    VALUE body = onibi_hash_value(ast, "body");
    VALUE children = onibi_hash_value(body, "children");
    VALUE bytes = rb_str_new(NULL, 0);
    for (long i = 0; i < RARRAY_LEN(children); i++) {
      VALUE child = rb_ary_entry(children, i);
      if (onibi_symbol_value(child, "type") != ID2SYM(rb_intern("literal")))
        rb_raise(eRegexpError, "lookahead body is not a literal sequence");
      rb_str_cat(bytes, (const char[]){(char)NUM2INT(onibi_hash_value(child, "byte"))}, 1);
    }
    rb_obj_freeze(bytes);
    VALUE action = rb_hash_new();
    rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern(type == ID2SYM(rb_intern("lookbehind")) ? "ASSERT_LOOKBEHIND" : "ASSERT_LOOKAHEAD")));
    rb_hash_aset(action, ID2SYM(rb_intern("positive")), onibi_hash_value(ast, "positive"));
    rb_hash_aset(action, ID2SYM(rb_intern("bytes")), bytes);
    onibi_fragment_t result = onibi_fragment_empty();
    result.nullable = 1;
    rb_ary_push(result.start_actions, action);
    return result;
  }
  if (type == ID2SYM(rb_intern("capture"))) {
    long capture_id = builder->capture_count++;
    onibi_fragment_t result = onibi_compile_node(onibi_hash_value(ast, "body"), builder);
    VALUE open = rb_hash_new(), close = rb_hash_new();
    rb_hash_aset(open, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("CAPTURE_OPEN")));
    rb_hash_aset(open, ID2SYM(rb_intern("slot")), LONG2NUM(2 * capture_id));
    rb_hash_aset(close, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("CAPTURE_CLOSE")));
    rb_hash_aset(close, ID2SYM(rb_intern("slot")), LONG2NUM(2 * capture_id + 1));
    VALUE capture_name = onibi_hash_value(ast, "name");
    if (!NIL_P(capture_name)) rb_hash_aset(builder->capture_names, capture_name, LONG2NUM(capture_id));
    rb_ary_push(result.start_actions, open);
    rb_ary_push(result.pending_actions, close);
    return result;
  }
  if (type == ID2SYM(rb_intern("group")))
    return onibi_compile_node(onibi_hash_value(ast, "body"), builder);
  if (type == ID2SYM(rb_intern("quantifier"))) {
    if (!RTEST(onibi_hash_value(ast, "greedy")) || RTEST(onibi_hash_value(ast, "possessive")))
      rb_raise(eRegexpError, "quantifier ordering modifier is not supported in RSeq");
    VALUE min_value = onibi_hash_value(ast, "min"), max_value = onibi_hash_value(ast, "max");
    long min = NUM2LONG(min_value);
    if (!NIL_P(max_value) && min == 0 && NUM2LONG(max_value) == 0)
      return onibi_fragment_empty();
    if (!NIL_P(max_value) && min == 0 && NUM2LONG(max_value) == 1) {
      onibi_fragment_t result = onibi_compile_node(onibi_hash_value(ast, "atom"), builder);
      result.nullable = 1;
      return result;
    }
    VALUE atom = onibi_hash_value(ast, "atom");
    onibi_fragment_t result = onibi_fragment_empty();
    result.starts = rb_ary_new(); result.exits = rb_ary_new(); result.nullable = min == 0;
    if (!NIL_P(max_value) && NUM2LONG(max_value) < min)
      rb_raise(eRegexpError, "invalid quantifier range");
    long max = NIL_P(max_value) ? -1 : NUM2LONG(max_value);
    if (max > 1000000)
      rb_raise(eRegexpError, "quantifier exceeds RSeq representation limit");
    if (max >= 0 && max != min) {
      /* Counted repeats use one counter slot.  The first start edge
         initializes it.  Optional bodies use ordered test edges. */
      VALUE init = onibi_counter_action("COUNTER_INIT", 0, Qnil);
      rb_hash_aset(init, ID2SYM(rb_intern("value")), INT2NUM(min > 0 ? 1 : 0));
      rb_ary_push(result.start_actions, init);
    }
    for (long i = 0; i < min; i++) {
      onibi_fragment_t part = onibi_compile_node(atom, builder);
      if (i == 0) result.starts = part.starts;
      else {
        VALUE actions = rb_ary_new();
        rb_ary_push(actions, onibi_counter_action("COUNTER_INCREMENT", 0, Qnil));
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
        rb_ary_push(repeat_actions, onibi_counter_action("TEST_COUNTER_LT", 0, LONG2NUM(max)));
        rb_ary_push(repeat_actions, onibi_counter_action("COUNTER_INCREMENT", 0, Qnil));
        if (RARRAY_LEN(result.exits) > 0)
          onibi_connect_actions(builder, result.exits, part.starts, repeat_actions);
        VALUE next_exits = rb_ary_dup(result.exits);
        onibi_append_values(next_exits, part.exits);
        result.exits = next_exits;
      }
      rb_ary_push(result.pending_actions, onibi_counter_action("TEST_COUNTER_GE", 0, LONG2NUM(min)));
    } else if (NIL_P(max_value)) {
      onibi_fragment_t repeat = onibi_compile_node(atom, builder);
      if (RARRAY_LEN(result.starts) == 0) result.starts = repeat.starts;
      if (RARRAY_LEN(result.exits) > 0) onibi_connect(builder, result.exits, repeat.starts);
      onibi_connect(builder, repeat.exits, repeat.starts);
      for (long i = 0; i < RARRAY_LEN(repeat.exits); i++) rb_ary_push(result.exits, rb_ary_entry(repeat.exits, i));
    }
    return result;
  }
  rb_raise(eRegexpError, "unsupported AST node");
  return onibi_fragment_empty();
}

static VALUE onibi_compiler_compile(VALUE self, VALUE parsed) {
  VALUE ast = onibi_hash_value(parsed, "ast");
  if (NIL_P(ast)) rb_raise(rb_eArgError, "compiler requires parser output");
  VALUE parsed_options = onibi_hash_value(parsed, "options");
  int ignorecase = 0;
  int multiline = 0;
  for (long i = 0; i < RARRAY_LEN(parsed_options); i++)
    if (rb_str_equal(rb_ary_entry(parsed_options, i), rb_str_new_cstr("ignorecase"))) ignorecase = 1;
    else if (rb_str_equal(rb_ary_entry(parsed_options, i), rb_str_new_cstr("multiline"))) multiline = 1;
  onibi_gir_builder_t builder = { rb_ary_new(), rb_ary_new(), 0, 0, rb_hash_new(), ignorecase, multiline };
  onibi_fragment_t fragment = onibi_compile_node(ast, &builder);
  long accept = builder.next_id++;
  onibi_gir_state(&builder, accept, rb_intern("G_ACCEPT"), Qnil);
  VALUE accept_starts = rb_ary_new();
  rb_ary_push(accept_starts, LONG2NUM(accept));
  onibi_connect_actions(&builder, fragment.exits, accept_starts, fragment.pending_actions);
  VALUE start_edges = rb_ary_new();
  for (long i = 0; i < RARRAY_LEN(fragment.starts); i++) {
    VALUE edge = rb_hash_new();
    rb_hash_aset(edge, ID2SYM(rb_intern("to")), rb_ary_entry(fragment.starts, i));
    rb_hash_aset(edge, ID2SYM(rb_intern("actions")), rb_ary_dup(fragment.start_actions));
    rb_ary_push(start_edges, edge);
  }
  if (fragment.nullable) {
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
  rb_hash_aset(graph, ID2SYM(rb_intern("capture_count")), LONG2NUM(builder.capture_count));
  long counter_count = 0;
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

static VALUE onibi_rseq_lower(VALUE self, VALUE compiled) {
  VALUE graph = onibi_hash_value(compiled, "graph");
  if (NIL_P(graph)) rb_raise(rb_eArgError, "RSeq lowering requires compiler output");
  VALUE states = onibi_hash_value(graph, "states");
  VALUE edges = onibi_hash_value(graph, "edges");
  VALUE start_edges = onibi_hash_value(graph, "start_edges");
  if (!RTEST(rb_obj_frozen_p(compiled)) || !RTEST(rb_obj_frozen_p(graph)) ||
      !RTEST(rb_obj_frozen_p(states)) || !RTEST(rb_obj_frozen_p(edges)) ||
      !RTEST(rb_obj_frozen_p(start_edges)))
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
    rb_hash_aset(out, ID2SYM(rb_intern("action_offset")), LONG2NUM(RARRAY_LEN(actions)));
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
    rb_hash_aset(out, ID2SYM(rb_intern("action_offset")), LONG2NUM(RARRAY_LEN(actions)));
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
        op == rb_intern("ASSERT_SEARCH_ORIGIN") || op == rb_intern("ASSERT_WORD_BOUNDARY") ||
        op == rb_intern("ASSERT_NONWORD_BOUNDARY") || op == rb_intern("ASSERT_LOOKAHEAD") ||
        op == rb_intern("ASSERT_LOOKBEHIND")) features |= 16U;
  }
  rb_hash_aset(header, ID2SYM(rb_intern("features")), UINT2NUM(features));
  rb_hash_aset(header, ID2SYM(rb_intern("class_count")), UINT2NUM(class_count));
  rb_hash_aset(header, ID2SYM(rb_intern("capture_count")), UINT2NUM(capture_count));
  rb_hash_aset(header, ID2SYM(rb_intern("semantic_capture_count")), UINT2NUM(capture_count));
  rb_hash_aset(header, ID2SYM(rb_intern("subprogram_count")), UINT2NUM(0));
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
    if (op == rb_intern("G_BACKREF") || op == rb_intern("G_CALL") ||
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
  VALUE blob = rb_str_new(NULL, offset);
  memset(RSTRING_PTR(blob), 0, offset);
  memcpy(RSTRING_PTR(blob), &physical, sizeof(physical));
  OnibiRState *physical_states = (OnibiRState *)(RSTRING_PTR(blob) + physical.states_offset);
  uint32_t class_index = 0, literal_index = 0;
  for (long i = 0; i < RARRAY_LEN(states); i++) {
    VALUE state = rb_ary_entry(states, i);
    ID op = SYM2ID(onibi_hash_value(state, "op"));
    physical_states[i].op = (uint8_t)(op == rb_intern("G_CHAR") ? ONIBI_RS_CHAR :
      op == rb_intern("G_CLASS") ? ONIBI_RS_CLASS : op == rb_intern("G_ANY") ? ONIBI_RS_ANY :
      op == rb_intern("G_ACCEPT") ? 0 : ONIBI_RS_BACKREF);
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
      op == rb_intern("COUNTER_INIT") ? ONIBI_RA_COUNTER_SET :
      op == rb_intern("COUNTER_INCREMENT") ? ONIBI_RA_COUNTER_ADD :
      op == rb_intern("TEST_COUNTER_LT") || op == rb_intern("TEST_COUNTER_GE") ? ONIBI_RA_COUNTER_TEST : ONIBI_RA_END);
    VALUE slot = rb_hash_aref(rb_ary_entry(actions, i), ID2SYM(rb_intern("slot")));
    if (!NIL_P(slot)) physical_actions[i].arg16 = (uint16_t)NUM2ULONG(slot);
    VALUE limit = rb_hash_aref(rb_ary_entry(actions, i), ID2SYM(rb_intern("limit")));
    if (!NIL_P(limit)) physical_actions[i].arg32 = (uint32_t)NUM2ULONG(limit);
    VALUE value = rb_hash_aref(rb_ary_entry(actions, i), ID2SYM(rb_intern("value")));
    if (!NIL_P(value)) physical_actions[i].arg32 = (uint32_t)NUM2ULONG(value);
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
  rb_hash_aset(result, ID2SYM(rb_intern("blob")), blob);
  rb_obj_freeze(header); rb_obj_freeze(r_edges); rb_obj_freeze(r_start_edges); rb_obj_freeze(actions); rb_obj_freeze(result);
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

/* Compute all dispatch/compiler feature bits in one pass over the immutable
   token stream.  Runtime entry points use these bits and never rescan source. */
static void onibi_token_features(VALUE tokens, onibi_regexp_t *obj) {
  int in_class = 0;
  VALUE previous = Qnil;
  obj->has_class_intersection = 0;
  obj->has_subroutine = 0;
  obj->has_dynamic = 0;
  obj->has_tagged = 0;
  for (long i = 0; i < RARRAY_LEN(tokens); i++) {
    VALUE token = rb_ary_entry(tokens, i);
    ID kind = onibi_token_kind(token);
    if (kind == rb_intern("class_start")) { in_class = 1; previous = Qnil; continue; }
    if (kind == rb_intern("class_end")) { in_class = 0; previous = Qnil; continue; }
    if (in_class && !NIL_P(previous) && onibi_token_kind(previous) == rb_intern("literal") &&
        kind == rb_intern("literal") && onibi_token_byte(previous) == '&' &&
        onibi_token_byte(token) == '&') obj->has_class_intersection = 1;
    if (kind == rb_intern("subroutine")) {
      obj->has_subroutine = 1;
      obj->has_dynamic = 1;
    } else if (kind == rb_intern("backref") || kind == rb_intern("atomic_start")) {
      obj->has_dynamic = 1;
    } else if (kind == rb_intern("group_start") ||
               (kind == rb_intern("quantifier") && onibi_token_byte(token) == '{')) {
      obj->has_tagged = 1;
    }
    previous = token;
  }
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
  int opts = NIL_P(options) ? 0 : NUM2INT(options);
  obj->options = opts;
  obj->timeout_seconds = NIL_P(timeout) ? onibi_default_timeout : onibi_timeout_value(timeout);
  VALUE source = StringValue(pattern);
  obj->source = rb_str_dup(source);
  rb_obj_freeze(obj->source);
  obj->regexp = rb_funcall(rb_cRegexp, id_new, 2, source, INT2NUM(opts));
  obj->parsed = obj->compiled = obj->rseq = Qnil;
  obj->tokens = Qnil;
  VALUE tokens = onibi_tokenize_internal(source, (opts & 2) != 0);
  onibi_token_features(tokens, obj);
  VALUE program_args = rb_ary_new_from_args(3, source, options, tokens);
  int program_state = 0;
  VALUE program = rb_protect(onibi_build_program, program_args, &program_state);
  if (!program_state) {
    obj->parsed = rb_ary_entry(program, 0);
    obj->compiled = rb_ary_entry(program, 1);
    obj->rseq = rb_ary_entry(program, 2);
    obj->tokens = tokens;
    /* Keep constructs without a complete GIR lowering on MRI.  This test
       runs once during compilation.  Match calls do not inspect source. */
    if (!onibi_ascii_pattern(source) || (opts & (16 | 32)) ||
        obj->has_class_intersection || obj->has_subroutine) {
      obj->parsed = obj->compiled = obj->rseq = Qnil;
    }
  } else {
    rb_set_errinfo(Qnil);
    obj->tokens = tokens;
  }
  obj->program_size = NIL_P(obj->rseq) ? RSTRING_LEN(source) + 1 :
    RSTRING_LEN(onibi_hash_value(obj->rseq, "blob"));
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
      rb_str_strlen(str) == RSTRING_LEN(str) &&
      rb_enc_compatible(str, obj->source) != NULL)
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
static VALUE onibi_inspect(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(obj->regexp, id_inspect, 0);
}
static VALUE onibi_to_s(VALUE self) { return onibi_inspect(self); }
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
  onibi_default_timeout = onibi_timeout_value(value);
  return NIL_P(value) ? Qnil : DBL2NUM(onibi_default_timeout);
}
static VALUE onibi_timeout_default(VALUE klass) {
  return onibi_default_timeout > 0.0 ? DBL2NUM(onibi_default_timeout) : Qnil;
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
  rb_hash_aset(out, ID2SYM(rb_intern("ast")), ast);
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
      rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern(kind == rb_intern("group_start") ? "CAPTURE_OPEN" : "CAPTURE_CLOSE")));
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

static int onibi_vm_actions_ok(VALUE actions, VALUE subject, long pos, long length) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    ID op = SYM2ID(onibi_hash_value(action, "op"));
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
      VALUE bytes = onibi_hash_value(action, "bytes");
      long width = RSTRING_LEN(bytes);
      int hit = pos + width <= length && memcmp(RSTRING_PTR(subject) + pos, RSTRING_PTR(bytes), (size_t)width) == 0;
      if (hit != RTEST(onibi_hash_value(action, "positive"))) return 0;
    }
    if (op == rb_intern("ASSERT_LOOKBEHIND")) {
      VALUE bytes = onibi_hash_value(action, "bytes");
      long width = RSTRING_LEN(bytes);
      int hit = pos >= width && memcmp(RSTRING_PTR(subject) + pos - width, RSTRING_PTR(bytes), (size_t)width) == 0;
      if (hit != RTEST(onibi_hash_value(action, "positive"))) return 0;
    }
  }
  return 1;
}

static int onibi_vm_class_match(VALUE payload, unsigned char byte) {
  int fold = RTEST(onibi_hash_value(payload, "ignorecase"));
  if (fold) byte = (unsigned char)tolower(byte);
  VALUE bitmap = onibi_hash_value(payload, "bitmap");
  if (NIL_P(bitmap) || !RB_TYPE_P(bitmap, T_STRING) || RSTRING_LEN(bitmap) != 32)
    rb_raise(eRegexpError, "class payload has no compiled bitmap");
  return (RSTRING_PTR(bitmap)[byte >> 3] & (1U << (byte & 7))) != 0;
}

static int onibi_vm_walk(VALUE states, VALUE edges, VALUE str, long state_id, long pos, VALUE visited, long *matched_end) {
  rb_thread_check_ints();
  onibi_check_deadline();
  VALUE key = rb_ary_new_from_args(2, LONG2NUM(state_id), LONG2NUM(pos));
  if (RTEST(rb_hash_aref(visited, key))) return 0;
  rb_hash_aset(visited, key, Qtrue);
  VALUE state = rb_ary_entry(states, state_id);
  ID op = SYM2ID(onibi_hash_value(state, "op"));
  if (op == rb_intern("G_ACCEPT")) { *matched_end = pos; return 1; }
  if (op == rb_intern("G_CHAR") || op == rb_intern("G_CLASS") || op == rb_intern("G_ANY")) {
    if (pos >= RSTRING_LEN(str)) return 0;
    unsigned char byte = (unsigned char)RSTRING_PTR(str)[pos];
    VALUE payload = onibi_hash_value(state, "payload");
    int hit = op == rb_intern("G_ANY") ? (byte != '\n' || RTEST(onibi_hash_value(payload, "multiline"))) :
      (op == rb_intern("G_CHAR") ?
        (RTEST(onibi_hash_value(payload, "ignorecase")) ?
          tolower(byte) == tolower(NUM2INT(onibi_hash_value(payload, "byte"))) :
          byte == NUM2INT(onibi_hash_value(payload, "byte"))) : onibi_vm_class_match(payload, byte));
    if (!hit) return 0;
    pos++;
  }
  for (long i = 0; i < RARRAY_LEN(edges); i++) {
    VALUE edge = rb_ary_entry(edges, i);
    if (NUM2LONG(onibi_hash_value(edge, "from")) != state_id) continue;
    if (!onibi_vm_actions_ok(onibi_hash_value(edge, "actions"), str, pos, RSTRING_LEN(str))) continue;
    if (onibi_vm_walk(states, edges, str, NUM2LONG(onibi_hash_value(edge, "to")), pos, visited, matched_end)) return 1;
  }
  return 0;
}

static int onibi_gir_match(VALUE graph, VALUE str, long start, long *matched_end) {
  VALUE states = onibi_hash_value(graph, "states");
  VALUE edges = onibi_hash_value(graph, "edges");
  VALUE starts = onibi_hash_value(graph, "start_edges");
  VALUE visited = rb_hash_new();
  for (long i = 0; i < RARRAY_LEN(starts); i++) {
    VALUE edge = rb_ary_entry(starts, i);
    if (!onibi_vm_actions_ok(onibi_hash_value(edge, "actions"), str, start, RSTRING_LEN(str))) continue;
    if (onibi_vm_walk(states, edges, str, NUM2LONG(onibi_hash_value(edge, "to")), start, visited, matched_end)) return 1;
  }
  return 0;
}

static VALUE onibi_capture_copy(VALUE captures) {
  VALUE copy = rb_hash_dup(captures);
  return copy;
}

static void onibi_apply_capture_actions(VALUE actions, long pos, VALUE captures, long *reported_start) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    ID op = SYM2ID(onibi_hash_value(action, "op"));
    if (op == rb_intern("MATCH_RESET")) { *reported_start = pos; continue; }
    if (op != rb_intern("CAPTURE_OPEN") && op != rb_intern("CAPTURE_CLOSE")) continue;
    VALUE slot = onibi_hash_value(action, "slot");
    rb_hash_aset(captures, slot, LONG2NUM(pos));
  }
}

static int onibi_vm_walk_captures(VALUE states, VALUE edges, VALUE str, long state_id, long pos,
                                  VALUE visited, VALUE captures, long reported_start,
                                  long *matched_end, long *matched_start, VALUE *matched_captures) {
  rb_thread_check_ints();
  onibi_check_deadline();
  VALUE key = rb_ary_new_from_args(4, LONG2NUM(state_id), LONG2NUM(pos), captures, LONG2NUM(reported_start));
  if (RTEST(rb_hash_aref(visited, key))) return 0;
  rb_hash_aset(visited, key, Qtrue);
  VALUE state = rb_ary_entry(states, state_id);
  ID op = SYM2ID(onibi_hash_value(state, "op"));
  if (op == rb_intern("G_ACCEPT")) { *matched_end = pos; *matched_start = reported_start; *matched_captures = captures; return 1; }
  if (op == rb_intern("G_CHAR") || op == rb_intern("G_CLASS") || op == rb_intern("G_ANY") || op == rb_intern("G_BACKREF")) {
    if (pos >= RSTRING_LEN(str)) return 0;
    if (op == rb_intern("G_BACKREF")) {
      VALUE payload = onibi_hash_value(state, "payload");
      long capture = NUM2LONG(onibi_hash_value(payload, "capture"));
      VALUE begin = rb_hash_aref(captures, LONG2NUM(2 * (capture - 1)));
      VALUE finish = rb_hash_aref(captures, LONG2NUM(2 * (capture - 1) + 1));
      if (NIL_P(begin) || NIL_P(finish)) return 0;
      long length = NUM2LONG(finish) - NUM2LONG(begin);
      if (pos + length > RSTRING_LEN(str) || memcmp(RSTRING_PTR(str) + pos, RSTRING_PTR(str) + NUM2LONG(begin), (size_t)length) != 0) return 0;
      pos += length;
    } else {
      unsigned char byte = (unsigned char)RSTRING_PTR(str)[pos];
      VALUE payload = onibi_hash_value(state, "payload");
      int hit = op == rb_intern("G_ANY") ? (byte != '\n' || RTEST(onibi_hash_value(payload, "multiline"))) :
        (op == rb_intern("G_CHAR") ?
          (RTEST(onibi_hash_value(payload, "ignorecase")) ?
            tolower(byte) == tolower(NUM2INT(onibi_hash_value(payload, "byte"))) :
            byte == NUM2INT(onibi_hash_value(payload, "byte"))) : onibi_vm_class_match(payload, byte));
      if (!hit) return 0;
      pos++;
    }
  }
  for (long i = 0; i < RARRAY_LEN(edges); i++) {
    VALUE edge = rb_ary_entry(edges, i);
    if (NUM2LONG(onibi_hash_value(edge, "from")) != state_id) continue;
    if (!onibi_vm_actions_ok(onibi_hash_value(edge, "actions"), str, pos, RSTRING_LEN(str))) continue;
    VALUE next_captures = onibi_capture_copy(captures);
    long next_reported_start = reported_start;
    onibi_apply_capture_actions(onibi_hash_value(edge, "actions"), pos, next_captures, &next_reported_start);
    if (onibi_vm_walk_captures(states, edges, str, NUM2LONG(onibi_hash_value(edge, "to")), pos,
                               visited, next_captures, next_reported_start,
                               matched_end, matched_start, matched_captures)) return 1;
  }
  return 0;
}

static int onibi_gir_match_captures(VALUE graph, VALUE str, long start, long *matched_end,
                                    long *matched_start, VALUE *matched_captures) {
  VALUE states = onibi_hash_value(graph, "states");
  VALUE edges = onibi_hash_value(graph, "edges");
  VALUE starts = onibi_hash_value(graph, "start_edges");
  VALUE visited = rb_hash_new();
  VALUE captures = rb_hash_new();
  for (long i = 0; i < RARRAY_LEN(starts); i++) {
    VALUE edge = rb_ary_entry(starts, i);
    if (!onibi_vm_actions_ok(onibi_hash_value(edge, "actions"), str, start, RSTRING_LEN(str))) continue;
    VALUE branch_captures = onibi_capture_copy(captures);
    long reported_start = start;
    onibi_apply_capture_actions(onibi_hash_value(edge, "actions"), start, branch_captures, &reported_start);
    if (onibi_vm_walk_captures(states, edges, str, NUM2LONG(onibi_hash_value(edge, "to")), start,
                               visited, branch_captures, reported_start,
                               matched_end, matched_start, matched_captures)) return 1;
  }
  return 0;
}

static void onibi_rseq_validate(VALUE rseq) {
  VALUE blob = onibi_hash_value(rseq, "blob");
  VALUE semantic = onibi_hash_value(rseq, "header");
  VALUE semantic_states = onibi_hash_value(rseq, "states");
  VALUE semantic_edges = onibi_hash_value(rseq, "edges");
  VALUE semantic_actions = onibi_hash_value(rseq, "actions");
  VALUE semantic_start_edges = onibi_hash_value(rseq, "start_edges");
  if (NIL_P(blob) || RSTRING_LEN(blob) < (long)sizeof(OnibiRSeqHeader) ||
      !RTEST(rb_obj_frozen_p(rseq)) || !RTEST(rb_obj_frozen_p(blob)) ||
      !RTEST(rb_obj_frozen_p(semantic)) || !RTEST(rb_obj_frozen_p(semantic_states)) ||
      !RTEST(rb_obj_frozen_p(semantic_edges)) || !RTEST(rb_obj_frozen_p(semantic_actions)) ||
      !RTEST(rb_obj_frozen_p(semantic_start_edges)))
    rb_raise(rb_eArgError, "invalid Onibi RSeq blob");
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
      header.start_edge_base + header.start_edge_count > header.edge_count ||
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
      semantic_op == rb_intern("G_BACKREF") ? ONIBI_RS_BACKREF : 0xff;
    if (expected_op == 0xff || states[i].op != expected_op)
      rb_raise(rb_eArgError, "RSeq semantic and physical states disagree");
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
      op == rb_intern("COUNTER_INIT") ? ONIBI_RA_COUNTER_SET :
      op == rb_intern("COUNTER_INCREMENT") ? ONIBI_RA_COUNTER_ADD :
      (op == rb_intern("TEST_COUNTER_LT") || op == rb_intern("TEST_COUNTER_GE")) ? ONIBI_RA_COUNTER_TEST : ONIBI_RA_END;
    VALUE slot = onibi_hash_value(semantic_action, "slot");
    VALUE limit = onibi_hash_value(semantic_action, "limit");
    VALUE value = onibi_hash_value(semantic_action, "value");
    uint32_t expected_arg32 = !NIL_P(limit) ? (uint32_t)NUM2ULONG(limit) :
      (!NIL_P(value) ? (uint32_t)NUM2ULONG(value) : 0);
    if (actions[i].op != expected_op || (!NIL_P(slot) && actions[i].arg16 != (uint16_t)NUM2ULONG(slot)) ||
        ((!NIL_P(limit) || !NIL_P(value)) && actions[i].arg32 != expected_arg32))
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

static VALUE onibi_vm_regular_fast(VALUE rseq, VALUE str) {
  for (long start = 0; start <= RSTRING_LEN(str); start++) {
    rb_thread_check_ints();
    onibi_check_deadline();
    long end = 0;
    if (onibi_gir_match(rseq, str, start, &end)) return Qtrue;
  }
  return Qfalse;
}

static VALUE onibi_vm_tagged_ordered(VALUE rseq, VALUE str) {
  for (long start = 0; start <= RSTRING_LEN(str); start++) {
    rb_thread_check_ints();
    onibi_check_deadline();
    long end = 0;
    long reported_start = start;
    VALUE captures = rb_hash_new();
    if (onibi_gir_match_captures(rseq, str, start, &end, &reported_start, &captures)) return Qtrue;
  }
  return Qfalse;
}

static VALUE onibi_vm_dynamic(VALUE rseq, VALUE str) {
  /* Dynamic execution uses the same ordered capture walk, with dynamic
     states such as G_BACKREF resolved by the walk itself. */
  return onibi_vm_tagged_ordered(rseq, str);
}

static VALUE onibi_vm_execute(VALUE self, VALUE rseq, VALUE str, VALUE execution_class) {
  StringValue(str);
  onibi_rseq_validate(rseq);
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
  if ((obj->options == 0 || obj->options == 1 || obj->options == 4) &&
      !NIL_P(obj->rseq) && rb_str_strlen(str) == RSTRING_LEN(str) &&
      rb_enc_compatible(str, obj->source) != NULL)
    {
      VALUE result = onibi_vm_execute(Qnil, obj->rseq, str, obj->execution_kind);
      onibi_deadline_ns = 0;
      return result;
    }
  onibi_deadline_ns = 0;
  return rb_funcall(obj->regexp, id_match_p, 1, str);
}
static VALUE onibi_vm_match_result(VALUE self, VALUE str) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  StringValue(str);
  int graph_ok = (obj->options == 0 || obj->options == 1 || obj->options == 4) && !NIL_P(obj->rseq) &&
    rb_str_strlen(str) == RSTRING_LEN(str) && rb_enc_compatible(str, obj->source) != NULL;
  if (!graph_ok) {
    if (!RTEST(onibi_vm_match_p(self, str))) return Qnil;
  }
  if (NIL_P(obj->rseq)) {
    VALUE match = rb_funcall(obj->regexp, id_match, 1, str);
    if (NIL_P(match)) return Qnil;
    VALUE result = rb_hash_new();
    rb_hash_aset(result, ID2SYM(rb_intern("start")), rb_funcall(match, rb_intern("begin"), 1, INT2NUM(0)));
    rb_hash_aset(result, ID2SYM(rb_intern("end")), rb_funcall(match, rb_intern("end"), 1, INT2NUM(0)));
    return result;
  }
  if (graph_ok) {
    onibi_set_deadline(obj->timeout_seconds);
    VALUE rseq = obj->rseq;
    for (long pos = 0; pos <= RSTRING_LEN(str); pos++) {
      long end = 0;
      long reported_start = pos;
      VALUE capture_state = rb_hash_new();
      if (!onibi_gir_match_captures(rseq, str, pos, &end, &reported_start, &capture_state)) continue;
      VALUE result = rb_hash_new();
      rb_hash_aset(result, ID2SYM(rb_intern("start")), LONG2NUM(reported_start));
      rb_hash_aset(result, ID2SYM(rb_intern("end")), LONG2NUM(end));
      VALUE captures = rb_hash_new();
      for (long group_id = 1; group_id <= 8; group_id++) {
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
  VALUE result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("start")), rb_funcall(match, rb_intern("begin"), 1, INT2NUM(0)));
  rb_hash_aset(result, ID2SYM(rb_intern("end")), rb_funcall(match, rb_intern("end"), 1, INT2NUM(0)));
  return result;
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
  id_options = rb_intern("options"); id_inspect = rb_intern("inspect");
  id_scan = rb_intern("scan"); id_gsub = rb_intern("gsub");
  id_encoding = rb_intern("encoding");
  id_index = rb_intern("index");
  mOnibi = rb_define_module("Onibi");
  eRegexpError = rb_define_class_under(mOnibi, "RegexpError", rb_eRegexpError);
  rb_define_const(mOnibi, "Error", rb_eStandardError);
  cLexer = rb_define_class_under(mOnibi, "Lexer", rb_cObject);
  rb_define_alloc_func(cLexer, onibi_lexer_alloc);
  rb_define_method(cLexer, "initialize", onibi_lexer_initialize, 1);
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
  rb_define_alloc_func(cRegexp, onibi_alloc);
  rb_define_method(cRegexp, "initialize", onibi_initialize, -1);
  rb_define_method(cRegexp, "match", onibi_match, -1);
  rb_define_method(cRegexp, "match?", onibi_match_p, -1);
  rb_define_method(cRegexp, "source", onibi_source, 0);
  rb_define_method(cRegexp, "options", onibi_options, 0);
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
