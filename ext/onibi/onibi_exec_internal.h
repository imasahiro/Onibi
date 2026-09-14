#ifndef ONIBI_EXEC_INTERNAL_H
#define ONIBI_EXEC_INTERNAL_H

/* Private execution contract.  All engines consume OnibiExecCtx and return
 * one status.  The dispatcher is the only execution-class switch. */

#include "onibi_ir.h"
#include "ruby/encoding.h"
#include "ruby/onigmo.h"

#include <stddef.h>
#include <stdint.h>

typedef OnigPosition OnibiBytePos;
typedef OnigPosition OnibiRegisterValue;

/* The caller owns the register arrays.  A zero count requests only the full
 * byte range.  The matcher never stores a Ruby object in this record. */
typedef struct OnibiRawMatch {
    OnibiBytePos begin_byte;
    OnibiBytePos end_byte;
    uint32_t num_regs;
    OnibiBytePos *beg;
    OnibiBytePos *end;
} OnibiRawMatch;

#define ONIBI_POLL_WORK 128

typedef enum {
    ONIBI_EXECUTOR_ERROR_NONE = 0,
    ONIBI_EXECUTOR_ERROR_CONTRACT,
    ONIBI_EXECUTOR_ERROR_ALLOCATION,
    ONIBI_EXECUTOR_ERROR_MALFORMED_PROGRAM,
    ONIBI_EXECUTOR_ERROR_UNEXPECTED
} OnibiExecutorErrorKind;

enum {
    ONIBI_EXEC_REQUIRE_TAGGED = 1u << 0,
    ONIBI_EXEC_REQUIRE_DYNAMIC = 1u << 1
};

typedef enum {
    ONIBI_EXEC_STATUS_NO_MATCH = 0,
    ONIBI_EXEC_STATUS_MATCH = 1,
    ONIBI_EXEC_STATUS_INTERNAL_ERROR = -1,
    ONIBI_EXEC_STATUS_FALLBACK = 2
} OnibiExecStatus;

/* Match-local semantic ABI.  The append-only arenas belong to one VM
 * traversal.  They never borrow Ruby objects or process-global state. */
typedef struct OnibiSemanticState OnibiSemanticState;
typedef struct {
    uint32_t *states;
    OnibiSemanticState *semantics;
    uint32_t *failure_owners;
    uint64_t *hashes;
    uint32_t *key_buckets;
    unsigned char *membership;
    uint32_t *histories;
    size_t count;
    size_t capacity;
    size_t key_capacity;
    size_t membership_capacity;
} OnibiFrontier;
typedef struct {
    unsigned char *data;
    size_t count, capacity;
} OnibiTagArena;
typedef struct {
    uint32_t parent;
    uint32_t slot;
    OnibiRegisterValue value;
} OnibiSemanticRegisterDelta;
typedef struct {
    uint32_t root;
    uint32_t slot_count;
    uint64_t hash;
} OnibiSemanticCaptureFile;
typedef struct {
    uint32_t root;
    uint32_t slot_count;
    uint64_t hash;
} OnibiCounterFile;
typedef struct {
    uint32_t root;
    uint32_t slot_count;
    uint64_t hash;
} OnibiProgressState;
typedef struct {
    uint32_t parent;
    OnibiCallFrame frame;
    OnibiTagEventId caller_tag_history;
    OnibiSemanticCaptureFile caller_captures;
    OnibiSemanticCaptureFile caller_condition_captures;
    OnibiCounterFile caller_counters;
    OnibiProgressState caller_progress;
    uint64_t hash;
} OnibiOwnedCallFrame;
typedef struct {
    uint32_t slot_offset;
    uint32_t slot_count;
} OnibiSubprogramLocalSlots;
typedef struct {
    uint32_t root;
    uint32_t depth;
} OnibiCallStack;
typedef struct {
    uint32_t parent;
    OnibiSubprogramId subprogram_id;
    OnibiBytePos begin;
    OnibiBytePos end;
    OnibiTagEventId tag_history;
    uint32_t flags;
    uint64_t hash;
} OnibiSemanticScope;
typedef struct {
    uint32_t root;
    uint32_t depth;
} OnibiAtomicState;
typedef OnibiAtomicState OnibiAbsenceState;
typedef struct {
    OnibiTagEventId parent;
    uint32_t slot;
    OnibiBytePos position;
    uint64_t hash;
} OnibiSemanticTagEvent;
struct OnibiSemanticState {
    uint32_t order;
    OnibiBytePos reported_start;
    OnibiSemanticCaptureFile semantic_captures;
    OnibiSemanticCaptureFile condition_captures;
    OnibiCounterFile counters;
    OnibiProgressState progress;
    OnibiCallStack calls;
    OnibiAtomicState atomic;
    OnibiAbsenceState absence;
    OnibiTagEventId tag_history;
    uint32_t capture_event_history;
    uint32_t capture_event_dependency;
};
typedef struct {
    uint32_t state_id;
    OnibiBytePos position;
    OnibiSemanticState semantic;
    uint64_t hash;
} OnibiDynamicThreadKey;
typedef struct {
    uint32_t state;
    OnibiBytePos position;
    OnibiSemanticState semantic;
    uint32_t cycle_root;
} OnibiDynamicFrame;
typedef struct {
    uint32_t parent;
    OnibiDynamicThreadKey key;
} OnibiDynamicCycleNode;
typedef struct {
    OnibiDynamicThreadKey key;
    uint32_t generation;
} OnibiDynamicKeyBucket;
typedef struct {
    uint32_t parent[32];
    uint32_t depth, label;
} OnibiCaptureOrderNode;
typedef struct {
    uint32_t parent;
    uint32_t order, slot;
    OnibiBytePos position;
} OnibiUnscopedCaptureEvent;
typedef struct {
    uint32_t history;
    uint32_t next;
} OnibiCaptureEventRoot;
typedef struct {
    uint32_t event_roots;
    uint32_t resolved_owner;
    uint8_t resolved;
} OnibiCaptureEventOwner;
typedef struct {
    OnibiCaptureOrderNode *order_nodes;
    size_t order_count, order_capacity;
    uint32_t *order_buckets;
    size_t order_bucket_capacity;
    OnibiUnscopedCaptureEvent *capture_events;
    size_t capture_event_count, capture_event_capacity;
    OnibiCaptureEventRoot *capture_event_roots;
    size_t capture_event_root_count, capture_event_root_capacity;
    OnibiCaptureEventOwner *capture_event_owners;
    size_t capture_event_owner_count, capture_event_owner_capacity;
    OnibiSemanticRegisterDelta *registers;
    size_t register_count, register_capacity;
    OnibiSemanticTagEvent *tags;
    size_t tag_count, tag_capacity;
    OnibiOwnedCallFrame *calls;
    size_t call_count, call_capacity;
    OnibiSubprogramLocalSlots *subprogram_local_slots;
    uint32_t subprogram_local_count;
    const OnibiRSeqHeader *subprogram_local_header;
    uint32_t *local_slots;
    size_t local_slot_count, local_slot_capacity;
    unsigned char *local_slot_visited;
    unsigned char *local_slot_queued;
    uint32_t *local_slot_work;
    unsigned char *local_slot_used;
    unsigned char *local_slot_nullable;
    OnibiSemanticScope *atomic;
    size_t atomic_count, atomic_capacity;
    OnibiSemanticScope *absence;
    size_t absence_count, absence_capacity;
    uint32_t *live_capture_slots;
    size_t live_capture_count, live_capture_capacity;
    unsigned char *live_capture_bitmap;
    size_t live_capture_bitmap_capacity;
    uint32_t *future_capture_slots;
    size_t future_capture_count, future_capture_capacity;
    unsigned char *future_capture_bitmap;
    size_t future_capture_bitmap_capacity;
    OnibiDynamicFrame *frames;
    size_t frame_count, frame_capacity;
    OnibiDynamicCycleNode *cycles;
    size_t cycle_count, cycle_capacity;
    OnibiDynamicKeyBucket *key_buckets;
    size_t key_count, key_capacity;
    uint32_t key_generation;
    size_t register_read_count;
    size_t key_hash_count;
} OnibiSemanticArena;

typedef enum {
    ONIBI_ACTION_FAIL = 0,
    ONIBI_ACTION_SUCCESS = 1
} OnibiActionResult;

/* Match-local execution ABI.  The interpreter owns this object for the
 * complete search.  Pointer fields refer to storage owned by this context or
 * its frontier arenas.  They never borrow storage from Ruby objects. */
typedef struct OnibiExecCtx {
    VALUE regexp;
    VALUE subject;
    const OnibiRSeqHeader *program;
    OnibiBytePos search_origin;
    OnibiBytePos attempt_start;
    OnibiBytePos reported_start;
    OnibiBytePos current_position;
    OnibiFrontier current;
    OnibiFrontier next;
    OnibiFrontier *assertion_frontiers;
    size_t assertion_frontier_count;
    size_t assertion_frontier_capacity;
    size_t assertion_depth;
    OnibiTagArena tags;
    OnibiSemanticArena semantic_arena;
    uint64_t work_before_poll;
    /* Ruby's private rb_hrtime_t is not public in this MRI release. */
    uint64_t timeout_deadline;
    VALUE rseq;
    const OnibiRSeqView *view;
    rb_encoding *encoding;
    OnibiEncodingMode encoding_mode;
    unsigned char *class_stack;
    size_t class_stack_capacity;
    OnibiBytePos matched_end;
    OnibiRawMatch *raw_match;
} OnibiExecCtx;

static OnibiExecStatus onibi_exec_regular(OnibiExecCtx *ctx);
static int onibi_rseq_regular_match(OnibiExecCtx *ctx);
static int onibi_rseq_backtracking_match(
    VALUE rseq, const OnibiRSeqView *view, VALUE subject, OnibiBytePos start,
    OnibiBytePos search_origin, OnibiBytePos *matched_end,
    OnibiSemanticState *accepted_state, OnibiSemanticArena *semantic_arena,
    unsigned char *class_stack, size_t class_stack_capacity, OnibiExecCtx *ctx);
static OnibiExecStatus onibi_exec_tagged(OnibiExecCtx *ctx);
static OnibiExecStatus onibi_exec_dynamic(OnibiExecCtx *ctx);
static OnibiExecStatus onibi_execute(OnibiExecCtx *ctx);
static void onibi_exec_ctx_release(OnibiExecCtx *ctx);
static void onibi_exec_poll_interrupts(OnibiExecCtx *ctx);

#endif
