#include "onibi_matchdata_internal.h"

#include <string.h>

static _Thread_local int onibi_matchdata_failure_stage_value;
static size_t onibi_matchdata_live_native_allocations;

static void
onibi_matchdata_maybe_fail(int stage)
{
    if (onibi_matchdata_failure_stage_value == stage)
	rb_raise(eRegexpError, "injected MatchData payload failure at stage %d",
		 stage);
}

static void
onibi_matchdata_set_failure_stage(int stage)
{
    onibi_matchdata_failure_stage_value = stage;
}

static int
onibi_matchdata_failure_stage(void)
{
    return onibi_matchdata_failure_stage_value;
}

static size_t
onibi_matchdata_live_allocations(void)
{
    return onibi_matchdata_live_native_allocations;
}

static void
onibi_matchdata_clear(OnibiMatchData *data)
{
    if (data == NULL) return;
    if (data->beg != NULL && onibi_matchdata_live_native_allocations > 0)
	onibi_matchdata_live_native_allocations--;
    xfree(data->beg);
    xfree(data->char_beg);
    xfree(data->char_end);
    data->beg = NULL;
    data->end = NULL;
    data->char_beg = NULL;
    data->char_end = NULL;
    data->num_regs = 0;
    data->subject_snapshot = Qnil;
    data->regexp = Qnil;
    data->names = Qnil;
    data->named_index = Qnil;
}

static void
onibi_matchdata_free(void *ptr)
{
    OnibiMatchData *data = (OnibiMatchData *)ptr;
    if (data == NULL) return;
    onibi_matchdata_clear(data);
    xfree(data);
}

static void
onibi_matchdata_mark(void *ptr)
{
    OnibiMatchData *data = (OnibiMatchData *)ptr;
    if (data == NULL) return;
    rb_gc_mark(data->subject_snapshot);
    rb_gc_mark(data->regexp);
    rb_gc_mark(data->names);
    rb_gc_mark(data->named_index);
}

static size_t
onibi_matchdata_memsize(const void *ptr)
{
    const OnibiMatchData *data = (const OnibiMatchData *)ptr;
    if (data == NULL) return 0;
    size_t size = sizeof(*data);
    if (data->num_regs <= SIZE_MAX / sizeof(OnibiBytePos) / 2U)
	size += (size_t)data->num_regs * sizeof(OnibiBytePos) * 2U;
    if (data->char_beg != NULL && data->num_regs <= SIZE_MAX / sizeof(long))
	size += (size_t)data->num_regs * sizeof(long);
    if (data->char_end != NULL && data->num_regs <= SIZE_MAX / sizeof(long))
	size += (size_t)data->num_regs * sizeof(long);
    return size;
}

static const rb_data_type_t onibi_matchdata_type = {
    "Onibi::MatchData",
    {onibi_matchdata_mark,
     onibi_matchdata_free,
     onibi_matchdata_memsize,
     NULL,
     {NULL}},
    0,
    0,
    RUBY_TYPED_FREE_IMMEDIATELY};

static VALUE
onibi_matchdata_alloc(VALUE klass)
{
    (void)klass;
    rb_raise(rb_eTypeError, "Onibi::MatchData cannot be allocated directly");
    return Qnil;
}

static void
onibi_matchdata_validate_raw(VALUE subject, const OnibiRawMatch *raw)
{
    if (raw == NULL || raw->num_regs == 0)
	rb_raise(rb_eArgError, "Onibi raw match must contain register zero");
    if (raw->beg == NULL || raw->end == NULL)
	rb_raise(rb_eArgError, "Onibi raw match registers are missing");
    if ((raw->begin_byte < 0) != (raw->end_byte < 0))
	rb_raise(rb_eRangeError, "Onibi raw match has an invalid full range");

    const OnibiBytePos length = (OnibiBytePos)RSTRING_LEN(subject);
    if (raw->begin_byte >= 0 &&
	(raw->begin_byte > raw->end_byte || raw->end_byte > length))
	rb_raise(rb_eRangeError, "Onibi raw match full range is out of bounds");
    if ((size_t)raw->num_regs > SIZE_MAX / sizeof(OnibiBytePos) / 2U)
	rb_raise(rb_eRangeError, "Onibi raw match register count is too large");
    if (raw->beg[0] != raw->begin_byte || raw->end[0] != raw->end_byte)
	rb_raise(rb_eRangeError, "Onibi raw match full range is inconsistent");
    if (raw->beg[0] < 0 || raw->end[0] < 0)
	rb_raise(rb_eRangeError, "Onibi raw match has no full capture");

    for (uint32_t i = 0; i < raw->num_regs; i++) {
	OnibiBytePos begin = raw->beg[i];
	OnibiBytePos end = raw->end[i];
	int begin_missing = begin == (OnibiBytePos)-1;
	int end_missing = end == (OnibiBytePos)-1;
	if (begin_missing || end_missing) {
	    if (!(begin_missing && end_missing))
		rb_raise(rb_eRangeError,
			 "Onibi raw match has a half-unmatched register");
	    continue;
	}
	if (begin < 0 || end < 0 || begin > end || end > length)
	    rb_raise(rb_eRangeError,
		     "Onibi raw match register is out of bounds");
    }
}

static VALUE
onibi_matchdata_copy_names(const onibi_regexp_t *regexp)
{
    VALUE source = regexp->names;
    VALUE result =
	NIL_P(source) ? rb_ary_new() : rb_ary_new_capa(RARRAY_LEN(source));
    if (!NIL_P(source)) {
	for (long i = 0; i < RARRAY_LEN(source); i++) {
	    VALUE name = rb_str_dup(rb_ary_entry(source, i));
	    rb_obj_freeze(name);
	    rb_ary_push(result, name);
	}
    }
    rb_obj_freeze(result);
    return result;
}

typedef struct {
    VALUE target;
    uint32_t num_regs;
} OnibiMatchDataNamedCopy;

static int
onibi_matchdata_copy_named_capture(VALUE key, VALUE value, VALUE opaque)
{
    OnibiMatchDataNamedCopy *copy =
	(OnibiMatchDataNamedCopy *)(uintptr_t)opaque;
    if (!RB_TYPE_P(key, T_STRING) || !RB_TYPE_P(value, T_ARRAY))
	rb_raise(rb_eTypeError, "Onibi regexp capture metadata is invalid");
    VALUE copied_key = rb_str_dup(key);
    VALUE copied_value = rb_ary_dup(value);
    for (long i = 0; i < RARRAY_LEN(copied_value); i++) {
	VALUE index = rb_ary_entry(copied_value, i);
	long group = NUM2LONG(index);
	if (group < 0 || (uint64_t)group >= copy->num_regs)
	    rb_raise(rb_eRangeError,
		     "Onibi capture metadata index is out of range");
    }
    rb_obj_freeze(copied_key);
    rb_obj_freeze(copied_value);
    rb_hash_aset(copy->target, copied_key, copied_value);
    return ST_CONTINUE;
}

static VALUE
onibi_matchdata_copy_named_index(const onibi_regexp_t *regexp,
				 uint32_t num_regs)
{
    VALUE result = rb_hash_new();
    OnibiMatchDataNamedCopy copy = {result, num_regs};
    if (!NIL_P(regexp->named_captures))
	rb_hash_foreach(regexp->named_captures,
			onibi_matchdata_copy_named_capture,
			(VALUE)(uintptr_t)&copy);
    rb_obj_freeze(result);
    return result;
}

typedef struct {
    VALUE object;
    VALUE regexp;
    VALUE subject;
    const OnibiRawMatch *raw_match;
} OnibiMatchDataBuild;

static VALUE
onibi_matchdata_build_body(VALUE opaque)
{
    OnibiMatchDataBuild *build = (OnibiMatchDataBuild *)(uintptr_t)opaque;
    OnibiMatchData *data;
    TypedData_Get_Struct(build->object, OnibiMatchData, &onibi_matchdata_type,
			 data);
    onibi_regexp_t *regexp;
    TypedData_Get_Struct(build->regexp, onibi_regexp_t, &onibi_type, regexp);
    StringValue(build->subject);
    onibi_matchdata_validate_raw(build->subject, build->raw_match);

    data->regexp = build->regexp;
    data->subject_snapshot = rb_str_dup(build->subject);
    rb_obj_freeze(data->subject_snapshot);
    onibi_matchdata_maybe_fail(1);
    data->num_regs = build->raw_match->num_regs;
    size_t bytes = (size_t)data->num_regs * sizeof(OnibiBytePos) * 2U;
    data->beg = ruby_xmalloc(bytes);
    onibi_matchdata_live_native_allocations++;
    data->end = data->beg + data->num_regs;
    memcpy(data->beg, build->raw_match->beg,
	   (size_t)data->num_regs * sizeof(OnibiBytePos));
    memcpy(data->end, build->raw_match->end,
	   (size_t)data->num_regs * sizeof(OnibiBytePos));
    onibi_matchdata_maybe_fail(2);
    data->names = onibi_matchdata_copy_names(regexp);
    onibi_matchdata_maybe_fail(3);
    data->named_index =
	onibi_matchdata_copy_named_index(regexp, data->num_regs);
    onibi_matchdata_maybe_fail(4);
    return build->object;
}

static VALUE
onibi_matchdata_new(VALUE regexp, VALUE subject, const OnibiRawMatch *raw_match)
{
    OnibiMatchData *data;
    VALUE object = TypedData_Make_Struct(cMatchData, OnibiMatchData,
					 &onibi_matchdata_type, data);
    MEMZERO(data, OnibiMatchData, 1);
    data->subject_snapshot = Qnil;
    data->regexp = Qnil;
    data->names = Qnil;
    data->named_index = Qnil;
    OnibiMatchDataBuild build = {object, regexp, subject, raw_match};
    int state = 0;
    rb_protect(onibi_matchdata_build_body, (VALUE)(uintptr_t)&build, &state);
    if (state) {
	onibi_matchdata_clear(data);
	rb_jump_tag(state);
    }
    return object;
}

static VALUE
onibi_matchdata_copy_names_for_summary(VALUE names)
{
    VALUE result = rb_ary_new_capa(RARRAY_LEN(names));
    for (long i = 0; i < RARRAY_LEN(names); i++)
	rb_ary_push(result, rb_str_dup(rb_ary_entry(names, i)));
    return result;
}

typedef struct {
    VALUE target;
} OnibiMatchDataSummaryCopy;

static int
onibi_matchdata_copy_index_for_summary(VALUE key, VALUE value, VALUE opaque)
{
    OnibiMatchDataSummaryCopy *copy =
	(OnibiMatchDataSummaryCopy *)(uintptr_t)opaque;
    rb_hash_aset(copy->target, rb_str_dup(key), rb_ary_dup(value));
    return ST_CONTINUE;
}

static VALUE
onibi_matchdata_summary(VALUE self)
{
    OnibiMatchData *data;
    TypedData_Get_Struct(self, OnibiMatchData, &onibi_matchdata_type, data);
    VALUE result = rb_hash_new();
    VALUE registers = rb_ary_new_capa(data->num_regs);
    for (uint32_t i = 0; i < data->num_regs; i++)
	rb_ary_push(registers, rb_ary_new_from_args(2, LONG2NUM(data->beg[i]),
						    LONG2NUM(data->end[i])));
    VALUE named_index = rb_hash_new();
    OnibiMatchDataSummaryCopy copy = {named_index};
    rb_hash_foreach(data->named_index, onibi_matchdata_copy_index_for_summary,
		    (VALUE)(uintptr_t)&copy);
    rb_hash_aset(result, ID2SYM(rb_intern("subject")),
		 rb_str_dup(data->subject_snapshot));
    rb_hash_aset(result, ID2SYM(rb_intern("subject_frozen")),
		 RTEST(rb_obj_frozen_p(data->subject_snapshot)) ? Qtrue
								: Qfalse);
    rb_hash_aset(result, ID2SYM(rb_intern("regexp")), data->regexp);
    rb_hash_aset(result, ID2SYM(rb_intern("num_regs")),
		 UINT2NUM(data->num_regs));
    rb_hash_aset(result, ID2SYM(rb_intern("raw_registers")), registers);
    rb_hash_aset(result, ID2SYM(rb_intern("names")),
		 onibi_matchdata_copy_names_for_summary(data->names));
    rb_hash_aset(result, ID2SYM(rb_intern("named_index")), named_index);
    rb_hash_aset(result, ID2SYM(rb_intern("lazy_character_cache")), Qtrue);
    return result;
}

static OnibiMatchData *
onibi_matchdata_get(VALUE self)
{
    OnibiMatchData *data;
    TypedData_Get_Struct(self, OnibiMatchData, &onibi_matchdata_type, data);
    return data;
}

static VALUE
onibi_matchdata_capture(VALUE self, long index)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    if (index < 0 || (uint64_t)index >= data->num_regs) return Qnil;
    OnibiBytePos begin = data->beg[index];
    OnibiBytePos end = data->end[index];
    if (begin < 0 || end < 0) return Qnil;
    return rb_str_subseq(data->subject_snapshot, begin, end - begin);
}

static VALUE
onibi_matchdata_capture_array(VALUE self, long start, long length)
{
    VALUE result = rb_ary_new_capa(length);
    for (long i = 0; i < length; i++)
	rb_ary_push(result, onibi_matchdata_capture(self, start + i));
    return result;
}

static VALUE
onibi_matchdata_numeric_capture(VALUE self, VALUE index, long count)
{
    if (RB_TYPE_P(index, T_STRING) || RB_TYPE_P(index, T_SYMBOL))
	rb_raise(rb_eIndexError, "undefined group name reference");
    long selected = rb_num2int(index);
    if (selected < 0) {
	selected += count;
	if (selected <= 0) return Qnil;
    }
    return onibi_matchdata_capture(self, selected);
}

static VALUE
onibi_matchdata_aref(int argc, VALUE *argv, VALUE self)
{
    rb_check_arity(argc, 1, 2);
    OnibiMatchData *data = onibi_matchdata_get(self);
    long count = (long)data->num_regs;
    VALUE index = argv[0];

    if (argc == 2 && NIL_P(argv[1])) return onibi_matchdata_aref(1, argv, self);

    if (argc == 2) {
	long start = rb_num2long(index);
	long length = rb_num2long(argv[1]);
	if (length < 0) return Qnil;
	if (start < 0) start += count;
	if (start < 0 || start > count) return Qnil;
	if (start == count) return rb_ary_new();
	if (length > count - start) length = count - start;
	return onibi_matchdata_capture_array(self, start, length);
    }

    if (rb_obj_is_kind_of(index, rb_cRange)) {
	long start, length;
	VALUE status = rb_range_beg_len(index, &start, &length, count, 0);
	if (status == Qnil) return Qnil;
	if (status == Qfalse)
	    rb_raise(rb_eTypeError, "invalid MatchData index");
	return onibi_matchdata_capture_array(self, start, length);
    }
    return onibi_matchdata_numeric_capture(self, index, count);
}

static VALUE
onibi_matchdata_captures(VALUE self)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    if (data->num_regs <= 1) return rb_ary_new();
    return onibi_matchdata_capture_array(self, 1, (long)data->num_regs - 1);
}

static VALUE
onibi_matchdata_to_a(VALUE self)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    return onibi_matchdata_capture_array(self, 0, (long)data->num_regs);
}

static VALUE
onibi_matchdata_size(VALUE self)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    return UINT2NUM(data->num_regs);
}

static VALUE
onibi_matchdata_to_s(VALUE self)
{
    return onibi_matchdata_capture(self, 0);
}

static VALUE
onibi_matchdata_string(VALUE self)
{
    return onibi_matchdata_get(self)->subject_snapshot;
}

static VALUE
onibi_matchdata_pre_match(VALUE self)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    return rb_str_subseq(data->subject_snapshot, 0, data->beg[0]);
}

static VALUE
onibi_matchdata_post_match(VALUE self)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    long length = RSTRING_LEN(data->subject_snapshot) - data->end[0];
    return rb_str_subseq(data->subject_snapshot, data->end[0], length);
}

static VALUE
onibi_matchdata_regexp(VALUE self)
{
    return onibi_matchdata_get(self)->regexp;
}
