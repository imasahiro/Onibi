#ifndef ONIBI_ENCODING_INTERNAL_H
#define ONIBI_ENCODING_INTERNAL_H

#include "onibi_exec_internal.h"

/* Private encoding contract.  Runtime positions are bytes.  Ruby character
 * indexes are created only by the public API materializer. */

typedef struct onibi_regexp_t onibi_regexp_t;

typedef enum {
    ONIBI_RUNTIME_FALLBACK_NONE = 0,
    ONIBI_RUNTIME_FALLBACK_INPUT_INELIGIBLE,
    ONIBI_RUNTIME_FALLBACK_NOENCODING
} OnibiRuntimeFallbackReason;

static int onibi_valid_encoding(VALUE string);
static OnibiEncodingMode onibi_encoding_mode_for(VALUE string,
						 rb_encoding *encoding);
static int onibi_character_boundary(VALUE string, OnibiBytePos position);
static OnibiRuntimeFallbackReason
onibi_vm_input_eligible(const onibi_regexp_t *regexp, VALUE string);
static long onibi_grapheme_width(VALUE string, OnibiBytePos position);

#endif
