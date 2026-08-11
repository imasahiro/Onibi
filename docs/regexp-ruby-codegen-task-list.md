# Onibi AST-to-Ruby Code Generation Task List

## Purpose

This plan migrates Onibi from the bytecode VM, AST fallback, capture matcher, and DFA specialization seams to the single generated-matcher architecture defined in [`regexp-ruby-codegen-design.md`](regexp-ruby-codegen-design.md).

The list is ordered to keep every pull request reviewable and keep `main` working. Temporary dual execution exists only in test/benchmark builds and has an explicit deletion task. No task introduces a user-facing backend option.

## Completion rule for every task

Every task follows the repository TDD lifecycle:

1. Create a dedicated worktree and `codex/` feature branch from current `main`.
2. Add one focused failing acceptance test first and run it to confirm the expected failure.
3. Add supporting unit tests only after the public behavior is pinned.
4. Implement the smallest coherent change that passes the focused test.
5. Run the focused test, related differential tests, and `bundle exec rake test`.
6. Run RuboCop autocorrection only on intended changed files, inspect the diff, then run `bundle exec rubocop`.
7. Run `bundle exec rake build`, install the local gem in a clean gem home, and run the smoke test when packaging or loaded files change.
8. Commit one atomic change, push it, open a pull request, enable auto-merge with squash, and wait for all required checks.

A task is not complete merely because unit tests pass. Any public matcher change requires an MRI differential acceptance test. Any fuzz failure is reduced to a deterministic regression test when practical.

## Global Definition of done

The migration is complete only when:

- the production pipeline is `Regexp source -> Token stream -> AST -> generated Ruby matcher`;
- `match?`, `match`, `=~`, `===`, `scan`, `gsub`, and MatchData-producing flows use the same generated control program;
- the full MRI differential, encoding, timeout, property/fuzz, and public API suites pass;
- generated source is deterministic, injection-tested, and linear in AST size;
- long and recursive patterns use explicit stacks and do not raise `SystemStackError`;
- concurrent calls do not share invocation state;
- supported-Ruby smoke tests and the selected Ractor contract pass;
- compile time, warm throughput, allocation, and memory results are recorded against the pre-migration baseline;
- no user-facing backend toggle or silent semantic fallback exists;
- all legacy matcher production code and matcher-routing heuristics are deleted;
- lint, gem build, clean install, and smoke gates pass.

## Dependency graph

```text
001 -> 002 -> 003 -> 004 -> 005 -> 006 -> 007 -> 008 -> 009 -> 010
                                                               |
                                                               v
011 -> 012 -> 013 -> 014 -> 015 -> 016 -> 017 -> 018 -> 019
                                                         /   |   |   \
                                                       020  021 022  023
                                                         \   |   |   /
                                                               v
                                                              024 -> 025
```

Tasks 020, 021, 022, and 023 may proceed in parallel after task 019. Task 024 waits for all four.

## Phase 0 — Freeze decisions and baselines

### CODEGEN-001 [Complete] — Accept the architecture and task plan

Add the completed design, this task list, and the canonical `onibi-design.md` update. Record the rejected NFA/DFA-codegen alternative and the final deletion criteria.

**Acceptance test:** A documentation acceptance test requires the selected pipeline, single-engine invariant, safety/resource/concurrency sections, ordered task IDs, and canonical-design consistency.

**Deliverables:**

- `docs/regexp-ruby-codegen-design.md`
- `docs/regexp-ruby-codegen-task-list.md`
- updated `docs/onibi-design.md`
- review record in the pull-request description

**Dependencies:** None.

### CODEGEN-002 [Complete] — Freeze the semantic and performance baseline

Create a versioned fixture manifest covering every currently supported AST node and public matching surface. Record current results, known MRI differences, construction/warm-match timings, allocations, and representative pathological scaling without treating current Onibi as the correctness oracle.

**Acceptance test:** The manifest test fails if an AST class, supported feature label, public matching method, or required benchmark workload lacks a fixture. MRI expectations remain the semantic oracle.

**Deliverables:**

- deterministic semantics corpus with seed/version metadata;
- benchmark corpus for literal, branch, repetition, captures, assertions, backreferences, Unicode, mismatch, and pathological cases;
- stored baseline report format, not machine-specific pass thresholds.

**Dependencies:** CODEGEN-001.

### CODEGEN-003 [Complete] — Specify hard semantic probes

Add MRI expectation fixtures for behavior most likely to be lost during a rewrite: alternation/capture priority, empty quantified bodies, full case-fold width, captures and choice points in assertions/calls, atomic cuts, possessive and lazy repetition, unmatched backreferences, quantified subexpression recursion, conditionals, absence, `\G`, `\K`, `\R`, start positions, and timeout timing.

**Acceptance test:** The frozen MRI fixture runner records and rechecks `match?`, normalized match/captures/offsets, and errors. It includes `/[ß]/i` on `"ss"`, `/(?<=[ß])x/i` on `"ssx"`, `(?=(a|aa))\1b`, `(?<x>a|ab)c\g<x>d`, `\G` from positions zero/one, and the normative absence examples. This task does not depend on a generated matcher.

**Dependencies:** CODEGEN-002.

## Phase 1 — Safe generated-program skeleton

### CODEGEN-004 [Complete] — Prove host source compilation and add the typed emitter boundary

Run the capability spike on the selected development host first; cross-runtime capability is a later CODEGEN-021 gate. Introduce `Onibi::Codegen::SourceCompiler`, `RubyEmitter`, `GeneratedProgram`, and `CodegenError`. Generate a fixed-name module-function entry through the supported string-eval adapter. Support a trivial empty/literal test program only in internal test mode.

**Acceptance test:** The selected development host compiles and executes the same trivial generated source with equivalent scoping and errors. The source-compiler API exposes an explicit capability probe for other hosts. The new codegen red test fails before the skeleton is implemented, then passes. A hostile pattern containing quotes, interpolation, comments, newlines, and encoding markers cannot alter generated control flow.

**Required unit tests:** deterministic source, valid labels, fixed identifiers, synthetic filename where supported, compilation-error diagnostics, no CRuby-only runtime dependency, explicit capability probing, and a clear unsupported-runtime failure. CODEGEN-021 must pass the matrix before public cutover.

**Dependencies:** CODEGEN-003.

### CODEGEN-005 [Complete] — Guard parser nesting, then implement analyzer metadata

First add an iterative token-stream nesting guard before recursive descent and make the parser consume that validated token stream. Then add an exhaustive AST dispatch table and analysis result for capture tables, group-call targets, option/encoding-aware finite width sets, nullability, option scopes, liveness inputs, and stable labels. Freeze the result recursively.

**Acceptance test:** Group/assertion/class nesting at 255 and 256 constructs without `SystemStackError`; level 257 raises `Onibi::RegexpError`, `"regexp compilation limit exceeded: pattern_nesting"`, before recursive parsing. Escaped/comment delimiters do not count. Every supported public pattern then constructs an analyzed program; injecting a test-only unknown AST node fails at construction rather than selecting a fallback.

**Required unit tests:** injected nesting limits at `N-1`, `N`, `N+1`; explicit refutation of `SystemStackError` on each supported host; one handler per `Onibi::AST` class; duplicate/missing handler detection; scalar/finite/variable width sets including full-fold expansion; group resolution; deterministic labels; and frozen graphs.

**Dependencies:** CODEGEN-004.

### CODEGEN-006 [Complete] — Add `InputView` and offset conversion

Implement the correctness-first character cursor and character-to-byte boundary mapping for UTF-8, ASCII-8BIT, and the currently supported invalid-byte cases. Keep encoding compatibility validation at the public boundary.

**Acceptance test:** Literal matching through the generated test path returns MRI-equivalent character and byte offsets for ASCII, multibyte UTF-8, binary data, positive/negative start positions, and incompatible encodings.

**Required unit tests:** empty strings, string end, invalid sequences, CRLF, boundary-table laziness if implemented, and no input mutation.

**Dependencies:** CODEGEN-005.

### CODEGEN-007 [Complete] — Implement invocation state, checkpoints, and rollback

Add invocation-local cursor and immutable search origin, capture trail, backtrack stack, and persistent call/repeat/cut arenas with restorable top pointers and call activation IDs. Emit label-loop restoration without recursive matcher calls.

**Acceptance test:** A generated test graph explores alternatives, restores cursor and captures, returns the first successful path, and handles thousands of checkpoints without `SystemStackError`.

**Required unit tests:** capture restoration, `\G` origin versus candidate start, backtracking into a subexpression after logical return, recursive activations of the same quantified group, nested checkpoints and cuts, exhausted stack, malformed-label invariant, and two concurrent calls on one program.

**Dependencies:** CODEGEN-006.

## Phase 2 — Regular syntax on the one control program

### CODEGEN-008 [Complete] — Lower literals, sequence, alternation, dot, classes, escapes, and properties

Compile the core consuming AST nodes and structural sequence/alternation nodes. Consuming atoms return ordered candidate end cursors so full case folding and `\R` are not forced into a one-character model. Reuse character predicate helpers only as leaf operations.

**Acceptance test:** The generated path passes the MRI differential corpus for literal runs, branch order, dot/multiline, character-class intersections/negation, shorthand escapes, Unicode/POSIX properties, early/late mismatch, `/[ß]/i` on `"ss"`, and `/ß/i` on `"SS"`.

**Required unit tests:** direct operands come from analyzed values, not pattern text; active option scope reaches predicates; source size is linear in sequence length.

**Dependencies:** CODEGEN-007.

### CODEGEN-009 [Complete] — Lower anchors, boundaries, and option scopes

Compile `^`, `$`, `\A`, `\Z`, `\z`, `\G`, word boundaries, and nested positive/negative i/m/x option groups. Extended mode remains a lexer/parser concern.

**Acceptance test:** Generated matching agrees with MRI across line boundaries, beginning/end variants, start positions, scoped option nesting, and UTF-8 word boundaries.

**Dependencies:** CODEGEN-008.

### CODEGEN-010 [Complete] — Lower greedy, lazy, bounded, and empty-body quantifiers

Generate counter-driven entry/body/exit labels. Implement zero-progress guards and avoid source unrolling for large bounds.

**Acceptance test:** MRI differential cases cover `*`, `+`, `?`, `{m}`, `{m,n}`, `{m,}`, greedy/lazy modes, nesting, captures after repetition, empty bodies, and long non-matches without stack overflow.

**Required unit tests:** a `{1,1000000}` pattern has source size within a constant factor of `{1,2}`; zero-width loops terminate; priority order is stable; nested and recursively re-entered quantifiers have distinct activation frames and restore their frame tops on backtrack.

**Dependencies:** CODEGEN-008, CODEGEN-009.

### CODEGEN-011 [Complete] — Lower captures and match reset with trail rollback

Compile numbered/named group begin/end writes and `\K`. Return the internal capture-offset protocol and preserve repeated/unmatched/empty capture semantics.

**Acceptance test:** Generated results match MRI for nested, repeated, optional, duplicate named, alternation-sensitive, lookaround-adjacent captures, and `\K`, including character and byte offsets.

**Required unit tests:** capture rollback after a failing branch, group 0 reset rollback, no public `MatchData` construction inside generated code, and capture array shape.

**Dependencies:** CODEGEN-010.

## Phase 3 — Non-regular and control features

### CODEGEN-012 [Complete] — Lower lookahead and lookbehind

Compile assertions through explicit atomic assertion boundaries. Positive assertions commit the selected captures but discard internal choice points; negative assertions exhaust internal choices and restore all state. Use option/encoding-aware width sets for lookbehind.

**Acceptance test:** Positive/negative lookahead and lookbehind agree with MRI for success, failure, captures, nested assertions, alternatives, options, match offsets, `(?=(a|aa))\1b`, and `(?<=[ß])x` under ignorecase.

**Required unit tests:** assertion cursor restoration, negative-state rollback, width validation, and no Ruby recursion.

**Dependencies:** CODEGEN-011.

### CODEGEN-013 [Complete] — Lower atomic groups and possessive quantifiers

Implement cut-stack semantics that remove only checkpoints created within the committed region.

**Acceptance test:** MRI differential cases include suffix failure after an atomic/possessive choice, nested cuts, captures within cuts, lazy neighbors, and long mismatch inputs.

**Dependencies:** CODEGEN-012.

### CODEGEN-014 [Complete] — Lower backreferences and conditionals

Compile numbered/named/relative references and capture-participation or assertion conditionals. Preserve option and encoding semantics for referenced text.

**Acceptance test:** MRI differential cases cover matched, unmatched, empty, repeated, named, and case-insensitive backreferences plus yes/no conditional branches and capture rollback.

**Dependencies:** CODEGEN-013.

### CODEGEN-015 [Complete] — Lower subexpression calls, recursion, and absence

Resolve group targets in analysis and execute them with persistent activation/return frames and budgets, retaining internal call choices across logical return. Compile the absence operator using the design's absent-stopper, capture, backtracking, and empty-stopper rules.

**Acceptance test:** MRI differential cases cover named/numbered calls, `(?<x>a|ab)c\g<x>d` on `"acabd"`, nested quantified recursion/base cases, recursion exhaustion, captures in calls, all normative absence examples, nested absence alternatives/assertions/cuts, and timeout behavior. Deep cases do not raise `SystemStackError`.

**Dependencies:** CODEGEN-014.

## Phase 4 — Public integration and hardening

### CODEGEN-016 [Complete] — Integrate the generated result with `Onibi::MatchData`

Adapt the internal offset result to the existing `MatchData` builder, including byte offsets, names, pre/post match, values, and regexp/input references. Generated code remains unaware of public objects.

**Acceptance test:** The complete MatchData contract suite passes through an explicitly selected generated test path for every capture fixture.

**Dependencies:** CODEGEN-015.

### CODEGEN-017 [Complete] — Integrate `match?` without a second matcher

Route `match?`, `===`, and boolean internal callers through the same generated control program with `capture: false`. Retain semantic captures needed by backreferences/conditionals and skip only proven-dead result construction.

**Acceptance test:** For the full fixture corpus, generated `match?` equals `!generated match.nil?` and MRI `match?`; a test proves that `Onibi::MatchData` is not allocated by boolean-only patterns.

**Dependencies:** CODEGEN-016.

### CODEGEN-018 [Complete] — Add timeout, interrupts, and deterministic resource accounting

Wire deadline/step checks and the exact source/AST/table/backtrack/call/repeat/trail ceilings from the design into construction and matching. Retain the existing outer timeout wrapper until cooperative checks meet the compatibility gate.

**Acceptance test:** Ordinary matches do not time out; adversarial patterns raise `Onibi::Regexp::TimeoutError` near the configured deadline; class/instance precedence, interruption, cleanup, and a subsequent match all agree with the contract.

**Required unit tests:** monotonic clock injection; `N-1`, `N`, and `N+1` for every injected limit; exact construction/match exception class, message, and timing; restored state after abort; no fallback; and bounded diagnostic values.

**Dependencies:** CODEGEN-017.

### CODEGEN-019 — Validate repeated-match and all public surfaces in explicit codegen mode

Keep legacy as the production default. Route the complete public API suite, including `scan`, `gsub`, replacement, `=~`, `===`, and empty-match iteration, through an explicitly selected codegen test mode. Add `verify` mode for normalized result/exception comparison; it reports a minimized context without changing the generated result.

**Acceptance test:** A repository-wide explicit-codegen run proves the generated program was invoked for every supported fixture before and after warm-up. MRI differential cases cover block and replacement-string forms, backreference expansion, multibyte input, empty matches at every position, `\K`, and no infinite loop. Deliberately perturbing the legacy test oracle makes verify mode report a mismatch.

**Dependencies:** CODEGEN-018.

## Phase 5 — Pre-cutover whole-product validation

### CODEGEN-020 — Complete security, fuzz, and property gates

Fuzz lexer/parser/codegen boundaries with hostile source strings and bounded random AST/input pairs while codegen remains explicitly selected. Add source-policy checks and memory/stack invariants. Reduce failures to regressions.

**Acceptance test:** The recorded fuzz/property corpus completes under fixed seeds, generated source passes the forbidden-construct policy, and injection sentinels cannot execute or alter constants/global state.

**Dependencies:** CODEGEN-019.

### CODEGEN-021 — Validate concurrency, Ractor contract, and supported hosts

Stress concurrent calls on a shared regexp and probe object-graph shareability on Ruby 4.0. Select either shared-regexp Ractor support or documented per-Ractor construction based on evidence. Re-run source compilation and the complete generated smoke corpus on MRI, JRuby, TruffleRuby, and the CODEGEN-004-selected mruby build.

**Acceptance test:** Thread results remain deterministic under concurrent mixed inputs. The selected Ractor scenario and cross-runtime build/load/compile/match matrix pass without `RubyVM::InstructionSequence`; a minimal mruby build without runtime eval is rejected with the documented capability error.

**Dependencies:** CODEGEN-019.

### CODEGEN-022 — Complete the migration encoding matrix

Implement `InputView`, case-fold, compatibility, invalid-sequence, character-offset, and byte-offset behavior for every encoding in the recorded migration baseline: UTF-8, US-ASCII, ASCII-8BIT, EUC-JP, and Windows-31J. Record remaining Onigumo encodings as the canonical v1 expansion goal rather than silently claiming them.

**Acceptance test:** Same-encoding, ASCII-compatible cross-encoding, incompatible non-ASCII, invalid byte, fixed/noencoding, full-fold, match/capture, and character/byte offset cases pass against MRI for all five encodings through explicit codegen mode.

**Dependencies:** CODEGEN-019.

### CODEGEN-023 — Benchmark and optimize the single control graph

Record compile time, source bytes, allocations, first/warm throughput, memory, steps, and pathological scaling while codegen remains explicitly selected. Add only transformations that preserve unoptimized-codegen and MRI equivalence.

**Acceptance test:** Every enabled optimization can be disabled in tests; optimized and baseline generated programs return identical normalized observations for the full corpus. The benchmark report records regressions and accepted tradeoffs.

**Dependencies:** CODEGEN-019.

## Phase 6 — Cutover completion

### CODEGEN-024 — Switch every public matcher surface to codegen

Make generated execution the production default only after CODEGEN-020 through CODEGEN-023 pass. Keep the internal legacy/verify modes for one final deletion PR; no user-facing backend option exists.

**Acceptance test:** The full public, differential, encoding, timeout, security corpus, concurrency, cross-runtime, package, and installed-gem smoke suites pass with codegen as the default. Instrumentation proves no pattern-text matcher routing or legacy execution occurs.

**Dependencies:** CODEGEN-020, CODEGEN-021, CODEGEN-022, CODEGEN-023.

### CODEGEN-025 — Remove the legacy VM, NFA, and DFA paths and finalize release docs

Remove the temporary mode and all production code, requires, tests, instance variables, configuration, and documentation for bytecode compilation, VM execution, AST/capture fallback matchers, matcher routing, and DFA specialization. Rename engine-focused tests to observable codegen behavior. Update README, architecture diagrams, feature coverage, release notes, resource/Ractor guidance, and package contents.

**Acceptance test:** A repository architecture test asserts that production code has no legacy constants/requires, `Onibi::Regexp` retains no `@bytecode` or DFA state, and every AST class is handled by the generator. The packaged gem contains codegen files and no legacy execution files, loads without development dependencies, and passes the full suite plus literal/capture/assertion/backreference/Unicode installed-gem smoke tests.

**Expected removals:**

- `lib/onibi/bytecode.rb`
- `lib/onibi/compiler.rb`, `alternation_compiler.rb`, `compiler_quantifiers.rb`, `compiler_references.rb`
- `lib/onibi/virtual_machine.rb`, `virtual_machine_anchors.rb`
- `lib/onibi/matching_result.rb`
- `lib/onibi/ast_matcher.rb`, `ast_matcher_dispatch.rb`
- `lib/onibi/capture_matcher.rb` and `capture_matcher_*.rb`
- `lib/onibi/dfa.rb`
- `test/features/engine/bytecode_test.rb`, `nfa_vm_test.rb`, and `dfa_*` tests after their public guarantees are relocated

**Dependencies:** CODEGEN-024.

## Per-pull-request checklist

- [ ] Dedicated worktree and `codex/` branch created from current `main`.
- [ ] Focused failing acceptance test added and observed before production code.
- [ ] MRI differential test added for public behavior.
- [ ] Focused and related tests pass.
- [ ] Full `bundle exec rake test` passes.
- [ ] Intended files were formatted; `bundle exec rubocop` passes.
- [ ] Generated source/security checks pass when codegen changes.
- [ ] Encoding/timeout/concurrency tests pass when affected.
- [ ] `bundle exec rake build`, clean install, and smoke test pass when load/package files change.
- [ ] Benchmark delta recorded when hot-path or source-shape code changes.
- [ ] No new production fallback or user-facing backend toggle was added.
- [ ] Pull request is atomic and auto-merges with squash only after required checks pass.
