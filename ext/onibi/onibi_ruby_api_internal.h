#ifndef ONIBI_RUBY_API_INTERNAL_H
#define ONIBI_RUBY_API_INTERNAL_H

#include "ruby.h"

/* Private Ruby boundary contract.  Ruby values enter and leave here.  The
 * compiler, RSeq validator, and interpreters use C records internally. */

static VALUE onibi_alloc(VALUE klass);
static VALUE onibi_initialize(int argc, VALUE *argv, VALUE self);
static VALUE onibi_match(int argc, VALUE *argv, VALUE self);
static VALUE onibi_match_p(int argc, VALUE *argv, VALUE self);
static VALUE onibi_source(VALUE self);
static VALUE onibi_options(VALUE self);
static VALUE onibi_names(VALUE self);
static VALUE onibi_named_captures(VALUE self);

#endif
