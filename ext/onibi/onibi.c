#include "ruby.h"
#include "onibi_ir.h"
#include <string.h>
#include <stdio.h>
#include <ctype.h>

static VALUE mOnibi, cRegexp, cLexer, eRegexpError;
static ID id_initialize, id_match, id_match_p, id_source, id_options, id_inspect, id_new;
static ID id_scan, id_gsub, id_encoding, id_index;
static VALUE onibi_vm_match_p(VALUE self, VALUE str);
static VALUE onibi_vm_match_result(VALUE self, VALUE str);

typedef struct { VALUE regexp; VALUE execution_class; long program_size; } onibi_regexp_t;
typedef struct { VALUE source; } onibi_lexer_t;

static void onibi_free(void *ptr) { xfree(ptr); }
static size_t onibi_memsize(const void *ptr) { return ptr ? sizeof(onibi_regexp_t) : 0; }
static const rb_data_type_t onibi_type = {
  "Onibi::Regexp", { 0, onibi_free, onibi_memsize }, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY
};

static void onibi_lexer_free(void *ptr) { xfree(ptr); }
static size_t onibi_lexer_memsize(const void *ptr) { return ptr ? sizeof(onibi_lexer_t) : 0; }
static const rb_data_type_t onibi_lexer_type = {
  "Onibi::Lexer", { 0, onibi_lexer_free, onibi_lexer_memsize }, 0, 0,
  RUBY_TYPED_FREE_IMMEDIATELY
};

static VALUE onibi_lexer_alloc(VALUE klass) {
  onibi_lexer_t *obj;
  return TypedData_Make_Struct(klass, onibi_lexer_t, &onibi_lexer_type, obj);
}

static VALUE onibi_tokenize(VALUE src) {
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
    if (byte == '\\' && i + 1 < RSTRING_LEN(src)) {
      unsigned char escaped = (unsigned char)RSTRING_PTR(src)[i + 1];
      byte = escaped;
    if (!in_class && strchr("AzZG", escaped) != NULL) kind = "anchor";
      else if (!in_class && escaped >= '1' && escaped <= '9') kind = "backref";
      else if (strchr("dDsSwWhHRXpP", escaped) != NULL) kind = "escape";
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
    rb_obj_freeze(token);
    rb_ary_push(tokens, token);
  }
  rb_obj_freeze(tokens);
  return tokens;
}

static VALUE onibi_lexer_initialize(VALUE self, VALUE source) {
  onibi_lexer_t *obj;
  TypedData_Get_Struct(self, onibi_lexer_t, &onibi_lexer_type, obj);
  source = StringValue(source);
  obj->source = rb_str_dup(source);
  rb_obj_freeze(obj->source);
  rb_obj_freeze(self);
  return self;
}

static VALUE onibi_lexer_tokens(VALUE self) {
  onibi_lexer_t *obj;
  TypedData_Get_Struct(self, onibi_lexer_t, &onibi_lexer_type, obj);
  return onibi_tokenize(obj->source);
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

static long onibi_find_close(VALUE tokens, long begin, long end, ID open, ID close) {
  long depth = 0;
  for (long i = begin; i < end; i++) {
    ID kind = onibi_token_kind(rb_ary_entry(tokens, i));
    if (kind == open) depth++;
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
    if (kind == rb_intern("class_range") && i > begin + 1 && i + 1 < close) {
      VALUE range = rb_ary_new();
      rb_ary_push(range, INT2NUM(onibi_token_byte(rb_ary_entry(tokens, i - 1))));
      rb_ary_push(range, INT2NUM(onibi_token_byte(rb_ary_entry(tokens, i + 1))));
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
  if (kind == rb_intern("group_start")) {
    long close = onibi_find_close(tokens, *index, end, rb_intern("group_start"), rb_intern("group_end"));
    if (close < 0) rb_raise(eRegexpError, "unterminated group");
    VALUE node = onibi_ast_node("capture", token);
    rb_hash_aset(node, ID2SYM(rb_intern("body")), onibi_parse_range(src, tokens, *index + 1, close));
    rb_hash_aset(node, ID2SYM(rb_intern("capturing")), Qtrue);
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
  VALUE node = NIL_P(token) ? Qnil :
    (kind == rb_intern("wildcard") ? onibi_ast_node("any", token) :
     (kind == rb_intern("anchor") ? onibi_ast_node("anchor", token) :
       (kind == rb_intern("escape") ? onibi_ast_node("escape", token) :
       (kind == rb_intern("backref") ? onibi_ast_node("backref", token) :
       (kind == rb_intern("literal") ? onibi_ast_node("literal", token) : Qnil)))));
  if (NIL_P(node)) rb_raise(eRegexpError, "unexpected token in expression");
  rb_hash_aset(node, ID2SYM(rb_intern("byte")), INT2NUM(onibi_token_byte(token)));
  if (kind == rb_intern("anchor")) {
    long marker = onibi_token_byte(token);
    const char *anchor = (marker == '^' || marker == 'A' || marker == 'G') ?
      "anchor_start" : ((marker == '$' || marker == 'z' || marker == 'Z') ?
      "anchor_end" : "anchor");
    rb_hash_aset(node, ID2SYM(rb_intern("kind")), ID2SYM(rb_intern(anchor)));
  }
  if (kind == rb_intern("escape"))
    rb_hash_aset(node, ID2SYM(rb_intern("name")), rb_str_new((const char[]){(char)onibi_token_byte(token)}, 1));
  if (kind == rb_intern("backref"))
    rb_hash_aset(node, ID2SYM(rb_intern("capture")), INT2NUM(onibi_token_byte(token) - '0'));
  rb_obj_freeze(node);
  *index = *index + 1;
  return node;
}

static VALUE onibi_parse_range(VALUE src, VALUE tokens, long begin, long end) {
  VALUE branches = rb_ary_new();
  long part = begin, depth = 0;
  for (long i = begin; i < end; i++) {
    ID kind = onibi_token_kind(rb_ary_entry(tokens, i));
    if (kind == rb_intern("group_start") || kind == rb_intern("class_start")) depth++;
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
          min = strtol(body, &endptr, 10);
          if (endptr != comma) rb_raise(eRegexpError, "invalid quantifier");
          if (comma[1] == '\0') has_max = 0;
          else {
            char *max_end = NULL;
            max_value = strtol(comma + 1, &max_end, 10);
            if (*max_end != '\0') rb_raise(eRegexpError, "invalid quantifier");
          }
        } else {
          char *endptr = NULL;
          min = strtol(body, &endptr, 10);
          if (*endptr != '\0') rb_raise(eRegexpError, "invalid quantifier");
          max_value = min;
        }
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
  if (options == Qtrue) rb_ary_push(result, rb_str_new_cstr("ignorecase"));
  else if (RB_TYPE_P(options, T_STRING)) {
    const char *p = RSTRING_PTR(options);
    for (long i = 0; i < RSTRING_LEN(options); i++) {
      const char *name = p[i] == 'i' ? "ignorecase" : (p[i] == 'm' ? "multiline" : (p[i] == 'x' ? "extended" : NULL));
      if (name != NULL) rb_ary_push(result, rb_str_new_cstr(name));
      else rb_raise(rb_eArgError, "unknown regexp option");
    }
  } else {
    int mask = NUM2INT(options);
    if (mask & ~(1 | 2 | 4)) rb_raise(rb_eArgError, "unknown regexp option");
    if (mask & 1) rb_ary_push(result, rb_str_new_cstr("ignorecase"));
    if (mask & 4) rb_ary_push(result, rb_str_new_cstr("multiline"));
    if (mask & 2) rb_ary_push(result, rb_str_new_cstr("extended"));
  }
  rb_obj_freeze(result);
  return result;
}

static VALUE onibi_parser_parse(int argc, VALUE *argv, VALUE self) {
  VALUE source, options = Qnil;
  rb_scan_args(argc, argv, "11", &source, &options);
  source = StringValue(source);
  VALUE tokens = onibi_tokenize(source);
  VALUE result = rb_hash_new();
  VALUE source_copy = rb_str_dup(source);
  rb_obj_freeze(source_copy);
  rb_hash_aset(result, ID2SYM(rb_intern("source")), source_copy);
  rb_hash_aset(result, ID2SYM(rb_intern("options")), onibi_parser_options(options));
  rb_hash_aset(result, ID2SYM(rb_intern("tokens")), tokens);
  rb_hash_aset(result, ID2SYM(rb_intern("ast")), onibi_parse_range(source, tokens, 0, RARRAY_LEN(tokens)));
  rb_obj_freeze(result);
  return result;
}

typedef struct { VALUE starts; VALUE exits; VALUE start_actions; VALUE pending_actions; int nullable; } onibi_fragment_t;
typedef struct { VALUE states; VALUE edges; long next_id; long capture_count; } onibi_gir_builder_t;

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

static onibi_fragment_t onibi_compile_sequence(VALUE children, onibi_gir_builder_t *builder) {
  onibi_fragment_t result = onibi_fragment_empty();
  int have_consuming = 0;
  for (long i = 0; i < RARRAY_LEN(children); i++) {
    onibi_fragment_t part = onibi_compile_node(rb_ary_entry(children, i), builder);
    if (RARRAY_LEN(part.starts) == 0) {
      if (have_consuming) onibi_append_values(result.pending_actions, part.pending_actions);
      else onibi_append_values(result.start_actions, part.pending_actions);
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
    long id = builder->next_id++;
    ID op = type == ID2SYM(rb_intern("literal")) ? rb_intern("G_CHAR") :
      ((type == ID2SYM(rb_intern("any"))) ? rb_intern("G_ANY") :
       ((type == ID2SYM(rb_intern("backref"))) ? rb_intern("G_BACKREF") : rb_intern("G_CLASS")));
    onibi_gir_state(builder, id, op, ast);
    onibi_fragment_t result = onibi_fragment_empty();
    result.starts = rb_ary_new(); result.exits = rb_ary_new(); result.nullable = 0;
    rb_ary_push(result.starts, LONG2NUM(id)); rb_ary_push(result.exits, LONG2NUM(id));
    return result;
  }
  if (type == ID2SYM(rb_intern("anchor")))
  {
    onibi_fragment_t result = onibi_fragment_empty();
    VALUE action = rb_hash_new();
    long marker = NUM2LONG(onibi_hash_value(ast, "byte"));
    const char *op = (marker == '^' || marker == 'A' || marker == 'G') ?
      "ASSERT_BEGIN_BUFFER" : "ASSERT_END_BUFFER";
    rb_hash_aset(action, ID2SYM(rb_intern("op")), ID2SYM(rb_intern(op)));
    rb_ary_push(result.pending_actions, action);
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
    rb_ary_push(result.start_actions, open);
    rb_ary_push(result.pending_actions, close);
    return result;
  }
  if (type == ID2SYM(rb_intern("quantifier"))) {
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
  onibi_gir_builder_t builder = { rb_ary_new(), rb_ary_new(), 0, 0 };
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
  rb_obj_freeze(graph);
  VALUE result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("ast")), ast);
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
  VALUE actions = rb_ary_new();
  VALUE r_edges = rb_ary_new();
  for (long i = 0; i < RARRAY_LEN(edges); i++) {
    VALUE edge = rb_ary_entry(edges, i);
    VALUE edge_actions = onibi_hash_value(edge, "actions");
    VALUE out = rb_hash_new();
    rb_hash_aset(out, ID2SYM(rb_intern("from")), onibi_hash_value(edge, "from"));
    rb_hash_aset(out, ID2SYM(rb_intern("to")), onibi_hash_value(edge, "to"));
    rb_hash_aset(out, ID2SYM(rb_intern("action_offset")), LONG2NUM(RARRAY_LEN(actions)));
    rb_hash_aset(out, ID2SYM(rb_intern("actions")), edge_actions);
    for (long j = 0; j < RARRAY_LEN(edge_actions); j++) {
      VALUE action = rb_ary_entry(edge_actions, j);
      rb_obj_freeze(action);
      rb_ary_push(actions, action);
    }
    rb_obj_freeze(out);
    rb_ary_push(r_edges, out);
  }
  VALUE header = rb_hash_new();
  rb_hash_aset(header, ID2SYM(rb_intern("version")), INT2NUM(1));
  rb_hash_aset(header, ID2SYM(rb_intern("state_count")), LONG2NUM(RARRAY_LEN(states)));
  rb_hash_aset(header, ID2SYM(rb_intern("edge_count")), LONG2NUM(RARRAY_LEN(r_edges)));
  rb_hash_aset(header, ID2SYM(rb_intern("action_count")), LONG2NUM(RARRAY_LEN(actions)));
  rb_hash_aset(header, ID2SYM(rb_intern("start_edge_count")), LONG2NUM(RARRAY_LEN(start_edges)));
  VALUE result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("header")), header);
  rb_hash_aset(result, ID2SYM(rb_intern("states")), states);
  rb_hash_aset(result, ID2SYM(rb_intern("edges")), r_edges);
  rb_hash_aset(result, ID2SYM(rb_intern("start_edges")), start_edges);
  rb_hash_aset(result, ID2SYM(rb_intern("actions")), actions);
  rb_obj_freeze(header); rb_obj_freeze(r_edges); rb_obj_freeze(actions); rb_obj_freeze(result);
  return result;
}

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
  VALUE tokens = onibi_tokenize(src);
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

static int onibi_vm_actions_ok(VALUE actions, long pos, long length) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    ID op = SYM2ID(onibi_hash_value(action, "op"));
    if (op == rb_intern("ASSERT_BEGIN_BUFFER") && pos != 0) return 0;
    if (op == rb_intern("ASSERT_END_BUFFER") && pos != length) return 0;
  }
  return 1;
}

static int onibi_vm_class_match(VALUE payload, unsigned char byte) {
  VALUE type = onibi_hash_value(payload, "type");
  if (type == ID2SYM(rb_intern("escape"))) {
    VALUE name = onibi_hash_value(payload, "name");
    int upper = RSTRING_LEN(name) == 1 && isupper((unsigned char)RSTRING_PTR(name)[0]);
    unsigned char n = (unsigned char)tolower((unsigned char)RSTRING_PTR(name)[0]);
    int hit = n == 'd' ? isdigit(byte) : (n == 's' ? isspace(byte) :
      (n == 'w' ? (isalnum(byte) || byte == '_') :
       (n == 'h' ? isxdigit(byte) : 0)));
    return upper ? !hit : hit;
  }
  VALUE ranges = onibi_hash_value(payload, "ranges");
  VALUE children = onibi_hash_value(payload, "children");
  int hit = 0;
  for (long i = 0; i < RARRAY_LEN(ranges); i++) {
    VALUE range = rb_ary_entry(ranges, i);
    if (RARRAY_LEN(range) == 2 && byte >= NUM2INT(rb_ary_entry(range, 0)) && byte <= NUM2INT(rb_ary_entry(range, 1))) hit = 1;
  }
  for (long i = 0; i < RARRAY_LEN(children); i++) {
    VALUE child = rb_ary_entry(children, i);
    if (onibi_hash_value(child, "kind") == ID2SYM(rb_intern("literal")) && byte == NUM2INT(onibi_hash_value(child, "byte"))) hit = 1;
  }
  return RTEST(onibi_hash_value(payload, "negated")) ? !hit : hit;
}

static int onibi_vm_walk(VALUE states, VALUE edges, VALUE str, long state_id, long pos, VALUE visited, long *matched_end) {
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
    int hit = op == rb_intern("G_ANY") ? byte != '\n' :
      (op == rb_intern("G_CHAR") ? byte == NUM2INT(onibi_hash_value(payload, "byte")) : onibi_vm_class_match(payload, byte));
    if (!hit) return 0;
    pos++;
  }
  for (long i = 0; i < RARRAY_LEN(edges); i++) {
    VALUE edge = rb_ary_entry(edges, i);
    if (NUM2LONG(onibi_hash_value(edge, "from")) != state_id) continue;
    if (!onibi_vm_actions_ok(onibi_hash_value(edge, "actions"), pos, RSTRING_LEN(str))) continue;
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
    if (!onibi_vm_actions_ok(onibi_hash_value(edge, "actions"), start, RSTRING_LEN(str))) continue;
    if (onibi_vm_walk(states, edges, str, NUM2LONG(onibi_hash_value(edge, "to")), start, visited, matched_end)) return 1;
  }
  return 0;
}

static VALUE onibi_capture_copy(VALUE captures) {
  VALUE copy = rb_hash_dup(captures);
  return copy;
}

static void onibi_apply_capture_actions(VALUE actions, long pos, VALUE captures) {
  for (long i = 0; i < RARRAY_LEN(actions); i++) {
    VALUE action = rb_ary_entry(actions, i);
    ID op = SYM2ID(onibi_hash_value(action, "op"));
    if (op != rb_intern("CAPTURE_OPEN") && op != rb_intern("CAPTURE_CLOSE")) continue;
    VALUE slot = onibi_hash_value(action, "slot");
    rb_hash_aset(captures, slot, LONG2NUM(pos));
  }
}

static int onibi_vm_walk_captures(VALUE states, VALUE edges, VALUE str, long state_id, long pos,
                                  VALUE visited, VALUE captures, long *matched_end, VALUE *matched_captures) {
  VALUE key = rb_ary_new_from_args(2, LONG2NUM(state_id), LONG2NUM(pos));
  if (RTEST(rb_hash_aref(visited, key))) return 0;
  rb_hash_aset(visited, key, Qtrue);
  VALUE state = rb_ary_entry(states, state_id);
  ID op = SYM2ID(onibi_hash_value(state, "op"));
  if (op == rb_intern("G_ACCEPT")) { *matched_end = pos; *matched_captures = captures; return 1; }
  if (op == rb_intern("G_CHAR") || op == rb_intern("G_CLASS") || op == rb_intern("G_ANY")) {
    if (pos >= RSTRING_LEN(str)) return 0;
    unsigned char byte = (unsigned char)RSTRING_PTR(str)[pos];
    VALUE payload = onibi_hash_value(state, "payload");
    int hit = op == rb_intern("G_ANY") ? byte != '\n' :
      (op == rb_intern("G_CHAR") ? byte == NUM2INT(onibi_hash_value(payload, "byte")) : onibi_vm_class_match(payload, byte));
    if (!hit) return 0;
    pos++;
  }
  for (long i = 0; i < RARRAY_LEN(edges); i++) {
    VALUE edge = rb_ary_entry(edges, i);
    if (NUM2LONG(onibi_hash_value(edge, "from")) != state_id) continue;
    if (!onibi_vm_actions_ok(onibi_hash_value(edge, "actions"), pos, RSTRING_LEN(str))) continue;
    VALUE next_captures = onibi_capture_copy(captures);
    onibi_apply_capture_actions(onibi_hash_value(edge, "actions"), pos, next_captures);
    if (onibi_vm_walk_captures(states, edges, str, NUM2LONG(onibi_hash_value(edge, "to")), pos,
                               visited, next_captures, matched_end, matched_captures)) return 1;
  }
  return 0;
}

static int onibi_gir_match_captures(VALUE graph, VALUE str, long start, long *matched_end, VALUE *matched_captures) {
  VALUE states = onibi_hash_value(graph, "states");
  VALUE edges = onibi_hash_value(graph, "edges");
  VALUE starts = onibi_hash_value(graph, "start_edges");
  VALUE visited = rb_hash_new();
  VALUE captures = rb_hash_new();
  for (long i = 0; i < RARRAY_LEN(starts); i++) {
    VALUE edge = rb_ary_entry(starts, i);
    if (!onibi_vm_actions_ok(onibi_hash_value(edge, "actions"), start, RSTRING_LEN(str))) continue;
    VALUE branch_captures = onibi_capture_copy(captures);
    onibi_apply_capture_actions(onibi_hash_value(edge, "actions"), start, branch_captures);
    if (onibi_vm_walk_captures(states, edges, str, NUM2LONG(onibi_hash_value(edge, "to")), start,
                               visited, branch_captures, matched_end, matched_captures)) return 1;
  }
  return 0;
}

static VALUE onibi_vm_match_p(VALUE self, VALUE str) {
  onibi_regexp_t *obj; TypedData_Get_Struct(self, onibi_regexp_t, &onibi_type, obj);
  VALUE src = rb_funcall(obj->regexp, id_source, 0);
  int options = NUM2INT(rb_funcall(obj->regexp, id_options, 0));
  int regular_graph = options == 0;
  for (long i = 0; regular_graph && i < RSTRING_LEN(src); i++) {
    unsigned char c = (unsigned char)RSTRING_PTR(src)[i];
    if (c == ':') regular_graph = 0;
    if (c == '\\' && (i + 1 >= RSTRING_LEN(src) ||
        !strchr("AzZGdDsSwWhH", RSTRING_PTR(src)[i + 1]))) regular_graph = 0;
  }
  if (regular_graph && rb_str_strlen(str) == RSTRING_LEN(str)) {
    VALUE parser_args[1] = { src };
    VALUE parsed = onibi_parser_parse(1, parser_args, Qnil);
    VALUE compiled = onibi_compiler_compile(Qnil, parsed);
    VALUE rseq = onibi_rseq_lower(Qnil, compiled);
    for (long start = 0; start <= RSTRING_LEN(str); start++) {
      long end = 0;
      if (onibi_gir_match(rseq, str, start, &end)) return Qtrue;
    }
    return Qfalse;
  }
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
  int graph_ok = NUM2INT(rb_funcall(obj->regexp, id_options, 0)) == 0;
  for (long i = 0; graph_ok && i < RSTRING_LEN(src); i++) {
    unsigned char c = (unsigned char)RSTRING_PTR(src)[i];
    if (c == ':' || (c == '\\' && (i + 1 >= RSTRING_LEN(src) ||
        !strchr("AzZGdDsSwWhH", RSTRING_PTR(src)[i + 1])))) graph_ok = 0;
  }
  if (graph_ok) {
    VALUE parser_args[1] = { src };
    VALUE compiled = onibi_compiler_compile(Qnil, onibi_parser_parse(1, parser_args, Qnil));
    VALUE rseq = onibi_rseq_lower(Qnil, compiled);
    for (long pos = 0; pos <= RSTRING_LEN(str); pos++) {
      long end = 0;
      VALUE capture_state = rb_hash_new();
      if (!onibi_gir_match_captures(rseq, str, pos, &end, &capture_state)) continue;
      VALUE result = rb_hash_new();
      rb_hash_aset(result, ID2SYM(rb_intern("start")), LONG2NUM(pos));
      rb_hash_aset(result, ID2SYM(rb_intern("end")), LONG2NUM(end));
      VALUE captures = rb_hash_new();
      for (long group_id = 1; group_id <= 8; group_id++) {
        VALUE begin = rb_hash_aref(capture_state, LONG2NUM(2 * (group_id - 1)));
        VALUE finish = rb_hash_aref(capture_state, LONG2NUM(2 * (group_id - 1) + 1));
        if (!NIL_P(begin) && !NIL_P(finish)) {
          VALUE group = rb_hash_new();
          rb_hash_aset(group, ID2SYM(rb_intern("start")), begin);
          rb_hash_aset(group, ID2SYM(rb_intern("end")), finish);
          rb_hash_aset(captures, INT2NUM(group_id), group);
        }
      }
      if (RHASH_SIZE(captures) > 0) rb_hash_aset(result, ID2SYM(rb_intern("captures")), captures);
      return result;
    }
    return Qnil;
  }
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
