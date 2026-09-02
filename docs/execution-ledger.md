| TASK-ID | review issue IDs | dependencies | model | status | changed files | tests |
| --- | --- | --- | --- | --- | --- | --- |
| TASK-00 | A-03, A-05, A-06, A-07, A-08, E-01, E-03, P-01 | none | sol/high | accepted | test/features/compatibility/gir_semantic_regression_test.rb; test/features/engine/gir_execution_regression_test.rb | Ruby 4 semantic 14 runs: 6 expected failures; execution 3 runs: 2 expected gate failures |
| TASK-10 | A-01, A-02, A-03, API-03 | TASK-00 | sol/high | accepted | ext/onibi/ast.c, compiler.c, gir.c, onibi_common.c, parser.c, rseq.c; resolved semantic and option tests | Ruby 4 build; 22 focused runs and 3 option runs passed |
| TASK-11 | A-01, P-11, C-08 | TASK-10 | sol/high | accepted | ext/onibi/ast.c, compiler.c, diagnostics.c, gir.c, onibi_common.c, rseq.c, token.c; resolved semantic test | Ruby 4 clean build; 34 runs/205 assertions and 17 option runs/33 assertions passed |
| TASK-12 | P-11, P-12 | TASK-10 | luna/medium | accepted | ext/onibi/ast.c, compiler.c, onibi_common.c, parser.c, token.c; resolved semantic index tests | Ruby 4 clean build; 33 runs/170 assertions passed with zero skips |
| TASK-13 | A-04, P-09 | TASK-10, TASK-11 | sol/high | accepted | compiler.c, diagnostics.c, gir.c, nfa.c, onibi_init.c; tagged NFA tests | Ruby 4 clean build; 108 runs/759 assertions passed with zero skips |
| TASK-14 | A-04, P-09 | TASK-13 | sol/high | accepted | ext/onibi/compiler.c, nfa.c; tagged NFA elimination tests | Ruby 4 clean build; 19 runs/436 assertions passed with zero skips |
| TASK-15 | M-01, M-04 | TASK-10 | sol/xhigh | accepted | compiler.c, diagnostics.c, gir.c, nfa.c, onibi_common.c, onibi_init.c, onibi_vector.h, rseq.c; exception-safety tests | Ruby 4 clean build; 35 runs/484 assertions passed with zero skips |
| TASK-20 | R-03, R-04 | TASK-14 | sol/xhigh | accepted | ext/onibi/compiler.c, diagnostics.c, gir.c, nfa.c, onibi_init.c, onibi_ir.h; GIR verifier tests | Ruby 4 clean build; 73 runs/648 assertions passed with zero skips |
| TASK-21 | R-04, A-08 | TASK-20 | sol/high | accepted | docs/gir.md; compiler.c, diagnostics.c, gir.c, onibi_ir.h, rseq.c; GIR verifier tests | Ruby 4 clean build; 94 runs/886 assertions passed with zero skips |
| TASK-22 | R-07, E-01, E-02, E-05 | TASK-10, TASK-20 | sol/high | pending | — | — |
| TASK-23 | R-01, A-03 | TASK-20 | sol/high | pending | — | — |
| TASK-24 | R-02 | TASK-21, TASK-22, TASK-23 | luna/high | pending | — | — |
| TASK-25 | P-05, P-06, P-07, P-08 | TASK-24 | luna/high | pending | — | — |
| TASK-30 | A-07, A-08, P-03 | TASK-21, TASK-23 | sol/high | pending | — | — |
| TASK-31 | A-05, A-09 | TASK-30 | sol/high | pending | — | — |
| TASK-32 | A-06, A-07, P-02, P-03 | TASK-30 | sol/high | pending | — | — |
| TASK-33 | P-02, A-09 | TASK-31, TASK-32 | luna/high | pending | — | — |
| TASK-34 | P-01 | TASK-31, TASK-32 | luna/high | pending | — | — |
| TASK-40 | E-03, E-04 | TASK-31 | sol/high | pending | — | — |
| TASK-41 | API-02 | TASK-30, TASK-40 | sol/high | pending | — | — |
| TASK-42 | API-01, API-02 | TASK-41 | sol/high | pending | — | — |
| TASK-43 | M-02, M-03 | TASK-24, TASK-31, TASK-32 | luna/medium | pending | — | — |
| TASK-50 | API-03 | TASK-20, TASK-31, TASK-32 | sol/high | pending | — | — |
| TASK-51 | P-04, P-05 | TASK-22, TASK-50 | sol/high | pending | — | — |
| TASK-52 | P-10 | none | luna/medium | pending | — | — |
| TASK-53 | C-01, C-02, C-03, C-04, C-05, C-06, C-07, C-08 | TASK-25 | luna/medium | pending | — | — |
| TASK-54 | C-03, C-04, C-05 | none | luna/medium | pending | — | — |
| TASK-55 | RC-01, M-04 | TASK-42, TASK-53 | sol/high | pending | — | — |

TASK-15 route change: two root audit rejections found unowned allocations during non-local exits.
TASK-20 route change: two root audit rejections found verifier performance and canonical action conflicts.
