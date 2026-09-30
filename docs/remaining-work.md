# Remaining gem PoC work

Snapshot: 2026-09-27, source `9460fc93`.
This list covers the MRI-only gem PoC.
It does not authorize MRI source changes, FFI, another engine, or ZJIT work.
The execution ledger records accepted work. This list records the remaining queue.

## Current result

The three native C interpreters exist.
Native MatchData, public match routing, scan blocks, and gsub paths have accepted implementation units.
AST arena growth, brace grammar, and escape cursor repairs are accepted through TASK-42C21B.
Do not repeat those implementation units.

The remaining confirmed escape defects are one-digit hex decoding and decoded-run quantifier binding.
Four audited meta/binary cases use explicit fallback. They are not four proven native defects.
The accepted MatchData method list includes `match` and `values_at`.
The current C registration has neither method. TASK-API01 must confirm this with a live probe.
Older reports record match-reset and error-encoding gaps. Reproduce them before repair.
Ractor support remains unaccepted. Several current-status documents still describe the older implementation.

This is a list of known work and required checks, not a claim that no other defect exists.
TASK-BASE01 identifies additional failures. TASK-BASE02 converts them into bounded tasks.

## Authority and execution rules

Read `AGENTS.md`, `docs/gir.md`, and the applicable ledger entry first.
GIR sections 58–59 define the accepted gem MatchData boundary.
GIR section 133.1 defines the eight PoC completion conditions.
The old blocked RMatch transfer requirement does not block the custom gem implementation.
Exact MRI object identity and caller-local VM backreferences remain outside this gem contract.

Run one relay implementation worker at a time.
The root prepares a frozen packet before each dispatch.
The packet supplies the exact commit, branch, workspace, owned files, commands, and evidence directory.
A task card below is not permission to edit every listed source file.
For an audit, read those files and change only external evidence.
For a repair, the root fixes the owned files after the audit is accepted.

Use `gpt-6-luna` with `max` effort for unresolved semantics, encoding, ordering, or ownership.
Use `gpt-6-luna` with `high` effort for settled documentation, signatures, or packaging tasks.
Record model and effort separately. Preserve the route during corrections.
The root reviews source and logs, then commits each accepted unit.
Record READY_FOR_REVIEW, ACCEPTED, COMMITTED, and INTEGRATED separately.
Only an accepted source state releases a dependent task.

At dispatch and acceptance, read account limits.
Reserve review capacity near 80% use. Start no new task near 90% use.
Save one exact next action. A saved queue does not configure an automatic restart.

## Common setup and checks

Use these process-local settings on the current Apple arm64 host:

```sh
export PATH=/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:/usr/bin:/bin
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export BUNDLE_IGNORE_CONFIG=true
export BUNDLE_PATH=/tmp/onibi-bench-gem
export BUNDLE_FROZEN=true
ruby -v
bundle --version
clang --version
bundle check
```

The verified runtime is MRI 4.0.6. Bundler is 4.0.16. Apple clang is 21.0.0.
The default Xcode selection has an unset license. Use the settings above for Python and Git too.
Do not change machine settings. On another host, verify an equivalent MRI toolchain before editing.

Build from the repository root:

```sh
(cd ext/onibi && ruby extconf.rb && make)
```

Confirm compiler warning flags in the generated Makefile.
The current build has two known warnings in unchanged `gir.c` and `rseq.c`.
For a test file listed below, run:

```sh
ruby -Ilib -Itest test/features/AREA/FILE_test.rb
```

Run changed-file checks. Replace each placeholder with the actual changed paths:

```sh
bundle exec rubocop --force-exclusion CHANGED_RUBY_FILES
clang-format --dry-run --Werror CHANGED_C_FILES
ruby -c CHANGED_RUBY_FILE
git diff --check
(cd ext/onibi && make distclean)
```

Do not run an empty changed-file command.
TASK-API04 must inspect installed RBS tooling and record its exact validation command.
Do not install RBS solely for unrelated tasks.
Read `docs/development.md` and `Rakefile` again when preparing each packet.
They control the current commands if this snapshot becomes stale.

For semantic tasks, first save a small MRI comparison and an exact-source Onibi failure.
Record pattern bytes, subject bytes, encodings, options, errors, and raw capture ranges.
Require native execution and zero fallback for behavior claimed as supported.
For negative tests, require the exact expected exception. Do not count an unexpected exception as a pass.
Bound subprocess lifetimes, drain both output streams, and kill and reap on timeout.

Save full logs outside the repository. Keep one acceptance manifest per attempt.
Record argv, working directory, environment, exit status, totals, and source/build hashes.
Every repair needs a regression test. Every audit needs a runnable probe and a conclusion with limits.
Do not weaken correct tests or silently change the accepted subset to make checks pass.

## Queue

`Ready` means the dependency is accepted. It does not mean a worker has started.
`Waiting` means another task must finish first.
`Assigned` means the root owns an active relay packet for that task.
`Accepted` means root review passed; the ledger records commit and integration evidence.
`Conditional` means an accepted audit must prove the need and fix the repair scope.

| Order | Task | State | Dependency | Result |
| --- | --- | --- | --- | --- |
| 1 | TASK-42C22 | Accepted | C21B | One-digit hex literals match MRI. |
| 2 | TASK-42C23A | Accepted | C22 | A frozen decoded-run atom contract. |
| 3 | TASK-42C23B | Accepted | C23A | Quantifiers apply to the correct decoded character. |
| 4 | TASK-API01 | Accepted | C21B | A measured public method inventory. |
| 5 | TASK-API02 | Accepted | API01 | Native MatchData `match` accessor. |
| 6 | TASK-API03 | Accepted | API01 | Native MatchData `values_at` accessor. |
| 7 | TASK-API04 | Accepted | API02, API03 | RBS agrees with the accepted API. |
| 8 | TASK-42C24 | Accepted | C23B | Four escape fallback cases have exact support classifications. |
| 9 | TASK-42C25A | Accepted | C21B | Current match-reset failure and MRI matrix. |
| 10 | TASK-42C25B | Accepted | C25A | The measured native match-reset gap is repaired. |
| 11 | TASK-42C26A | Accepted | C18B | Current named-group error encoding matrix. |
| 12 | TASK-42C26B | Accepted | C26A | The measured named-group error encoding gap is repaired. |
| 13 | TASK-DOC01 | Accepted | API04, C24, C25A, C26A | Current docs and parent statuses agree with accepted evidence. |
| 14 | TASK-API05 | Accepted | API04, DOC01 | Public routing and caller boundaries pass a final audit. |
| 15 | TASK-SAFE01 | Accepted | C21B | Unicode helper exception ownership is measured. |
| 16 | TASK-SAFE02 | Accepted | SAFE01 | The measured helper cleanup defect is repaired. |
| 17 | TASK-SAFE03 | Accepted | C21B | Native nested-call and invocation-state checks. |
| 18 | TASK-SAFE04 | Accepted | API05, SAFE03 | Final GC and abandoned-call lifetime evidence. |
| 19 | TASK-SAFE05 | Accepted | SAFE03 | Final timeout and interrupt evidence. |
| 20 | TASK-RAC01 | Ready | API05, SAFE04, SAFE05 | Final Ractor audit with explicit support limits. |
| 21 | TASK-BASE01 | Waiting | All earlier repairs resolved | One current failure census. |
| 22 | TASK-BASE02 | Waiting | BASE01 | Every remaining in-scope failure has a bounded task. |
| 23 | TASK-CI01 | Waiting | BASE02 and its blocking repairs | Reproducible gem acceptance checks in CI. |
| 24 | TASK-PKG01 | Waiting | CI01 | A clean installed gem passes smoke checks. |
| 25 | TASK-POC01 | Waiting | RAC01, CI01, PKG01 | Evidence for all eight PoC conditions. |
| 26 | TASK-REL01 | Waiting | POC01 | Reviewed PR, passing required checks, and integration record. |

Follow this order by default. If a conditional repair is unnecessary, record the proof and close it without code changes.
Do not dispatch a placeholder repair before its audit defines the acceptance decision.

## Task cards

### TASK-42C22 — One-digit hex decoding

Read `token.c:onibi_token_scan_escape` and `test/features/syntax/escape_cursor_test.rb`.
Use the three one-digit failures in the accepted C21A matrix.
Freeze `\xH`, `\xHH`, a non-hex suffix, a group suffix, a quantifier suffix, and end-of-source cases.
Keep encoded byte runs and one-digit forms distinct. Test literals inside and outside classes.
Own `ext/onibi/token.c` and a focused syntax test.
Do not change decoded-run quantifier binding in this task.
Run the new test, escape cursor, brace grammar, and fixed-interval suffix tests.
Done: MRI ranges and errors agree; supported rows use native RSeq; cursor bounds remain valid.

Check files: `test/features/syntax/escape_cursor_test.rb`, `brace_grammar_test.rb`, and `fixed_interval_optional_suffix_test.rb` in the same directory.

### TASK-42C23A — Decoded-run atom contract

Read the C21A two-row repeat finding and the hex/octal run loops in `token.c`.
Compare ASCII runs, one encoded character, multiple encoded characters, and mixed literal/escaped forms.
Test `?`, `*`, `+`, and bounded repeats with captures that expose the repeated atom.
Use UTF-8, Windows-31J, and EUC-JP bytes. Add binary controls only when MRI accepts them.
Produce a matrix and one proposed C token/AST representation. State allocation ownership and cursor rules.
Done: each input has an exact MRI atom boundary; a repair packet can name the owned symbols.
No production edit belongs to this audit.

### TASK-42C23B — Decoded-run repetition

Implement only the accepted C23A representation and matrix.
Candidate files are `token.c`, `parser.c`, and their directly required internal token/AST declarations.
The packet must narrow this set before edits. Keep multibyte characters intact.
Add a focused test for native raw ranges and captures.
Run that test, escape cursor, brace grammar, fixed-interval suffix, and encoding descriptor tests.
Done: both original repeat failures and the accepted encoded matrix pass without fallback.

Check files: `test/features/syntax/escape_cursor_test.rb`, `brace_grammar_test.rb`, `fixed_interval_optional_suffix_test.rb`; `test/features/encoding/encoding_class_descriptor_test.rb`.

### TASK-API01 — Public method inventory

Read GIR 58–59, the B1 public method table, `onibi_init.c`, `match_data.c`, and `sig/onibi.rbs`.
Compare live public methods with the accepted list. Check `match` and `values_at` first.
Probe MRI coercion, nil/omitted arguments, names, duplicate names, ranges, and error messages for missing methods.
Produce one table: implemented, missing required method, explicit limitation, or later MRI integration.
Run the existing MatchData numeric and named tests as the baseline.
Done: API02 and API03 have frozen MRI cases; every other discrepancy has a disposition.

Check files: `test/features/captures/match_data_numeric_test.rb` and `match_data_named_test.rb` in the same directory.

### TASK-API02 — MatchData `match`

Use API01's accepted selector and coercion matrix.
Own `match_data.c`, the required private declarations, C method registration, and a focused capture test.
Read the existing selector helper before adding another conversion path.
Return strings from the native snapshot. Never rerun MRI for a supported result.
Run the new test plus numeric, named, and payload MatchData tests.
Done: MRI values, encodings, errors, and coercion order agree.

Check files: `test/features/captures/match_data_numeric_test.rb`, `match_data_named_test.rb`, and `match_data_payload_test.rb`.

### TASK-API03 — MatchData `values_at`

Use API01's accepted integer/range/name/coercion matrix.
Keep out-of-range, unmatched, empty, negative, and oversized selectors distinct.
Own the same API layer as API02, but use a separate commit and test.
Run the new test plus numeric, named, and value-semantics MatchData tests.
Done: each result array agrees with MRI and contains values from the native snapshot.

Check files: `test/features/captures/match_data_numeric_test.rb`, `match_data_named_test.rb`, and `match_data_value_semantics_test.rb`.

### TASK-API04 — RBS API signatures

Compare `sig/onibi.rbs` with the accepted API inventory and C arities.
Include native/fallback result types, `match` block returns, gsub Hash replacements, and omitted-replacement Enumerators.
Preserve documented coercion rather than narrowing signatures to convenience types.
Own the RBS file and its focused signature checks only.
Use the repository's installed type tooling. Record a missing tool as a prerequisite, not a semantic pass.
Done: signature parsing and a small usage sample pass; every signature maps to a measured API method.

### TASK-42C24 — Escape fallback classification

Re-run the four unsupported C21A rows after C22 and C23B.
Inspect typed compile/runtime reasons. Distinguish unsupported syntax from input ineligibility.
Use meta escapes and high-byte binary literals from the saved matrix, not invented substitutes.
Run `test/features/engine/runtime_outcome_test.rb`.
Done: each row has a precise reason and a contract reference.
If support is required by the accepted subset, create a separate bounded repair through BASE02.
Do not silently claim native support or enable a new decoder in this audit.

### TASK-42C25A — Match-reset audit

Read `test/features/matching/match_reset_test.rb`, `exec_dynamic.c`, and the C4/C5 evidence notes.
Reproduce the recorded multibyte `\K` gap on current source.
Compare group zero, captures, byte ranges, character offsets, `=~`, and `~` with MRI.
Include empty matches and successful/failed alternatives.
Done: one current minimal failure, native proof, source boundary, and frozen repair matrix, or proof that the gap is closed.

### TASK-42C25B — Match-reset repair

Use C25A's accepted invariant and exact source owner.
Do not patch Ruby character conversion to conceal wrong native byte ranges.
Run match-reset, native match-operator, native tilde, and MatchData character-offset tests.
Done: all accepted rows agree with MRI; raw and public offsets agree; no fallback hides the repair.

Check files: `test/features/matching/match_reset_test.rb`; `test/features/api/native_match_operator_test.rb` and `native_tilde_test.rb`; `test/features/captures/match_data_character_offsets_test.rb`.

### TASK-42C26A — Named-group error encodings

Read C18B evidence and `test/features/syntax/encoded_capture_name_test.rb`.
Reproduce invalid-name error message bytes and encoding in supported encodings.
Keep error class, text bytes, encoding, and timing as separate columns.
Done: prove whether the older recorded gap still exists and define its exact repair boundary.
Do not reopen accepted valid-name canonical identity without a new failure.

### TASK-42C26B — Named-group error repair

Change only the error construction path accepted in C26A.
Preserve valid-name hashing, equality, capture indices, and native replacement lookup.
Run encoded capture-name and named-replacement tests selected from the accepted C18B evidence.
Done: invalid cases and the valid-name controls match MRI.

### TASK-DOC01 — Current contract and status

Own `README.md`, `docs/development.md`, `docs/README.md`, and current parent rows in `docs/execution-ledger.md`.
Keep historical acceptance evidence intact. Mark superseded status text instead of erasing history.
Replace the obsolete MRI MatchData adapter description with the accepted custom-object contract.
State the declared API subset, explicit fallback, String caller limits, backreference limits, and Ractor status.
Reconcile TASK-42, TASK-42B, and TASK-55 dependencies with accepted child evidence.
Done: no current section claims the extension loader is absent or native MatchData implementation is still wholly pending.

### TASK-API05 — Public routing and caller gate

Run native match routing, case equality, tilde, match-operator, backreference-boundary, and String caller tests.
Also run scan block, gsub mutation, Hash, replacement encoding, and Enumerator tests.
Inspect the supported path for MRI rematching. Use explicit MRI-call guards with fallback controls.
Keep MRI object identity and caller-local VM backreferences outside the gem contract.
Done: required public methods pass; String caller limits are explicit; no supported result is repaired by MRI.
Do not add String adapters without a separately accepted scope decision.

Check files: `test/features/api/native_match_routing_test.rb`, `native_case_equality_test.rb`, `native_tilde_test.rb`, `native_match_operator_test.rb`, `backreference_boundary_audit_test.rb`, and `string_caller_boundary_audit_test.rb`; `test/features/matching/scan_block_test.rb`, `gsub_mutation_test.rb`, `gsub_hash_test.rb`, `gsub_replacement_encoding_test.rb`, and `gsub_enumerator_test.rb`.

### TASK-SAFE01 — Unicode helper cleanup audit

Read `unicode.c:onibi_grapheme_width` and the C2 helper warning.
Trace backreference save/restore through success and exceptions.
Prove public reachability separately from a copied-build diagnostic probe.
Done: exact ownership finding and a bounded repair packet, or evidence that no repair is needed.
Native grapheme enablement is not part of this task.

### TASK-SAFE02 — Unicode cleanup repair

Use SAFE01's accepted error and non-local-exit cases.
Own only the helper and focused cleanup test fixed in the packet.
Restore prior MRI state on every required exit. Do not enable grapheme support as a side effect.
Done: success and raised-exception controls preserve state; native/fallback boundaries stay explicit.

### TASK-SAFE03 — Native invocation-state checks

Inspect `test/features/engine/invocation_state_test.rb` and the old removed-Ruby-internal failures in TASK-55A.
Replace obsolete test entry points with current public or documented native diagnostics.
Exercise nested matches, exceptions, Fiber suspension, and thread isolation with distinct values.
Do not weaken valid state-isolation assertions. Production defects get separate repair tasks.
Run invocation-state, semantic-state, and runtime-outcome tests.
Done: tests exercise the C engine and report no unexplained state leakage.

Check files: `test/features/engine/invocation_state_test.rb`, `semantic_state_test.rb`, and `runtime_outcome_test.rb`.

### TASK-SAFE04 — GC and abandoned-call gate

Read accepted payload and C16B ownership evidence before adding probes.
Run MatchData payload/copy tests and scan/gsub ownership tests on final source.
Check GC compaction, abandoned Fiber/Enumerator calls, live suspensions, and prompt normal cleanup.
Use allocation ownership evidence for native heap claims. Object collection alone is not proof of heap reclamation.
Done: no double free, stale pointer, or unexplained retained allocation in the bounded matrix.
Any defect gets its own owner and repair packet.

Check files: `test/features/captures/match_data_payload_test.rb` and `match_data_copy_deconstruct_test.rb`; the exact C16B ownership test paths from its accepted evidence.

### TASK-SAFE05 — Timeout and interrupt gate

Read `test/features/engine/work_budget_poll_test.rb` and the accepted TASK-34 contract.
Check all three execution classes, nested calls, timeout errors, and external interruption.
Bound the complete subprocess lifetime and prove the harness kills and reaps a hung child.
Run compiler exception-safety checks for cleanup across errors.
Done: each expected interruption occurs, cleanup completes, and a subsequent match still works.

Check files: `test/features/engine/work_budget_poll_test.rb` and `test/features/quality/compiler_exception_safety_test.rb`.

### TASK-RAC01 — Final Ractor boundary audit

Re-run TASK-55A's retained-graph and child-Ractor checks after the custom MatchData changes.
Inspect regexp, MatchData, lazy offsets, metadata, timeout state, and thread-local execution context.
Test match and scan separately. Verify an unsupported call fails explicitly rather than crashing.
Do not set shareability or Ractor-safe flags during an audit.
Done: TASK-55 has a current support decision and evidence for its declared boundary.
If native Ractor support is required, split graph ownership, state policy, and callable safety into separate approved units.

### TASK-BASE01 — Current failure census

Run `bundle exec rake test` once with a bounded full log after the required repairs.
Also run `bundle exec rubocop` once. Preserve exact test names and failure messages.
Group failures into supported-semantic defects, obsolete contracts, explicit unsupported features, and environment failures.
Use exact-source MRI probes for every proposed semantic classification.
Done: each failure has an evidence link and owner category. An unexplained failure remains open.
The complete legacy suite is not automatically a gem PoC semantic gate.

### TASK-BASE02 — Split census findings

Create one task per independent invariant from BASE01.
Each task must name its reproduction, owned symbols, dependencies, MRI cases, checks, and done condition.
Do not bundle unrelated engine fixes or create one task per trivial edit.
Add only in-scope blockers to the PoC queue. Preserve excluded cases and their reasons.
Done: no unexplained supported-subset failure lacks a bounded task.
Complete those tasks before CI01. The final queue can therefore exceed these 26 initial cards.

### TASK-CI01 — Acceptance suite and CI

Read `Rakefile`, `docs/development.md`, and `.github/workflows/main.yml`.
Define a reproducible focused gem acceptance command from accepted feature tests.
Keep legacy coverage visible. Do not remove a correct failing assertion to obtain green CI.
Make CI distinguish the declared gem gate from legacy or later MRI integration checks.
Run the local gate, changed-file lint, and workflow validation available in the repository.
Done: the same source and command produce the same acceptance result locally and in CI.

### TASK-PKG01 — Installed gem smoke check

Run `bundle exec rake build`.
Install the produced gem into a temporary GEM_HOME with an isolated GEM_PATH.
Do not rely on a checkout load path. Record the gem hash and loaded extension path.
Check load, constructor, native match, MatchData access, scan, gsub, explicit fallback, and one error.
Done: the installed artifact passes the declared smoke cases on supported MRI.
Keep the artifact and logs outside committed product documentation.

### TASK-POC01 — Completion evidence

Map each of GIR 133.1's eight conditions to a passing command or accepted evidence artifact.
List every explicit unsupported feature and verify that it fails or falls back as documented.
Check that no supported-subset mismatch remains open.
Do not equate an accepted worker report with an accepted root review.
Done: all eight rows have verified evidence and no unexplained blocker.
Otherwise, return the exact missing task to the queue.

### TASK-REL01 — PR and integration

The root owns this task. Inspect existing draft PR #421 and its current branch before publication.
Use atomic commits, inspect final diffs, and retain hook output.
Publish the intended commits only after local acceptance and the current publication scope are clear.
Wait for all required CI checks. Resolve failures in separate bounded units.
Do not merge or enable auto-merge while the PR is draft.
Done: required checks pass, the PR is ready under the user's instructions, and integration state is recorded.
If publication is not authorized, record that exact remaining action instead of claiming remote integration.

## Later work outside this queue

GIR 133.2 covers full MRI replacement: VM backreferences, RMatch transfer, MRI/Ruby Spec suites, and ZJIT.
It also covers replacement-level Ractor, sanitizer, code-cache, and performance gates.
Those requirements do not authorize MRI source dependencies during this gem PoC.
Do not report the gem PoC as a complete MRI replacement.

## Evidence locations

The latest accepted source is recorded in `docs/execution-ledger.md`.
The current relay root is:

`/Users/masa/.codex/relay/01a0e063-df14-7243-a0a6-56dc68a1d838/`

C21A contains the frozen escape audit. C21B contains the cursor repair evidence.
Packets and checkpoints remain outside the repository. Repository task cards must remain readable without those local paths.
A new worker receives exact artifact paths and an immutable packet when dispatched.

## API01 follow-up findings (2026-09-28)

Track binary `MatchData#names` string encoding as a bounded gem follow-up.
The accepted design has no exclusion for this difference. API04 corrected the symbol-key report: API01 serialization converted keys to strings. Native keyword behavior matches MRI for both checked ASCII fixtures.
API02 and API03 use the corrected method-specific selector rules in `docs/task-42b1-matchdata-design.md`.

C25B follow-up: audit fallback `~` with `\K`; its unchanged path reads group-zero start. Native repair does not establish fallback parity.
