| TASK-ID | review issue IDs | dependencies | model | status | changed files | tests |
| --- | --- | --- | --- | --- | --- | --- |
| TASK-00 | A-03, A-05, A-06, A-07, A-08, E-01, E-03, P-01 | none | sol/high | accepted | test/features/compatibility/gir_semantic_regression_test.rb; test/features/engine/gir_execution_regression_test.rb | Ruby 4 semantic 14 runs: 6 expected failures; execution 3 runs: 2 expected gate failures |
| TASK-10 | A-01, A-02, A-03, API-03 | TASK-00 | sol/high | ready | — | — |
| TASK-11 | A-01, P-11, C-08 | TASK-10 | sol/high | pending | — | — |
| TASK-12 | P-11, P-12 | TASK-10 | luna/medium | pending | — | — |
| TASK-13 | A-04, P-09 | TASK-10, TASK-11 | sol/high | pending | — | — |
| TASK-14 | A-04, P-09 | TASK-13 | sol/high | pending | — | — |
| TASK-15 | M-01, M-04 | TASK-10 | luna/high | pending | — | — |
| TASK-20 | R-03, R-04 | TASK-14 | sol/high | pending | — | — |
| TASK-21 | R-04, A-08 | TASK-20 | sol/high | pending | — | — |
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
