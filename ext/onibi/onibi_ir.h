#ifndef ONIBI_IR_H
#define ONIBI_IR_H

#include <stdint.h>

/* These types contain semantic data only.  They do not contain Ruby values,
   subject pointers, or process-local addresses. */
typedef uint32_t OnibiStateId;
typedef uint32_t OnibiActionProgramId;

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

typedef char onibi_rstate_size_must_be_12[(sizeof(OnibiRState) == 12) ? 1 : -1];
typedef char onibi_redge_size_must_be_8[(sizeof(OnibiREdge) == 8) ? 1 : -1];
typedef char onibi_raction_size_must_be_8[(sizeof(OnibiRAction) == 8) ? 1 : -1];

#endif
