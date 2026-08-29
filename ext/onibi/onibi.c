/*
 * Onibi translation unit.
 *
 * The implementation is split by pipeline responsibility.  The include
 * order is intentional: each module can use the C types and helpers that
 * earlier modules define, while the extension still builds as one unit.
 */
#include "ast.c"
#include "compiler.c"
#include "exec_dynamic.c"
#include "exec_regular.c"
#include "exec_tagged.c"
#include "gir.c"
#include "match.c"
#include "nfa.c"
#include "onibi_common.c"
#include "onibi_init.c"
#include "parser.c"
#include "rseq.c"
#include "rseq_verify.c"
#include "token.c"
