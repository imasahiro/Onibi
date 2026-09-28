#ifndef ONIBI_MATCHDATA_INTERNAL_H
#define ONIBI_MATCHDATA_INTERNAL_H

#include "onibi_exec_internal.h"

typedef struct {
    VALUE subject_snapshot;
    VALUE regexp;
    VALUE names;
    VALUE named_index;
    OnibiBytePos *beg;
    OnibiBytePos *end;
    long *char_beg;
    long *char_end;
    uint32_t num_regs;
} OnibiMatchData;

static VALUE onibi_matchdata_new(VALUE regexp, VALUE subject,
				 const OnibiRawMatch *raw_match);
static VALUE onibi_matchdata_summary(VALUE self);
static VALUE onibi_matchdata_aref(int argc, VALUE *argv, VALUE self);
static VALUE onibi_matchdata_match(VALUE self, VALUE selector);
static VALUE onibi_matchdata_captures(VALUE self);
static VALUE onibi_matchdata_names(VALUE self);
static VALUE onibi_matchdata_named_captures(int argc, VALUE *argv, VALUE self);
static VALUE onibi_matchdata_to_a(VALUE self);
static VALUE onibi_matchdata_size(VALUE self);
static VALUE onibi_matchdata_to_s(VALUE self);
static VALUE onibi_matchdata_string(VALUE self);
static VALUE onibi_matchdata_pre_match(VALUE self);
static VALUE onibi_matchdata_post_match(VALUE self);
static VALUE onibi_matchdata_regexp(VALUE self);
static VALUE onibi_matchdata_bytebegin(VALUE self, VALUE selector);
static VALUE onibi_matchdata_byteend(VALUE self, VALUE selector);
static VALUE onibi_matchdata_byteoffset(VALUE self, VALUE selector);
static VALUE onibi_matchdata_begin(VALUE self, VALUE selector);
static VALUE onibi_matchdata_end(VALUE self, VALUE selector);
static VALUE onibi_matchdata_offset(VALUE self, VALUE selector);
static VALUE onibi_matchdata_match_length(VALUE self, VALUE selector);
static VALUE onibi_matchdata_inspect(VALUE self);
static VALUE onibi_matchdata_equal(VALUE self, VALUE other);
static VALUE onibi_matchdata_eql(VALUE self, VALUE other);
static VALUE onibi_matchdata_hash(VALUE self);
static VALUE onibi_matchdata_dup(VALUE self);
static VALUE onibi_matchdata_clone(VALUE self);
static VALUE onibi_matchdata_initialize_copy(VALUE self, VALUE source);
static VALUE onibi_matchdata_deconstruct(VALUE self);
static VALUE onibi_matchdata_deconstruct_keys(VALUE self, VALUE keys);
static VALUE onibi_matchdata_payload_diagnostics(int argc, VALUE *argv,
						 VALUE self);
static VALUE onibi_matchdata_payload_new(int argc, VALUE *argv, VALUE self);
static VALUE onibi_matchdata_factory(int argc, VALUE *argv, VALUE klass);
static VALUE onibi_matchdata_failure_diagnostics(int argc, VALUE *argv,
						 VALUE self);
static void onibi_matchdata_set_failure_stage(int stage);
static int onibi_matchdata_failure_stage(void);
static size_t onibi_matchdata_live_allocations(void);
static VALUE onibi_matchdata_alloc(VALUE klass);

#endif
