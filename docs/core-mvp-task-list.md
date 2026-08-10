# Onibi Core MVP Task List

This task list covers the work from the design document through the Core MVP (`0.x.y`). It does not cover v1's complete `Regexp` / `MatchData` API, full encoding compatibility, or v2 MRI replacement integration.

## Completion rule for every task

No task is complete unless it follows TDD:

1. Create one feature worktree and branch.
2. Add the acceptance test first.
3. Run the new test and confirm the expected failure.
4. Implement the smallest change that makes the test pass.
5. Run the focused tests and the complete suite.
6. Run RuboCop and formatting checks.
7. Open a GitHub Pull Request and merge with auto-merge/squash only after required checks pass.

Every task below must add and pass at least one acceptance test. Unit tests may be added in support of the acceptance test, but unit tests alone do not satisfy completion.

## Definition of Core MVP complete

Core MVP is complete only when all tasks below are complete and the following are true:

- `onibi` builds and installs as a Ruby gem.
- Runtime dependencies are zero; no C extension or FFI is used.
- The target runtime is MRI Ruby 4.0.6, or the newer baseline explicitly selected at the beginning of the milestone.
- `Onibi::Regexp.new` and `Onibi::Regexp.compile` work.
- `Onibi::Regexp#match` returns an `Onibi::MatchData` result or `nil`.
- `Onibi::Regexp#match?` returns a boolean.
- UTF-8 and ASCII-8BIT are supported for the Core MVP behavior.
- The Core MVP syntax subset works:
  - literals and Unicode characters;
  - concatenation and alternation;
  - numbered capturing groups;
  - greedy `*`, `+`, `?`, and `{m,n}` quantifiers;
  - character classes, negated classes, and ranges;
  - `\d`, `\s`, `\w`, and escaped metacharacters;
  - `^` and `$` anchors;
  - case-insensitive and multiline options.
- Ruby differential tests pass for the supported Core MVP corpus.
- DFA specialization is lazy, per `Onibi::Regexp` instance, and bounded by a memory budget.
- NFA fallback remains correct when specialization is unavailable or exceeds its budget.
- All required tests, package checks, RuboCop, and clean-install smoke tests pass.

## Ordered tasks

### CORE-001 — Freeze Core MVP scope and fixtures [Complete]

Create the initial acceptance corpus and explicitly record supported and unsupported syntax. Include positive matches, negative matches, captures, invalid patterns, UTF-8, and ASCII-8BIT cases.

**Acceptance test:** A Minitest corpus test loads the fixture table and verifies that every case has a pattern, options, input, expected outcome, and feature label. The test must also fail when an unsupported feature is accidentally marked as supported without an explicit update.

**Dependencies:** None.

### CORE-002 — Bootstrap the Ruby gem and test harness [Complete]

Create `onibi.gemspec`, `Gemfile`, `Rakefile`, `lib/onibi.rb`, `test/test_helper.rb`, and the initial Minitest layout. Configure zero runtime dependencies and Apache License 2.0 metadata.

**Acceptance test:** A packaging acceptance test builds the gem, installs it into a clean temporary gem home, and successfully runs `require "onibi"` plus a minimal public API smoke test.

**Dependencies:** CORE-001.

### CORE-003 — Add RuboCop and the pre-commit hook [Complete]

Add RuboCop configuration and `.githooks/pre-commit`. Configure `core.hooksPath` documentation and ensure the hook formats changed Ruby files, runs lint, and stops when formatting changes require re-staging.

**Acceptance test:** A shell-backed Minitest or repository check creates a temporary staged Ruby file with a formatting violation, runs the hook, verifies that RuboCop was invoked, and verifies that the commit is rejected when the hook modifies the file.

**Dependencies:** CORE-002.

### CORE-004 — Build the MRI differential-test harness [Complete]

Implement a reusable harness that runs the same pattern, options, and input through MRI `Regexp` and `Onibi::Regexp`. Normalize results so class identity and implementation-specific details are excluded while match values, captures, offsets, and exceptions remain comparable.

**Acceptance test:** A differential acceptance test runs a table containing matching, non-matching, capture, invalid-pattern, and invalid-argument cases against MRI and the current Onibi placeholder, and reports a clear mismatch when either result differs.

**Dependencies:** CORE-002.

### CORE-005 — Define public errors and input validation [Complete]

Define the initial public error behavior for invalid pattern types, invalid input types, invalid options, and malformed syntax. Add `Onibi::RegexpError` only if the compatibility design requires a namespaced error; otherwise map to the documented Ruby-compatible exception class.

**Acceptance test:** The public API raises the expected exception class at the expected call site for each invalid-input fixture, and the normalized error message is semantically equivalent to MRI's message.

**Dependencies:** CORE-004.

### CORE-006 — Implement the lexer for literals and escapes [Complete]

Implement tokenization for literals, escaped metacharacters, grouping, alternation, quantifiers, character classes, anchors, options, and the Core MVP escapes `\d`, `\s`, and `\w`.

**Acceptance test:** End-to-end acceptance tests construct a regexp through `Onibi::Regexp.new` and verify that representative patterns tokenize and eventually match. Malformed escape sequences must produce the expected public error.

**Dependencies:** CORE-005.

### CORE-007 — Implement the AST and parser precedence [Complete]

Implement AST nodes and parsing for literals, concatenation, alternation, groups, quantifiers, character classes, anchors, and options. Explicitly test precedence and grouping.

**Acceptance test:** Public regexp acceptance tests verify that patterns such as `ab|cd`, `a(b|c)d`, and `a+|bc` produce the same match decisions and capture structure as MRI for the supported corpus.

**Dependencies:** CORE-006.

### CORE-008 — Compile AST to Thompson-NFA bytecode [Complete]

Compile the parsed AST into the bytecode representation used by the single VM. Include epsilon transitions, character transitions, accept states, capture tags, and option metadata.

**Acceptance test:** Through the public API, every CORE-001 fixture that uses only literals, concatenation, alternation, or groups produces the expected match/no-match result and capture values. The test must not inspect internal bytecode classes as its acceptance criterion.

**Dependencies:** CORE-007.

### CORE-009 — Implement the NFA execution path [Complete]

Implement the bytecode VM's Thompson-NFA simulation, including epsilon closure, input consumption, search semantics, and leftmost-first behavior.

**Acceptance test:** The public differential corpus for literals, concatenation, alternation, and basic groups passes against MRI for both matching and non-matching inputs, including long non-matching inputs.

**Dependencies:** CORE-008.

### CORE-010 — Implement greedy quantifiers [Complete]

Add `*`, `+`, `?`, and `{m,n}` with greedy behavior, including bounded and unbounded repetition and the empty-match cases.

**Acceptance test:** Differential acceptance tests compare match/no-match, full match, and capture boundaries for `a*`, `a+`, `a?`, `a{2}`, `a{2,4}`, and representative nested/grouped patterns.

**Dependencies:** CORE-009.

### CORE-011 — Implement character classes and Core MVP escapes [Complete]

Implement positive classes, negated classes, ranges, escaped characters inside classes, and the Core MVP forms of `\d`, `\s`, and `\w`.

**Acceptance test:** Differential acceptance tests cover `[abc]`, `[^a]`, `[a-z]`, escaped class metacharacters, `\d`, `\s`, and `\w` over UTF-8 and ASCII-8BIT inputs.

**Dependencies:** CORE-009.

### CORE-012 — Implement anchors and matching options [Complete]

Implement `^`, `$`, case-insensitive matching, and multiline behavior as defined for the Core MVP.

**Acceptance test:** Differential acceptance tests compare anchored and unanchored matches across single-line and multi-line inputs, with and without case-insensitive options.

**Dependencies:** CORE-009, CORE-011.

### CORE-013 — Implement tagged captures and `Onibi::MatchData` [Complete]

Implement capture start/end tags in NFA execution and construct the initial public `Onibi::MatchData`. Support the Core MVP operations required to inspect the full match, numbered captures, capture values, and begin/end offsets.

**Acceptance test:** Public differential tests compare `nil` versus match, full match, numbered captures, unmatched captures, and offsets for nested and repeated groups. Tests must compare observable values rather than class identity.

**Dependencies:** CORE-010, CORE-011, CORE-012.

### CORE-014 — Implement `Onibi::Regexp.new` and `.compile` [Complete]

Expose the public constructors, pattern/options storage, and compile-time validation. Ensure equivalent constructor forms behave consistently.

**Acceptance test:** API acceptance tests cover valid and invalid constructor arguments, default options, explicit options, repeated construction, and the documented return type/behavior of `.new` and `.compile`.

**Dependencies:** CORE-005, CORE-013.

### CORE-015 — Implement `Regexp#match` and `Regexp#match?` [Complete]

Connect the public methods to the single bytecode VM and `Onibi::MatchData` builder. Ensure `#match` returns `nil` on no match and `#match?` returns only a boolean.

**Acceptance test:** End-to-end differential tests compare `#match` and `#match?` across all Core MVP syntax fixtures, including captures, options, encoding, invalid inputs, and repeated use of the same regexp instance.

**Dependencies:** CORE-014.

### CORE-016 — Add lazy DFA specialization [Complete]

Implement runtime conversion of reachable NFA state sets into DFA bytecode sequences. Store specialization pointers in the bytecode, publish generated sequences only after completion, and preserve tagged capture semantics.

**Acceptance test:** A public behavior test runs the same regexp before and after warm-up and verifies identical match results, captures, and offsets. An instrumentation test verifies that a regular pattern creates a lazy specialization only after execution and that the specialization is associated with the regexp instance.

**Dependencies:** CORE-013, CORE-015.

### CORE-017 — Add DFA memory budget and NFA fallback

Add a configurable internal memory budget for per-instance DFA specialization. When the budget is exhausted or a state cannot be specialized, continue execution through the NFA path without changing observable behavior.

**Acceptance test:** A test forces the budget to be reached, verifies that no additional DFA specialization is retained, and compares all subsequent public results with the same pattern executed without specialization. No match result, capture, or exception may differ.

**Dependencies:** CORE-016.

### CORE-018 — Validate UTF-8 and ASCII-8BIT behavior

Complete the Core MVP encoding handling for UTF-8 and ASCII-8BIT, including compatible pattern/input combinations and documented incompatibility errors.

**Acceptance test:** Differential acceptance tests cover literal matching, classes, escapes, captures, invalid byte sequences where applicable, and incompatible pattern/input encodings for both supported encodings.

**Dependencies:** CORE-011, CORE-013, CORE-015.

### CORE-019 — Complete the Core MVP differential corpus

Expand the corpus to cover every Core MVP syntax feature and public method combination. Add regression cases for every defect found during implementation.

**Acceptance test:** The complete Core MVP differential suite passes against MRI 4.0.6, and the suite fails if any supported fixture is removed or silently skipped.

**Dependencies:** CORE-001, CORE-004, CORE-015, CORE-018.

### CORE-020 — Complete package, clean-install, and release checks

Finalize gem metadata, README usage examples, version `0.x.y`, package contents, and the MVP release checklist. Verify that the package has no runtime dependencies and can be installed in a clean environment.

**Acceptance test:** CI builds the gem, installs it into a clean gem home, runs the smoke test and full Minitest suite using the installed gem, and verifies that the package contains the expected public files and license.

**Dependencies:** CORE-002, CORE-003, CORE-019.

## Per-task pull request checklist

- [ ] A feature-specific worktree and branch were used.
- [ ] Acceptance test was written before implementation.
- [ ] The acceptance test failed for the expected reason before implementation.
- [ ] Acceptance test passes.
- [ ] Relevant unit and integration tests pass.
- [ ] Full Minitest suite passes.
- [ ] Differential tests pass when applicable.
- [ ] RuboCop and formatting checks pass.
- [ ] Gem/package checks pass when applicable.
- [ ] The GitHub PR has required checks enabled.
- [ ] The PR is merged with GitHub auto-merge and squash merge.
