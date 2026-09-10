# TASK-31: Small repair tasks

## Status and acceptance

Keep the current implementation as a WIP baseline on the feature branch.
Checkpoint commit: `29ad58dc`.
This records the work. It does not approve its semantics or complete TASK-31.
Do not discard the working TAGGED frontier while repairing the remaining defects.

`gir.md` remains the design authority. `review-result.md` remains the review authority.
This plan divides TASK-31. It does not replace its requirements or the review dependency graph.
TASK-31 remains the completion gate for every task that depends on it.
Do not start TASK-32 during these repairs; its runtime changes overlap this work.

Accept each repair independently after root diff review and focused tests.
Acceptance applies to that repair, not to all behavior in the WIP baseline.
A tests-only task can complete with a documented failing regression.
Do not change the MRI expectation or skip that regression to obtain a pass.

## Baseline evidence

Root checked this baseline with MRI 4.0.6:

- Build: succeeds with five unused-helper warnings.
- Focused semantic tests: 36 runs, 4,983 assertions, no failures.
- Compiler quality tests: 71 runs, 576 assertions, eight failures and one error.
- Bounded differential audit: 39,160 completed cases had no semantic differences.
- Thirty additional cases reached a diagnostic 50 ms timeout. The remaining matrix was not checked.
- Three timeout samples matched MRI with a one-second limit. They took 35–68 ms.
- UTF-8 audit: one capture difference in 260 cases.

The confirmed defect is `^(あ??){2}x` on `あx`.
MRI returns capture bytes `[3,3]`. Native TAGGED returns `[0,3]`, without fallback.

The original uncapped audit reached about 900 MB RSS before root stopped it.
This is a resource risk, not a proven leak or a complete performance measurement.
Assertion checkpoints also omit the capture-event count. Their rollback behavior needs proof.

## Task boundaries

Run the tasks in table order. Dependencies describe evidence needed for acceptance.
Keep production changes serial because these tasks share semantic rules.
Use a separate agent for each task. Reuse that agent only for immediate corrections.

| Task | Dependencies | Single objective | Allowed change area | Acceptance |
| --- | --- | --- | --- | --- |
| TASK-31A | TASK-30 | Record the confirmed native UTF-8 capture defect | One new differential test file | Fewer than 40 cases; raw byte ranges; native TAGGED counters; confirmed failure stays visible |
| TASK-31B | TASK-31A | Define nullable-repeat action semantics | Relevant sections of `docs/gir.md` only | Root approves slot ownership, initialization, rollback, priority, live captures, and the MRI reference rule; no production edits |
| TASK-31C | TASK-31B | Correct encoding-dependent nullable-repeat lowering | Repeat reference analysis in `compiler.c`; focused differential tests | TASK-31A passes; ASCII and multibyte controls pass; no numeric threshold fitting or larger unroll limit |
| TASK-31P | TASK-31A | Validate the fixed-interval optional suffix parser change | `parser.c`; fixed-interval tests | `{n}?` and `{n,n}?` match MRI; tests compare raw native results, including captures; no repeat-compiler redesign |
| TASK-31D | TASK-31B, TASK-31C, TASK-31P | Restore tests for explicit epsilon paths | `tagged_nfa_lowering_test.rb`; directly required diagnostic adapters | Ordered reachability and distinct action paths remain tested; no stale direct-edge assumption; report real graph defects instead of changing their expectations |
| TASK-31E | TASK-31B, TASK-31D | Verify GIR nullable-action resource rules | GIR verifier in `gir.c`; GIR malformed-input diagnostics and tests | Reject uninitialized, aliased, out-of-range, and wrong-owner guard uses; preserve valid programs |
| TASK-31F | TASK-31E | Verify the same rules in physical RSeq | Blob verifier in `rseq_runtime.c`; physical malformed-input diagnostics and tests | Match the accepted GIR contract; restore the resource-range diagnostic test; reject malformed blobs without a Ruby graph |
| TASK-31G | TASK-31B, TASK-31F | Make assertion capture-event rollback complete | Checkpoint and assertion code in `exec_dynamic.c`; semantic-state and assertion tests | Failed actions, negative assertions, and failed assertion trials cannot publish capture events; no whole-state copies |
| TASK-31H | TASK-31C, TASK-31D, TASK-31G | Verify ordered frontier identity and accepted captures | TAGGED key, priority, and materialization code; focused native tests | Earlier output-only history wins; all future-observable state remains distinct; nested assertions and counters pass without DFS or fallback |
| TASK-31I | TASK-31H | Bound capture-order and capture-event work | TAGGED order/event storage and materialization; bounded scaling tests | Explain retained data; test work and memory growth; no full capture copies or new Ruby objects per thread; warning-clean build |
| TASK-31J | TASK-31A through TASK-31I, including TASK-31P | Complete the original TASK-31 acceptance gate | Root verification and ledger only | All repair tests, related subsystem tests, full current C-path suite, and relevant differential/fuzz checks reviewed; no unresolved TASK-31 architecture defects |

TASK-31D must stop if an actual graph defect requires production changes.
Root must issue a separate packet for that defect before implementation.
Apply the same rule to any unexpected change outside a task's allowed area.
TASK-31B must derive its rules from the design and MRI evidence, not approve the current algorithm by description.

TASK-31I does not absorb TASK-33 or TASK-34.
Shared execution arenas and common timeout polling stay in those later tasks.
However, unexplained growth introduced by TASK-31 cannot pass its gate.

## Agent routing

Use smaller, bounded assignments instead of one replacement implementation task.
Use the original Sol/high route for semantic work when that route is available.
Use Luna/medium for bounded test work and Luna/high for verifier or ownership work when available.
The current collaboration tool does not list Luna. TASK-31A therefore uses Sol/high.
Do not assume that a smaller task removes an account usage limit.
Keep Astra escalation for a specific unresolved semantic conflict, not the entire task group.

## Packet and review limits

Each packet must use the task format required by the user.
Include only its issue IDs, required design sections, allowed files, and acceptance checks.
Do not give an agent this entire repair queue as an implementation assignment.
Do not ask an agent to spawn another agent.

Use MRI 4.0.6 and inspect `Rakefile` and `development.md` before verification.
Build once for a serial test group. Run focused tests after each repair.
Run broader checks only at TASK-31J or when a changed invariant requires them.
Keep known failures separate from new failures. Do not suppress either.

The parent TASK-31 closes only after TASK-31J passes root review.
