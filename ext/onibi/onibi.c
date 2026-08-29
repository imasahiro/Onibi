/*
 * Onibi translation unit.
 *
 * The implementation is split by pipeline responsibility.  The include
 * order is intentional: each module can use the C types and helpers that
 * earlier modules define, while the extension still builds as one unit.
 */
#include "onibi_common.c"
#include "token.c"
#include "ast.c"
#include "parser.c"
#include "nfa.c"
#include "gir.c"
#include "compiler.c"
#include "rseq.c"
#include "rseq_verify.c"
#include "exec_tagged.c"
#include "exec_regular.c"
#include "exec_dynamic.c"
#include "match.c"
#include "onibi_init.c"
