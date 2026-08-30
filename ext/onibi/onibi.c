/*
 * Onibi translation unit.
 *
 * The implementation is split by pipeline responsibility.  The include
 * order is intentional.  The translation unit is the PoC module boundary;
 * each included module exposes only the prototypes declared by earlier
 * modules and keeps its implementation helpers static.
 */
// clang-format off
#include "onibi_common.c"
#include "token.c"
#include "ast.c"
#include "parser.c"
#include "gir.c"
#include "nfa.c"
#include "compiler.c"
#include "rseq.c"
/* RSeq diagnostics and Unicode support are separate from execution. */
#include "diagnostics.c"
#include "unicode.c"
#include "rseq_runtime.c"
#include "exec_dynamic.c"
#include "match.c"
#include "onibi_init.c"
// clang-format on
