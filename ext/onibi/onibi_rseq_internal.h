#ifndef ONIBI_RSEQ_INTERNAL_H
#define ONIBI_RSEQ_INTERNAL_H

#include "onibi_compiler_internal.h"
#include "onibi_ir.h"

/* Private RSeq contract.  Lowering consumes immutable typed GIR records and
 * publishes one relocatable Ruby String.  Runtime validation binds the view
 * only after it checks every section. */

typedef struct OnibiAllocationAccounting OnibiAllocationAccounting;
typedef struct OnibiLoweringWork OnibiLoweringWork;

static VALUE onibi_rseq_lower_with_work(VALUE compiled, int failure_phase,
					int *failure_fired,
					OnibiAllocationAccounting *accounting,
					OnibiLoweringWork *result_work,
					OnibiCompileOutcome *compile_outcome);
static VALUE
onibi_rseq_lower_with_failure(VALUE compiled, int failure_phase,
			      int *failure_fired,
			      OnibiAllocationAccounting *accounting);
static int onibi_rseq_view_init(VALUE blob, OnibiRSeqView *view);
static void onibi_rseq_view_prepare(OnibiRSeqView *view);
static void onibi_rseq_blob_validate(VALUE blob);

#endif
