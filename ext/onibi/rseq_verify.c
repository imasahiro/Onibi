			    ONIBI_GA_CAPTURE_CLOSE &&
			NUM2LONG(onibi_hash_value_id(
			    event_action, id_key_slot)) == 2 * capture + 1 &&
			!NIL_P(rb_hash_aref(captures, LONG2NUM(2 * capture))))
			    {
				set = 1;
				break;
			    }
			    }
			    }
			    if (set !=
				RTEST(onibi_hash_value_id(action, id_key_set)))
				return 0;
			    continue;
			    }
			    if (code == ONIBI_GA_TEST_COUNTER_LT ||
				code == ONIBI_GA_TEST_COUNTER_GE) {
				long count = 0;
				if (counter_state && counter_state->values) {
				    VALUE slot_value = onibi_hash_value_id(
					action, id_key_slot);
				    long slot = NIL_P(slot_value)
						    ? -1
						    : NUM2LONG(slot_value);
				    count =
					slot >= 0 && (uint32_t)slot <
							 counter_state->count
					    ? counter_state->values[slot]
					    : 0;
				}
				else {
				    if (NIL_P(counters)) continue;
				    VALUE value = rb_hash_aref(
					counters, onibi_hash_value_id(
						      action, id_key_slot));
				    count = NIL_P(value) ? 0 : NUM2LONG(value);
				}
				long limit = NUM2LONG(
				    onibi_hash_value_id(action, id_key_limit));
				if ((code == ONIBI_GA_TEST_COUNTER_LT &&
				     !(count < limit)) ||
				    (code == ONIBI_GA_TEST_COUNTER_GE &&
				     !(count >= limit)))
				    return 0;
				continue;
			    }
			    VALUE assertion_value =
				onibi_hash_value_id(action, id_key_assert_kind);
			    OnibiRAssertKind assertion =
				NIL_P(assertion_value)
				    ? (OnibiRAssertKind)0
				    : (OnibiRAssertKind)NUM2ULONG(
					  assertion_value);
			    if (assertion == ONIBI_RAP_BEGIN_BUFFER && pos != 0)
				return 0;
			    if (assertion == ONIBI_RAP_SEARCH_ORIGIN &&
				pos != search_origin)
				return 0;
			    if (assertion == ONIBI_RAP_END_BUFFER &&
				pos != length)
				return 0;
			    if (assertion == ONIBI_RAP_BEGIN_LINE && pos != 0 &&
				RSTRING_PTR(subject)[pos - 1] != '\n')
				return 0;
			    if (assertion == ONIBI_RAP_END_LINE &&
				pos != length &&
				RSTRING_PTR(subject)[pos] != '\n')
				return 0;
			    if (assertion == ONIBI_RAP_WORD_BOUNDARY ||
				assertion == ONIBI_RAP_NONWORD_BOUNDARY) {
				int before =
				    pos > 0 &&
				    (isalnum((unsigned char)RSTRING_PTR(
					 subject)[pos - 1]) ||
				     RSTRING_PTR(subject)[pos - 1] == '_');
				int after = pos < length &&
					    (isalnum((unsigned char)RSTRING_PTR(
						 subject)[pos]) ||
					     RSTRING_PTR(subject)[pos] == '_');
				int boundary = before != after;
				if ((assertion == ONIBI_RAP_WORD_BOUNDARY &&
				     !boundary) ||
				    (assertion == ONIBI_RAP_NONWORD_BOUNDARY &&
				     boundary))
				    return 0;
			    }
			    if (assertion == ONIBI_RAP_SEMI_END_BUFFER &&
				pos != length &&
				!(pos + 1 == length && length > 0 &&
				  RSTRING_PTR(subject)[length - 1] == '\n'))
				return 0;
			    if (assertion == ONIBI_RAP_LOOKAHEAD) {
				VALUE predicates = onibi_hash_value_id(
				    action, id_key_predicates);
				if (RB_TYPE_P(predicates, T_ARRAY)) {
				    int matched = 1;
				    for (long i = 0; i < RARRAY_LEN(predicates);
					 i++) {
					VALUE predicate =
					    rb_ary_entry(predicates, i);
					long at = pos + i;
					if (at >= length) {
					    matched = 0;
					    break;
					}
					unsigned char byte =
					    (unsigned char)RSTRING_PTR(
						subject)[at];
					OnibiPredicateKind kind =
					    (OnibiPredicateKind)NUM2UINT(
						onibi_hash_value_id(
						    predicate,
						    id_key_predicate_code));
					if (kind == ONIBI_PRED_BYTE) {
					    unsigned char expected =
						(unsigned char)NUM2INT(
						    onibi_hash_value_id(
							predicate,
							id_key_byte));
					    matched =
						matched &&
						(RTEST(onibi_hash_value_id(
						     predicate,
						     id_key_ignorecase))
						     ? tolower(byte) ==
							   tolower(expected)
						     : byte == expected);
					}
					else if (kind == ONIBI_PRED_ANY) {
					    matched =
						matched &&
						(byte != '\n' ||
						 RTEST(onibi_hash_value_id(
						     predicate,
						     id_key_multiline)));
					}
					else {
					    VALUE bits = onibi_hash_value_id(
						predicate, id_key_bitmap);
					    matched =
						matched &&
						RB_TYPE_P(bits, T_STRING) &&
						RSTRING_LEN(bits) == 32 &&
						(((unsigned char *)RSTRING_PTR(
						     bits))[byte >> 3] &
						 (1U << (byte & 7))) != 0;
					}
					if (!matched) break;
				    }
				    if (matched !=
					RTEST(onibi_hash_value_id(
					    action, id_key_positive)))
					return 0;
				    continue;
				}
				VALUE bitmap =
				    onibi_hash_value_id(action, id_key_bitmap);
				if (!NIL_P(bitmap)) {
				    int hit =
					pos < length &&
					RSTRING_LEN(bitmap) == 32 &&
					(((unsigned char *)RSTRING_PTR(
					     bitmap))[(unsigned char)
							  RSTRING_PTR(
							      subject)[pos] >>
						      3] &
					 (1U << ((unsigned char)RSTRING_PTR(
						     subject)[pos] &
						 7))) != 0;
				    if (hit != RTEST(onibi_hash_value_id(
						   action, id_key_positive)))
					return 0;
				    continue;
				}
				VALUE bytes =
				    onibi_hash_value_id(action, id_key_bytes);
				long width = RSTRING_LEN(bytes);
				int hit = pos + width <= length &&
					  memcmp(RSTRING_PTR(subject) + pos,
						 RSTRING_PTR(bytes),
						 (size_t)width) == 0;
				if (hit != RTEST(onibi_hash_value_id(
					       action, id_key_positive)))
				    return 0;
			    }
			    if (assertion == ONIBI_RAP_LOOKBEHIND) {
				VALUE predicates = onibi_hash_value_id(
				    action, id_key_predicates);
				if (RB_TYPE_P(predicates, T_ARRAY)) {
				    long width = RARRAY_LEN(predicates);
				    int matched = pos >= width;
				    for (long i = 0; matched && i < width;
					 i++) {
					VALUE predicate =
					    rb_ary_entry(predicates, i);
					unsigned char byte =
					    (unsigned char)RSTRING_PTR(
						subject)[pos - width + i];
					OnibiPredicateKind kind =
					    (OnibiPredicateKind)NUM2UINT(
						onibi_hash_value_id(
						    predicate,
						    id_key_predicate_code));
					if (kind == ONIBI_PRED_BYTE) {
					    unsigned char expected =
						(unsigned char)NUM2INT(
						    onibi_hash_value_id(
							predicate,
							id_key_byte));
					    matched =
						RTEST(onibi_hash_value_id(
						    predicate,
						    id_key_ignorecase))
						    ? tolower(byte) ==
							  tolower(expected)
						    : byte == expected;
					}
					else if (kind == ONIBI_PRED_ANY) {
					    matched =
						matched &&
						(byte != '\n' ||
						 RTEST(onibi_hash_value_id(
						     predicate,
						     id_key_multiline)));
					}
					else {
					    VALUE bits = onibi_hash_value_id(
						predicate, id_key_bitmap);
					    matched =
						RB_TYPE_P(bits, T_STRING) &&
						RSTRING_LEN(bits) == 32 &&
						(((unsigned char *)RSTRING_PTR(
						     bits))[byte >> 3] &
						 (1U << (byte & 7))) != 0;
					}
				    }
				    if (matched !=
					RTEST(onibi_hash_value_id(
					    action, id_key_positive)))
					return 0;
				    continue;
				}
				VALUE bitmap =
				    onibi_hash_value_id(action, id_key_bitmap);
				if (!NIL_P(bitmap)) {
				    int hit =
					pos > 0 && RSTRING_LEN(bitmap) == 32 &&
					(((unsigned char *)RSTRING_PTR(bitmap))
					     [(unsigned char)RSTRING_PTR(
						  subject)[pos - 1] >>
					      3] &
					 (1U << ((unsigned char)RSTRING_PTR(
						     subject)[pos - 1] &
						 7))) != 0;
				    if (hit != RTEST(onibi_hash_value_id(
						   action, id_key_positive)))
					return 0;
				    continue;
				}
				VALUE bytes =
				    onibi_hash_value_id(action, id_key_bytes);
				long width = RSTRING_LEN(bytes);
				int hit =
				    pos >= width &&
				    memcmp(RSTRING_PTR(subject) + pos - width,
					   RSTRING_PTR(bytes),
					   (size_t)width) == 0;
				if (hit != RTEST(onibi_hash_value_id(
					       action, id_key_positive)))
				    return 0;
			    }
			    }
			    return 1;
			    }

			    static int
			    onibi_unicode_ctype_id(ID property)
			    {
				static ID ids[26];
				static int ready = 0;
				if (!ready) {
				    const char *names[] = {
					"Alpha", "alpha",  "Letter", "Digit",
					"digit", "Alnum",  "alnum",  "Lower",
					"lower", "Upper",  "upper",  "Space",
					"space", "Blank",  "blank",  "Word",
					"word",	 "XDigit", "xdigit", "Cntrl",
					"Print", "Graph",  "Punct"};
				    for (size_t i = 0; i < 23; i++)
					ids[i] = rb_intern(names[i]);
				    ready = 1;
				}
				if (property == ids[0] || property == ids[1] ||
				    property == ids[2])
				    return ONIGENC_CTYPE_ALPHA;
				if (property == ids[3] || property == ids[4])
				    return ONIGENC_CTYPE_DIGIT;
				if (property == ids[5] || property == ids[6])
				    return ONIGENC_CTYPE_ALNUM;
				if (property == ids[7] || property == ids[8])
				    return ONIGENC_CTYPE_LOWER;
				if (property == ids[9] || property == ids[10])
				    return ONIGENC_CTYPE_UPPER;
				if (property == ids[11] || property == ids[12])
				    return ONIGENC_CTYPE_SPACE;
				if (property == ids[13] || property == ids[14])
				    return ONIGENC_CTYPE_BLANK;
				if (property == ids[15] || property == ids[16])
				    return ONIGENC_CTYPE_WORD;
				if (property == ids[17] || property == ids[18])
				    return ONIGENC_CTYPE_XDIGIT;
				if (property == ids[19])
				    return ONIGENC_CTYPE_CNTRL;
				if (property == ids[20])
				    return ONIGENC_CTYPE_PRINT;
				if (property == ids[21])
				    return ONIGENC_CTYPE_GRAPH;
				if (property == ids[22])
				    return ONIGENC_CTYPE_PUNCT;
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
				    onibi_ast_kind(copy) ==
					    ONIBI_AST_CLASS_INTERSECTION
					? ONIBI_CLASS_MODE_INTERSECTION
					: ONIBI_CLASS_MODE_NORMAL;
				rb_hash_aset(copy, ID2SYM(id_key_class_mode),
					     INT2NUM(match_mode));
				int fold = RTEST(onibi_hash_value_id(
				    copy, id_key_ignorecase));
				VALUE name_id =
				    onibi_hash_value_id(copy, id_key_name_id);
				ID property =
				    NIL_P(name_id) ? 0 : (ID)NUM2ULONG(name_id);
				int ctype = onibi_unicode_ctype_id(property);
				if (ctype >= 0)
				    rb_hash_aset(copy, ID2SYM(id_key_ctype),
						 INT2NUM(ctype));
				VALUE children =
				    onibi_hash_value_id(copy, id_key_children);
				if (RB_TYPE_P(children, T_ARRAY)) {
				    VALUE compiled =
					rb_ary_new_capa(RARRAY_LEN(children));
				    for (long i = 0; i < RARRAY_LEN(children);
					 i++) {
					VALUE child = rb_ary_entry(children, i);
					VALUE child_copy =
					    RB_TYPE_P(child, T_HASH)
						? rb_hash_dup(child)
						: child;
					if (RB_TYPE_P(child_copy, T_HASH) &&
					    (onibi_hash_value_id(
						 child_copy,
						 id_key_kind_code) ==
						 UINT2NUM(ONIBI_TOKEN_ESCAPE) ||
					     onibi_ast_kind(child_copy) ==
						 ONIBI_AST_ESCAPE)) {
					    VALUE child_name_id =
						onibi_hash_value_id(
						    child_copy, id_key_name_id);
					    ID property =
						NIL_P(child_name_id)
						    ? 0
						    : (ID)NUM2ULONG(
							  child_name_id);
					    int child_ctype =
						onibi_unicode_ctype_id(
						    property);
					    if (child_ctype >= 0)
						rb_hash_aset(
						    child_copy,
						    ID2SYM(id_key_ctype),
						    INT2NUM(child_ctype));
					}
					if (fold &&
					    RB_TYPE_P(child_copy, T_HASH))
					    rb_hash_aset(
						child_copy,
						ID2SYM(id_key_ignorecase),
						Qtrue);
					rb_ary_push(compiled, child_copy);
				    }
				    rb_hash_aset(copy, ID2SYM(id_key_children),
						 compiled);
				}
				VALUE operands =
				    onibi_hash_value_id(copy, id_key_operands);
				if (RB_TYPE_P(operands, T_ARRAY)) {
				    VALUE compiled_operands =
					rb_ary_new_capa(RARRAY_LEN(operands));
				    for (long i = 0; i < RARRAY_LEN(operands);
					 i++) {
					VALUE operand =
					    onibi_class_payload_with_ctypes(
						rb_ary_entry(operands, i));
					if (fold)
					    rb_hash_aset(
						operand,
						ID2SYM(id_key_ignorecase),
						Qtrue);
					OnibiAstKind operand_type =
					    onibi_ast_kind(operand);
					if (operand_type ==
						ONIBI_AST_CHARACTER_CLASS ||
					    operand_type ==
						ONIBI_AST_CLASS_INTERSECTION)
					    rb_hash_aset(
						operand, ID2SYM(id_key_bitmap),
						onibi_class_bitmap(operand, 0));
					rb_ary_push(compiled_operands, operand);
				    }
				    rb_hash_aset(copy, ID2SYM(id_key_operands),
						 compiled_operands);
				}
				return copy;
			    }

			    static int
			    onibi_codepoint_at(VALUE str, long pos,
					       OnigCodePoint *codepoint,
					       long *width)
			    {
				const char *ptr = RSTRING_PTR(str) + pos;
				const char *end =
				    RSTRING_PTR(str) + RSTRING_LEN(str);
				int length =
				    rb_enc_mbclen(ptr, end, rb_enc_get(str));
				if (length <= 0 || ptr + length > end) return 0;
				*codepoint = ONIGENC_MBC_TO_CODE(
				    rb_enc_get(str), (const OnigUChar *)ptr,
				    (const OnigUChar *)end);
				*width = length;
				return 1;
			    }

			    static int
			    onibi_ctype_casefold_hit(VALUE str, long pos,
						     OnigCodePoint code,
						     int ctype, int hit)
			    {
				if (hit) return 1;
				const OnigEncoding enc = rb_enc_get(str);
				const OnigUChar *ptr =
				    (const OnigUChar *)RSTRING_PTR(str) + pos;
				const OnigUChar *end =
				    (const OnigUChar *)RSTRING_PTR(str) +
				    RSTRING_LEN(str);
				OnigCaseFoldCodeItem
				    folds[ONIGENC_GET_CASE_FOLD_CODES_MAX_NUM];
				int count = ONIGENC_GET_CASE_FOLD_CODES_BY_STR(
				    enc, ONIGENC_CASE_FOLD_DEFAULT, ptr, end,
				    folds);
				for (int i = 0; i < count; i++) {
				    for (int j = 0; j < folds[i].code_len; j++)
					if (folds[i].code[j] != code &&
					    ONIGENC_IS_CODE_CTYPE(
						enc, folds[i].code[j], ctype))
					    return 1;
				}
				return 0;
			    }

			    static inline int
			    onibi_vm_class_match(VALUE payload, VALUE str,
						 long pos, unsigned char byte,
						 long *width)
			    {
				VALUE class_mode = onibi_hash_value_id(
				    payload, id_key_class_mode);
				int encoding_index = rb_enc_get_index(str);
				if (!NIL_P(class_mode) &&
				    NUM2INT(class_mode) ==
					ONIBI_CLASS_MODE_INTERSECTION &&
				    encoding_index == rb_utf8_encindex()) {
				    VALUE operands = onibi_hash_value_id(
					payload, id_key_operands);
				    if (!RB_TYPE_P(operands, T_ARRAY) ||
					RARRAY_LEN(operands) == 0)
					return 0;
				    long common_width = 0;
				    int hit = 1;
				    for (long i = 0; i < RARRAY_LEN(operands);
					 i++) {
					long operand_width = 0;
					VALUE operand =
					    rb_ary_entry(operands, i);
					/* Ignorecase is propagated to every
					 * operand by
					 * onibi_class_payload_with_ctypes
					 * during compilation.  Do not copy
					 * semantic payloads in this
					 * per-character VM path. */
					int operand_hit = onibi_vm_class_match(
					    operand, str, pos, byte,
					    &operand_width);
					if (i == 0)
					    common_width = operand_width;
					else if (operand_width != common_width)
					    operand_hit = 0;
					hit = hit && operand_hit;
				    }
				    *width = common_width;
				    return hit;
				}
				VALUE ctype_value =
				    onibi_hash_value_id(payload, id_key_ctype);
				int ctype = NIL_P(ctype_value)
						? -1
						: NUM2INT(ctype_value);
				if (ctype >= 0 &&
				    encoding_index == rb_utf8_encindex()) {
				    if (pos > 0 &&
					((unsigned char)RSTRING_PTR(str)[pos] &
					 0xc0) == 0x80 &&
					(((unsigned char)RSTRING_PTR(
					      str)[pos - 1] &
					  0xc0) == 0x80 ||
					 (unsigned char)RSTRING_PTR(
					     str)[pos - 1] >= 0xc0))
					return 0;
				    OnigCodePoint code;
				    long length = 0;
				    if (!onibi_codepoint_at(str, pos, &code,
							    &length))
					return 0;
				    int hit = ONIGENC_IS_CODE_CTYPE(
					rb_enc_get(str), code, ctype);
				    if (RTEST(onibi_hash_value_id(
					    payload, id_key_ignorecase)))
					hit = onibi_ctype_casefold_hit(
					    str, pos, code, ctype, hit);
				    if (NUM2INT(onibi_hash_value_id(
					    payload, id_key_byte)) == 'P')
					hit = !hit;
				    *width = length;
				    return hit;
				}
				VALUE name =
				    onibi_hash_value_id(payload, id_key_name);
				if (NIL_P(name) &&
				    !rb_enc_str_asciionly_p(str) &&
				    encoding_index != rb_ascii8bit_encindex()) {
				    VALUE children = onibi_hash_value_id(
					payload, id_key_children);
				    VALUE ranges = onibi_hash_value_id(
					payload, id_key_ranges);
				    if (RB_TYPE_P(children, T_ARRAY) &&
					RB_TYPE_P(ranges, T_ARRAY)) {
					OnigCodePoint code;
					long decoded_width = 0;
					if (!onibi_codepoint_at(str, pos, &code,
								&decoded_width))
					    return 0;
					int hit = 0;
					for (long i = 0;
					     i < RARRAY_LEN(children); i++) {
					    VALUE child =
						rb_ary_entry(children, i);
					    VALUE kind_value =
						onibi_hash_value_id(
						    child, id_key_kind_code);
					    if (NIL_P(kind_value)) continue;
					    OnibiTokenKind kind =
						(OnibiTokenKind)NUM2UINT(
						    kind_value);
					    if (kind == ONIBI_TOKEN_LITERAL) {
						VALUE bytes =
						    onibi_hash_value_id(
							child, id_key_bytes);
						if (NIL_P(bytes)) {
						    VALUE child_byte =
							onibi_hash_value_id(
							    child, id_key_byte);
						    if (!NIL_P(child_byte) &&
							code ==
							    (OnigCodePoint)
								NUM2INT(
								    child_byte))
							hit = 1;
						}
						else {
						    const char *child_ptr =
							RSTRING_PTR(bytes);
						    const char *child_end =
							child_ptr +
							RSTRING_LEN(bytes);
						    int child_len =
							rb_enc_mbclen(
							    child_ptr,
							    child_end,
							    rb_enc_get(str));
						    if (child_len > 0 &&
							child_ptr + child_len <=
							    child_end &&
							ONIGENC_MBC_TO_CODE(
							    rb_enc_get(str),
							    (const OnigUChar *)
								child_ptr,
							    (const OnigUChar *)
								child_end) ==
							    code)
							hit = 1;
						}
					    }
					    else if (
						kind == ONIBI_TOKEN_ESCAPE ||
						kind ==
						    ONIBI_TOKEN_META_ESCAPE) {
						VALUE child_ctype_value =
						    onibi_hash_value_id(
							child, id_key_ctype);
						VALUE child_byte_value =
						    onibi_hash_value_id(
							child, id_key_byte);
						int child_ctype =
						    NIL_P(child_ctype_value)
							? -1
							: NUM2INT(
							      child_ctype_value);
						if (child_ctype >= 0) {
						    int child_hit =
							ONIGENC_IS_CODE_CTYPE(
							    rb_enc_get(str),
							    code, child_ctype);
						    if (!NIL_P(
							    child_byte_value) &&
							NUM2INT(
							    child_byte_value) ==
							    'P')
							child_hit = !child_hit;
						    if (child_hit) hit = 1;
						}
					    }
					}
					for (long i = 0; i < RARRAY_LEN(ranges);
					     i++) {
					    VALUE range =
						rb_ary_entry(ranges, i);
					    if (RARRAY_LEN(range) != 2)
						continue;
					    if (RB_INTEGER_TYPE_P(
						    rb_ary_entry(range, 0)) &&
						RB_INTEGER_TYPE_P(
						    rb_ary_entry(range, 1))) {
						if (code >=
							(OnigCodePoint)
							    NUM2ULONG(
								rb_ary_entry(
								    range,
								    0)) &&
						    code <=
							(OnigCodePoint)
							    NUM2ULONG(
								rb_ary_entry(
								    range, 1)))
						    hit = 1;
						continue;
					    }
					    if (!RB_TYPE_P(
						    rb_ary_entry(range, 0),
						    T_STRING) ||
						!RB_TYPE_P(
						    rb_ary_entry(range, 1),
						    T_STRING))
						continue;
					    uint32_t first = 0, last = 0;
					    VALUE first_bytes =
						      rb_ary_entry(range, 0),
						  last_bytes =
						      rb_ary_entry(range, 1);
					    const char *first_ptr = RSTRING_PTR(
							   first_bytes),
						       *last_ptr = RSTRING_PTR(
							   last_bytes);
					    const char *first_end =
							   first_ptr +
							   RSTRING_LEN(
							       first_bytes),
						       *last_end =
							   last_ptr +
							   RSTRING_LEN(
							       last_bytes);
					    int first_len = rb_enc_mbclen(
						first_ptr, first_end,
						rb_enc_get(str));
					    int last_len = rb_enc_mbclen(
						last_ptr, last_end,
						rb_enc_get(str));
					    if (first_len > 0 && last_len > 0 &&
						first_ptr + first_len <=
						    first_end &&
						last_ptr + last_len <=
						    last_end) {
						first = ONIGENC_MBC_TO_CODE(
						    rb_enc_get(str),
						    (const OnigUChar *)
							first_ptr,
						    (const OnigUChar *)
							first_end);
						last = ONIGENC_MBC_TO_CODE(
						    rb_enc_get(str),
						    (const OnigUChar *)last_ptr,
						    (const OnigUChar *)
							last_end);
						if (code >= first &&
						    code <= last)
						    hit = 1;
					    }
					}
					if (RTEST(onibi_hash_value_id(
						payload, id_key_negated)))
					    hit = !hit;
					*width = decoded_width;
					return hit;
				    }
				}
				int fold = RTEST(onibi_hash_value_id(
				    payload, id_key_ignorecase));
				if (fold) byte = (unsigned char)tolower(byte);
				VALUE bitmap =
				    onibi_hash_value_id(payload, id_key_bitmap);
				if (NIL_P(bitmap) ||
				    !RB_TYPE_P(bitmap, T_STRING) ||
				    RSTRING_LEN(bitmap) != 32)
				    rb_raise(
					eRegexpError,
					"class payload has no compiled bitmap");
				*width = 1;
				return (((unsigned char *)RSTRING_PTR(
					    bitmap))[byte >> 3] &
					(1U << (byte & 7))) != 0;
			    }
