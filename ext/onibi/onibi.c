#include "ruby.h"
#include "onibi_ir.h"
#include <string.h>
#include <stdio.h>
#include <ctype.h>

static VALUE mOnibi, cRegexp, eRegexpError;
static ID id_initialize, id_match, id_match_p, id_source, id_options, id_inspect, id_new;
static ID id_scan, id_gsub, id_encoding, id_index;
static VALUE onibi_vm_match_p(VALUE self, VALUE str);
static VALUE onibi_vm_match_result(VALUE self, VALUE str);

typedef struct { VALUE regexp; VALUE execution_class; long program_size; } onibi_regexp_t;

static void onibi_free(void *ptr) { xfree(ptr); }
static size_t onibi_memsize(const void *ptr) { return ptr ? sizeof(onibi_regexp_t) : 0; }
static const rb_data_type_t onibi_type = {
  "Onibi::Regexp", { 0, onibi_free, onibi_memsize }, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY
};

static VALUE onibi_alloc(VALUE klass) {
  onibi_regexp_t *obj;
  return TypedData_Make_Struct(klass, onibi_regexp_t, &onibi_type, obj);
}

static VALUE onibi_initialize(int argc, VALUE *argv, VALUE self) {
  VALUE pattern, options = Qnil;
  rb_scan_args(argc, argv, "11", &pattern, &options);
  onibi_regexp_t *obj;
  TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  int opts = NIL_P(options) ? 0 : NUM2INT(options);
  VALUE source = StringValue(pattern);
  obj->regexp = rb_funcall(rb_cRegexp, id_new, 2, source, INT2NUM(opts));
  obj->program_size = RSTRING_LEN(source) + 1;
  obj->execution_class = rb_str_new_cstr("REGULAR_FAST");
  rb_obj_freeze(obj->execution_class);
  const char *p = RSTRING_PTR(source);
  long n = RSTRING_LEN(source);
  for (long i = 0; i < n; i++) {
    if (p[i] == '\\' && i + 1 < n && (p[i + 1] == 'k' || p[i + 1] == 'g' ||
        (p[i + 1] >= '1' && p[i + 1] <= '9'))) {
      obj->execution_class = rb_str_new_cstr("DYNAMIC"); rb_obj_freeze(obj->execution_class); break;
    }
    if (p[i] == '(') {
      obj->execution_class = rb_str_new_cstr("TAGGED_ORDERED"); rb_obj_freeze(obj->execution_class);
    }
    if (p[i] == '(' && i + 2 < n && p[i + 1] == '?' &&
        (p[i + 2] == '=' || p[i + 2] == '!' || p[i + 2] == '<')) {
      obj->execution_class = rb_str_new_cstr("TAGGED_ORDERED");
      rb_obj_freeze(obj->execution_class);
    }
  }
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
  VALUE src = rb_funcall(obj->regexp, id_source, 0);
  int supported = 1;
  int buffer_literal = RSTRING_LEN(src) >= 4 && RSTRING_PTR(src)[0] == '\\' && RSTRING_PTR(src)[1] == 'A' &&
                       RSTRING_PTR(src)[RSTRING_LEN(src) - 2] == '\\' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == 'z';
  for (long i = 2; buffer_literal && i < RSTRING_LEN(src) - 2; i++)
    if (strchr("\\^$|()[]{}*+?.", RSTRING_PTR(src)[i])) buffer_literal = 0;
  int capture_literal = RSTRING_LEN(src) >= 3 && RSTRING_PTR(src)[0] == '(' &&
                        RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == ')';
  for (long i = 1; capture_literal && i < RSTRING_LEN(src) - 1; i++)
    if (strchr("?~:<>=!", RSTRING_PTR(src)[i])) capture_literal = 0;
  for (long i = 0; i < RSTRING_LEN(src); i++)
    if (strchr("\\()", RSTRING_PTR(src)[i]) && !(capture_literal && (i == 0 || i == RSTRING_LEN(src) - 1)) &&
        !(buffer_literal && (i == 0 || i == 1 || i == RSTRING_LEN(src) - 2 || i == RSTRING_LEN(src) - 1))) supported = 0;
  if (strchr(RSTRING_PTR(src), '{') && !(RSTRING_LEN(src) >= 5 &&
      RSTRING_PTR(src)[1] == '{' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '}')) supported = 0;
  int class_plus = RSTRING_LEN(src) >= 6 && RSTRING_PTR(src)[0] == '[' &&
                   RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '+';
  if (class_plus && (strchr(RSTRING_PTR(src) + 1, ':') || strchr(RSTRING_PTR(src) + 1, ']') != strrchr(RSTRING_PTR(src), ']'))) class_plus = 0;
  int class_pair = 0;
  if (RSTRING_LEN(src) >= 12 && RSTRING_PTR(src)[0] == '[' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '+') {
    const char *close = strchr(RSTRING_PTR(src) + 1, ']');
    class_pair = close && close[1] == '+' && close[2] == '[';
  }
  if (strchr(RSTRING_PTR(src), '-') && !class_plus && !class_pair) supported = 0;
  if (strchr(RSTRING_PTR(src), '|') && (strchr(RSTRING_PTR(src), '[') || strchr(RSTRING_PTR(src), ']'))) supported = 0;
  long pipes = 0;
  for (long i = 0; i < RSTRING_LEN(src); i++) if (RSTRING_PTR(src)[i] == '|') pipes++;
  if (pipes > 1) supported = 0;
  int options_mask = NUM2INT(rb_funcall(obj->regexp, id_options, 0));
  int plain_literal = 1; for (long i = 0; i < RSTRING_LEN(src); i++) if (strchr("\\^$|()[]{}*+?.", RSTRING_PTR(src)[i])) plain_literal = 0;
  if (options_mask != 0 && !(options_mask == 4 && strchr(RSTRING_PTR(src), '.') != NULL) &&
      !(options_mask == 1 && plain_literal)) supported = 0;
  if (NIL_P(pos) && supported && rb_str_strlen(str) == RSTRING_LEN(str)) return onibi_vm_match_p(self, str);
  return NIL_P(pos) ? rb_funcall(obj->regexp, id_match_p, 1, str)
                    : rb_funcall(obj->regexp, id_match_p, 2, str, pos);
}

static VALUE onibi_source(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(obj->regexp, id_source, 0);
}
static VALUE onibi_options(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  return rb_funcall(obj->regexp, id_options, 0);
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
  return RTEST(rb_obj_frozen_p(obj->execution_class)) ? Qtrue : Qfalse;
}
static VALUE onibi_pipeline(VALUE self) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  VALUE out = rb_hash_new();
  VALUE src = rb_funcall(obj->regexp, id_source, 0);
  VALUE tokens = rb_ary_new();
  /* One escape is one semantic token.  Do not let an escaped metacharacter
     enter the AST as syntax. */
  for (long i = 0; i < RSTRING_LEN(src); i++) {
    long start = i;
    VALUE token = rb_hash_new();
    const char *kind = "literal";
    unsigned char byte = (unsigned char)RSTRING_PTR(src)[i];
    if (byte == '\\' && i + 1 < RSTRING_LEN(src)) {
      unsigned char escaped = (unsigned char)RSTRING_PTR(src)[i + 1];
      byte = escaped;
      if (strchr("AzZG", escaped) != NULL) kind = "anchor";
      else if (strchr("dDsSwWhHRXpP", escaped) != NULL) kind = "escape";
      i++;
    } else if (byte == '[') kind = "class_start";
    else if (byte == ']') kind = "class_end";
    else if (byte == '|') kind = "alternation";
    else if (byte == '(') kind = "group_start";
    else if (byte == ')') kind = "group_end";
    else if (strchr("*+?{} ,", byte) != NULL) kind = "quantifier";
    else if (byte == '.') kind = "wildcard";
    else if (byte == '^' || byte == '$') kind = "anchor";
    rb_hash_aset(token, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern(kind)));
    rb_hash_aset(token, ID2SYM(rb_intern("byte")), INT2NUM(byte));
    rb_hash_aset(token, ID2SYM(rb_intern("start")), LONG2NUM(start));
    rb_hash_aset(token, ID2SYM(rb_intern("end")), LONG2NUM(i + 1));
    rb_ary_push(tokens, token);
  }
  rb_hash_aset(out, ID2SYM(rb_intern("tokens")), tokens);
  VALUE ast = rb_hash_new();
  int is_quant = RSTRING_LEN(src) >= 2 && (strchr("*+?", RSTRING_PTR(src)[RSTRING_LEN(src)-1]) != NULL ||
                                           (RSTRING_PTR(src)[1] == '{' && RSTRING_PTR(src)[RSTRING_LEN(src)-1] == '}'));
  int is_alt = 0; for (long i = 0; i < RSTRING_LEN(src); i++) if (RSTRING_PTR(src)[i] == '|') is_alt = 1;
  int is_class = RSTRING_LEN(src) >= 2 && RSTRING_PTR(src)[0] == '[' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == ']';
  int is_anchor = RSTRING_LEN(src) > 0 && (RSTRING_PTR(src)[0] == '^' || RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '$' ||
      (RSTRING_LEN(src) >= 2 && RSTRING_PTR(src)[0] == '\\' && RSTRING_PTR(src)[1] == 'A') ||
      (RSTRING_LEN(src) >= 2 && RSTRING_PTR(src)[RSTRING_LEN(src) - 2] == '\\' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == 'z'));
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
    if (RSTRING_LEN(src) == 5 && RSTRING_PTR(src)[2] == '-') {
      VALUE range = rb_ary_new();
      rb_ary_push(range, INT2NUM((unsigned char)RSTRING_PTR(src)[1]));
      rb_ary_push(range, INT2NUM((unsigned char)RSTRING_PTR(src)[3]));
      rb_ary_push(ranges, range);
    }
    rb_hash_aset(ast, ID2SYM(rb_intern("ranges")), ranges);
    rb_hash_aset(ast, ID2SYM(rb_intern("negated")), RSTRING_LEN(src) > 2 && RSTRING_PTR(src)[1] == '^' ? Qtrue : Qfalse);
  }
  if (is_quant) {
    rb_hash_aset(ast, ID2SYM(rb_intern("atom")), rb_str_substr(src, 0, 1));
    rb_hash_aset(ast, ID2SYM(rb_intern("quantifier")), rb_str_substr(src, 1, RSTRING_LEN(src) - 1));
    rb_hash_aset(ast, ID2SYM(rb_intern("greedy")), RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '?' ? Qfalse : Qtrue);
    rb_hash_aset(ast, ID2SYM(rb_intern("possessive")), RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '+' ? Qtrue : Qfalse);
    if (RSTRING_PTR(src)[1] == '{') {
      long min = 0, max = 0; char tail;
      if (sscanf(RSTRING_PTR(src) + 2, "%ld,%ld%c", &min, &max, &tail) >= 2 ||
          sscanf(RSTRING_PTR(src) + 2, "%ld%c", &min, &tail) == 1) {
        if (max == 0) max = min;
        rb_hash_aset(ast, ID2SYM(rb_intern("min")), LONG2NUM(min));
        rb_hash_aset(ast, ID2SYM(rb_intern("max")), LONG2NUM(max));
      }
    }
  }
  if (is_alt) {
    VALUE branches = rb_ary_new(); long begin = 0;
    for (long i = 0; i <= RSTRING_LEN(src); i++) if (i == RSTRING_LEN(src) || RSTRING_PTR(src)[i] == '|') {
      VALUE branch = rb_hash_new(), branch_children = rb_ary_new();
      rb_hash_aset(branch, ID2SYM(rb_intern("type")), ID2SYM(rb_intern("sequence")));
      rb_hash_aset(branch, ID2SYM(rb_intern("source")), rb_str_substr(src, begin, i - begin));
      for (long j = begin; j < i; j++) {
        VALUE node = rb_hash_new();
        rb_hash_aset(node, ID2SYM(rb_intern("type")), ID2SYM(rb_intern("literal")));
        rb_hash_aset(node, ID2SYM(rb_intern("byte")), INT2NUM((unsigned char)RSTRING_PTR(src)[j]));
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
  } else if (RSTRING_LEN(src) == 2 && strchr("*+?", RSTRING_PTR(src)[1])) {
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
  } else if (RSTRING_LEN(src) >= 5 && RSTRING_PTR(src)[1] == '{' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '}') {
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
  if (RSTRING_LEN(src) > 0 && RSTRING_PTR(src)[0] == '^' && RARRAY_LEN(edges) > 0) {
    VALUE action = rb_hash_new();
    rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("ASSERT_BEGIN_BUFFER")));
    rb_ary_push(rb_hash_aref(rb_ary_entry(edges, 0), ID2SYM(rb_intern("actions"))), action);
  }
  if (RSTRING_LEN(src) > 0 && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '$' && RARRAY_LEN(edges) > 0) {
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
  if (strstr(RSTRING_PTR(src), "(") != NULL) {
    VALUE capture = rb_hash_new();
    rb_hash_aset(capture, ID2SYM(rb_intern("id")), INT2NUM(1));
    rb_hash_aset(capture, ID2SYM(rb_intern("use")), ID2SYM(rb_intern("CAPTURE_OUTPUT_ONLY")));
    VALUE slots = rb_ary_new(); rb_ary_push(slots, INT2NUM(2)); rb_ary_push(slots, INT2NUM(3));
    rb_hash_aset(capture, ID2SYM(rb_intern("slots")), slots); rb_ary_push(captures, capture);
  }
  rb_hash_aset(out, ID2SYM(rb_intern("captures")), captures);
  rb_hash_aset(out, ID2SYM(rb_intern("rseq")), gir);
  VALUE compact = rb_ary_new();
  int literal_only = RSTRING_LEN(src) > 0;
  for (long i = 0; i < RSTRING_LEN(src); i++) if (strchr("\\^$|()[]{}*+?.", RSTRING_PTR(src)[i])) literal_only = 0;
  if (literal_only) {
    VALUE op = rb_hash_new();
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("STRING")));
    rb_hash_aset(op, ID2SYM(rb_intern("arg")), src);
    rb_ary_push(compact, op);
  } else if (RSTRING_LEN(src) >= 5 && RSTRING_PTR(src)[1] == '{' &&
             RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '}') {
    VALUE op = rb_hash_new();
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("REPEAT")));
    rb_hash_aset(op, ID2SYM(rb_intern("atom")), rb_str_substr(src, 0, 1));
    rb_hash_aset(op, ID2SYM(rb_intern("bounds")), rb_str_substr(src, 2, RSTRING_LEN(src) - 3));
    rb_ary_push(compact, op);
  } else if (RSTRING_LEN(src) >= 6 && RSTRING_PTR(src)[0] == '[' &&
             RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '+' && strchr(RSTRING_PTR(src) + 1, ']') != NULL) {
    VALUE op = rb_hash_new();
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("RUN_CLASS")));
    rb_hash_aset(op, ID2SYM(rb_intern("arg")), src);
    rb_ary_push(compact, op);
  } else if (RSTRING_LEN(src) >= 3 && RSTRING_PTR(src)[0] == '[' &&
             RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == ']') {
    VALUE op = rb_hash_new();
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("RUN_CLASS")));
    rb_hash_aset(op, ID2SYM(rb_intern("arg")), src);
    rb_ary_push(compact, op);
  } else if (RSTRING_LEN(src) == 1 && RSTRING_PTR(src)[0] == '.') {
    VALUE op = rb_hash_new();
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("RUN_ANY")));
    rb_hash_aset(op, ID2SYM(rb_intern("arg")), INT2NUM(1));
    rb_ary_push(compact, op);
  } else if (strchr(RSTRING_PTR(src), '|') != NULL) {
    VALUE op = rb_hash_new(), branches = rb_ary_new(); long begin = 0;
    for (long i = 0; i <= RSTRING_LEN(src); i++) if (i == RSTRING_LEN(src) || RSTRING_PTR(src)[i] == '|') {
      rb_ary_push(branches, rb_str_substr(src, begin, i - begin)); begin = i + 1;
    }
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("ALT")));
    rb_hash_aset(op, ID2SYM(rb_intern("branches")), branches);
    rb_ary_push(compact, op);
  } else if (RSTRING_LEN(src) >= 3 && RSTRING_PTR(src)[0] == '(' &&
             RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == ')') {
    VALUE open = rb_hash_new(), string = rb_hash_new(), close = rb_hash_new();
    rb_hash_aset(open, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("CAPTURE_OPEN")));
    rb_hash_aset(open, ID2SYM(rb_intern("slot")), INT2NUM(2));
    rb_hash_aset(string, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("STRING")));
    rb_hash_aset(string, ID2SYM(rb_intern("arg")), rb_str_substr(src, 1, RSTRING_LEN(src) - 2));
    rb_hash_aset(close, ID2SYM(rb_intern("op")), ID2SYM(rb_intern("CAPTURE_CLOSE")));
    rb_hash_aset(close, ID2SYM(rb_intern("slot")), INT2NUM(3));
    rb_ary_push(compact, open); rb_ary_push(compact, string); rb_ary_push(compact, close);
  } else compact = gir;
  rb_hash_aset(out, ID2SYM(rb_intern("rseq_compact")), compact);
  int simple = 1;
  int buffer_literal = RSTRING_LEN(src) >= 4 && RSTRING_PTR(src)[0] == '\\' && RSTRING_PTR(src)[1] == 'A' &&
                       RSTRING_PTR(src)[RSTRING_LEN(src) - 2] == '\\' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == 'z';
  for (long i = 2; buffer_literal && i < RSTRING_LEN(src) - 2; i++)
    if (strchr("\\^$|()[]{}*+?.", RSTRING_PTR(src)[i])) buffer_literal = 0;
  int capture_literal = RSTRING_LEN(src) >= 3 && RSTRING_PTR(src)[0] == '(' &&
                        RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == ')';
  for (long i = 1; capture_literal && i < RSTRING_LEN(src) - 1; i++)
    if (strchr("?~:<>=!", RSTRING_PTR(src)[i])) capture_literal = 0;
  int class_pair = 0;
  if (RSTRING_LEN(src) >= 12 && RSTRING_PTR(src)[0] == '[' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '+') {
    const char *close = strchr(RSTRING_PTR(src) + 1, ']');
    class_pair = close && close[1] == '+' && close[2] == '[';
  }
  const char *meta = "\\^$|()[]{}*+?";
  for (long i = 0; i < RSTRING_LEN(src); i++)
    if (strchr(meta, RSTRING_PTR(src)[i])) { simple = 0; break; }
  if (RSTRING_LEN(src) == 3 && RSTRING_PTR(src)[1] == '|') simple = 1;
  if (RSTRING_LEN(src) == 4 && RSTRING_PTR(src)[1] == '.' && RSTRING_PTR(src)[2] == '*') simple = 1;
  if (RSTRING_LEN(src) >= 5 && RSTRING_PTR(src)[1] == '{' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '}') simple = 1;
  if (RSTRING_LEN(src) >= 3 && RSTRING_PTR(src)[0] == '[' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == ']') simple = 1;
  if (capture_literal) simple = 1;
  if (buffer_literal) simple = 1;
  if (strchr(RSTRING_PTR(src), '-') && !(RSTRING_LEN(src) >= 6 && RSTRING_PTR(src)[0] == '[' &&
      RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '+')) simple = 0;
  if (RSTRING_LEN(src) >= 6 && RSTRING_PTR(src)[0] == '[' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '+' &&
      !strchr(RSTRING_PTR(src) + 1, ':') && strchr(RSTRING_PTR(src) + 1, ']') == strrchr(RSTRING_PTR(src), ']')) simple = 1;
  if (class_pair) simple = 1;
  long pipes = 0; for (long i = 0; i < RSTRING_LEN(src); i++) if (RSTRING_PTR(src)[i] == '|') pipes++;
  if (pipes > 1) simple = 0;
  int pipeline_options = NUM2INT(rb_funcall(obj->regexp, id_options, 0));
  if (pipeline_options != 0 && !(pipeline_options == 4 && strchr(RSTRING_PTR(src), '.') != NULL) &&
      !(pipeline_options == 1 && literal_only)) simple = 0;
  rb_hash_aset(out, ID2SYM(rb_intern("vm")), ID2SYM(rb_intern(simple ? "RSEQ" : "MRI")));
  VALUE klass = obj->execution_class;
  rb_hash_aset(out, ID2SYM(rb_intern("interpreter")), rb_equal(klass, rb_str_new_cstr("DYNAMIC")) ?
    ID2SYM(rb_intern("DYNAMIC")) : (rb_equal(klass, rb_str_new_cstr("TAGGED_ORDERED")) ?
      ID2SYM(rb_intern("TAGGED_ORDERED")) : ID2SYM(rb_intern("REGULAR_FAST"))));
  return out;
}
static VALUE onibi_vm_match_p(VALUE self, VALUE str) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  VALUE src = rb_funcall(obj->regexp, id_source, 0);
  const char *p = RSTRING_PTR(src);
  int multiline = NUM2INT(rb_funcall(obj->regexp, id_options, 0)) == 4;
  int class_plus = RSTRING_LEN(src) >= 6 && p[0] == '[' && p[RSTRING_LEN(src) - 1] == '+';
  if (RSTRING_LEN(src) >= 4 && p[0] == '\\' && p[1] == 'A' && p[RSTRING_LEN(src) - 2] == '\\' && p[RSTRING_LEN(src) - 1] == 'z') {
    VALUE body = rb_str_substr(src, 2, RSTRING_LEN(src) - 4);
    return rb_str_equal(body, str) ? Qtrue : Qfalse;
  }
  if (class_plus && (strchr(p + 1, ':') || strchr(p + 1, ']') != strrchr(p, ']'))) class_plus = 0;
  if (RSTRING_LEN(src) >= 3 && p[0] == '(' && p[RSTRING_LEN(src) - 1] == ')') {
    VALUE body = rb_str_substr(src, 1, RSTRING_LEN(src) - 2);
    return NIL_P(rb_funcall(str, id_index, 1, body)) ? Qfalse : Qtrue;
  }
  int class_pair = RSTRING_LEN(src) >= 12 && p[0] == '[' && p[RSTRING_LEN(src) - 1] == '+' &&
                    strchr(p + 1, ']') && strchr(p + 1, ']')[1] == '+' && strchr(p + 1, ']')[2] == '[';
  if (RSTRING_LEN(src) >= 3 && p[0] == '^' && p[RSTRING_LEN(src)-1] == '$') {
    VALUE body = rb_str_substr(src, 1, RSTRING_LEN(src) - 2);
    return rb_str_equal(body, str) ? Qtrue : Qfalse;
  }
  const char *meta = "\\.^$|()[]{}*+?";
  if (RSTRING_LEN(src) >= 3 && p[0] == '[' && p[RSTRING_LEN(src)-1] == ']') {
    if (RSTRING_LEN(src) == 5 && p[2] == '-') {
      for (long j = 0; j < RSTRING_LEN(str); j++) if (RSTRING_PTR(str)[j] >= p[1] && RSTRING_PTR(str)[j] <= p[3]) return Qtrue;
      return Qfalse;
    }
    for (long j = 0; j < RSTRING_LEN(str); j++)
      for (long i = 1; i < RSTRING_LEN(src)-1; i++)
        if (RSTRING_PTR(str)[j] == p[i]) return Qtrue;
    return Qfalse;
  }
  if (RSTRING_LEN(src) == 4 && p[0] == '[' && p[2] == ']') {
    for (long j = 0; j + 1 < RSTRING_LEN(str); j++)
      if (RSTRING_PTR(str)[j] == p[1] && RSTRING_PTR(str)[j+1] == p[3]) return Qtrue;
    return Qfalse;
  }
  if (RSTRING_LEN(src) >= 5 && p[0] == '[' && !class_plus) {
    long close = 0; for (long i = 1; i < RSTRING_LEN(src); i++) if (p[i] == ']') { close = i; break; }
    if (close > 1 && close + 2 == RSTRING_LEN(src)) {
      for (long j = 0; j + 1 < RSTRING_LEN(str); j++) {
        int hit = 0; for (long i = 1; i < close; i++) if (RSTRING_PTR(str)[j] == p[i]) hit = 1;
        if (hit && RSTRING_PTR(str)[j + 1] == p[close + 1]) return Qtrue;
      }
      return Qfalse;
    }
  }
  if (class_plus) {
    long close = 0; for (long i = 1; i < RSTRING_LEN(src); i++) if (p[i] == ']') { close = i; break; }
    if (close > 1 && close == RSTRING_LEN(src) - 2) {
      for (long j = 0; j < RSTRING_LEN(str); j++) {
        long run = 0;
        while (j + run < RSTRING_LEN(str)) {
          unsigned char c = (unsigned char)RSTRING_PTR(str)[j + run]; int hit = 0;
          for (long i = 1; i < close; i++) {
            if (p[i] == '-' && i > 1 && i + 1 < close && c >= (unsigned char)p[i - 1] && c <= (unsigned char)p[i + 1]) hit = 1;
            else if (p[i] != '-' && c == (unsigned char)p[i]) hit = 1;
          }
          if (!hit) break;
          run++;
        }
        if (run > 0) return Qtrue;
        j += run;
      }
      return Qfalse;
    }
  }
  if (class_pair) {
    long first_close = (long)(strchr(p + 1, ']') - p);
    long second_open = first_close + 2;
    for (long j = 0; j < RSTRING_LEN(str); j++) {
      long run1 = 0;
      while (j + run1 < RSTRING_LEN(str) && RSTRING_PTR(str)[j + run1] >= p[1] && RSTRING_PTR(str)[j + run1] <= p[3]) run1++;
      long run2 = 0, k = j + run1;
      while (k + run2 < RSTRING_LEN(str) && RSTRING_PTR(str)[k + run2] >= p[second_open + 1] && RSTRING_PTR(str)[k + run2] <= p[second_open + 3]) run2++;
      if (run1 > 0 && run2 > 0) return Qtrue;
    }
    return Qfalse;
  }
  if (RSTRING_LEN(src) == 3 && p[1] == '|') {
    for (long j = 0; j < RSTRING_LEN(str); j++)
      if (RSTRING_PTR(str)[j] == p[0] || RSTRING_PTR(str)[j] == p[2]) return Qtrue;
    return Qfalse;
  }
  if (RSTRING_LEN(src) == 2 && strchr("*+?", p[1])) {
    for (long j = 0; j < RSTRING_LEN(str); j++) if (RSTRING_PTR(str)[j] == p[0]) return Qtrue;
    return p[1] == '?' ? Qtrue : Qfalse;
  }
  if (RSTRING_LEN(src) == 4 && p[1] == '.' && p[2] == '*') {
    for (long j = 0; j < RSTRING_LEN(str); j++) if (RSTRING_PTR(str)[j] == p[0])
      for (long k = j + 1; k < RSTRING_LEN(str); k++) if (RSTRING_PTR(str)[k] == p[3]) return Qtrue;
    return Qfalse;
  }
  if (RSTRING_LEN(src) == 1 && p[0] == '.') {
    for (long j = 0; j < RSTRING_LEN(str); j++) if (multiline || RSTRING_PTR(str)[j] != '\n') return Qtrue;
    return Qfalse;
  }
  if (RSTRING_LEN(src) == 2 && p[1] == '.') {
    for (long j = 0; j + 1 < RSTRING_LEN(str); j++) if (RSTRING_PTR(str)[j] == p[0]) return Qtrue;
    return Qfalse;
  }
  if (RSTRING_LEN(src) >= 3) {
    long dot = -1;
    int literal = 1;
    for (long i = 0; i < RSTRING_LEN(src); i++) {
      if (p[i] == '.') {
        if (dot >= 0) { literal = 0; break; }
        dot = i;
      } else if (strchr("\\^$|()[]{}*+?", p[i])) literal = 0;
    }
    if (literal && dot >= 0) {
      for (long j = 0; j + RSTRING_LEN(src) <= RSTRING_LEN(str); j++) {
        int hit = 1;
        for (long i = 0; i < RSTRING_LEN(src); i++)
          if (i == dot) { if (!multiline && RSTRING_PTR(str)[j + i] == '\n') hit = 0; }
          else if (RSTRING_PTR(str)[j + i] != p[i]) hit = 0;
        if (hit) return Qtrue;
      }
      return Qfalse;
    }
  }
  if (RSTRING_LEN(src) >= 5 && p[1] == '{' && p[RSTRING_LEN(src)-1] == '}') {
    long min = 0, max = 0; char tail;
    if (sscanf(p + 2, "%ld,%ld%c", &min, &max, &tail) < 2) {
      if (sscanf(p + 2, "%ld%c", &min, &tail) == 1) max = min;
    }
    for (long j = 0; j < RSTRING_LEN(str); j++) if (RSTRING_PTR(str)[j] == p[0]) {
      long run = 0; while (j + run < RSTRING_LEN(str) && RSTRING_PTR(str)[j + run] == p[0]) run++;
      if (run >= min) return Qtrue;
      j += run - 1;
    }
    return Qfalse;
  }
  for (long i = 1; i < RSTRING_LEN(src) - 1; i++) if (p[i] == '|') {
    VALUE left = rb_str_substr(src, 0, i), right = rb_str_substr(src, i + 1, RSTRING_LEN(src) - i - 1);
    return (!NIL_P(rb_funcall(str, id_index, 1, left)) || !NIL_P(rb_funcall(str, id_index, 1, right))) ? Qtrue : Qfalse;
  }
  for (long i = 0; i < RSTRING_LEN(src); i++)
    if (strchr(meta, p[i])) return rb_funcall(obj->regexp, id_match_p, 1, str);
  if (NUM2INT(rb_funcall(obj->regexp, id_options, 0)) == 1) {
    for (long j = 0; j + RSTRING_LEN(src) <= RSTRING_LEN(str); j++) {
      int hit = 1; for (long i = 0; i < RSTRING_LEN(src); i++)
        if (tolower((unsigned char)RSTRING_PTR(str)[j + i]) != tolower((unsigned char)p[i])) hit = 0;
      if (hit) return Qtrue;
    }
    return Qfalse;
  }
  return NIL_P(rb_funcall(str, id_index, 1, src)) ? Qfalse : Qtrue;
}
static VALUE onibi_vm_match_result(VALUE self, VALUE str) {
  if (!RTEST(onibi_vm_match_p(self, str))) return Qnil;
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  VALUE src = rb_funcall(obj->regexp, id_source, 0);
  VALUE needle = src;
  if (RSTRING_LEN(src) >= 3 && RSTRING_PTR(src)[0] == '(' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == ')')
    needle = rb_str_substr(src, 1, RSTRING_LEN(src) - 2);
  VALUE start = rb_funcall(str, id_index, 1, needle);
  if (RSTRING_LEN(src) == 1 && RSTRING_PTR(src)[0] == '.') {
    start = Qnil;
    for (long i = 0; i < RSTRING_LEN(str); i++) if (RSTRING_PTR(str)[i] != '\n') { start = LONG2NUM(i); break; }
    needle = rb_str_new_cstr("x");
  } else if (RSTRING_LEN(src) == 3 && RSTRING_PTR(src)[1] == '.') {
    start = Qnil;
    for (long i = 0; i + 2 < RSTRING_LEN(str); i++) if (RSTRING_PTR(str)[i] == RSTRING_PTR(src)[0] &&
        RSTRING_PTR(str)[i + 2] == RSTRING_PTR(src)[2]) { start = LONG2NUM(i); break; }
    needle = rb_str_substr(src, 0, 3);
  }
  if (RSTRING_PTR(src) && strchr(RSTRING_PTR(src), '|')) {
    start = Qnil; needle = Qnil;
    long begin = 0;
    for (long i = 0; i <= RSTRING_LEN(src); i++) if (i == RSTRING_LEN(src) || RSTRING_PTR(src)[i] == '|') {
      VALUE branch = rb_str_substr(src, begin, i - begin), candidate = rb_funcall(str, id_index, 1, branch);
      if (!NIL_P(candidate) && (NIL_P(start) || NUM2LONG(candidate) < NUM2LONG(start))) { start = candidate; needle = branch; }
      begin = i + 1;
    }
  }
  if (NIL_P(start)) return Qnil;
  VALUE result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("start")), start);
  rb_hash_aset(result, ID2SYM(rb_intern("end")), LONG2NUM(NUM2LONG(start) + RSTRING_LEN(needle)));
  if (RSTRING_LEN(src) >= 3 && RSTRING_PTR(src)[0] == '(' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == ')') {
    VALUE captures = rb_hash_new(), group = rb_hash_new();
    rb_hash_aset(group, ID2SYM(rb_intern("start")), start);
    rb_hash_aset(group, ID2SYM(rb_intern("end")), LONG2NUM(NUM2LONG(start) + RSTRING_LEN(needle)));
    rb_hash_aset(captures, INT2NUM(1), group);
    rb_hash_aset(result, ID2SYM(rb_intern("captures")), captures);
  }
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
  cRegexp = rb_define_class_under(mOnibi, "Regexp", rb_cObject);
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
