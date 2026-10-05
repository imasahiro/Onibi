# Remaining gem PoC work

Snapshot: 2026-09-30, source `fc6b1b6a`.
This list covers the MRI-only gem PoC.
It does not authorize MRI source changes, FFI, another engine, or ZJIT work.
The execution ledger records accepted work. This list records the remaining queue.

## Current result

The three native C interpreters exist.
Native MatchData, public match routing, scan blocks, and gsub paths have accepted implementation units.
AST arena growth, brace grammar, and escape cursor repairs are accepted through TASK-42C21B.
Do not repeat those implementation units.

The queue records accepted escape, MatchData API, operator, error-encoding, and safety work below.
Do not reopen those units without new evidence.
RAC01 confirms the main-Ractor-only boundary. Child-Ractor support remains excluded.

The accepted BASE01 census has 52 failure rows: 43 supported defects, one explicit limit,
one obsolete expectation, and seven open scope rows.
Cases 2, 13, and 46 share an accepted capture-numbering repair. Cases 21–45 need an audit before repair.
Case 17 has an explicit 256-level limit. Its exact error text remains a decision.
Case 49 expects native MRI backreference state. GIR 58 excludes it; keep the failure visible.
BASE01 also records 70 lint findings across seven test files. TASK-BASE02 maps them separately.

This list records known work and required checks. It does not claim that no other defect exists.
TASK-BASE02 maps every census row to repair, audit, decision, or contract closure.

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
The latest user instruction permits sequential work until either allowance has less than 1% remaining.
Save one exact next action. A saved queue does not configure an automatic restart.

## Common setup and checks

Use these process-local settings on the current Apple arm64 host:

```sh
export PATH=/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:/usr/bin:/bin
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export BUNDLE_IGNORE_CONFIG=true
export CC=/opt/homebrew/opt/llvm@21/bin/clang
export BUNDLE_FROZEN=true
ruby -v
bundle --version
"$CC" --version
bundle check
```

The verified runtime is MRI 4.0.6. Bundler is 4.0.16. Homebrew clang is 21.1.8.
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
| 20 | TASK-RAC01 | Accepted | API05, SAFE04, SAFE05 | Final Ractor audit with explicit support limits. |
| 21 | TASK-BASE01 | Accepted | All earlier repairs resolved | One current failure census. |
| 22 | TASK-BASE02 | Accepted | BASE01 | Every remaining in-scope failure has a bounded task. |
| 23 | TASK-BASE02-CALL-CAPTURE-COUNT | Accepted | BASE02 | Nullable calls return the MRI-visible capture count. |
| 24 | TASK-BASE02-NAMED-CAPTURE-PROJECTION | Accepted | BASE02 | Numbered captures follow the named-capture view. |
| 25 | TASK-BASE02-MATCHDATA-SLICE | Accepted | BASE02 | MatchData slices use MRI selector rules. |
| 26 | TASK-BASE02-BACKREF-FOLD | Split | BASE02 | Case-folded backreferences follow MRI. |
| 26a | TASK-BASE02-FOLD-END-AUDIT | Accepted | BACKREF-FOLD case 3 | Audit the remaining case 5 end-anchor mismatch. |
| 26b | TASK-BASE02-FOLD-END-REPAIR | Accepted | FOLD-END-AUDIT | Preserve MRI absolute-end candidate-start bounds. |
| 26c | TASK-BASE02-FOLD-END-WRAPPER | Accepted | FOLD-END-REPAIR | Resolve the retained scoped-wrapper mismatch. |
| 26d | TASK-BASE02-FOLD-END-NESTED-RESTORE | Waiting | FOLD-END-WRAPPER | Prove the retained nested-option form with an extra literal. |
| 27 | TASK-BASE02-ASSERTION-GREEDY | Accepted | BASE02 | A greedy dot respects terminal assertion priority. |
| 28 | TASK-BASE02-CLASS-RANGE | Accepted | BASE02 | The access-log class compiles and matches MRI. |
| 29 | TASK-BASE02-REVERSE-FOLD | Accepted | BASE02 | Reverse Unicode folds preserve native and fallback routes. |
| 30 | TASK-BASE02-UNICODE-CLASS-FOLD | Waiting | BASE02 | Ignore-case range closure follows MRI encoding folds. |
| 31 | TASK-BASE02-ABSENCE-AUDIT | Waiting | BASE02 | The 25 absence failures have a bounded root-cause map. |
| 32 | TASK-BASE02-INLINE-M | Waiting | BASE02 | Inline multiline changes stay inside their scopes. |
| 33 | TASK-BASE02-LINE-ANCHOR | Waiting | BASE02 | Line-start behavior matches MRI after a final newline. |
| 34 | TASK-BASE02-STACKED-QUANTIFIER-SCOPE | Waiting | BASE02 | Decide whether stacked quantifiers are in the PoC subset. |
| 35 | TASK-BASE02-PATTERN-COMMENT-SCOPE | Waiting | BASE02 | Decide whether pattern comments are in the PoC subset. |
| 36 | TASK-BASE02-CLASS-SUBTRACTION-SCOPE | Waiting | BASE02 | Decide whether nested class subtraction is in scope. |
| 37 | TASK-BASE02-OCTAL-SCOPE | Waiting | BASE02 | Decide the scope of octal and backreference disambiguation. |
| 38 | TASK-BASE02-NONASCII-ENCODING-SCOPE | Waiting | BASE02 | Decide the scope of non-ASCII-compatible pattern encodings. |
| 39 | TASK-BASE02-DEPTH-ERROR-DECISION | Waiting | BASE02 | Decide whether nesting-limit error text is an API promise. |
| 40 | TASK-BASE02-LINT-HYGIENE | Waiting | BASE02 | Map and resolve 70 test-source lint findings safely. |
| 41 | TASK-CI01 | Waiting | BASE02, blocking cards, and absence follow-up repairs | Reproducible gem acceptance checks in CI. |
| 42 | TASK-PKG01 | Waiting | CI01 | A clean installed gem passes smoke checks. |
| 43 | TASK-POC01 | Waiting | RAC01, CI01, PKG01 | Evidence for all eight PoC conditions. |
| 44 | TASK-REL01 | Waiting | POC01 | Reviewed PR, passing required checks, and integration record. |

The queue has 47 tasks. BASE02 adds 18 bounded cards before CI01.
The absence audit may add repair cards before CI01.
Follow this order by default. Close an unnecessary repair with evidence and no code change.
Do not dispatch an absence repair before its audit defines the cause.

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

Map every BASE01 row to one primary card. Each card names its reproduction, candidate C symbols,
dependencies, MRI cases, focused checks, and done condition.
Keep cases 2, 13, and 46 in separate cards. Do not merge independent capture failures.
Keep the 25 absence cases in one bounded audit. Define repair cards after root-cause review.
Keep the seven scope cases open unless current contract text resolves them.
Keep case 17's exact error text as a decision. Close case 49 by the current MRI backreference boundary.
Map all 70 lint findings to one separate hygiene card. Do not change test meaning to clear lint.
Add only in-scope blockers and unresolved decisions before CI01.
Done: every row has one primary disposition and evidence link. No supported mismatch lacks a bounded task.
The census map and evidence live outside the repository. The cards below remain readable without them.

| Census row(s) | Primary card | Action |
| --- | --- | --- |
| 1 | BASE02-STACKED-QUANTIFIER-SCOPE | Decide scope |
| 2 | BASE02-CALL-CAPTURE-COUNT | Repair |
| 3, 5 | BASE02-BACKREF-FOLD | Repair |
| 4 | BASE02-ASSERTION-GREEDY | Repair |
| 6, 7 | BASE02-CLASS-RANGE | Repair |
| 8, 9 | BASE02-PATTERN-COMMENT-SCOPE | Decide scope |
| 10, 11, 12, 18, 19, 20 | BASE02-REVERSE-FOLD | Repair with route limits |
| 13 | BASE02-NAMED-CAPTURE-PROJECTION | Repair |
| 14 | BASE02-CLASS-SUBTRACTION-SCOPE | Decide scope |
| 15 | BASE02-UNICODE-CLASS-FOLD | Repair |
| 16 | BASE02-OCTAL-SCOPE | Decide scope |
| 17 | BASE02-DEPTH-ERROR-DECISION | Decide API text |
| 21–45 | BASE02-ABSENCE-AUDIT | Audit, then split repairs |
| 46 | BASE02-MATCHDATA-SLICE | Repair |
| 47, 48 | BASE02-INLINE-M | Repair |
| 49 | BASE02-EXCLUDED-49 | Contract closure; no queue item |
| 50 | BASE02-LINE-ANCHOR | Repair |
| 51, 52 | BASE02-NONASCII-ENCODING-SCOPE | Decide scope |
| Lint 1–70 | BASE02-LINT-HYGIENE | Separate test-source hygiene |

BASE01 used census source `ed681b17`. This task uses source `fc6b1b6a`.
All 52 census test-source hashes match the current test files.
The original frozen-input bytes are missing. BASE01 correction records eight old hash mismatches.
Use current test sources, recorded commands and logs, and current MRI controls.
Do not claim complete historical input provenance.

Case 19 has ten `reverse-alternation` rows on explicit `input_ineligible` MRI fallback.
Those ten rows are not native implementation defects.
`reverse-alternation-11` reaches native DYNAMIC with zero fallback and returns a wrong match.
Keep that distinction in the repair scope.

Case 49 is `RegexpUtilityTest#test_last_match_matches_mri_and_match_question_does_not_change_it`.
GIR 58 and `docs/development.md` exclude native MRI backreference updates.
Keep its legacy failure visible. Do not add a repair unless the contract changes.

The exact case and lint rows are in the immutable BASE02 `mapping-01.json` evidence.

### TASK-BASE02-CALL-CAPTURE-COUNT — Nullable call captures

Cases: `#2`. Reproduce `DynamicDifferentialTest#test_named_subprogram_variants_keep_nullable_call_context`.
Candidate C owners: `ext/onibi/compiler.c:onibi_resolve_capture_numbers`,
`ext/onibi/compiler.c:onibi_resolve_semantic_node`, `ext/onibi/exec_dynamic.c:onibi_rseq_dynamic_run`,
and `ext/onibi/match_data.c:onibi_matchdata_to_a`.
Dependency: accepted BASE02 mapping. Keep raw capture registers and MRI-visible indexing separate.
Run the existing E2E method. Compare all patterns, subjects, values, and byte ranges with MRI 4.0.6.
Record the DYNAMIC route and require zero fallback for the claimed native result.
Done: every visible capture matches MRI, and the nullable call adds no unnamed capture.

### TASK-BASE02-NAMED-CAPTURE-PROJECTION — Numbered capture view

Case: `#13`. Reproduce `RegexpConstructorTest#test_named_capture_numbers_hide_unnamed_groups_like_mri`.
Candidate C owners: `ext/onibi/compiler.c:onibi_resolve_capture_numbers` and
`ext/onibi/match_data.c:onibi_matchdata_capture_array`, `onibi_matchdata_to_a`,
and `onibi_matchdata_named_capture_index`.
Dependency: accepted BASE02 mapping. Keep raw capture registers in their current order.
Run the existing E2E method. Compare `to_a`, `captures`, named lookup, and byte ranges with MRI 4.0.6.
Record the REGULAR_FAST route and require zero fallback for the native result.
Done: numbered and named accessors expose the same captures as MRI.

### TASK-BASE02-MATCHDATA-SLICE — MatchData slice selectors

Case: `#46`. Reproduce `MatchDataIndexTest#test_match_value_access_supports_mri_slice_form`.
Candidate owners: `ext/onibi/match_data.c:onibi_matchdata_aref`,
`ext/onibi/match_data.c:onibi_matchdata_capture_array`,
and `sig/onibi.rbs:MatchData#[]`.
Dependency: accepted BASE02 mapping. Preserve the accepted selector rules for every accessor.
Run the existing E2E method. Compare selector `[0, 2]`, values, and byte ranges with MRI 4.0.6.
Record the REGULAR_FAST route and require zero fallback for the native result.
Done: slice selection returns the same capture values and ranges as MRI.

### TASK-BASE02-BACKREF-FOLD — Case-folded backreferences

Cases: `#3, #5`. Reproduce `QuantifierModeTest#test_casefold_backreference_keeps_mri_direction`
and `QuantifierModeTest#test_casefold_backreference_does_not_cross_absolute_end`.
Candidate C owners: `ext/onibi/exec_dynamic.c:onibi_rseq_casefold_span_equal`,
`ext/onibi/exec_dynamic.c:onibi_rseq_backref_consume`,
and `ext/onibi/compiler.c:onibi_compile_backref_descriptor`.
Dependency: accepted BASE02 mapping. Use MRI encoding folds and keep capture spans byte-based.
Run both existing E2E methods. Compare patterns, subjects, captures, and ranges with MRI 4.0.6.
Record DYNAMIC diagnostics. Require native execution and zero fallback for both cases.
Done: both directions and absolute-end behavior match MRI.

### TASK-BASE02-FOLD-END-AUDIT — Case 5 end-anchor audit

Case 3 is accepted under BACKREF-FOLD. Case 5 remains open.
The captured-byte lower bound fixes case 3 without changing anchor behavior.
Audit case 5 with literal, capture and backreference forms, plus ASCII and multibyte controls.
Compare exact MRI results and native search-start ranges. Keep explicit fallback routes separate.
Source candidates: `ext/onibi/exec_dynamic.c`, compiler search metadata, and public search dispatch.
Do not edit production code. Determine the cause before selecting repair owners.
Done: the mismatch has a reproducible cause and a bounded repair proposal, or a precise remaining question.
Evidence starts at `task-backref-fold-01/worker/pre-edit/scope-case5-anchor-01` in the relay record.

### TASK-BASE02-FOLD-END-REPAIR — Absolute-end candidate bounds

Case 5 remains open. The audit traces MRI's candidate-start bound from compiled byte widths.
Implement the proven absolute-end bound in native compiler metadata and public search.
Review finite/unknown widths, anchor precedence, character boundaries and overflow before edits.
Keep the end assertion and backreference consumer unchanged.
Own only the required compiler, RSeq header/serialization/validation and search paths.
Use MRI differential E2E for fold direction, wrappers, branches, finite/unbounded repeats and nonzero starts.
Preserve explicit fallback controls. Do not apply a guessed finite bound to unknown widths.
Done: case 5 and the frozen supported controls agree with MRI without native fallback substitution.

### TASK-BASE02-FOLD-END-WRAPPER — Scoped end-bound form

The narrow numeric and named case 5 forms and `scoped_wrapper` are accepted.
The 12-row wrapper matrix passes on native DYNAMIC with zero fallback.
Reuse the immutable 17-row matrix and exact MRI/native results from FOLD-END-REPAIR.
Inspect effective option scope and wrapper transparency before extending compiler eligibility.
Candidate owner: `ext/onibi/compiler.c` source-byte analysis. Do not change executor end assertions.
Freeze tests before C edits. Preserve disabled options, nested scope restoration and anchor precedence.
Done: the scoped form and bounded controls match MRI on native routes; unrelated unknown forms stay explicit.

### TASK-BASE02-FOLD-END-NESTED-RESTORE — Nested option restore

The wrapper audit found a native mismatch in `nested_option_restore` with an extra literal.
Reuse `task-fold-end-wrapper-audit-01/worker/freeze-01/minimal-inputs-01.json` under the saved relay root.
MRI returns nil; Onibi returns a native DYNAMIC match with zero fallback.
Prove the optimizer bound and option restoration before extending compiler eligibility.
Keep the accepted narrow wrapper profile unchanged until a test-first proof supports extension.
Done: the retained row and bounded controls match MRI on native routes.

### TASK-BASE02-ASSERTION-GREEDY — Greedy repeat after terminal assertion

Case: `#4`. Reproduce `QuantifierModeTest#test_multiline_greedy_dot_after_terminal_assertion_matches_mri`.
Candidate C owners: `ext/onibi/exec_dynamic.c:onibi_rseq_position_assertion_hit`,
`ext/onibi/exec_dynamic.c:onibi_rseq_dynamic_run`, and `ext/onibi/exec_dynamic.c:onibi_rseq_tagged_run`.
Dependency: accepted BASE02 mapping. Preserve ordered priority across terminal assertions and greedy repeats.
Run the existing E2E method. Compare the match value and byte range with MRI 4.0.6.
Record the execution class. Require native execution and zero fallback for the supported result.
Done: the native result and byte range match MRI.

### TASK-BASE02-CLASS-RANGE — Basic range compilation

Cases: `#6, #7`. Reproduce `MacroBenchmarksTest#test_each_workload_matches_ruby_regexp`
and `MacroBenchmarksTest#test_runner_rejects_differential_mismatch`.
Candidate C owners: `ext/onibi/token.c:onibi_token_scan_class`,
`ext/onibi/parser.c:onibi_c_parse_class_part`, `ext/onibi/parser.c:onibi_c_parse_range`,
and `ext/onibi/compiler.c:onibi_compiler_normalize_class`.
Dependency: accepted BASE02 mapping. Keep class subtraction and other unsupported forms outside this repair.
Run the access-log workload against MRI 4.0.6. Confirm the false adapter raises `DifferentialError`.
Record the class compile route. Require native execution and zero fallback for the workload result.
Done: the access-log captures match MRI, and the differential guard still rejects false results.

### TASK-BASE02-REVERSE-FOLD — Reverse Unicode fold paths

Case 11 is accepted for direct optional singleton ASCII letter classes.
The compiler uses the existing one-byte absolute-end search bound.
Class-tail MAP search is accepted for the documented narrow singleton/scoped-i form.
Case 20 passes. The direct Greek capture/reference form is accepted.
Repeated-capture case 12 is accepted for the narrow end-minimum policy.
Atomic case 10 is accepted for the narrow two-literal alternation end bound.
Greek direct-capture search is accepted with fold-derived minimum and maximum distances.
All six original methods pass after two nil-assertion corrections.
The repeated 29-row MRI artifact matches; fallback controls remain explicit.

Cases: `#10, #11, #12, #18, #19, #20`. Reproduce these six methods:
`LookaheadTest#test_ignorecase_reverse_fold_anchor_boundary_through_wrappers`,
`LookaheadTest#test_ignorecase_long_s_optional_class_stops_before_absolute_end`,
`LookaheadTest#test_ignorecase_reverse_literal_repeat_rejects_folded_capture_backreference`,
`UnicodePropertyDifferentialTest#test_reverse_fold_class_and_capture_boundaries_match_mri`,
`UnicodePropertyDifferentialTest#test_reverse_fold_alternation_keeps_branch_source_policy`,
and `UnicodePropertyDifferentialTest#test_reverse_simple_fold_source_does_not_split_before_a_literal_tail`.
Candidate C owners: `ext/onibi/compiler.c:onibi_compile_literal_bytes`,
`ext/onibi/compiler.c:onibi_compile_character_class`, `ext/onibi/compiler.c:onibi_compiler_normalize_class`,
`ext/onibi/exec_dynamic.c:onibi_rseq_consume_character`, and `ext/onibi/exec_dynamic.c:onibi_rseq_dynamic_run`.
Dependency: accepted BASE02 mapping. Keep existing input-ineligible fallback rows explicit.
Run each existing E2E method. Compare all frozen Unicode rows and ranges with MRI 4.0.6.
Record each selected route. Preserve MRI fallback wherever the support check rejects the input.
Do not claim the ten `reverse-alternation-1` through `-10` fallback rows as native defects.
Investigate `reverse-alternation-11` as the native DYNAMIC mismatch. Require zero fallback only for rows claimed native.
Done: every row matches MRI; native rows use the correct interpreter, and fallback rows remain explicit.

### TASK-BASE02-UNICODE-CLASS-FOLD — Unicode range closure

Case: `#15`. Reproduce `RegexpSyntaxSemanticsTest#test_ignorecase_closes_unicode_range_casefolds`.
Candidate C owners: `ext/onibi/compiler.c:onibi_class_expr_apply_casefold`,
`ext/onibi/compiler.c:onibi_compiler_normalize_class`, and `ext/onibi/exec_dynamic.c:onibi_rseq_class_hit`.
Dependency: accepted BASE02 mapping. Use the MRI encoding fold table and keep class data immutable.
Run the existing E2E method. Compare both subjects with MRI 4.0.6.
Record the class route. Require native execution and zero fallback for the supported class.
Done: the range and its one-character fold closure match MRI.

### TASK-BASE02-ABSENCE-AUDIT — Absence failure root cause

Cases: `#21–45`. Reproduce all 25 methods in `AbsenceOperatorTest`:
`test_absence_operator_restores_deep_nested_repeat_captures`,
`test_absence_operator_backtracks_nested_unbounded_capture_to_a_suffix`,
`test_absence_operator_restores_outer_quantifier_suffix_captures`,
`test_absence_operator_applies_quantifier_boundary_to_suffix_bodies`,
`test_absence_operator_does_not_export_quantifier_body_captures`,
`test_absence_operator_handles_nested_equal_length_captures`,
`test_absence_operator_propagates_nested_bytecode_endpoints`,
`test_absence_operator_restores_repeated_suffix_capture_frames`,
`test_absence_operator_restores_nested_suffix_group_captures`,
`test_absence_operator_keeps_a_nullable_body_capture`,
`test_absence_operator_preserves_body_captures`,
`test_absence_operator_clears_nested_repeat_captures`,
`test_absence_operator_keeps_capture_from_a_positive_lookahead_boundary`,
`test_absence_operator_replays_variable_suffix_backtracking`,
`test_absence_operator_replays_finite_and_positive_quantifier_probes`,
`test_absence_operator_keeps_captures_from_a_zero_width_body`,
`test_absence_operator_clears_nested_bounded_captures`,
`test_absence_operator_tracks_finite_nested_repeat_frames`,
`test_absence_operator_clears_nullable_captures_on_suffix_failure_at_end`,
`test_absence_operator_preserves_captures_from_a_failed_suffix`,
`test_absence_operator_preserves_alternation_branch_order`,
`test_absence_operator_restores_nested_repeat_suffix_frames`,
`test_absence_operator_handles_overlapping_nested_zero_width_boundaries`,
`test_absence_body_capture_presence_is_visible_to_conditionals`,
and `test_absence_operator_tracks_nullable_nested_repeat_frames`.
Candidate C owners: `ext/onibi/exec_dynamic.c:onibi_dynamic_absence_consume`,
`ext/onibi/exec_dynamic.c:onibi_dynamic_absence_filter_captures`,
`ext/onibi/exec_dynamic.c:onibi_apply_action_program`,
`ext/onibi/exec_dynamic.c:onibi_dynamic_assert_subprogram`, and `ext/onibi/exec_dynamic.c:onibi_rseq_dynamic_run`.
Dependency: accepted BASE02 mapping. Do not begin implementation in this audit.
Run all 25 E2E methods. Compare their direct MRI results and the saved MRI control rows that concern absence.
Record route diagnostics, raw registers, captures, and byte ranges for every case.
The BASE01 DYNAMIC routes were inferred from `G_ABSENT`; verify them before repair.
Reject half-open and out-of-bounds raw ranges. Do not weaken MRI assertions.
Done: every failure has a bounded root cause, route, and owner. Root review creates separate repair cards.

### TASK-BASE02-INLINE-M — Inline multiline scope

Cases: `#47, #48`. Reproduce
`InlineModifierTest#test_inline_multiline_disable_modifier_turns_dot_all_off` and
`InlineModifierTest#test_supported_modifier_scopes_match_mri`.
Candidate C owners: `ext/onibi/token.c:onibi_token_scan_inline_options`,
`ext/onibi/compiler.c:onibi_resolve_option_node`, and `ext/onibi/compiler.c:onibi_resolve_option_slice`.
Dependency: accepted BASE02 mapping. Resolve options before G-IR and restore outer scope after each node.
Run both E2E methods. Compare each scoped and unscoped result with MRI 4.0.6.
Record native diagnostics and require zero fallback for supported forms.
Done: both forms preserve lexical scope and match MRI.

### TASK-BASE02-LINE-ANCHOR — Final newline line-start behavior

Case: `#50`. Reproduce `AnchorsOptionsTest#test_line_start_does_not_match_the_empty_line_after_a_final_newline`.
Candidate C owners: `ext/onibi/exec_dynamic.c:onibi_rseq_position_assertion_hit` and
`ext/onibi/exec_dynamic.c:onibi_rseq_dynamic_run`.
Dependency: accepted BASE02 mapping. Keep byte positions aligned with MRI line anchors.
Run the existing E2E method. Compare match value and byte range with MRI 4.0.6.
Record the execution class. Require native execution and zero fallback.
Done: the native anchor does not return the empty position after the final newline.

### TASK-BASE02-STACKED-QUANTIFIER-SCOPE — Stacked quantifier decision

Case: `#1`. Reproduce `QuantifierTest#test_nested_quantifiers_follow_mri_composition`.
The method checks five stacked forms and compares each result with MRI 4.0.6.
Candidate files, only if support is accepted: `ext/onibi/token.c`, `ext/onibi/parser.c`,
and `ext/onibi/compiler.c`.
Dependency: accepted BASE02 mapping. Read GIR sections 27–29 and 133.1.
Decide whether these exact stacked forms belong to the current PoC subset.
If they do, create a separate repair card. If they do not, record the contract evidence.
Done: the support decision cites current contract text. Keep the original test visible.

### TASK-BASE02-PATTERN-COMMENT-SCOPE — Pattern comment decision

Cases: `#8, #9`. Reproduce `PatternCommentTest#test_pattern_comments_are_ignored` and
`PatternCommentTest#test_pattern_comments_do_not_create_captures`.
The exact forms are `(?# greeting)cat` and `(?# greeting)(cat)`.
Candidate files, only if support is accepted: `ext/onibi/token.c` and `ext/onibi/parser.c`.
Dependency: accepted BASE02 mapping. Read GIR 133.1 and the declared syntax subset.
Decide whether `(?#...)` comments belong to the current PoC subset.
If they do, create a separate repair card. If they do not, record the contract evidence.
Done: the support decision cites current contract text. Keep both original tests visible.

### TASK-BASE02-CLASS-SUBTRACTION-SCOPE — Nested subtraction decision

Case: `#14`. Reproduce `CharacterClassDifferentialTest#test_character_class_corpus_matches_mri`.
The method includes `[a-[b]]` and its saved MRI comparisons.
Candidate files, only if support is accepted: `ext/onibi/token.c`, `ext/onibi/parser.c`,
and `ext/onibi/compiler.c`.
Dependency: accepted BASE02 mapping. Read GIR section 42 and 133.1.
Decide whether nested class subtraction belongs to the current PoC subset.
Do not infer support from class intersection alone.
If support is accepted, create a separate repair card. Keep all corpus assertions visible.
Done: the support decision cites current contract text and preserves the test.

### TASK-BASE02-OCTAL-SCOPE — Octal disambiguation decision

Case: `#16`. Reproduce `RegexpSyntaxSemanticsTest#test_octal_escapes_match_the_encoded_byte`.
The pattern is `\10` with no captures. MRI reads octal byte `0x08`; Onibi reports an undefined backreference.
Candidate files, only if support is accepted: `ext/onibi/token.c`, `ext/onibi/parser.c`,
and `ext/onibi/compiler.c`.
Dependency: accepted BASE02 mapping. Read GIR sections 34 and 133.1.
Decide whether this octal and backreference disambiguation rule belongs to the PoC subset.
If it does, create a separate repair card. If it does not, record the contract evidence.
Done: the support decision cites current contract text. Keep the original assertion visible.

### TASK-BASE02-NONASCII-ENCODING-SCOPE — Pattern encoding decision

Cases: `#51, #52`. Reproduce
`EncodingContractTest#test_non_ascii_compatible_unicode_classes_honor_ignorecase` and
`EncodingContractTest#test_non_ascii_compatible_character_classes_compare_codepoints`.
Case 51 covers Unicode classes in UTF-16 and UTF-32 pattern encodings.
Case 52 covers `[あ]` and `\d` in those encodings.
Candidate files, only if support is accepted: tokenizer, parser, compiler, and encoding helpers.
Dependency: accepted BASE02 mapping. Read GIR sections 10, 61, and 133.1.
Decide which non-ASCII-compatible pattern encodings the gem PoC supports.
Keep case 51 compile errors separate from case 52 literal-class errors and `\d` fallback rows.
If support is accepted, create separate repair cards for each proven invariant.
Done: the support decision names accepted forms and routes. Keep both original methods visible.

### TASK-BASE02-DEPTH-ERROR-DECISION — Nesting-limit error text

Case: `#17`. Reproduce `RegexpNestingLimitTest#test_pattern_nesting_limit_is_reported_before_recursive_parse`.
The 256-level limit is explicit. The test expects `regexp compilation limit exceeded: pattern_nesting`.
Current source reports `regexp nesting is too deep` as `Onibi::RegexpError`.
Candidate file, only if the text is an API promise: `ext/onibi/parser.c`.
Dependency: accepted BASE02 mapping. Review GIR 133.1 and review-result P-10.
Decide whether the exact message is part of the current public error contract.
Do not change the limit or the message during this decision.
Done: root records the decision and its contract source. If required, create a separate repair card.

### BASE02-EXCLUDED-49 — Native MRI backreference state

Case: `#49`. Reproduce `RegexpUtilityTest#test_last_match_matches_mri_and_match_question_does_not_change_it`.
GIR 58 and `docs/development.md` exclude native matches from MRI backreference storage.
This case has no repair card or queue row under the current contract.
Keep the test and failure visible in legacy reports. Reopen only if the contract changes.

### TASK-BASE02-LINT-HYGIENE — Census test-source lint

Cases: all 70 BASE01 RuboCop findings across seven test files.
The immutable mapping assigns each offense its own number, path, line, column, cop, and message.
Owned files: `test/features/api/backreference_boundary_audit_test.rb` (10),
`test/features/api/match_api_test.rb` (2), `test/features/api/native_case_equality_test.rb` (20),
`test/features/api/native_match_operator_test.rb` (15), `test/features/api/native_tilde_test.rb` (12),
`test/features/matching/scan_block_test.rb` (9), and `test/features/matching/scan_gsub_test.rb` (2).
Dependency: accepted BASE02 mapping. Keep this hygiene work separate from semantic repairs.
Review each global-variable and Perl-backreference offense by hand.
Some tests need exact `$~`, `$&`, or numbered capture spelling. Do not replace them automatically.
Keep `===` where a test checks case equality. Use narrow lint exceptions when spelling carries test meaning.
Fix unrelated style findings without changing expected values or removing legacy tests.
Run focused RuboCop on these seven files after repair. Do not run the full suite for this card.
Done: all 70 findings have a safe fix or a narrow documented exception. Test meaning stays intact.

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
