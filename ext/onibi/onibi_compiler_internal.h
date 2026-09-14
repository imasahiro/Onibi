#ifndef ONIBI_COMPILER_INTERNAL_H
#define ONIBI_COMPILER_INTERNAL_H

#include "ruby.h"

#include <stddef.h>
#include <stdint.h>

/* Private compiler contract.  Passes report one typed outcome.  Only the
 * unsupported outcome is eligible for the MRI compatibility path. */

#define ONIBI_RSEQ_REPEAT_UNROLL_LIMIT 8L

typedef enum {
    ONIBI_COMPILE_OK = 0,
    ONIBI_COMPILE_UNSUPPORTED,
    ONIBI_COMPILE_INVALID_PATTERN,
    ONIBI_COMPILE_INTERNAL_ERROR,
    ONIBI_COMPILE_ALLOCATION_ERROR,
    ONIBI_COMPILE_VERIFIER_ERROR,
    ONIBI_COMPILE_UNEXPECTED_ERROR
} OnibiCompileErrorKind;

typedef enum {
    ONIBI_UNSUPPORTED_NONE = 0,
    ONIBI_UNSUPPORTED_META_ESCAPE,
    ONIBI_UNSUPPORTED_ESCAPE,
    ONIBI_UNSUPPORTED_GRAPHEME,
    ONIBI_UNSUPPORTED_CLASS,
    ONIBI_UNSUPPORTED_LIMIT,
    ONIBI_UNSUPPORTED_POSSESSIVE,
    ONIBI_UNSUPPORTED_ZERO_WIDTH_REPEAT
} OnibiUnsupportedReason;

typedef struct {
    OnibiCompileErrorKind error_kind;
    OnibiUnsupportedReason unsupported_reason;
} OnibiCompileOutcome;

/* Lowering counters are diagnostic data.  They belong to one compile and do
 * not affect the published execution class. */
typedef struct OnibiLoweringWork {
    uint64_t gir_class_probes;
    uint64_t rseq_class_probes;
    uint64_t literal_probes;
    uint64_t action_probes;
    uint64_t prefix_edges;
} OnibiLoweringWork;

typedef struct OnibiAllocationAccounting {
    size_t live_count;
} OnibiAllocationAccounting;

static VALUE onibi_compiler_compile_with_outcome(VALUE parsed,
						 OnibiCompileOutcome *outcome);
static VALUE onibi_compiler_nfa_diagnostics(VALUE parsed);

#endif
