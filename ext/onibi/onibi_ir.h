#ifndef ONIBI_IR_H
#define ONIBI_IR_H

#include "onibi_vector.h"

#include <stddef.h>
#include <stdint.h>

/* These types contain semantic data only.  They do not contain Ruby values,
   subject pointers, or process-local addresses. */
typedef uint32_t OnibiStateId;
typedef uint32_t OnibiActionProgramId;
typedef uint32_t OnibiSubprogramId;
typedef uint32_t OnibiTagEventId;
typedef uint32_t OnibiCallFrameId;

/* Immutable entry metadata for a compiled subprogram. */
typedef struct {
    OnibiStateId entry;
    OnibiStateId accept;
    uint32_t flags;
} OnibiSubprogramDesc;

/* Semantic call-frame shape.  Runtime storage is owned by the VM sidecar. */
typedef struct {
    OnibiSubprogramId subprogram_id;
    OnibiStateId continuation;
    OnibiTagEventId tag_history;
    uint32_t recursion_depth;
    OnibiCallFrameId parent;
} OnibiCallFrame;

/* Mutable repeat-counter state owned by a VM traversal frame.  The values
   are indexed by the immutable RSeq counter slots and contain no Ruby VALUE. */
typedef struct {
    long *values;
    uint32_t count;
} OnibiCounterState;

typedef ONIBI_VECTOR(OnibiStateId) OnibiIdVector;

typedef enum {
    ONIBI_EXEC_REGULAR = 0,
    ONIBI_EXEC_TAGGED = 1,
    ONIBI_EXEC_DYNAMIC = 2
} OnibiExecutionKind;

typedef enum {
    ONIBI_OPT_IGNORECASE = 1u << 0,
    ONIBI_OPT_EXTENDED = 1u << 1,
    ONIBI_OPT_MULTILINE = 1u << 2,
    ONIBI_OPT_FIXEDENCODING = 1u << 4,
    ONIBI_OPT_NOENCODING = 1u << 5
} OnibiRegexpOption;

typedef enum {
    ONIBI_FEATURE_DYNAMIC = 1u << 0,
    ONIBI_FEATURE_TAGGED = 1u << 1,
    ONIBI_FEATURE_ATOMIC = 1u << 2,
    ONIBI_FEATURE_GRAPHEME = 1u << 3,
    ONIBI_FEATURE_WILDCARD = 1u << 4,
    ONIBI_FEATURE_ANCHOR = 1u << 5,
    ONIBI_FEATURE_META_ESCAPE = 1u << 6,
    ONIBI_FEATURE_UNICODE_ESCAPE = 1u << 7,
    ONIBI_FEATURE_CLASS_INTERSECTION = 1u << 8,
    ONIBI_FEATURE_NESTED_CLASS = 1u << 9,
    ONIBI_FEATURE_LARGE_REPEAT = 1u << 10,
    ONIBI_FEATURE_ABSENCE = 1u << 11,
    ONIBI_FEATURE_CONDITIONAL = 1u << 12,
    ONIBI_FEATURE_BACKREF = 1u << 13,
    ONIBI_FEATURE_SUBROUTINE = 1u << 14,
    ONIBI_FEATURE_ASCII_PROPERTY = 1u << 15,
    ONIBI_FEATURE_UNICODE_PROPERTY = 1u << 16,
    ONIBI_FEATURE_UNICODE_PROPERTY_CLASS = 1u << 17,
    ONIBI_FEATURE_PROPERTY_ESCAPE = 1u << 18,
    ONIBI_FEATURE_NON_ASCII_LITERAL = 1u << 19,
    ONIBI_FEATURE_NON_ASCII_CLASS = 1u << 20,
    ONIBI_FEATURE_INLINE_IGNORECASE = 1u << 21
} OnibiFeatureFlag;

enum {
    ONIBI_RSEQ_STATE_FLAG_NEGATED = 1u << 0,
    ONIBI_RSEQ_LITERAL_FLAG_IGNORECASE = 1u << 0,
    ONIBI_RSEQ_HEADER_FLAG_IGNORECASE = 1u << 0,
    ONIBI_RSEQ_HEADER_FLAG_MULTILINE = 1u << 1,
    ONIBI_RSEQ_CLASS_FLAG_NEGATED = 1u << 0
};
enum {
    ONIBI_RSEQ_FEATURE_BACKREF = 1u << 0,
    ONIBI_RSEQ_FEATURE_CAPTURE = 1u << 1,
    ONIBI_RSEQ_FEATURE_COUNTER = 1u << 2,
    ONIBI_RSEQ_FEATURE_MATCH_RESET = 1u << 3,
    ONIBI_RSEQ_FEATURE_ASSERTION = 1u << 4,
    ONIBI_RSEQ_FEATURE_LOOKAROUND = 1u << 5
};

typedef enum {
    ONIBI_G_ACCEPT = 0,
    ONIBI_G_CHAR,
    ONIBI_G_CLASS,
    ONIBI_G_ANY,
    ONIBI_G_GRAPHEME,
    ONIBI_G_BACKREF,
    ONIBI_G_CALL,
    ONIBI_G_ATOMIC,
    ONIBI_G_ABSENT
} OnibiGStateOp;

/* Numeric action tags used by the semantic GIR representation. */
typedef enum {
    ONIBI_GA_END = 0,
    ONIBI_GA_CAPTURE_OPEN,
    ONIBI_GA_CAPTURE_CLOSE,
    ONIBI_GA_MATCH_RESET,
    ONIBI_GA_ASSERT_POSITION,
    ONIBI_GA_TEST_CAPTURE,
    ONIBI_GA_COUNTER_INIT,
    ONIBI_GA_COUNTER_INCREMENT,
    ONIBI_GA_TEST_COUNTER_LT,
    ONIBI_GA_TEST_COUNTER_GE
} OnibiGActionOp;

typedef enum {
    ONIBI_PRED_BYTE = 0,
    ONIBI_PRED_BITMAP,
    ONIBI_PRED_ANY
} OnibiPredicateKind;

typedef struct {
    OnibiStateId destination;
    OnibiActionProgramId actions;
} OnibiGEdge;

typedef struct {
    OnibiStateId id;
    uint32_t payload;
    uint8_t op;
    uint8_t flags;
} OnibiGState;

typedef enum {
    ONIBI_RA_END = 0,
    ONIBI_RA_CAPTURE,
    ONIBI_RA_MATCH_RESET,
    ONIBI_RA_ASSERT_POSITION,
    ONIBI_RA_ASSERT_SUBPROGRAM,
    ONIBI_RA_TEST_CAPTURE,
    ONIBI_RA_COUNTER_SET,
    ONIBI_RA_COUNTER_ADD,
    ONIBI_RA_COUNTER_TEST,
    ONIBI_RA_PROGRESS
} OnibiRActionOp;

typedef struct {
    uint8_t op;
    uint8_t flags;
    uint16_t arg16;
    uint32_t arg32;
} OnibiRAction;

/* Flags preserve semantic action variants in the compact physical form. */
#define ONIBI_RA_CAPTURE_CLOSE UINT8_C(1)
#define ONIBI_RA_TEST_CAPTURE_SET UINT8_C(1)
#define ONIBI_RA_TEST_CAPTURE_UNSET UINT8_C(2)
#define ONIBI_RA_COUNTER_GE UINT8_C(1)
#define ONIBI_RA_ASSERT_END_BUFFER UINT8_C(1)
#define ONIBI_RA_ASSERT_BEGIN_LINE UINT8_C(2)
#define ONIBI_RA_ASSERT_END_LINE UINT8_C(3)
#define ONIBI_RA_ASSERT_SEMI_END_BUFFER UINT8_C(4)
#define ONIBI_RA_ASSERT_SEARCH_ORIGIN UINT8_C(5)
#define ONIBI_RA_ASSERT_WORD_BOUNDARY UINT8_C(6)
#define ONIBI_RA_ASSERT_NONWORD_BOUNDARY UINT8_C(7)
#define ONIBI_RA_ASSERT_LOOKAHEAD UINT8_C(8)
#define ONIBI_RA_ASSERT_LOOKBEHIND UINT8_C(9)
/* Numeric position-assertion subtypes.  These values are stored in GIR
   actions and RSeq physical action operands. */
typedef enum {
    ONIBI_RAP_BEGIN_BUFFER = 1,
    ONIBI_RAP_END_BUFFER,
    ONIBI_RAP_BEGIN_LINE,
    ONIBI_RAP_END_LINE,
    ONIBI_RAP_SEMI_END_BUFFER,
    ONIBI_RAP_SEARCH_ORIGIN,
    ONIBI_RAP_WORD_BOUNDARY,
    ONIBI_RAP_NONWORD_BOUNDARY,
    ONIBI_RAP_LOOKAHEAD,
    ONIBI_RAP_LOOKBEHIND
} OnibiRAssertKind;

typedef enum {
    ONIBI_RS_CHAR = 1,
    ONIBI_RS_CLASS,
    ONIBI_RS_ANY,
    ONIBI_RS_GRAPHEME,
    ONIBI_RS_BACKREF,
    ONIBI_RS_CALL,
    ONIBI_RS_ATOMIC,
    ONIBI_RS_ABSENT,
    ONIBI_RS_STRING,
    ONIBI_RS_RUN_CLASS,
    ONIBI_RS_RUN_ANY
} OnibiRStateOp;

typedef struct {
    uint32_t edge_base;
    uint32_t payload;
    uint16_t edge_count;
    uint8_t op;
    uint8_t flags;
} OnibiRState;

typedef struct {
    uint32_t destination;
    uint32_t action_offset;
} OnibiREdge;

typedef struct {
    uint32_t data_offset;
    uint16_t data_length;
    uint8_t kind;
    uint8_t flags;
} OnibiClassDesc;

typedef struct {
    uint32_t data_offset;
    uint16_t data_length;
    uint16_t flags;
} OnibiLiteralDesc;

#define ONIBI_ACCEPT_STATE UINT32_MAX
#define ONIBI_RSEQ_MAGIC UINT32_C(0x4f4e5251) /* "ONRQ" */
#define ONIBI_RSEQ_VERSION UINT16_C(1)

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint8_t exec_kind;
    uint8_t flags;
    uint32_t features;
    uint32_t state_count;
    uint32_t edge_count;
    uint32_t action_count;
    uint32_t class_count;
    uint32_t subprogram_count;
    uint32_t capture_count;
    uint32_t semantic_capture_count;
    uint32_t counter_count;
    uint32_t start_edge_base;
    uint32_t start_edge_count;
    uint32_t states_offset;
    uint32_t edges_offset;
    uint32_t actions_offset;
    uint32_t classes_offset;
    uint32_t literals_offset;
    uint32_t descriptors_offset;
    uint32_t subprograms_offset;
    uint32_t blob_size;
} OnibiRSeqHeader;

/* Read-only view over a published RSeq blob.  The VM uses this view for
   physical execution data.  It avoids repeated offset arithmetic and keeps
   the blob ownership in the Ruby String. */
typedef struct {
    const unsigned char *blob;
    const OnibiRSeqHeader *header;
    const OnibiRState *states;
    const OnibiREdge *edges;
    const OnibiRAction *actions;
    const OnibiClassDesc *classes;
    const OnibiLiteralDesc *literals;
    const OnibiSubprogramDesc *subprograms;
    uint8_t native_eligible;
} OnibiRSeqView;

typedef char onibi_rstate_size_must_be_12[(sizeof(OnibiRState) == 12) ? 1 : -1];
typedef char onibi_redge_size_must_be_8[(sizeof(OnibiREdge) == 8) ? 1 : -1];
typedef char onibi_raction_size_must_be_8[(sizeof(OnibiRAction) == 8) ? 1 : -1];
typedef char
    onibi_class_desc_size_must_be_8[(sizeof(OnibiClassDesc) == 8) ? 1 : -1];
typedef char
    onibi_literal_desc_size_must_be_8[(sizeof(OnibiLiteralDesc) == 8) ? 1 : -1];
typedef char onibi_subprogram_desc_size_must_be_12
    [(sizeof(OnibiSubprogramDesc) == 12) ? 1 : -1];
typedef char
    onibi_call_frame_size_must_be_20[(sizeof(OnibiCallFrame) == 20) ? 1 : -1];

#endif
