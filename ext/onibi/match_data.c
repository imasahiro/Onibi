#include "onibi_matchdata_internal.h"

#include <limits.h>
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
    rb_hash_aset(result, ID2SYM(rb_intern("character_cache_present")),
		 data->char_beg != NULL ? Qtrue : Qfalse);
    return result;
}

static OnibiMatchData *
onibi_matchdata_get(VALUE self)
{
    OnibiMatchData *data;
    TypedData_Get_Struct(self, OnibiMatchData, &onibi_matchdata_type, data);
    return data;
}

#define ONIBI_MATCHDATA_CHAR_UNSET LONG_MIN

static void
onibi_matchdata_set_char_boundary(OnibiMatchData *data, long *char_beg,
				  long *char_end, OnibiBytePos byte,
				  long characters)
{
    for (uint32_t i = 0; i < data->num_regs; i++) {
	if (data->beg[i] == byte && char_beg[i] == ONIBI_MATCHDATA_CHAR_UNSET)
	    char_beg[i] = characters;
	if (data->end[i] == byte && char_end[i] == ONIBI_MATCHDATA_CHAR_UNSET)
	    char_end[i] = characters;
    }
}

static void
onibi_matchdata_cache_char_positions(OnibiMatchData *data)
{
    if (data->char_beg != NULL) return;

    if (data->num_regs > SIZE_MAX / (sizeof(long) * 2U))
	rb_raise(rb_eRangeError,
		 "Onibi MatchData character cache is too large");

    size_t bytes = (size_t)data->num_regs * sizeof(long) * 2U;
    long *cache = ruby_xmalloc(bytes);
    long *char_beg = cache;
    long *char_end = cache + data->num_regs;
    for (uint32_t i = 0; i < data->num_regs; i++) {
	char_beg[i] = ONIBI_MATCHDATA_CHAR_UNSET;
	char_end[i] = ONIBI_MATCHDATA_CHAR_UNSET;
    }

    OnibiBytePos maximum = 0;
    for (uint32_t i = 0; i < data->num_regs; i++) {
	if (data->beg[i] >= 0 && data->beg[i] > maximum) maximum = data->beg[i];
	if (data->end[i] >= 0 && data->end[i] > maximum) maximum = data->end[i];
    }

    VALUE subject = data->subject_snapshot;
    const char *base = RSTRING_PTR(subject);
    const char *tail = base + RSTRING_LEN(subject);
    rb_encoding *encoding = rb_enc_get(subject);
    OnibiBytePos byte = 0;
    long characters = 0;
    onibi_matchdata_set_char_boundary(data, char_beg, char_end, 0, characters);
    while (byte < maximum) {
	int encoded_length = rb_enc_precise_mbclen(base + byte, tail, encoding);
	if (!MBCLEN_CHARFOUND_P(encoded_length)) {
	    ruby_xfree(cache);
	    rb_raise(rb_eArgError, "invalid byte sequence in %s",
		     rb_enc_name(encoding));
	}
	long width = MBCLEN_CHARFOUND_LEN(encoded_length);
	if (width <= 0 || byte > maximum - width) break;
	byte += width;
	characters++;
	onibi_matchdata_set_char_boundary(data, char_beg, char_end, byte,
					  characters);
    }

    for (uint32_t i = 0; i < data->num_regs; i++) {
	if (data->beg[i] >= 0 && char_beg[i] == ONIBI_MATCHDATA_CHAR_UNSET)
	    char_beg[i] = rb_enc_strlen(base, base + data->beg[i], encoding);
	if (data->end[i] >= 0 && char_end[i] == ONIBI_MATCHDATA_CHAR_UNSET)
	    char_end[i] = rb_enc_strlen(base, base + data->end[i], encoding);
    }

    data->char_beg = char_beg;
    data->char_end = char_end;
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
    long selected = rb_num2int(index);
    if (selected < 0) {
	selected += count;
	if (selected <= 0) return Qnil;
    }
    return onibi_matchdata_capture(self, selected);
}

static VALUE
onibi_matchdata_name_string(VALUE selector)
{
    if (SYMBOL_P(selector)) return rb_sym2str(selector);
    if (RB_TYPE_P(selector, T_STRING)) return selector;
    return Qundef;
}

typedef struct {
    const char *bytes;
    long length;
    rb_encoding *encoding;
} OnibiMatchDataNameFormat;

static VALUE
onibi_matchdata_format_name_body(VALUE opaque)
{
    OnibiMatchDataNameFormat *format =
	(OnibiMatchDataNameFormat *)(uintptr_t)opaque;
    VALUE result = rb_str_buf_new(format->length);
    rb_enc_associate(result, format->encoding);
    long end = format->length - 1;
    for (long i = 1; i < end;) {
	if (format->bytes[i] == '\\' && i + 1 < end) {
	    if (format->bytes[i + 1] == '\\' || format->bytes[i + 1] == '"') {
		rb_str_buf_cat(result, format->bytes + i + 1, 1);
		i += 2;
		continue;
	    }
	    if (format->bytes[i + 1] == '#' && i + 2 < end &&
		(format->bytes[i + 2] == '{' || format->bytes[i + 2] == '@' ||
		 format->bytes[i + 2] == '$')) {
		rb_str_buf_cat(result, format->bytes + i + 1, 1);
		i += 2;
		continue;
	    }
	    if (i + 5 < end && format->bytes[i + 1] == 'u' &&
		format->bytes[i + 2] == '0' && format->bytes[i + 3] == '0' &&
		format->bytes[i + 4] == '0' && format->bytes[i + 5] == '0') {
		rb_str_buf_cat(result, "\\0", 2);
		i += 6;
		continue;
	    }
	    if (i + 5 < end && format->bytes[i + 1] == 'u' &&
		format->bytes[i + 2] == '0' && format->bytes[i + 3] == '0' &&
		format->bytes[i + 4] == '7' &&
		(format->bytes[i + 5] == 'F' || format->bytes[i + 5] == 'f')) {
		rb_str_buf_cat(result, "\\c?", 3);
		i += 6;
		continue;
	    }
	    if (i + 3 < end && format->bytes[i + 1] == 'x' &&
		format->bytes[i + 2] == '0' && format->bytes[i + 3] == '0') {
		rb_str_buf_cat(result, "\\0", 2);
		i += 4;
		continue;
	    }
	    if (i + 3 < end && format->bytes[i + 1] == 'x' &&
		format->bytes[i + 2] == '7' &&
		(format->bytes[i + 3] == 'F' || format->bytes[i + 3] == 'f')) {
		rb_str_buf_cat(result, "\\c?", 3);
		i += 4;
		continue;
	    }
	}
	rb_str_buf_cat(result, format->bytes + i, 1);
	i++;
    }
    return result;
}

static VALUE
onibi_matchdata_format_name_cleanup(VALUE opaque)
{
    ruby_xfree((void *)(uintptr_t)opaque);
    return Qnil;
}

static VALUE
onibi_matchdata_format_name(VALUE name)
{
    VALUE inspected = rb_str_inspect(name);
    long length = RSTRING_LEN(inspected);
    char *bytes = ruby_xmalloc((size_t)length);
    memcpy(bytes, RSTRING_PTR(inspected), (size_t)length);
    OnibiMatchDataNameFormat format = {bytes, length, rb_enc_get(inspected)};
    VALUE result =
	rb_ensure(onibi_matchdata_format_name_body, (VALUE)(uintptr_t)&format,
		  onibi_matchdata_format_name_cleanup, (VALUE)(uintptr_t)bytes);
    return result;
}

NORETURN(static void onibi_matchdata_raise_unknown_name(VALUE name));
static void
onibi_matchdata_raise_unknown_name(VALUE name)
{
    VALUE name_text = onibi_matchdata_format_name(name);
    VALUE message = rb_str_plus(
	rb_str_new_cstr("undefined group name reference: "), name_text);
    rb_exc_raise(rb_exc_new_str(rb_eIndexError, message));
}

static long
onibi_matchdata_named_capture_index(OnibiMatchData *data, VALUE selector)
{
    VALUE name = onibi_matchdata_name_string(selector);
    if (name == Qundef) return -1;
    VALUE indices = rb_hash_lookup(data->named_index, name);
    if (NIL_P(indices)) onibi_matchdata_raise_unknown_name(name);
    for (long i = RARRAY_LEN(indices) - 1; i >= 0; i--) {
	VALUE index_value = rb_ary_entry(indices, i);
	long index = NUM2LONG(index_value);
	if (index < 0 || (uint64_t)index >= data->num_regs)
	    rb_raise(rb_eRangeError,
		     "Onibi capture metadata index is out of range");
	if (data->beg[index] >= 0 && data->end[index] >= 0) return index;
    }
    return -1;
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
    if (RB_TYPE_P(index, T_STRING) || SYMBOL_P(index)) {
	long selected = onibi_matchdata_named_capture_index(data, index);
	return selected < 0 ? Qnil : onibi_matchdata_capture(self, selected);
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
onibi_matchdata_names(VALUE self)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    VALUE result = rb_ary_new_capa(RARRAY_LEN(data->names));
    for (long i = 0; i < RARRAY_LEN(data->names); i++)
	rb_ary_push(result, rb_str_dup(rb_ary_entry(data->names, i)));
    return result;
}

static VALUE
onibi_matchdata_named_captures(int argc, VALUE *argv, VALUE self)
{
    VALUE keyword_values[1] = {Qfalse};
    VALUE keywords = Qnil;
    rb_scan_args(argc, argv, "0:", &keywords);
    if (!NIL_P(keywords)) {
	static ID symbolize_names_id;
	if (symbolize_names_id == 0)
	    symbolize_names_id = rb_intern_const("symbolize_names");
	const ID ids[] = {symbolize_names_id};
	rb_get_kwargs(keywords, ids, 0, 1, keyword_values);
    }

    OnibiMatchData *data = onibi_matchdata_get(self);
    VALUE result = rb_hash_new();
    for (long i = 0; i < RARRAY_LEN(data->names); i++) {
	VALUE name = rb_ary_entry(data->names, i);
	long index = onibi_matchdata_named_capture_index(data, name);
	VALUE key =
	    RTEST(keyword_values[0]) ? rb_str_intern(name) : rb_str_dup(name);
	VALUE value = index < 0 ? Qnil : onibi_matchdata_capture(self, index);
	if (!RTEST(keyword_values[0])) rb_obj_freeze(key);
	rb_hash_aset(result, key, value);
    }
    return result;
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

static long
onibi_matchdata_byte_index(OnibiMatchData *data, VALUE selector)
{
    if (RB_TYPE_P(selector, T_STRING) || SYMBOL_P(selector))
	return onibi_matchdata_named_capture_index(data, selector);

    long index = rb_num2int(selector);

    if (index < 0 || (uint32_t)index >= data->num_regs) {
	rb_raise(rb_eIndexError, "index %ld out of matches", index);
    }
    return index;
}

static int
onibi_matchdata_byte_range(OnibiMatchData *data, VALUE selector,
			   OnibiBytePos *begin, OnibiBytePos *end)
{
    long index = onibi_matchdata_byte_index(data, selector);
    if (index < 0) return 0;
    *begin = data->beg[index];
    *end = data->end[index];
    return *begin >= 0 && *end >= 0;
}

static VALUE
onibi_matchdata_bytebegin(VALUE self, VALUE selector)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    OnibiBytePos begin, end;
    if (!onibi_matchdata_byte_range(data, selector, &begin, &end)) return Qnil;
    return LONG2NUM(begin);
}

static VALUE
onibi_matchdata_byteend(VALUE self, VALUE selector)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    OnibiBytePos begin, end;
    if (!onibi_matchdata_byte_range(data, selector, &begin, &end)) return Qnil;
    return LONG2NUM(end);
}

static VALUE
onibi_matchdata_byteoffset(VALUE self, VALUE selector)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    OnibiBytePos begin, end;
    if (!onibi_matchdata_byte_range(data, selector, &begin, &end))
	return rb_ary_new_from_args(2, Qnil, Qnil);
    return rb_ary_new_from_args(2, LONG2NUM(begin), LONG2NUM(end));
}

static int
onibi_matchdata_char_range(OnibiMatchData *data, VALUE selector, long *begin,
			   long *end)
{
    long index = onibi_matchdata_byte_index(data, selector);
    if (index < 0) return 0;
    if (data->beg[index] < 0 || data->end[index] < 0) return 0;
    onibi_matchdata_cache_char_positions(data);
    *begin = data->char_beg[index];
    *end = data->char_end[index];
    return 1;
}

static VALUE
onibi_matchdata_begin(VALUE self, VALUE selector)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    long begin, end;
    if (!onibi_matchdata_char_range(data, selector, &begin, &end)) return Qnil;
    return LONG2NUM(begin);
}

static VALUE
onibi_matchdata_end(VALUE self, VALUE selector)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    long begin, end;
    if (!onibi_matchdata_char_range(data, selector, &begin, &end)) return Qnil;
    return LONG2NUM(end);
}

static VALUE
onibi_matchdata_offset(VALUE self, VALUE selector)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    long begin, end;
    if (!onibi_matchdata_char_range(data, selector, &begin, &end))
	return rb_ary_new_from_args(2, Qnil, Qnil);
    return rb_ary_new_from_args(2, LONG2NUM(begin), LONG2NUM(end));
}

static VALUE
onibi_matchdata_match_length(VALUE self, VALUE selector)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    long begin, end;
    if (!onibi_matchdata_char_range(data, selector, &begin, &end)) return Qnil;
    return LONG2NUM(end - begin);
}

static void
onibi_matchdata_inspect_append(VALUE target, VALUE value)
{
    VALUE inspected = rb_inspect(value);
    rb_str_buf_cat(target, RSTRING_PTR(inspected), RSTRING_LEN(inspected));
}

static VALUE
onibi_matchdata_name_for_index(OnibiMatchData *data, uint32_t index)
{
    for (long i = 0; i < RARRAY_LEN(data->names); i++) {
	VALUE name = rb_ary_entry(data->names, i);
	VALUE indices = rb_hash_lookup(data->named_index, name);
	if (NIL_P(indices)) continue;
	for (long j = 0; j < RARRAY_LEN(indices); j++) {
	    if ((uint32_t)NUM2UINT(rb_ary_entry(indices, j)) == index)
		return name;
	}
    }
    return Qnil;
}

static VALUE
onibi_matchdata_inspect(VALUE self)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    VALUE full = onibi_matchdata_capture(self, 0);
    VALUE full_inspected = rb_inspect(full);
    VALUE result = rb_str_buf_new(RSTRING_LEN(full_inspected) + 32);
    rb_enc_associate(result, rb_enc_get(full_inspected));
    rb_str_buf_cat2(result, "#<MatchData ");
    rb_str_buf_cat(result, RSTRING_PTR(full_inspected),
		   RSTRING_LEN(full_inspected));

    for (uint32_t i = 1; i < data->num_regs; i++) {
	VALUE label = onibi_matchdata_name_for_index(data, i);
	rb_str_buf_cat2(result, " ");
	if (NIL_P(label)) {
	    VALUE index = rb_inspect(UINT2NUM(i));
	    rb_str_buf_cat(result, RSTRING_PTR(index), RSTRING_LEN(index));
	}
	else {
	    rb_str_buf_cat(result, RSTRING_PTR(label), RSTRING_LEN(label));
	}
	rb_str_buf_cat2(result, ":");
	onibi_matchdata_inspect_append(result,
				       onibi_matchdata_capture(self, i));
    }

    rb_str_buf_cat2(result, ">");
    return result;
}

static int
onibi_matchdata_values_equal(const OnibiMatchData *left,
			     const OnibiMatchData *right)
{
    if (left->num_regs != right->num_regs) return 0;
    if (!RTEST(rb_equal(left->regexp, right->regexp))) return 0;
    if (!RTEST(rb_equal(left->subject_snapshot, right->subject_snapshot)))
	return 0;
    for (uint32_t i = 0; i < left->num_regs; i++) {
	if (left->beg[i] != right->beg[i] || left->end[i] != right->end[i])
	    return 0;
    }
    return 1;
}

static VALUE
onibi_matchdata_equal(VALUE self, VALUE other)
{
    if (!rb_obj_is_kind_of(other, cMatchData)) return Qfalse;
    OnibiMatchData *left = onibi_matchdata_get(self);
    OnibiMatchData *right = onibi_matchdata_get(other);
    return onibi_matchdata_values_equal(left, right) ? Qtrue : Qfalse;
}

static VALUE
onibi_matchdata_eql(VALUE self, VALUE other)
{
    return onibi_matchdata_equal(self, other);
}

static VALUE
onibi_matchdata_hash(VALUE self)
{
    OnibiMatchData *data = onibi_matchdata_get(self);
    st_index_t hash = rb_hash_start(0);
    hash = rb_hash_uint(hash, (st_data_t)NUM2ULL(rb_hash(data->regexp)));
    hash = rb_hash_uint(hash, (st_data_t)rb_str_hash(data->subject_snapshot));
    hash = rb_hash_uint32(hash, data->num_regs);
    for (uint32_t i = 0; i < data->num_regs; i++) {
	hash = rb_hash_uint(hash, (st_data_t)data->beg[i]);
	hash = rb_hash_uint(hash, (st_data_t)data->end[i]);
    }
    return ST2FIX(rb_hash_end(hash));
}
