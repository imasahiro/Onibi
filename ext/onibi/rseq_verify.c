static int
onibi_unicode_ctype_id(ID property)
{
    static ID ids[26];
    static int ready = 0;
    if (!ready) {
	const char *names[] = {"Alpha", "alpha", "Letter", "Digit",  "digit",
			       "Alnum", "alnum", "Lower",  "lower",  "Upper",
			       "upper", "Space", "space",  "Blank",  "blank",
			       "Word",	"word",	 "XDigit", "xdigit", "Cntrl",
			       "Print", "Graph", "Punct"};
	for (size_t i = 0; i < 23; i++)
	    ids[i] = rb_intern(names[i]);
	ready = 1;
    }
    if (property == ids[0] || property == ids[1] || property == ids[2])
	return ONIGENC_CTYPE_ALPHA;
    if (property == ids[3] || property == ids[4]) return ONIGENC_CTYPE_DIGIT;
    if (property == ids[5] || property == ids[6]) return ONIGENC_CTYPE_ALNUM;
    if (property == ids[7] || property == ids[8]) return ONIGENC_CTYPE_LOWER;
    if (property == ids[9] || property == ids[10]) return ONIGENC_CTYPE_UPPER;
    if (property == ids[11] || property == ids[12]) return ONIGENC_CTYPE_SPACE;
    if (property == ids[13] || property == ids[14]) return ONIGENC_CTYPE_BLANK;
    if (property == ids[15] || property == ids[16]) return ONIGENC_CTYPE_WORD;
    if (property == ids[17] || property == ids[18]) return ONIGENC_CTYPE_XDIGIT;
    if (property == ids[19]) return ONIGENC_CTYPE_CNTRL;
    if (property == ids[20]) return ONIGENC_CTYPE_PRINT;
    if (property == ids[21]) return ONIGENC_CTYPE_GRAPH;
    if (property == ids[22]) return ONIGENC_CTYPE_PUNCT;
    return -1;
}

/* Property names are resolved while the AST is
   compiled.  VM payloads carry this integer, so
   matching never compares property strings. */
static VALUE
onibi_class_payload_with_ctypes(VALUE payload)
{
    VALUE copy = rb_hash_dup(payload);
    OnibiClassMatchMode match_mode =
	onibi_ast_kind(copy) == ONIBI_AST_CLASS_INTERSECTION
	    ? ONIBI_CLASS_MODE_INTERSECTION
	    : ONIBI_CLASS_MODE_NORMAL;
    rb_hash_aset(copy, ID2SYM(id_key_class_mode), INT2NUM(match_mode));
    int fold = RTEST(onibi_hash_value_id(copy, id_key_ignorecase));
    VALUE name_id = onibi_hash_value_id(copy, id_key_name_id);
    ID property = NIL_P(name_id) ? 0 : (ID)NUM2ULONG(name_id);
    int ctype = onibi_unicode_ctype_id(property);
    if (ctype >= 0) rb_hash_aset(copy, ID2SYM(id_key_ctype), INT2NUM(ctype));
    VALUE children = onibi_hash_value_id(copy, id_key_children);
    if (RB_TYPE_P(children, T_ARRAY)) {
	VALUE compiled = rb_ary_new_capa(RARRAY_LEN(children));
	for (long i = 0; i < RARRAY_LEN(children); i++) {
	    VALUE child = rb_ary_entry(children, i);
	    VALUE child_copy =
		RB_TYPE_P(child, T_HASH) ? rb_hash_dup(child) : child;
	    if (RB_TYPE_P(child_copy, T_HASH) &&
		(onibi_hash_value_id(child_copy, id_key_kind_code) ==
		     UINT2NUM(ONIBI_TOKEN_ESCAPE) ||
		 onibi_ast_kind(child_copy) == ONIBI_AST_ESCAPE)) {
		VALUE child_name_id =
		    onibi_hash_value_id(child_copy, id_key_name_id);
		ID property =
		    NIL_P(child_name_id) ? 0 : (ID)NUM2ULONG(child_name_id);
		int child_ctype = onibi_unicode_ctype_id(property);
		if (child_ctype >= 0)
		    rb_hash_aset(child_copy, ID2SYM(id_key_ctype),
				 INT2NUM(child_ctype));
	    }
	    if (fold && RB_TYPE_P(child_copy, T_HASH))
		rb_hash_aset(child_copy, ID2SYM(id_key_ignorecase), Qtrue);
	    rb_ary_push(compiled, child_copy);
	}
	rb_hash_aset(copy, ID2SYM(id_key_children), compiled);
    }
    VALUE operands = onibi_hash_value_id(copy, id_key_operands);
    if (RB_TYPE_P(operands, T_ARRAY)) {
	VALUE compiled_operands = rb_ary_new_capa(RARRAY_LEN(operands));
	for (long i = 0; i < RARRAY_LEN(operands); i++) {
	    VALUE operand =
		onibi_class_payload_with_ctypes(rb_ary_entry(operands, i));
	    if (fold) rb_hash_aset(operand, ID2SYM(id_key_ignorecase), Qtrue);
	    OnibiAstKind operand_type = onibi_ast_kind(operand);
	    if (operand_type == ONIBI_AST_CHARACTER_CLASS ||
		operand_type == ONIBI_AST_CLASS_INTERSECTION)
		rb_hash_aset(operand, ID2SYM(id_key_bitmap),
			     onibi_class_bitmap(operand, 0));
	    rb_ary_push(compiled_operands, operand);
	}
	rb_hash_aset(copy, ID2SYM(id_key_operands), compiled_operands);
    }
    return copy;
}
