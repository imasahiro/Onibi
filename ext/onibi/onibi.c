#include "ruby.h"
#include <string.h>
#include <stdio.h>

static VALUE mOnibi, cRegexp, eRegexpError;
static ID id_initialize, id_match, id_match_p, id_source, id_options, id_inspect, id_new;
static ID id_scan, id_gsub, id_encoding, id_index;
static VALUE onibi_vm_match_p(VALUE self, VALUE str);

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
    if (p[i] == '\\' && i + 1 < n && (p[i + 1] == 'k' || p[i + 1] == 'g')) {
      obj->execution_class = rb_str_new_cstr("DYNAMIC"); rb_obj_freeze(obj->execution_class); break;
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
  for (long i = 0; i < RSTRING_LEN(src); i++)
    if (strchr("\\(){}", RSTRING_PTR(src)[i])) supported = 0;
  if (strchr(RSTRING_PTR(src), '-')) supported = 0;
  if (NUM2INT(rb_funcall(obj->regexp, id_options, 0)) != 0) supported = 0;
  if (supported && rb_str_strlen(str) == RSTRING_LEN(str)) return onibi_vm_match_p(self, str);
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
  for (long i = 0; i < RSTRING_LEN(src); i++) {
    VALUE token = rb_hash_new();
    const char *kind = "literal";
    if (RSTRING_PTR(src)[i] == '[') kind = "class_start";
    else if (RSTRING_PTR(src)[i] == ']') kind = "class_end";
    else if (RSTRING_PTR(src)[i] == '|') kind = "alternation";
    else if (strchr("*+?{} ,", RSTRING_PTR(src)[i])) kind = "quantifier";
    else if (RSTRING_PTR(src)[i] == '.') kind = "wildcard";
    else if (RSTRING_PTR(src)[i] == '^' || RSTRING_PTR(src)[i] == '$') kind = "anchor";
    rb_hash_aset(token, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern(kind)));
    rb_hash_aset(token, ID2SYM(rb_intern("byte")), INT2NUM((unsigned char)RSTRING_PTR(src)[i]));
    rb_ary_push(tokens, token);
  }
  rb_hash_aset(out, ID2SYM(rb_intern("tokens")), tokens);
  VALUE ast = rb_hash_new();
  int is_quant = RSTRING_LEN(src) >= 2 && (strchr("*+?", RSTRING_PTR(src)[RSTRING_LEN(src)-1]) != NULL ||
                                           (RSTRING_PTR(src)[1] == '{' && RSTRING_PTR(src)[RSTRING_LEN(src)-1] == '}'));
  int is_alt = 0; for (long i = 0; i < RSTRING_LEN(src); i++) if (RSTRING_PTR(src)[i] == '|') is_alt = 1;
  int is_class = RSTRING_LEN(src) >= 2 && RSTRING_PTR(src)[0] == '[' && RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == ']';
  int is_anchor = RSTRING_LEN(src) > 0 && (RSTRING_PTR(src)[0] == '^' || RSTRING_PTR(src)[RSTRING_LEN(src) - 1] == '$');
  rb_hash_aset(ast, ID2SYM(rb_intern("type")), ID2SYM(rb_intern(is_quant ? "quantifier" : (is_alt ? "alternation" : (is_class ? "character_class" : (is_anchor ? "anchor" : "sequence"))))));
  rb_hash_aset(ast, ID2SYM(rb_intern("children")), tokens);
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
    rb_hash_aset(op, ID2SYM(rb_intern("op")), ID2SYM(opid));
    rb_hash_aset(op, ID2SYM(rb_intern("arg")), tk);
    rb_ary_push(gir, op);
  }
  rb_hash_aset(out, ID2SYM(rb_intern("gir")), gir);
  rb_hash_aset(out, ID2SYM(rb_intern("rseq")), gir);
  int simple = 1;
  const char *meta = "\\.^$|()[]{}*+?";
  for (long i = 0; i < RSTRING_LEN(src); i++)
    if (strchr(meta, RSTRING_PTR(src)[i])) { simple = 0; break; }
  if (RSTRING_LEN(src) == 3 && RSTRING_PTR(src)[1] == '|') simple = 1;
  if (NUM2INT(rb_funcall(obj->regexp, id_options, 0)) != 0) simple = 0;
  rb_hash_aset(out, ID2SYM(rb_intern("vm")), ID2SYM(rb_intern(simple ? "RSEQ" : "MRI")));
  return out;
}
static VALUE onibi_vm_match_p(VALUE self, VALUE str) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  VALUE src = rb_funcall(obj->regexp, id_source, 0);
  const char *p = RSTRING_PTR(src);
  if (RSTRING_LEN(src) >= 3 && p[0] == '^' && p[RSTRING_LEN(src)-1] == '$') {
    VALUE body = rb_str_substr(src, 1, RSTRING_LEN(src) - 2);
    return rb_str_equal(body, str) ? Qtrue : Qfalse;
  }
  const char *meta = "\\.^$|()[]{}*+?";
  if (RSTRING_LEN(src) >= 3 && p[0] == '[' && p[RSTRING_LEN(src)-1] == ']') {
    for (long j = 0; j < RSTRING_LEN(str); j++)
      for (long i = 1; i < RSTRING_LEN(src)-1; i++)
        if (RSTRING_PTR(str)[j] == p[i]) return Qtrue;
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
  if (RSTRING_LEN(src) == 1 && p[0] == '.') return RSTRING_LEN(str) > 0 ? Qtrue : Qfalse;
  if (RSTRING_LEN(src) == 2 && p[1] == '.') {
    for (long j = 0; j + 1 < RSTRING_LEN(str); j++) if (RSTRING_PTR(str)[j] == p[0]) return Qtrue;
    return Qfalse;
  }
  if (RSTRING_LEN(src) >= 5 && p[1] == '{' && p[RSTRING_LEN(src)-1] == '}') {
    long min = 0, max = 0; char tail;
    if (sscanf(p + 2, "%ld,%ld%c", &min, &max, &tail) < 2) {
      if (sscanf(p + 2, "%ld%c", &min, &tail) == 1) max = min;
    }
    long run = 0; for (long j = 0; j < RSTRING_LEN(str); j++) if (RSTRING_PTR(str)[j] == p[0]) run++; else if (run) break;
    return (run >= min && run <= max) ? Qtrue : Qfalse;
  }
  for (long i = 1; i < RSTRING_LEN(src) - 1; i++) if (p[i] == '|') {
    VALUE left = rb_str_substr(src, 0, i), right = rb_str_substr(src, i + 1, RSTRING_LEN(src) - i - 1);
    return (!NIL_P(rb_funcall(str, id_index, 1, left)) || !NIL_P(rb_funcall(str, id_index, 1, right))) ? Qtrue : Qfalse;
  }
  for (long i = 0; i < RSTRING_LEN(src); i++)
    if (strchr(meta, p[i])) return rb_funcall(obj->regexp, id_match_p, 1, str);
  return NIL_P(rb_funcall(str, id_index, 1, src)) ? Qfalse : Qtrue;
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
  rb_define_method(cRegexp, "scan", onibi_scan, 1);
  rb_define_method(cRegexp, "gsub", onibi_gsub, 2);
  rb_define_const(cRegexp, "IGNORECASE", INT2NUM(1));
  rb_define_const(cRegexp, "EXTENDED", INT2NUM(2));
  rb_define_const(cRegexp, "MULTILINE", INT2NUM(4));
  rb_define_const(cRegexp, "FIXEDENCODING", INT2NUM(16));
  rb_define_const(cRegexp, "NOENCODING", INT2NUM(32));
}
