# TASK-55A Ractor and object graph audit

Date: 2026-09-19

Revision: `02310b3b32fc2578749fafaab166537c09594892`

Worktree: `/Users/masa/.codex/worktrees/d64e/Onibi`

Branch: `codex/task-55a-ractor-audit`

## Scope and result

This is a read-only audit. It adds one probe driver and this note. It does not
change production C, tests, architecture rules, or the execution ledger.

The current contract is **main-Ractor only**. Onibi objects are frozen after
initialization, but they are not shareable. Onibi C methods also remain
Ractor-unsafe. These results are expected isolation failures, not native match
successes.

Native execution remains callable in the main Ractor. The representatives below
all returned a native match with no fallback:

```text
regular: exec_kind=0 regular=1 tagged=0 dynamic=0 fallback=0 status=1
tagged:  exec_kind=1 regular=0 tagged=1 dynamic=0 fallback=0 status=1
dynamic: exec_kind=2 regular=0 tagged=0 dynamic=1 fallback=0 status=1
```

## Source inventory

### Typed data and retained Ruby values

`onibi_regexp_t` stores `regexp`, `source`, `rseq`, `rseq_blob`, `names`, and
`named_captures` as Ruby `VALUE`s (`ext/onibi/onibi_common.c:545-569`). The mark
callback marks all six values (`:632-643`). `rseq_blob` aliases `rseq` after
lowering (`ext/onibi/rseq.c:1563-1568`). The blob is frozen before validation and
publication (`ext/onibi/rseq.c:968-976`).

The cached `OnibiRSeqView` stores raw pointers into that frozen String
(`ext/onibi/rseq_runtime.c:14-25,45-62`). The view is prepared once during
initialization and reused by match calls (`ext/onibi/rseq.c:1563-1574`,
`ext/onibi/match.c:182-206`). A compaction probe matched both before and after
`GC.verify_compaction_references` and `GC.compact`. No stale-pointer failure was
observed. The blob remains a marked, frozen owner of the view data.

The `rb_data_type_t` flags contain only `RUBY_TYPED_FREE_IMMEDIATELY`
(`ext/onibi/onibi_common.c:650-655`). MRI 4.0.6 documents
`RUBY_TYPED_FROZEN_SHAREABLE` as the flag that permits a frozen typed object to
be made shareable (`ruby/internal/core/rtypeddata.h:145-158`). Onibi does not
set this flag.

### Mutable process and thread state

| Item | Owner and access | Isolation result |
| --- | --- | --- |
| `onibi_default_timeout` | Process-static `double`; `Onibi::Regexp.timeout=` and `.timeout` (`onibi_common.c:191-193`, `rseq.c:1821-1839`) and initialization copy (`rseq.c:1451-1459`) | Shared extension state. It is not per Ractor. Methods are currently blocked in child Ractors. A future safe implementation needs an explicit synchronized or per-Ractor policy. |
| `onibi_deadline_ns` | `_Thread_local`; set at match entry and restored by `OnibiSearchEnsure` (`onibi_common.c:193`, `match.c:115-140,248-288`) | Match deadline is isolated per native thread. Nested searches save and restore the prior value. |
| `onibi_diagnostics` | `_Thread_local`; reset and updated by executor diagnostics (`onibi_common.c:207-225`) | Telemetry is thread-local and must not select execution. No Ractor probe could call diagnostics because C methods are unsafe. |
| `onibi_active_exec_ctx` | `_Thread_local` pointer to one stack `OnibiExecCtx` (`onibi_common.c:326-327`) | The context is match-local. `rb_ensure` releases a nested context and restores the prior pointer (`match.c:248-288`). |
| `onibi_inject_internal_error` | `_Thread_local` diagnostic switch (`onibi_common.c:326-327`) | Test-only thread-local state. It is not a shareability mechanism. |
| ID and class globals | Static `ID` values and class/error `VALUE`s initialized once in `Init_onibi` (`onibi_common.c:328-386`, `onibi_init.c:5-135`) | Read-only after initialization, but extension callbacks remain Ractor-unsafe. |

The execution context contains borrowed Ruby values and the cached view, but
its frontiers, semantic arena, tags, class stack, and raw result are allocated
for one traversal (`onibi_exec_internal.h:234-265`). The release path frees
these arrays. Poll failure releases the active context before re-raising
(`onibi_common.c:498-515`).

## Probe evidence

The required driver is [ractor_audit.rb](/Users/masa/.codex/worktrees/d64e/Onibi/.task-55a-logs/ractor_audit.rb).
Its complete output is [ractor_audit.out](/Users/masa/.codex/worktrees/d64e/Onibi/.task-55a-logs/ractor_audit.out).
Each Ractor operation runs in a separate child process. The parent enforces a
two-second monotonic deadline until process exit, kills and reaps a child on
expiry, and handles the exit race. Match and scan use separate child
operations.

The driver tests REGULAR (`abc`), TAGGED (`^a`), and DYNAMIC
(`(?<x>a)\\k<x>`) construction, reuse, `Ractor.shareable?`,
`Ractor.make_shareable`, child-Ractor calls, default timeout access, and cached
view use after compaction. Each Ractor result has a two-second bound.

Observed results on MRI 4.0.6:

* Every Onibi object was frozen but `Ractor.shareable?` returned `false`.
* `Ractor.make_shareable(onibi_regexp)` raised `Ractor::Error` for all three
  representatives: `can not make shareable object`.
* Passing each object to a child and calling `match?` raised a
  `Ractor::RemoteError` with cause `Ractor::UnsafeError` and child exit 10.
* A separate scan operation for each object raised the same exact error.
  Every child result reported `child_exit: 10`, `child_reaped: true`, and an
  elapsed time below the two-second limit.
* Constructing Onibi in a child Ractor also raised `Ractor::UnsafeError`.
* Reading `Onibi::Regexp.timeout` in a child raised `Ractor::UnsafeError`.
* MRI `Regexp.new("abc").match?("abc")` in a child Ractor returned `true`.
* The cached-view compaction probe returned `{before: true, after: true}`.

The driver exits zero when these expected isolation errors occur. It exits
nonzero for a timeout or any unexpected harness error.

Additional object-graph observations from MRI probes:

* `Onibi::Regexp#source` returns a getter result from the retained MRI Regexp
  (`onibi_source` calls `obj->regexp.source`). Each of two getter results had
  `frozen: false`, was a different object, and mutating the first did not change
  the second or the next getter result. The separate C-owned `obj->source` is
  frozen. This probe does not claim that the getter String is retained.
* `names` and `named_captures` return the marked values stored in the C object.
  Their outer containers are shallow-frozen (`rseq.c:1520-1523`), but nested
  name strings and capture arrays remain mutable. A probe changed `"x"` to
  `"xz"` and appended `2` to the stored capture array. This is a retained
  graph fact for those metadata values.

These observations do not prove that hidden MRI Regexp metadata changes native
RSeq semantics. Native matching uses the published RSeq and uses MRI only for
the documented MatchData adapter.

## Findings and smallest repair boundaries

### RC-01: the published Onibi typed object is not shareable

Evidence: the type has no `RUBY_TYPED_FROZEN_SHAREABLE` flag; all three probes
returned `frozen: true, shareable: false`; `Ractor.make_shareable` raised.

Required behavior for a future Ractor contract: an immutable, deeply
shareable retained graph, with a typed-data flag and a safe ownership proof.

Smallest independent repair boundary: the public typed-data and retained-value
ownership layer. Do not set the flag alone. The hidden MRI Regexp and nested
names/capture arrays must first be removed from the shared graph or made
immutable with an explicit compatibility design. The public source getter needs
its own compatibility test; its returned String is not the C-owned source.

### M-04: the extension has no Ractor-safe callable boundary

MRI 4.0.6 says extensions are shut out from Ractors by default and exposes
`rb_ext_ractor_safe(bool)` for an extension that has completed the required
audit (`ruby/internal/intern/load.h:224-249`). Onibi does not call it. All
registered constructors, match methods, scan, and timeout methods therefore
produce `Ractor::UnsafeError` in child Ractors.

Required behavior: only enable the boundary after all mutable globals, cached
views, Ruby references, GC rules, and method-level synchronization are proven.

Smallest independent repair boundary: a dedicated extension initialization and
Ractor-safety design review. This task must not add `rb_ext_ractor_safe` or
claim child-Ractor native execution.

### Additional repair candidate: shallow metadata freezing

`names` and `named_captures` are frozen only at the outer container. The nested
strings and arrays remain mutable. This is a retained graph defect for any
future shareability design, even though MRI itself returns fresh mutable
metadata from these APIs.

Smallest independent repair boundary: define whether metadata is copied per API
call or deeply immutable at publication. Recheck this with the MatchData work
after TASK-42B.

## Required recheck after TASK-42B

TASK-42B must define the supported MRI transfer path for `MatchData`. After that
work, repeat this audit for:

1. the final retained MRI adapter graph and its mark/free rules;
2. raw-register and lazy character-offset objects crossing a Ractor boundary;
3. native `match`, `match?`, and `scan` calls in child Ractors, with no fallback
   misreported as native success;
4. copied and shared Regexp ownership, timeout policy, and concurrent view use;
5. nested and failed MatchData materialization cleanup.

Until those checks pass, TASK-55 remains pending and Ractor support remains
explicitly unsupported.

## Acceptance evidence

Environment:

```text
ruby 4.0.6 (2026-07-14 revision 03b6d3f889) +PRISM [arm64-darwin25]
PATH=/opt/homebrew/opt/ruby/bin:$PATH
DEVELOPER_DIR=/Library/Developer/CommandLineTools
```

Commands and results:

1. `ruby -v` — exit 0; MRI 4.0.6.
2. `(cd ext/onibi && make distclean)` before the verification build — exit 0
   with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.
3. `(cd ext/onibi && ruby extconf.rb && make)` — exit 0. Warnings enabled. Two
   known warnings only: `onibi_c_ast_has_capture` and
   `onibi_rseq_mark_unsupported`.
4. `ruby -Ilib -Itest test/features/engine/invocation_state_test.rb` — exit 1,
   6 runs, 0 assertions, 0 failures, 6 errors. All errors are the known stale
   Ruby API contract (`Onibi::ExecutionState`, `Onibi::InvocationState`, and
   `Onibi::Interpreter` are undefined).
5. `ruby -Ilib .task-55a-logs/ractor_audit.rb` — exit 0; all bounded probes
   completed; expected isolation errors reported; no timeout or harness error.
   Output is in `.task-55a-logs/ractor_audit.out`.
6. `set +e; ruby -Ilib .task-55a-logs/ractor_audit.rb --harness-timeout; echo $?`
   — exit 1 through the normal rejection classifier. The parent killed and
   reaped the injected sleeping child (`child_reaped: true`, about 2015 ms).
7. `set +e; ruby -Ilib .task-55a-logs/ractor_audit.rb --harness-unexpected; echo $?`
   — exit 1 through the normal rejection classifier. The parent reaped the
   injected failing child (`child_exit: 20`, `child_reaped: true`).
8. `set +e; ruby -Ilib .task-55a-logs/ractor_audit.rb --harness-closed-pipes; echo $?`
   — exit 1 through the normal timeout rejection classifier. The child closed
   both pipes and slept; the parent killed and reaped it in about 2015 ms.
9. `git diff --check` — exit 0.
10. Final `(cd ext/onibi && make distclean)` — exit 0. The generated extension
   and Makefile were removed.

The native representative probe is in
`.task-55a-logs/native_representatives.out`: 3/3 native matches, one each for
REGULAR, TAGGED, and DYNAMIC, with fallback count zero. The two harness checks
left no matching child process after parent reap.

No production files were changed.
