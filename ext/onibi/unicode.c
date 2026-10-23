#include "onibi_encoding_internal.h"

typedef struct {
    VALUE subject;
    OnibiBytePos position;
    VALUE previous;
    VALUE restore;
    OnibiBytePos width;
} OnibiGraphemeWidthCall;

/* Use MRI's Onigmo grapheme implementation as the Unicode source of truth. */
static VALUE
onibi_grapheme_width_body(VALUE opaque)
{
    OnibiGraphemeWidthCall *call = (OnibiGraphemeWidthCall *)(uintptr_t)opaque;
    call->previous = rb_backref_get();
    call->restore = call->previous;
    if (!NIL_P(call->previous)) call->restore = rb_obj_dup(call->previous);

    VALUE source = rb_str_new_cstr("\\X");
    rb_enc_associate(source, rb_enc_get(call->subject));
    VALUE regexp_class = rb_const_get(rb_cObject, rb_intern("Regexp"));
    VALUE regexp = rb_funcall(regexp_class, id_new, 1, source);
    VALUE tail = rb_str_substr(call->subject, call->position,
			       RSTRING_LEN(call->subject) - call->position);
    rb_reg_match(regexp, tail);
    VALUE match = rb_backref_get();
    if (!NIL_P(match))
	call->width = NUM2LONG(rb_funcall(match, id_byteend, 1, INT2NUM(0)));

    RB_GC_GUARD(source);
    RB_GC_GUARD(regexp);
    RB_GC_GUARD(tail);
    RB_GC_GUARD(match);
    return Qnil;
}

static VALUE
onibi_grapheme_width_ensure(VALUE opaque)
{
    OnibiGraphemeWidthCall *call = (OnibiGraphemeWidthCall *)(uintptr_t)opaque;
    rb_backref_set(call->restore);
    return Qnil;
}

static long
onibi_grapheme_width(VALUE str, OnibiBytePos pos)
{
    if (pos < 0 || pos >= RSTRING_LEN(str)) return 0;
    OnibiGraphemeWidthCall call = {
	.subject = str,
	.position = pos,
	.previous = Qnil,
	.restore = Qnil,
	.width = 0,
    };
    (void)rb_ensure(onibi_grapheme_width_body, (VALUE)(uintptr_t)&call,
		    onibi_grapheme_width_ensure, (VALUE)(uintptr_t)&call);
    RB_GC_GUARD(call.subject);
    RB_GC_GUARD(call.previous);
    RB_GC_GUARD(call.restore);
    return (long)call.width;
}
