/* Use MRI's Onigmo grapheme implementation as the Unicode source of truth. */
static long
onibi_grapheme_width(VALUE str, long pos)
{
    if (pos < 0 || pos >= RSTRING_LEN(str)) return 0;
    VALUE previous = rb_backref_get();
    VALUE source = rb_str_new_cstr("\\X");
    rb_enc_associate(source, rb_enc_get(str));
    VALUE regexp_class = rb_const_get(rb_cObject, rb_intern("Regexp"));
    VALUE regexp = rb_funcall(regexp_class, id_new, 1, source);
    VALUE tail = rb_str_substr(str, pos, RSTRING_LEN(str) - pos);
    rb_reg_match(regexp, tail);
    VALUE match = rb_backref_get();
    long width = NIL_P(match)
		     ? 0
		     : NUM2LONG(rb_funcall(match, id_byteend, 1, INT2NUM(0)));
    rb_backref_set(previous);
    return width;
}
