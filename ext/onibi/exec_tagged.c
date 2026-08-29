/* Unicode grapheme helpers used by the native RSeq walker. */
static int onibi_codepoint_at(VALUE str, long pos, OnigCodePoint *codepoint,
			      long *width);

static int
onibi_grapheme_extend(OnigCodePoint code)
{
    return (code >= 0x0300 && code <= 0x036f) ||
	   (code >= 0x1ab0 && code <= 0x1aff) ||
	   (code >= 0x1dc0 && code <= 0x1dff) ||
	   (code >= 0x20d0 && code <= 0x20ff) ||
	   (code >= 0xfe00 && code <= 0xfe0f) ||
	   (code >= 0x1f3fb && code <= 0x1f3ff) ||
	   (code >= 0x1f300 && code <= 0x1faff && code >= 0x1f7e0) ||
	   (code >= 0x0903 && code <= 0x093c) ||
	   (code >= 0x0a3e && code <= 0x0a42) ||
	   (code >= 0x0bbe && code <= 0x0bce) ||
	   (code >= 0x1d165 && code <= 0x1d169) ||
	   (code >= 0xe0020 && code <= 0xe007f);
}

static int
onibi_grapheme_ri(OnigCodePoint code)
{
    return code >= 0x1f1e6 && code <= 0x1f1ff;
}

static int
onibi_grapheme_hangul_l(OnigCodePoint code)
{
    return (code >= 0x1100 && code <= 0x115f) ||
	   (code >= 0xa960 && code <= 0xa97c);
}

static int
onibi_grapheme_hangul_v(OnigCodePoint code)
{
    return (code >= 0x1160 && code <= 0x11a7) ||
	   (code >= 0xd7b0 && code <= 0xd7c6);
}

static int
onibi_grapheme_hangul_t(OnigCodePoint code)
{
    return (code >= 0x11a8 && code <= 0x11ff) ||
	   (code >= 0xd7cb && code <= 0xd7fb);
}

static int
onibi_grapheme_prepend(OnigCodePoint code)
{
    return (code >= 0x0600 && code <= 0x0605) ||
	   (code >= 0x06dd && code <= 0x06dd) ||
	   (code >= 0x070f && code <= 0x070f) ||
	   (code >= 0x0890 && code <= 0x0891) ||
	   (code >= 0x0d4e && code <= 0x0d4e) ||
	   (code >= 0x110bd && code <= 0x110bd) ||
	   (code >= 0x111c2 && code <= 0x111c3) ||
	   (code >= 0x1193f && code <= 0x1193f) ||
	   (code >= 0x11941 && code <= 0x11941) ||
	   (code >= 0x11a3a && code <= 0x11a3a) ||
	   (code >= 0x11a84 && code <= 0x11a89) ||
	   (code >= 0x11d46 && code <= 0x11d46);
}

static long
onibi_grapheme_width(VALUE str, long pos)
{
    OnigCodePoint code;
    long width;
    if (!onibi_codepoint_at(str, pos, &code, &width)) return 0;
    long end = pos + width;
    if (code == '\r' && end < RSTRING_LEN(str) && RSTRING_PTR(str)[end] == '\n')
	return width + 1;
    if (onibi_grapheme_ri(code)) {
	OnigCodePoint next;
	long next_width;
	if (onibi_codepoint_at(str, end, &next, &next_width) &&
	    onibi_grapheme_ri(next))
	    end += next_width;
	return end - pos;
    }
    if (onibi_grapheme_hangul_l(code)) {
	OnigCodePoint next;
	long next_width;
	while (onibi_codepoint_at(str, end, &next, &next_width) &&
	       (onibi_grapheme_hangul_l(next) || onibi_grapheme_hangul_v(next)))
	    end += next_width;
	return end - pos;
    }
    if (onibi_grapheme_hangul_v(code)) {
	OnigCodePoint next;
	long next_width;
	while (onibi_codepoint_at(str, end, &next, &next_width) &&
	       (onibi_grapheme_hangul_v(next) || onibi_grapheme_hangul_t(next)))
	    end += next_width;
	return end - pos;
    }
    int join = onibi_grapheme_prepend(code);
    for (;;) {
	OnigCodePoint next;
	long next_width;
	if (!onibi_codepoint_at(str, end, &next, &next_width)) break;
	if (onibi_grapheme_extend(next)) {
	    end += next_width;
	    continue;
	}
	if (next == 0x200d) {
	    join = 1;
	    end += next_width;
	    continue;
	}
	if (join) {
	    join = 0;
	    end += next_width;
	    continue;
	}
	break;
    }
    return end - pos;
}
static int
onibi_codepoint_at(VALUE str, long pos, OnigCodePoint *codepoint, long *width)
{
    const char *ptr = RSTRING_PTR(str) + pos;
    const char *end = RSTRING_PTR(str) + RSTRING_LEN(str);
    int length = rb_enc_mbclen(ptr, end, rb_enc_get(str));
    if (length <= 0 || ptr + length > end) return 0;
    *codepoint = ONIGENC_MBC_TO_CODE(rb_enc_get(str), (const OnigUChar *)ptr,
				     (const OnigUChar *)end);
    *width = length;
    return 1;
}
