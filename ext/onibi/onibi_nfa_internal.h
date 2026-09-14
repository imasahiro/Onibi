#ifndef ONIBI_NFA_INTERNAL_H
#define ONIBI_NFA_INTERNAL_H

#include "onibi_ir.h"

/* Private NFA contract.  NFA state IDs are not GIR state IDs.  Keep the
 * sentinel outside the valid fixed-width state range. */
typedef uint32_t OnibiNfaStateId;
#define ONIBI_NFA_STATE_NONE UINT32_MAX
typedef ONIBI_VECTOR(OnibiNfaStateId) OnibiNfaStateIdVector;

ONIBI_VECTOR_DEFINE(onibi_nfa_state_id_vector, OnibiNfaStateIdVector,
		    OnibiNfaStateId, 8, "NFA state vector is too large")

#endif
