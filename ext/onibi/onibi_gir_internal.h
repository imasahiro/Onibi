#ifndef ONIBI_GIR_INTERNAL_H
#define ONIBI_GIR_INTERNAL_H

#include "onibi_ir.h"
#include "ruby.h"

/* Private GIR contract.  The compiler publishes typed states, edges,
 * actions, classes, and subprogram descriptors to RSeq lowering. */

#define ONIBI_SUBPROGRAM_ATOMIC UINT32_C(1)
#define ONIBI_SUBPROGRAM_ABSENT UINT32_C(2)

typedef struct OnibiTaggedNfa OnibiTaggedNfa;
typedef enum OnibiAsciiProperty OnibiAsciiProperty;
typedef enum OnibiPosixKind OnibiPosixKind;

static int onibi_ascii_property_name_p(ID name_id);
static OnibiAsciiProperty onibi_ascii_property_kind_id(ID property);
static OnibiPosixKind onibi_posix_kind_id(ID property);

#endif
