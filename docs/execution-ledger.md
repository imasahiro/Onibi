| TASK-ID | review issue IDs | dependencies | model | status | changed files | tests |
| --- | --- | --- | --- | --- | --- | --- |
| TASK-00 | A-03, A-05, A-06, A-07, A-08, E-01, E-03, P-01 | none | sol/high | accepted | test/features/compatibility/gir_semantic_regression_test.rb; test/features/engine/gir_execution_regression_test.rb | Ruby 4 semantic 14 runs: 6 expected failures; execution 3 runs: 2 expected gate failures |
| TASK-00B | stale test contracts | TASK-41 | luna/high | accepted: test contracts match the native pipeline | `docs/development.md`; `test/features/api/match_api_test.rb`; `test/features/quality/internal_regexp_dependency_test.rb` | API 37/107 and internal quality 34/412 pass; full quality 164/1498 has two unrelated baseline failures; Ruby syntax, RuboCop, and diff checks pass |
| TASK-10 | A-01, A-02, A-03, API-03 | TASK-00 | sol/high | accepted | ext/onibi/ast.c, compiler.c, gir.c, onibi_common.c, parser.c, rseq.c; resolved semantic and option tests | Ruby 4 build; 22 focused runs and 3 option runs passed |
| TASK-11 | A-01, P-11, C-08 | TASK-10 | sol/high | accepted | ext/onibi/ast.c, compiler.c, diagnostics.c, gir.c, onibi_common.c, rseq.c, token.c; resolved semantic test | Ruby 4 clean build; 34 runs/205 assertions and 17 option runs/33 assertions passed |
| TASK-12 | P-11, P-12 | TASK-10 | luna/medium | accepted | ext/onibi/ast.c, compiler.c, onibi_common.c, parser.c, token.c; resolved semantic index tests | Ruby 4 clean build; 33 runs/170 assertions passed with zero skips |
| TASK-13 | A-04, P-09 | TASK-10, TASK-11 | sol/high | accepted | compiler.c, diagnostics.c, gir.c, nfa.c, onibi_init.c; tagged NFA tests | Ruby 4 clean build; 108 runs/759 assertions passed with zero skips |
| TASK-14 | A-04, P-09 | TASK-13 | sol/high | accepted | ext/onibi/compiler.c, nfa.c; tagged NFA elimination tests | Ruby 4 clean build; 19 runs/436 assertions passed with zero skips |
| TASK-15 | M-01, M-04 | TASK-10 | sol/xhigh | accepted | compiler.c, diagnostics.c, gir.c, nfa.c, onibi_common.c, onibi_init.c, onibi_vector.h, rseq.c; exception-safety tests | Ruby 4 clean build; 35 runs/484 assertions passed with zero skips |
| TASK-20 | R-03, R-04 | TASK-14 | sol/xhigh | accepted | ext/onibi/compiler.c, diagnostics.c, gir.c, nfa.c, onibi_init.c, onibi_ir.h; GIR verifier tests | Ruby 4 clean build; 73 runs/648 assertions passed with zero skips |
| TASK-21 | R-04, A-08 | TASK-20 | sol/high | accepted | docs/gir.md; compiler.c, diagnostics.c, gir.c, onibi_ir.h, rseq.c; GIR verifier tests | Ruby 4 clean build; 94 runs/886 assertions passed with zero skips |
| TASK-22 | R-07, E-01, E-02, E-05 | TASK-10, TASK-20 | sol/xhigh | accepted | docs/gir.md; compiler, GIR, NFA, RSeq, encoding runtime; descriptor and verifier tests | Ruby 4 clean build; 215 runs/3103 assertions passed; known scan byte-slice failure deferred to TASK-40 |
| TASK-23 | R-01, A-03 | TASK-20 | sol/high | accepted | docs/gir.md; compiler, GIR, NFA, RSeq, runtime view; subprogram representation tests | clean warning build; 188 runs/1204 assertions passed; Ruby 4 legacy style failures remain outside this task |
| TASK-24 | R-02 | TASK-21, TASK-22, TASK-23 | sol/xhigh | accepted | docs/gir.md; compiler.c, diagnostics.c, onibi_common.c, onibi_init.c, onibi_ir.h, rseq.c, rseq_runtime.c; physical verifier tests | Ruby 4 clean warning build; 74 runs/1515 assertions passed; broader syntax 192 runs/843 assertions with 2 confirmed baseline failures |
| TASK-25 | P-05, P-06, P-07, P-08 | TASK-24 | terra/high | accepted | compiler, GIR, RSeq, diagnostics; RSeq lowering scale tests | Ruby 4 clean warning build; 37 runs/1387 assertions passed; targeted RuboCop passed |
| TASK-30 | A-07, A-08, P-03 | TASK-21, TASK-23 | sol/xhigh | accepted | exec_dynamic.c, match.c, onibi_common.c, onibi_init.c; semantic state tests | clean warning build; 17 runs/418 assertions passed; future executor matrix retains 2 expected failures |
| TASK-31  | A-05, A-09                                     | TASK-30, TASK-31J                                                                                  | sol/high (root gate) | accepted: native TAGGED ordered execution remediation complete             | compiler, GIR, NFA, RSeq, parser, executor, focused tests; `docs/task-31-plan.md` | root gate: build with five known warnings; repair 134/5905 and fuzz 3/18 pass; broad 1248/12416 reviewed with 20 known failures and 380 known errors |
| TASK-31A | A-05                                           | TASK-30                                                                                            | sol/high             | accepted tests-only; known failure retained                              | test/features/compatibility/tagged_nullable_utf8_regression_test.rb             | root: 8 runs/104 assertions; 7 pass; ^(あ??){2}x on あx gives [0,3], MRI [3,3]; native TAGGED only                                                    |
| TASK-31B | A-05, A-08                                     | TASK-31A                                                                                           | astra/high           | accepted: nullable-action contract                                       | docs/gir.md                                                                     | root: MRI 4.0.6 verified 19 byte-range cases; scope and diff checks passed                                                                           |
| TASK-31C | A-05, E-01                                     | TASK-31B                                                                                           | luna/max             | accepted: MRI opcode-length repeat lowering                              | ext/onibi/compiler.c; test/features/compatibility/tagged_nullable_utf8_regression_test.rb | root: Ruby 4.0.6 clean build with 5 known warnings; UTF-8 11/137 and tagged differential 14/4786 pass; 336 nested native cases pass                                        |
| TASK-31P | A-03, A-05                                     | TASK-31A                                                                                           | luna/high            | accepted: fixed-interval parser behavior                                 | test/features/syntax/fixed_interval_optional_suffix_test.rb                     | root: Ruby 4.0.6 warning build; 3 runs/372 assertions pass; raw native ranges and zero DFS/fallback verified                                         |
| TASK-31D | A-04, A-05                                     | TASK-31B, TASK-31C, TASK-31P                                                                       | luna/high            | accepted: explicit epsilon-path invariant tests                          | test/features/quality/tagged_nfa_lowering_test.rb                                | root: 17 runs/91 assertions pass; ordered paths, action identity, and connected consume/epsilon cycle verified                                        |
| TASK-31E | R-03, R-04                                     | TASK-31B, TASK-31D                                                                                 | luna/high            | accepted: GIR nullable-owner verifier                                    | ext/onibi/gir.c; ext/onibi/diagnostics.c; test/features/quality/gir_verifier_test.rb | root: clean build with 5 known warnings; verifier 49/166, tagged differential 14/4762, NFA 17/91, semantic state 12/67 pass                           |
| TASK-31F | R-02, R-04                                     | TASK-31E                                                                                           | luna/high            | accepted: physical nullable-owner verifier                               | ext/onibi/rseq_runtime.c; ext/onibi/diagnostics.c; test/features/quality/rseq_physical_verifier_test.rb | root: clean build with 5 known warnings; physical 17/84, GIR 49/166, RSeq scale 5/14, subprogram 6/46, tagged differential 14/4762 pass                  |
| TASK-31G | A-07, A-08                                     | TASK-31B, TASK-31F                                                                                 | luna/max             | accepted: assertion capture-event rollback                               | `ext/onibi/exec_dynamic.c`; focused semantic-state and tagged differential tests | clean build passed with five known warnings; semantic state 15/80; tagged differential 15/4798; physical verifier 17/84; GIR verifier 49/166          |
| TASK-31H | A-05, A-09                                     | TASK-31C, TASK-31D, TASK-31G, TASK-31H1, TASK-31H2                                                  | luna/max             | accepted: ordered frontier identity and accepted capture ownership         | `ext/onibi/exec_dynamic.c`; owner storage and focused tests                       | root: clean build with five known warnings; semantic state 18/105, tagged differential 16/4867, nullable UTF-8 11/137 pass; RuboCop and diff check pass |
| TASK-31H1 | A-05, A-09                                    | TASK-31C, TASK-31D, TASK-31G                                                                       | sol/max              | accepted: per-entry failure-continuation owner design                      | —                                                                               | read-only gate: single-assignment owner cells connect ordered child failure to the next child                                                          |
| TASK-31H2 | A-05, A-09                                    | TASK-31H1                                                                                          | luna/max             | accepted: per-entry failure-continuation owner implementation               | `ext/onibi/onibi_common.c`; `exec_dynamic.c`; `match.c`; focused tests            | commit `d2260001`; root deep audit and the TASK-31H focused test set pass                                                                               |
| TASK-31I | A-09, P-03                                     | TASK-31H                                                                                           | luna/high            | accepted: linear order/event storage and bounded materialization           | `ext/onibi/exec_dynamic.c`; `onibi_common.c`; `diagnostics.c`; focused scale test | commit `c55f9163`; root: Ruby 4 build with five known warnings; scale 3/43 and TASK-31H focused suites pass; RuboCop and diff check pass                 |
| TASK-31J | A-05, A-09                                     | TASK-31A, TASK-31B, TASK-31C, TASK-31P, TASK-31D, TASK-31E, TASK-31F, TASK-31G, TASK-31H, TASK-31I | sol/high (root gate) | accepted: original TASK-31 integration gate                               | `docs/execution-ledger.md`                                                       | repair group and bounded fuzz pass; changed Ruby files pass RuboCop; broad failures map to recorded dynamic, API, encoding, and legacy debt             |
| TASK-32  | A-06, A-07, P-02, P-03                         | TASK-30, TASK-31, TASK-32K, TASK-32N                                                               | luna/max             | accepted: real DYNAMIC interpreter                                        | `compiler.c`; `exec_dynamic.c`; `gir.c`; `onibi_common.c`; `rseq_runtime.c`; focused tests | commit `3e5e29e7`; root clean Ruby 4 build has five known warnings; 208/20078 pass; no DFS or fallback; lookahead has 10 failures that match clean HEAD   |
| TASK-32K | A-07, P-03                                     | TASK-30, TASK-31                                                                                   | luna/max             | accepted: future-observable capture key only                              | `ext/onibi/exec_dynamic.c`; `test/features/engine/semantic_state_test.rb`         | commit `3e5e29e7`; root: semantic 19/114, dynamic 10/19008, absence 64/419, tagged UTF-8 11/137 pass; output-only hashes and equality merge               |
| TASK-32N | A-06                                           | TASK-32K                                                                                           | luna/max             | accepted: absence semantic nullability                                    | `ext/onibi/compiler.c`; `test/features/compatibility/dynamic_differential_test.rb` | commit `3e5e29e7`; root: dynamic 10/19008, absence 64/419, semantic 19/114, GIR 53/177, physical 18/91 pass; one owner, explicit G_ABSENT                 |
| TASK-33  | P-02, A-09                                     | TASK-31, TASK-32                                                                                   | luna/high            | accepted: execution arenas and reusable buffers                           | `onibi_common.c`; `exec_dynamic.c`; `match.c`; `diagnostics.c`; execution arena test | commit `f29db67d`; root clean Ruby 4 build has five known warnings; 56/24101 pass; 15/273 has one confirmed GIR baseline failure; no production alloca |
| TASK-34  | P-01                                           | TASK-31, TASK-32                                                                                   | luna/high            | accepted: bounded timeout and interrupt polling                           | `onibi_common.c`; `exec_dynamic.c`; `match.c`; `diagnostics.c`; work-budget test | commits `b6b58c20`, `b81d0801`, `5688bd37`; root clean Ruby 4 build has five known warnings; 89/24155 pass; 15/273 has one confirmed GIR baseline failure |
| TASK-40  | E-03, E-04                                     | TASK-31, TASK-40A, TASK-40B                                                                         | luna/max             | accepted: byte/character API boundary and explicit runtime types         | API adapter, runtime types, focused public and structural tests                  | root: TASK-40A and TASK-40B gates pass; VM positions remain bytes; Ruby positions convert only at the API boundary                                   |
| TASK-40A | E-03                                           | TASK-31                                                                                            | luna/max             | accepted: Ruby character-position adapter and byte slicing               | `docs/gir.md`; `ext/onibi/match.c`; `ext/onibi/rseq.c`; focused API tests         | commits `48711d3e`, `43ce32ac`; root: 72/167 focused pass; API 37/102 has one known `bytecode_program` error; clean build, format, and diff checks pass  |
| TASK-40B | E-04                                           | TASK-40A                                                                                           | luna/max             | accepted: explicit position, counter, and register types                 | runtime C modules; `docs/gir.md`; `runtime_position_type_test.rb`                 | commit `5f6673ef`; root clean build; 88 runs/19534 assertions pass; widths and serialized layouts unchanged; format and diff checks pass             |
| TASK-41  | API-02                                         | TASK-30, TASK-40                                                                                   | luna/max             | accepted: common raw match result                                        | `docs/gir.md`; runtime dispatch and diagnostics; focused raw-match test          | root clean Ruby 4 build has one known warning; 93/24559 focused pass; API 37/102 retains one known error; format and diff checks pass               |
| TASK-42  | API-01, API-02                                 | TASK-41                                                                                            | luna/high            | partial: TASK-42A and TASK-42C1 accepted; TASK-42B remains incomplete    | direct scan materialization; native match routing to Onibi::MatchData; MRI integration remains separate | TASK-42A and TASK-42C1 focused gates pass; MatchData accessors and MRI integration remain open |
| TASK-42A | API-02                                         | TASK-41                                                                                            | luna/high            | accepted: capture-aware scan uses common raw match ranges                 | `ext/onibi/match.c`; `test/features/captures/match_data_contract_test.rb`         | commit `2bb49916`; root Ruby 4.0.6 build; 54/24156 focused pass; API 108/323 retains one known error; raw ranges only, heap cleanup through `rb_ensure` |
| TASK-42B | API-01, API-02                                 | TASK-41, TASK-42A                                                                                  | luna/high            | blocked design: extension API cannot construct `RMatch` from external registers | —                                                                               | MRI 4.0.6 `rmatch.h` forbids manual generation; GIR requires MRI API routing and lazy character offsets; next: add supported MRI transfer API        |
| TASK-42C1 | API-01, API-02 | TASK-42B6B | luna/max | accepted: native Regexp#match routing with ensured capture storage | `ext/onibi/rseq.c`; `test/features/api/native_match_routing_test.rb`; API contract tests; `docs/task-42c1-evidence.md` | Ruby 4.0.6 warning build; native routing 4/20, API 37/110, MatchData regression 54/690; C/Ruby format and diff checks pass |
| TASK-42C2 | API-01, API-02 | TASK-42C1 | audit | accepted: backreference and caller boundary audit | `docs/task-42c2-evidence.md`; `test/features/api/backreference_boundary_audit_test.rb` | MRI 4.0.6 warning build; boundary audit 6/40; native routing 4/20; two existing API baseline failures reproduced |
| TASK-42C3 | API-01, API-02 | TASK-42C2 | luna | accepted: native-success case equality routing | `ext/onibi/match.c`; `test/features/api/native_case_equality_test.rb`; API and boundary tests; `docs/task-42c3-evidence.md` | MRI 4.0.6 warning build; focused group 51/205; C formatting, Ruby Layout, diff checks, and cleanup pass |
| TASK-42C4 | API-01, API-02 | TASK-42C3 | luna | accepted: native-success tilde routing | `ext/onibi/match.c`; `test/features/api/native_tilde_test.rb`; boundary tests; `docs/task-42c4-evidence.md` | MRI 4.0.6 warning build; focused group 55/245; C formatting, diff checks, and cleanup pass; existing `\\K` multibyte position gap retained |
| TASK-42C5 | API-01, API-02 | TASK-42C4 | luna | accepted: native `=~` boundary | `ext/onibi/match.c`; `ext/onibi/onibi_init.c`; `ext/onibi/onibi_ruby_api_internal.h`; operator tests; `docs/task-42c5-evidence.md` | MRI 4.0.6 warning build; focused group 59/314; C/Ruby formatting, diff checks, and cleanup pass; existing native `\\K` gap retained |
| TASK-42C6 | API-01, API-02 | TASK-42C5 | audit | accepted: String caller and scan/gsub boundary audit | `docs/task-42c6-evidence.md`; `test/features/api/string_caller_boundary_audit_test.rb` | MRI 4.0.6 warning build; audit 10/314; combined boundary/API group 61/552; no production source changed |
| TASK-42C7 | API-01, API-02 | TASK-42C6 | luna | accepted: native and fallback scan block support | `ext/onibi/match.c`; scan block tests; boundary tests; `docs/task-42c7-evidence.md` | MRI 4.0.6 warning build; scan/boundary group 34/929; combined group 79/1129; C/Ruby checks and cleanup pass |
| TASK-43  | M-02, M-03                                     | TASK-24, TASK-31, TASK-32, TASK-43A, TASK-43B                                                       | luna/high            | accepted: typed outcomes preserve native behavior                        | typed compiler and executor outcomes                                              | TASK-43A repair restored native global and scoped multiline wildcard execution                                                                       |
| TASK-43A | M-02                                           | TASK-24, TASK-31, TASK-32                                                                          | luna/high            | accepted: compiler failures use typed outcomes                           | compiler outcome classification, physical verifier, and focused tests             | commit `8c83be2b`; root Ruby 4.0.6 build; 108/737 focused pass; multiline wildcards use native RSeq with no fallback                                  |
| TASK-43B | M-03                                           | TASK-43A                                                                                           | luna/high            | accepted: runtime fallback and executor errors are typed                 | executor status, search fallback reasons, diagnostics, and focused tests         | commit `dec1e514`; Ruby 4.0.6 clean build; 144/837 final pass; no executor returns fallback                                                          |
| TASK-50  | API-03                                         | TASK-20, TASK-31, TASK-32, TASK-50A, TASK-50B                                                       | luna/max             | accepted: verified GIR is the only execution-class authority             | compiler analysis, API classification, and RSeq view preparation                  | compiler and runtime use the verified header class                                                                                                   |
| TASK-50A | API-03                                         | TASK-20, TASK-31, TASK-32                                                                          | luna/max             | accepted: verified GIR is the execution-class authority                  | compiler analysis, initialization, API classification, and focused tests         | commit `1d2fdba0`; Ruby 4.0.6 build; 125/481 pass; dependency suite retains one reproduced GC-stress baseline error                                   |
| TASK-50B | API-03                                         | TASK-50A, TASK-43A                                                                                 | luna/max             | accepted: runtime preserves the verified execution class                  | `ext/onibi/onibi_common.c`; `ext/onibi/rseq_runtime.c`; focused tests              | commits `33623293`, `8c83be2b`; root 108/737 focused pass; accepted parent retains one GC-stress error in 34/411 dependency assertions                 |
| TASK-51  | P-04, P-05                                     | TASK-22, TASK-50, TASK-51A, TASK-51B                                                               | split                 | accepted: character-aware candidate iterator and linear prefix analysis                | —                                                                               | TASK-51A commit `814835c1`; TASK-51B confirmed accepted TASK-25 implementation                                                                           |
| TASK-51A | P-04                                           | TASK-22, TASK-50                                                                                   | luna/max              | accepted: character-aware search candidate iteration                       | `ext/onibi/match.c`; focused tests                                                | commits `814835c1`, `221a7935`; root Ruby 4.0.6 build; 100/24174 pass; width steps, byte modes, order, and end candidate verified                                                                    |
| TASK-51B | P-05                                           | TASK-51A                                                                                           | luna/high             | accepted: grouped-edge prefix analysis                                | compiler and RSeq lowering; focused tests                                        | commit `842861b3`; root 47/493 pass; grouped edge ranges and fanout-independent prefix work verified                                                                                                        |
| TASK-52  | P-10                                           | none                                                                                               | luna/high            | accepted: one-pass parser delimiter indexing                                       | `ext/onibi/ast.c`; `parser.c`; `token.c`; focused test                                  | commit `2591a518`; root Ruby 4.0.6 build; 17/120 focused pass; four broader baseline failures match clean `main`                                                                                                                                                   |
| TASK-53  | C-01, C-02, C-03, C-04, C-05, C-06, C-07, C-08 | TASK-25                                                                                            | split                | accepted: module contracts, tokenizer, IDs, and C-08 audit                  | draft PR #421; module contracts, tokenizer, and fixed-width NFA IDs accepted          | TASK-53D root review: comments only; warning build and module contract 4/122 pass                                                                                     |
| TASK-53A | C-01, C-02                                     | TASK-25, TASK-54                                                                                   | luna/high            | accepted: explicit private C module contracts                            | commit `b2a087b0`; seven private headers, module includes, structural tests         | root Ruby 4.0.6 build; contract 4/112, safety 2/314, GIR 53/177, physical 18/91, semantic 19/114, dynamic 10/19008 pass; dependency 34/418 has one known GC error |
| TASK-53B1 | C-06                                          | TASK-52, TASK-53A                                                                                  | luna/high            | accepted: grouped token and inline-option recognition                    | commits `995603e1`, `4781e92b`; `ext/onibi/token.c`                                | root Ruby 4.0.6 build; 76/449 focused pass; syntax contract 3/50 pass; inline 20/33 and lookahead 60/141 match source baseline failures             |
| TASK-53B2 | C-06                                          | TASK-53B1                                                                                          | luna/high            | accepted: complete escape token recognition                              | commit `91ba5f23`; `ext/onibi/token.c`                                              | root: 33/19112 focused pass; Unicode 7/19 and lexer boundary 6/85 match exact source baseline failures                                             |
| TASK-53B3 | C-06                                          | TASK-53B2                                                                                          | luna/high            | accepted: character-class structural recognition                        | commit `7cbc851e`; `ext/onibi/token.c`                                              | root: class 2/7, delimiter 4/19, syntax contract 3/50 pass; syntax 6/16, differential 3/28, Unicode 7/19 match exact source baseline failures       |
| TASK-53C1 | C-07                                          | TASK-53A                                                                                           | luna/max             | accepted: fixed-width NFA state identifiers                              | commit `c6e822bf`; NFA contract, compiler boundary conversions, focused tests        | root Ruby 4.0.6 build; 111/19662 focused pass; reserved sentinel and checked GIR conversions verified                                             |
| TASK-53C2 | C-07 | TASK-53A, TASK-53C1 | luna/max | accepted: fixed-width GIR builder IDs | GIR, NFA, compiler, RSeq, diagnostics, focused ID tests | root deep review; MRI 4.0.6 warning build; quality 106/640 and semantic 40/19259 pass; exact commands below |
| TASK-53D | C-08 | TASK-53A, TASK-53B3, TASK-53C2 | luna/high | accepted: current architecture comments and documentation | ext/onibi comments and docs/development.md | root warning build; module contracts 4/122 pass; comment-only diff verified; exact evidence in docs/task-53d-audit.md |
| TASK-54  | C-03, C-04, C-05                               | none                                                                                               | luna/high            | accepted: explicit vector safety invariants                                        | `ext/onibi/onibi_vector.h`; focused tests                                        | commit `3da080a3`; root Ruby 4.0.6 build; 126/24066 pass; standalone header compile, alias append, and invalid insert verified                                                                                                                                                   |
| TASK-55A | RC-01, M-04 | TASK-53; final gate still needs TASK-42B | luna/high | accepted: current-state audit only | docs/task-55a-audit.md; probe evidence retained in worker worktree | warning build passes; exact Ractor isolation probes pass; three harness fault probes reject and reap; invocation-state baseline has 6 stale API errors |
| TASK-55B | RC-01, MRI metadata semantics | TASK-55A | luna/max | accepted: immutable retained metadata and isolated public getter copies | rseq.c; regexp_metadata_isolation_test.rb; docs/task-55b-evidence.md | worker 163618f3; root ownership review; MRI 4.0.6 warning build; focused 4/43 and existing 43/171 pass; zero native fallback; format checks pass |
| TASK-55  | RC-01, M-04                                    | TASK-42, TASK-53                                                                                   | luna/high            | pending: Ractor/shareability audit                                       | —                                                                               | —                                                                                                                                                   |




TASK-15 route change: two root audit rejections found unowned allocations during non-local exits.
TASK-20 route change: two root audit rejections found verifier performance and canonical action conflicts.
TASK-22 route change: two root audit rejections found runtime case-fold architecture and later-phase scope conflicts.
TASK-24 route change: Luna was unavailable; two root audit rejects required Sol/xhigh escalation.
TASK-25 route change: Luna is unavailable in the collaboration runtime; Terra/high is the closest serialization route.
TASK-30 route change: two root audit rejects found unsafe dedup bounds and full-state key scans.
TASK-31 route change: two root audit rejects found unstable nested frontiers and an unimplemented public counter path.
TASK-31 route change: Sol/xhigh reached its usage limit; Terra/xhigh continues the same escalation.
TASK-31 route change: user requested available GPT-6 Astra; repeated semantic audit failures retain xhigh effort.
TASK-31B route change: the Sol agent hit its usage limit; the user requested available GPT-6 Astra.
Pending Sol routes now use Astra at the same effort, as requested by the user; Luna routes stay unchanged.
TASK-31 split: user requested smaller tasks; bounded semantic tasks return to Sol/high; TASK-31A uses Sol/high because Luna is not listed by the collaboration tool.
TASK-32 review split resolved: the accepted key uses future-observable captures. Absence uses semantic nullability and keeps its physical subprogram.
TASK-42A integration: PR #412 is open. Ruby and Cross-runtime CI cannot start because repository Actions policy blocks required external actions. Do not merge; allow the required actions and rerun CI.

## TASK-53C2 acceptance evidence

Root accepted this unit on 2026-09-19 after source review and final checks.
Source: `ab0449e2` plus TASK-53C2 changes on `codex/task-53c2-gir-ids`.
Workspace: `/Users/masa/.codex/worktrees/b71a/Onibi`.

GIR state identities use `OnibiGirStateId` (`uint32_t`).
`UINT32_MAX` is reserved. Allocation checks prevent ID wrap.
NFA/GIR conversions check reserved values and state bounds where required.
RSeq lowering preserves the physical layout and converts verified GIR IDs explicitly.
Start-edge diagnostics retain `-1`. Executors and fallback behavior are unchanged.

Exact root commands:

```sh
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ruby -v
(cd ext/onibi && ruby extconf.rb && make)
ruby -Ilib -Itest -e 'ARGV.each { |f| require_relative f }' test/features/quality/gir_state_id_contract_test.rb test/features/quality/nfa_state_id_contract_test.rb test/features/quality/module_interface_contract_test.rb test/features/quality/gir_verifier_test.rb test/features/quality/rseq_physical_verifier_test.rb test/features/quality/tagged_nfa_lowering_test.rb test/features/quality/rseq_subprogram_representation_test.rb
ruby -Ilib -Itest -e 'ARGV.each { |f| require_relative f }' test/features/engine/semantic_state_test.rb test/features/compatibility/dynamic_differential_test.rb test/features/compatibility/tagged_nullable_utf8_regression_test.rb
git diff --check
(cd ext/onibi && make distclean)
```

All commands exited 0. Ruby reported MRI 4.0.6.
The build enabled `-Wall` and `-Wextra` and reported two existing warnings:
`onibi_c_ast_has_capture` and `onibi_rseq_mark_unsupported`.
Quality checks passed: 106 runs, 640 assertions, no failures, errors, or skips.
Semantic checks passed: 40 runs, 19,259 assertions, no failures, errors, or skips.
Cleanup removed the generated extension.

Root continuation: the user authorized agent-selected Relay tasks through completion on 2026-09-19.
Keep one active worker. Preserve blocked dependencies; do not claim all tasks complete while TASK-42B remains blocked.
Publication and remote merge still require explicit authorization.

TASK-55 next action: audit the current object graph and Ractor behavior as TASK-55A (Luna/High).
This audit can identify independent defects before TASK-42B. Final TASK-55 acceptance still depends on TASK-42.

TASK-55A review 1: rejected audit evidence; keep source findings and correct the probe harness.
Worker: `01a0b9f3-81e4-7b80-a864-b6ac8069cdd8`, Luna/High, worktree `/Users/masa/.codex/worktrees/d64e/Onibi`.
Required corrections: reject timeouts and unexpected errors, isolate each probe in a bounded process, test scan separately, and distinguish retained values from getter returns.
TASK-55 remains pending. No runtime changes or shareability enablement are authorized by this audit.

TASK-55A review 2: source/getter correction retained; process harness still rejected.
After scope reassessment, the same Luna/High worker owns only the bounded harness correction.
Required proof: deadline through process exit after pipe EOF, exact expected exit status, and self-checks through normal rejection logic.
At this review the five-hour usage window was 84% used; start no large semantic task and stabilize active work first.

TASK-55A review 3: ACCEPT current-state audit at worker commit `d63d1dcb`.
Root inspected corrected process-lifetime deadlines, exact exit classification, separate match/scan probes, source/getter isolation, and recorded outputs.
Production behavior is unchanged. Onibi objects remain non-shareable and child-Ractor C calls remain unsafe.
Audit driver and complete outputs remain at `/Users/masa/.codex/worktrees/d64e/Onibi/.task-55a-logs/`; keep this worktree.
Required invocation-state checks retain 6 baseline NameErrors for removed Ruby internals; these are not native test passes.

Dispatch stop: five-hour account window reached 90% used on 2026-09-19.
No new worker was opened. TASK-42B remains blocked; TASK-55 is not accepted.
Next action after reset: dispatch TASK-55B (Luna/Max) to define and test MRI-compatible metadata getter isolation for stored names/named_captures, without enabling Ractor-safe methods or changing MatchData integration.
Scope the unit to retained metadata ownership and fresh public return values. Use the TASK-55A nested-mutation reproduction and MRI expected behavior.

TASK-55B accepted on 2026-09-20 at worker commit `163618f3`.
Root verified the durable relay digest, source/workspace, ownership diff, MRI probes, and exact check logs.
Retained names and capture metadata are immutable; getters copy mutable containers and values.
No Ractor enablement, execution classification change, or MatchData adapter change occurred.
Keep probe logs in `/Users/masa/.codex/worktrees/0167/Onibi/.task-55b-logs/`.

Remaining dependency frontier: TASK-42B is blocked on a supported MRI MatchData register-transfer API; TASK-42 remains partial.
Final TASK-55 depends on TASK-42B and remains pending. TASK-55A/B do not remove that dependency.
No additional implementation unit is ready under the current MRI-only gem scope.
Next action: obtain a supported MRI transfer API or explicitly approve a separate MRI-integration scope before resuming TASK-42B.
Do not construct RMatch manually, rerun MRI as the native implementation, or mark the blocked parents complete.

TASK-42B1 design review 1: repair requested, Luna/High worker `01a0bbee-0ef4-7ab0-9a55-5bc899962299`.
Keep native Onibi::MatchData proposal. Correct duplicate-name representation, string/nil metadata semantics, and forbid custom-object injection into MRI backreference storage.
Split accessor implementation by independent invariant before adoption. User authorized consideration of an Onibi-owned compatible implementation on 2026-09-20.

TASK-42B1 accepted on 2026-09-20: native Onibi::MatchData gem design.
Root reproduced all 68 MRI probe observations byte-for-byte and reviewed duplicate-name and backreference boundaries.
The new gem contract in GIR sections 58-59 removes the external RMatch constructor dependency for gem implementation only.
Exact MRI type identity, C consumers, and VM backreferences remain later MRI-integration requirements.
TASK-42B is now split for gem implementation; it is not complete. The earlier blocked frontier is superseded by this accepted contract.
Next: TASK-42B2, Luna/High, native payload/lifetime only; later units implement numeric access, named lookup, offsets, value behavior, and public routing.
Keep the probe and output at `/Users/masa/.codex/worktrees/f7d9/Onibi/.task-42b1-logs/`.

TASK-42B2 review 1: repair requested from Luna/High worker `01a0bbfa-5d2c-7912-afdc-ee07f34d9583`.
Keep payload ownership design; replace input-sized diagnostic stack arrays with ensured heap ownership.
Required remaining evidence: explicit validation errors, coercion-failure cleanup, GC compaction, MRI capture-outside-group0 example, and restored diagnostic injection state.

TASK-42B2 ACCEPT: native payload/lifetime at worker commit `2c267baf`.
Root inspected range validation, copied raw buffers, frozen subject/metadata, mark/free/memsize, and ensured diagnostic heap cleanup.
After commit-hook C formatting, root rebuilt with MRI 4.0.6 and reran the focused group: 23 runs, 242 assertions, no failures/errors/skips.
Exact root test command: `ruby -Ilib -Itest -e 'ARGV.each { |f| require_relative f }' test/features/captures/match_data_payload_test.rb test/features/captures/match_data_contract_test.rb test/features/api/regexp_metadata_isolation_test.rb test/features/quality/module_interface_contract_test.rb`.
Build and cleanup: `(cd ext/onibi && ruby extconf.rb && make)` and `(cd ext/onibi && make distclean)` exited 0.
Environment: `PATH=/opt/homebrew/opt/ruby/bin:$PATH`, `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.
Worker checks and known warnings are recorded in docs/task-42b2-evidence.md. Keep its worktree logs.
Public accessors, copy/value behavior, and match routing remain incomplete.

At the review boundary the five-hour window was 88% used, near the 90% stop threshold. No new worker was dispatched.
Next after reset: TASK-42B3, Luna/High, numeric capture/string access only.
Scope: match_data.c, private header, method registration, focused MRI differential tests; implement numeric [], captures, to_a, size/length, to_s, string, pre_match/post_match, and regexp without public Regexp#match routing.
Use private payload creation for differential fixtures. Keep named lookup, character offsets, value/copy/deconstruction, and routing as separate later units.

TASK-42B3 review 1: REJECT numeric semantics; same Luna/High worker `01a0bd16-430d-74c0-b74a-a947d5af44a4`.
MRI evidence: single index -num_regs returns nil; +/-2**40 raises int-conversion RangeError; two-argument String index raises TypeError.
Keep byte slicing and snapshot ownership. Correct per-form coercion and add real runtime MRI differential coverage.

TASK-42B3 review 2: narrow correction remains for explicit nil-length Range dispatch.
MRI `m[1..2, nil]` returns the range slice; current scalar-only nil branch raises TypeError.
After reassessment, preserve all corrected numeric work and repair only this dispatch path with differential cases. Same Luna/High worker.

TASK-42B3 ACCEPT: numeric capture and snapshot string access at worker commit `6e4da9df`.
Root verified relay identity, final source, explicit nil-length Range dispatch, and exact check logs.
MRI differential tests passed: 5 runs, 81 assertions. Regression checks passed: 23 runs, 242 assertions.
Build, RuboCop, C formatting, diff check, and build cleanup passed. Only the two known compiler warnings remain.
Exact commands are in docs/task-42b3-evidence.md; logs remain in `/Users/masa/.codex/worktrees/6391/Onibi/.task-42b3-logs/`.
Getters use copied registers and frozen subject bytes without MRI execution. Public routing remains unchanged.
Next: TASK-42B4, Luna/High, named capture lookup and metadata return isolation only.

TASK-42B4 review 1: REJECT unknown-name error escaping; retain duplicate-name lookup and metadata isolation.
Worker: `01a0bd29-c433-73f1-8d4c-ed038ff0c464`, Luna/High, worktree `/Users/masa/.codex/worktrees/5b14/Onibi`.
Root MRI 4.0.6 probe found that quote and backslash names gain extra escapes under `rb_str_inspect` slicing.
Correction scope: MRI-compatible unknown-name formatting and differential edge cases; rerun original exact checks.

TASK-42B4 review 2: retain formatter ownership and corrected quote/backslash/control cases.
Root checked all single-byte names under binary and UTF-8 encodings, plus four additional selectors: 514/516 matched MRI.
Literal `#@foo` and `#$foo` still gain an extra backslash. The formatter removes only the `#{` escape.
After reassessment, keep the same Luna/High worker for this narrow interpolation-escape correction and full required checks.

TASK-42B4 ACCEPT at worker commit `eac367e2`: named lookup and metadata isolation.
Root inspected final interpolation handling, ordered duplicate-name participation, index bounds, and ensured formatter cleanup.
Required MRI differential checks passed: 7 runs, 106 assertions. Regression group passed: 28 runs, 323 assertions.
Build, Ruby/C formatting, diff check, and cleanup passed with only the two baseline compiler warnings.
Exact commands are in docs/task-42b4-evidence.md; retain worker `.task-42b4-logs/` in worktree `5b14`.
Public routing remains incomplete. Next bounded unit: TASK-42B5A, Luna/High, byte offsets only.
Character conversion, remaining accessors/value methods, and routing stay separate.

TASK-42B5A ACCEPT at worker commit `457053fb`: bytebegin, byteend, and byteoffset.
Root verified relay identity, source/workspace, numeric coercion and bounds, named participation lookup, and fresh offset arrays.
Required differential checks passed: 5 runs, 139 assertions. Regression group passed: 35 runs, 429 assertions.
Build, RuboCop, diff check, and cleanup passed with the two known warnings. Root C formatting check also passed.
Exact commands are in docs/task-42b5a-evidence.md; keep logs in `/Users/masa/.codex/worktrees/7c0c/Onibi/.task-42b5a-logs/`.
No character conversion, fallback change, or public match routing occurred.

At this review, the five-hour window was 86% used. Defer the next larger semantic unit until reset.
Next action: dispatch TASK-42B5B, Luna/High, lazy character offsets and begin/end/offset/match_length from the frozen subject and retained byte ranges.
Define encoding-aware conversion, cache ownership/failure cleanup, and MRI differential cases before dispatch.
Keep remaining match/values_at, copy/value/deconstruction, public routing, and final TASK-55 work separate.
TASK-42B and TASK-55 remain incomplete. No worker is active and no publication is authorized.

Continuation check: five-hour usage reached 90% on 2026-09-20. The user's dispatch-stop rule now applies.
No new worker was opened. Accepted source and the working tree remain clean.
Resume after the reported reset at 18:05 JST with TASK-42B5B as specified above.

TASK-42B5B ACCEPT at worker commit `cc5f3896`: lazy character begin/end/offset/match_length.
Root verified callback identity, source/workspace, per-payload cache allocation, publication-after-success, encoding-aware conversion, and cleanup.
Focused MRI checks passed: 7 runs, 83 assertions. Required capture and contract group passed: 40 runs, 568 assertions.
Build, RuboCop, diff check, and cleanup passed with only the two known compiler warnings.
Exact commands are in docs/task-42b5b-evidence.md; retain worker logs in `/Users/masa/.codex/worktrees/ef8b/Onibi/.task-42b5b-logs/`.
No public match routing or fallback behavior changed.

Next: TASK-42B6, Luna/High, remaining MatchData values and selector APIs, split by invariant if needed.
Keep match/values_at, copy/value/deconstruction, inspect, public routing, and TASK-55 integration separate.

TASK-42B5B review boundary: value and copy work must split before dispatch.
Next TASK-42B6A covers inspect, equality, eql?, and hash only. TASK-42B6B will cover dup/clone and deconstruction after A is accepted.

TASK-42B6A ACCEPT at worker commit `00b9b573`: inspect, equality, eql?, and hash.
Root verified callback identity, native value sources, hash/equality consistency, and reran the checks.
Focused tests passed: 3 runs, 14 assertions. Required regression group passed: 50 runs, 665 assertions.
Build, RuboCop, C formatting, diff check, and cleanup passed with the two known warnings.
Exact root results are in `/Users/masa/.codex/worktrees/27f7/Onibi/.task-42b6a-logs/checks.txt`; evidence is in docs/task-42b6a-evidence.md.
The initial pre-build distclean had no Makefile; the post-build cleanup passed. No functional failures occurred.

Next: TASK-42B6B, Luna/High, dup/clone and deconstruction/deconstruct_keys only.
Keep match, values_at, public routing, and MRI integration separate.

TASK-42B6B ACCEPT at worker commit `078539ef`: native dup, clone, deconstruct, and deconstruct_keys.
Root verified callback identity, independent register/cache ownership, freeze and singleton behavior, fresh deconstruction values, and key validation.
Focused checks passed: 4 runs, 19 assertions. Required regression group passed: 50 runs, 665 assertions.
Command Line Tools build, RuboCop, C formatting, diff check, and cleanup passed with the two known warnings.
The default Xcode wrapper remains blocked by its local license state; the documented Command Line Tools build passed.
Evidence is in docs/task-42b6b-evidence.md. Public match routing remains separate.

Next: TASK-42C, Luna/Max, native Regexp#match routing and backreference integration boundary.
Before dispatch, split routing and integration if the source review shows independent invariants.

TASK-42B6B ACCEPT at worker commit `078539ef`: native dup, clone, deconstruct, and deconstruct_keys.
Root verified callback identity, independent register/cache ownership, freeze and singleton behavior, fresh deconstruction values, and key validation.
Focused checks passed: 4 runs, 19 assertions. Required regression group passed: 50 runs, 665 assertions.
Command Line Tools build, RuboCop, C formatting, diff check, and cleanup passed with the two known warnings.
Default Xcode wrapper remains blocked by its local license state; the Command Line Tools build passed.
Evidence is in docs/task-42b6b-evidence.md. Public match routing remains separate.

Next: TASK-42C1, Luna/Max, supported native Regexp#match routing only. Keep backreference behavior and Ractor integration separate.

TASK-42C1 review 1: REJECT input-sized stack allocation.
Worker `01a0be3f-f3f2-7f31-9683-360b94f9b936` routed supported native matches correctly, but `rseq.c:onibi_match` uses `ALLOCA_N` for capture registers sized by the pattern.
Require ensured heap storage with cleanup around native search and MatchData construction. Preserve the native/fallback split, unchanged match? path, and valid tests.

TASK-42C1 accepted after the ownership repair. `rseq.c:onibi_match` now allocates capture registers on the heap and frees them through `rb_ensure` across native search, MatchData construction, block yield, and exceptions. Supported matches return `Onibi::MatchData` from the native raw ranges. Explicit fallback still calls the source MRI regexp. The MRI backreference remains unchanged for the custom object.

Root checks: MRI 4.0.6 warning build; native routing 4 runs/20 assertions; API 37 runs/110 assertions; MatchData regression 54 runs/690 assertions; C formatting and diff checks pass. RuboCop was unavailable in the root environment because the locked bundle gems are not installed; the worker reported a clean RuboCop run before callback.

Next: TASK-42C2, audit C backreference consumers and caller paths. Keep String callers, scan/gsub/===/~, and Ractor integration separate.

TASK-42C2 accepted as a read-only boundary audit. Native `Onibi::MatchData` does not enter MRI backreference storage. Native `===` and `~` still rematch through MRI. `=~` is not defined. String callers reject the custom regexp. Native scan and gsub keep their current block and backreference limits. The Unicode helper restores MRI state without `rb_ensure`, but public grapheme support remains rejected.

Root verification: the audit note and six-test boundary gate were copied from the worker. After a clean Command Line Tools build, the audit passed 6 runs/40 assertions. Build cleanup and diff checks passed. The next implementation unit is native-success `===` routing, with explicit fallback unchanged. Keep `~`, `=~`, String adapters, scan/gsub block state, Unicode cleanup, and Ractor work separate.

TASK-42C3 accepted. Native-success `Onibi::Regexp#===` now returns the native Boolean result without rematching through MRI. Native success preserves the prior MRI backreference. Native misses still clear it. Explicit fallback, non-String behavior, `~`, `=~`, String callers, scan/gsub state, Unicode cleanup, and Ractor behavior remain unchanged.

Root verification: MRI 4.0.6 warning build; native case-equality, boundary, native routing, and API tests passed 51 runs/205 assertions. C formatting, Ruby Layout checks, diff checks, and build cleanup passed. The next unit is the native `~` boundary.

TASK-42C4 accepted. Native-success `Onibi::Regexp#~` now returns the character position from the native raw range without rematching through MRI. Native success preserves the prior MRI backreference. Native misses clear it. Explicit fallback and non-String global input behavior remain unchanged. The existing multibyte `\\K` position gap remains outside this routing unit.

Root verification: MRI 4.0.6 warning build; tilde, case-equality, boundary, native routing, and API tests passed 55 runs/245 assertions. C formatting, diff checks, and build cleanup passed. The next unit is the missing `=~` boundary.

TASK-42C5 accepted. `Onibi::Regexp#=~` now returns native character positions without MRI rematching. Native success preserves the prior MRI backreference. Native misses and nil clear it. Symbol and `to_str` coercion work, invalid inputs raise `TypeError`, and explicit fallback retains MRI MatchData behavior. String `=~` delegates through the new operator automatically. The known native `\\K` raw-range position gap remains outside this unit.

Root verification: MRI 4.0.6 warning build; operator, tilde, case-equality, boundary, native routing, and API tests passed 59 runs/314 assertions. C/Ruby formatting, diff checks, and build cleanup passed. The next unit is the `String` caller and scan/gsub boundary audit.

TASK-42C6 accepted as a read-only audit. String `=~` delegates to the new operator. Other tested String callers reject the custom regexp. Native scan and gsub return tested values but ignore blocks and preserve prior MRI state. Backslash replacement uses MRI for both native and fallback patterns. Fallback scan and gsub publish MRI MatchData. No native MatchData enters MRI storage.

Root verification: after a clean Command Line Tools build, the audit passed 10 runs/314 assertions. The combined boundary and API group passed 61 runs/552 assertions. Build cleanup and diff checks passed. The next unit is native scan block support, including subject identity, block exceptions, and mutation rules. Replacement expansion remains separate.

TASK-42C7 accepted after the mutation-check repair. Native scan and explicit fallback now forward blocks, yield MRI-compatible values, and return the original subject on normal completion. Native paths preserve the prior MRI backreference. Length and encoding changes raise `string modified`; same-length byte changes match MRI in the tested cases. `rb_ensure` cleanup covers exceptions and non-local exits. Replacement expansion remains separate.

Root verification: MRI 4.0.6 warning build; scan, gsub, boundary, native routing, and API tests passed 79 runs/1129 assertions. C formatting, Ruby syntax/Layout, diff checks, and build cleanup passed. The next unit is native replacement expansion or a separate gsub block audit. Keep String adapters, Unicode cleanup, Ractor behavior, and MatchData integration separate.

TASK-42C8 accepted on 2026-09-21: native replacement expansion. `gsub` now expands numbered and named captures, whole-match, prefix, suffix, last-capture, escaped-backslash, and literal unknown escapes from native raw ranges. Unknown named references use the stored MRI regexp for MRI `IndexError` behavior. Native replacement keeps the prior MRI backreference; explicit input fallback, block behavior, String adapters, Unicode cleanup, Ractor behavior, and MatchData integration remain separate.

Root verification: MRI 4.0.6 warning build; replacement, scan, block, boundary, operator, routing, and API tests passed 80 runs/1115 assertions. Direct MRI differential probes covered optional and duplicate captures, mixed named and unnamed groups, long numeric references, empty matches, and unknown names. C formatting, Ruby syntax, diff checks, and cleanup passed. Evidence: `docs/task-42c8-evidence.md`.

TASK-42C9 review 1: REJECT audit harness and evidence. Worker `01a0c1ab-be49-7d81-9129-c08b290a2862`, Luna/High, worktree `/Users/masa/.codex/worktrees/a561/Onibi`, source `3a2aa006`. Callback identity verified. Keep the gsub differential findings and unchanged production source. Require bounded child exit handling with distinct exit/signal/timeout results, exact check commands, and evidence limited to measured behavior. Worker logs show audit 10/86 and regression 76/1046 pass; root has not accepted the audit. Repair remains in the same Relay task `task-42c9-6b4322d5d97f`.

TASK-42C9 ACCEPT: gsub block audit, source `3a2aa006`, worker `01a0c1ab-be49-7d81-9129-c08b290a2862`. Revised callback ID typo was corrected by the authenticated sender. Root verified both files, native/fallback evidence, child exit/signal/timeout handling, and native gsub cleanup/range reuse. Root ran `/opt/homebrew/opt/ruby/bin/ruby extconf.rb` from worker `ext/onibi`, `DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi warnflags='-Wall -Wextra'`, `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/matching/gsub_block_audit_test.rb` (11/120 pass), and Command Line Tools `make -C ext/onibi distclean`; all exited 0. Worker regression 76/1046, syntax, Layout and whitespace checks pass. Exact worker commands are in `docs/task-42c9-evidence.md`. Production defects remain open: subject mutation, block-result coercion, and replacement precedence. Next: TASK-42C10, Luna/Max, subject mutation safety only.

TASK-42C10 ACCEPT: subject mutation safety. Worker `01a0c1bf-8d92-7e90-9cc7-049905d61539`, Luna/Max, worktree `/Users/masa/.codex/worktrees/0719/Onibi`, base `3a2aa006` plus accepted TASK-42C9 files. Relay identity and inherited file hashes verified. `onibi_gsub_body` checks original byte length after yield and after StringValue conversion before reusing raw ranges. MRI permits the tested same-length mutations. Ensured heap cleanup remains unchanged; no new fallback or rematch. Root clean warning build passed, followed by `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/matching/gsub_block_audit_test.rb test/features/matching/gsub_mutation_test.rb test/features/matching/scan_gsub_test.rb test/features/matching/scan_block_test.rb test/features/api/string_caller_boundary_audit_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb`: 95 runs, 1189 assertions, zero failures/errors/skips. C formatting and Command Line Tools distclean passed. Root logs: worker `.task-42c10-logs/root-build.txt` and `root-tests.txt`. Evidence: `docs/task-42c10-evidence.md`; root corrected a stale test total in its table. Accepted files remain uncommitted because the local commit hook has a Ruby environment failure. Next: TASK-42C11, Luna/Max, block-result conversion only; replacement precedence stays separate.

TASK-42C11 ACCEPT: native block-result conversion. Worker `01a0c1d0-9cc4-7961-9540-7aa0486e37e0`, Luna/Max, worktree `/Users/masa/.codex/worktrees/97a6/Onibi`; inherited source hashes and Relay identity verified. `onibi_gsub_body` now uses `rb_obj_as_string`, then validates subject byte length before range reuse. MRI conversion exceptions and side effects occur before mutation validation. Ensured cleanup and native/fallback routing remain unchanged. Root warning build and `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/matching/gsub_block_conversion_test.rb test/features/matching/gsub_block_audit_test.rb test/features/matching/gsub_mutation_test.rb test/features/matching/scan_gsub_test.rb test/features/matching/scan_block_test.rb test/features/api/string_caller_boundary_audit_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb` passed: 100 runs, 1206 assertions, zero failures/errors/skips. Root conversion throw/nested-call probes matched MRI; C formatting and cleanup passed. Exact worker checks: `docs/task-42c11-evidence.md`; root logs: worker `.task-42c11-logs/root-build.txt` and `root-tests.txt`. Root narrowed the encoding limitation wording to the measured probe. Separate debts: result encoding adoption, replacement-plus-block precedence. Accepted source remains staged and uncommitted. Next: TASK-42C12, Luna/Max, replacement-plus-block precedence only.

TASK-42C12 ACCEPT: explicit replacement precedence. Worker `01a0c1e2-fd77-7bf3-9955-fa44eec30e93`, Luna/Max, worktree `/Users/masa/.codex/worktrees/f705/Onibi`. Actual callback sender, metadata, Relay digest and unchanged inherited hashes verified. `onibi_gsub` selects replacement by argument presence; StringValue validates explicit replacement and the existing missing-argument error path. Explicit replacement suppresses the block for native and fallback paths. Native expansion, block-only conversion, subject guards and cleanup remain intact. Root warning build and `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/matching/gsub_precedence_test.rb test/features/matching/gsub_block_conversion_test.rb test/features/matching/gsub_block_audit_test.rb test/features/matching/gsub_mutation_test.rb test/features/matching/scan_gsub_test.rb test/features/matching/scan_block_test.rb test/features/api/string_caller_boundary_audit_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb` passed: 107 runs, 1253 assertions, zero failures/errors/skips. C format and cleanup passed. Root logs are worker `.task-42c12-logs/root-build.txt` and `root-tests.txt`; worker commands are in `docs/task-42c12-evidence.md`. Root corrected the evidence attribution: missing both replacement and block still raises Onibi TypeError, while MRI returns an Enumerator.

Session boundary: weekly usage 81%, five-hour usage 79% at review. No new large semantic task dispatched. TASK-42C9 through TASK-42C12 are accepted and staged in the saved checkout at HEAD `3a2aa006`; no commit/push/PR/merge occurred. Commit attempt failed in the local Ruby pre-commit environment. Next stabilization action: repair the hook environment without bypassing checks, then record accepted audit/mutation/conversion/precedence work as atomic commits using retained worker snapshots. Next semantic unit: TASK-42C13, Luna/Max, gsub result encoding compatibility; first establish the exact MRI encoding rules and native reproduction, then split if needed. Hash replacements, missing-argument Enumerator, String adapters, Unicode cleanup, Ractor and MatchData integration remain separate.

TASK-42C12S review 1: REJECT stabilization evidence and unapproved lint suppressions. Worker `01a0c29c-2904-7583-a5fc-8e4db289c43b`, Luna/High, worktree `/Users/masa/.codex/worktrees/e84c/Onibi`, prepared commits `e680a3db` through `6f566e5b`. Identity and frozen accepted hashes verified. Final C source and accepted evidence/ledger are byte-identical; test edits include local RuboCop suppressions beyond the original formatting scope. Root requests removal of unnecessary suppressions, explicit justification for minimal intentional-test exceptions, exact hook commands/results, and per-stage validation. Preserve all five prepared commits and valid environment repair. No integration yet. Weekly usage 88%; no new worker dispatched.

TASK-42C12S ACCEPT: prepared atomic local commits with repaired worker-local MRI/Bundler environment. Worker `01a0c29c-2904-7583-a5fc-8e4db289c43b`, worktree `/Users/masa/.codex/worktrees/e84c/Onibi`, branch `codex/task-42c12s-accepted-commits`. Actual callback sender and task metadata verified despite a body ID typo. Ordered commits from base `3a2aa006`: `e680a3db` (C9), `c6bf48ba` (C10), `3994482b` (C11), `d24d6016` (C12), `6f566e5b` (records), `0f8d7db8814d4e1b67c91fb797f5a5b325a17e73` (bounded lint correction/evidence). Root verified parent chain, per-commit scope, all frozen accepted hashes, unchanged final C/evidence/ledger content, and final Ruby changes. Narrow test-only RescueException and harness BlockLength exceptions are justified; unnecessary exceptions were removed. Original hook logs were absent; isolated per-commit hook rechecks report exit 0 in worker `.task-42c12s-logs/history/*-result.txt`. Hook/config/Gemfile/lockfile have no diff. Final worker warning build, 107 runs/1253 assertions, full scoped RuboCop, C format and cleanup pass. Exact environment and evidence: worker `docs/task-42c12s-evidence.md`. Worker tracked tree is clean; local dependencies/logs remain untracked.

Usage stop: weekly usage 90%, five-hour usage 36%. No new worker. Saved checkout remains at `3a2aa006` with accepted implementation staged and root review ledger additions; prepared commits remain on the isolated branch above. No push, PR, merge or branch-history integration occurred. Next action: integrate the verified six-commit sequence while preserving these newer root ledger entries and confirming saved-checkout changes still match the accepted snapshot. The prepared branch is the durable commit source. Result-encoding task TASK-42C13 remains unstarted.


TASK-42C12S local integration (2026-09-23): root verified nine saved-checkout file hashes against the frozen accepted snapshot. The ledger contained only the retained review and usage records. Root preserved the dirty state in a Git stash and an external patch, then fast-forwarded the feature branch from `3a2aa006` to `0f8d7db8`. All six accepted commits are now in the saved branch. Root restored the newer ledger records. A clean Homebrew MRI 4.0.6 warning build passed. The focused MRI group passed: 107 runs, 1253 assertions, no failures, errors, or skips. Command Line Tools distclean passed. Exact commands, exits, and full logs: `/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/integration-checks.json`. No publication occurred. The former worker worktree is absent; retained commits and frozen snapshots supplied recovery evidence. Default `bundle check` reports missing locked gem versions; direct MRI tests work. Next: TASK-42C13A, Luna/Max, a bounded result-encoding audit before implementation.
