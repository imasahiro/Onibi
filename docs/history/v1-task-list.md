# Onibi v1 Task List

> **Historical record — non-normative.** This preserves the completed v1
> implementation sequence. Architecture statements in this record are
> superseded by [`../hfa-design.md`](../hfa-design.md); current compatibility is
> tracked in [`../regexp-feature-coverage.md`](../regexp-feature-coverage.md).

This document decomposes the v1 work described in docs/onibi-design.md, using the
current snapshot in docs/regexp-feature-coverage.md. The Core MVP and REGEXP-001
through REGEXP-013 are treated as complete; this list covers the remaining partial
compatibility gaps and the cross-cutting requirements for a v1.0.0 release.

## v1 definition of done

v1 is complete only when all of the following are true:

- The latest stable MRI selected at milestone start is recorded with its Ruby version,
  source revision, and execution environment.
- The v1 API inventory and differential results are stored for the selected baseline.
- Every Onibi::Regexp and Onibi::MatchData public method included in the inventory
  matches MRI for normal results, return values, documented error classes, major error
  conditions, and encoding behavior.
- All encodings selected from the baseline's Onigumo support are covered by a documented
  matrix including same-encoding, ASCII-compatible cross-encoding, incompatible input,
  and invalid-byte cases.
- Acceptance tests run on MRI, JRuby, TruffleRuby, and mruby at the versions selected for
  v1. VM-specific internals are not part of the public contract.
- Property-based and fuzz tests are reproducible by seed, and discovered bugs are turned
  into deterministic regression tests whenever practical.
- bundle exec rake test, bundle exec rubocop, bundle exec rake build, clean gem
  installation, and the installed-gem smoke test all pass. Known limitations are
  documented.

## Common completion rule

Every task follows TDD: use a dedicated worktree and branch, add a focused acceptance or
differential test first, confirm the expected failure, implement the smallest change,
then run focused tests, the complete suite, relevant cross-runtime tests, RuboCop, and
package checks. A fuzz failure must retain its pattern, options, input, and seed in a
regression test or corpus record.

## Tasks

### V1-001 — Freeze the Ruby baseline and public API inventory [Complete]

- Priority: P0
- Dependencies: None
- Record the latest stable MRI version, Ruby source revision, and execution environment.
- Create a machine-readable inventory of public Regexp and MatchData methods, aliases,
  constants, argument forms, keywords, and block behavior.
- Exclude Regexp.last_match, $~, and other global match state; String/Symbol implicit
  integration; JSON extension APIs; and /u, /e, /s regex-literal parsing. Record an
  explicit reason for every exclusion.

Acceptance test: An inventory test requires every entry to contain a method name,
argument shape, keywords, block behavior, target class, and status. It compares the
inventory with MRI introspection and reports the exact difference. An excluded API cannot
be removed without a recorded reason.

### V1-002 — Extend the differential harness to the v1 API [Complete]

- Priority: P0
- Dependencies: V1-001
- Normalize Regexp and MatchData results while excluding implementation-specific class
  identity.
- Compare nil, captures, offsets, encodings, options, inspect/to_s, hash/eql?,
  exception classes, and the call site at which an exception occurs.
- Represent keywords, blocks, position arguments, Float coercion, Ranges, and String/Symbol
  capture names in fixtures.
- Distinguish unsupported-by-design from not-yet-implemented in reports.

Acceptance test: Fixtures generated from every inventory target include success,
nil/false, type, range, syntax, and encoding errors. MRI and Onibi normalized results
match, and a mismatch report contains fixture ID, pattern, options, input, expected, and
actual values.

### V1-003 — Close the remaining syntax and execution-semantics gaps [Complete]

- Priority: P0
- Dependencies: V1-002
- Match MRI semantics for ., ^, $, \A, \Z, \z, word boundaries, and \R, including CR,
  LF, CRLF, NEL, LSEP, and PSEP. In particular, ^ and $ must not gain the wrong meaning
  from the m option.
- Verify combinations of shorthand classes, class escapes, nested/intersection classes,
  Unicode/POSIX classes, lazy/possessive quantifiers, lookaround, backreferences,
  subexpression calls, atomic groups, conditional groups, and absence groups.
- Preserve MRI's greedy, leftmost-first, capture-priority, and unmatched-capture choices
  in both tagged NFA execution and warmed-up DFA execution.

Acceptance test: test/features/syntax/syntax_differential_contract_test.rb compares match spans,
captures, and offsets for the cases above before and after DFA warm-up. Invalid syntax
fixtures also compare the exception class and normalized error category.

### V1-004 — Complete the encoding matrix and case folding contract [Complete]

- Priority: P0
- Dependencies: V1-002, V1-003
- Enumerate every encoding supported by the selected baseline; initially cover at least
  UTF-8, US-ASCII, ASCII-8BIT, EUC-JP, and Windows-31J in the pattern/input matrix.
- Cover same-encoding, ASCII-only cross-encoding, non-ASCII cross-encoding, invalid bytes,
  FIXEDENCODING, NOENCODING, and Unicode-property fixed-encoding behavior.
- Define Unicode folding for literals, classes, properties, and ignorecase, including when
  incompatible input returns false versus raising Encoding::CompatibilityError.

Acceptance test: Every case in fixtures/encoding/matrix.yml runs against MRI and
Onibi. Match results, captures, source encoding, encoding, fixed_encoding?, and exceptions
match. Removing or skipping a matrix case fails the acceptance test.

### V1-005 — Complete constructor, mode, introspection, and utility contracts [Complete]

- Priority: P1
- Dependencies: V1-002, V1-004
- Cover new / compile with pattern strings, Regexp copies, integer/boolean/String/Symbol
  options, timeout keywords, and invalid arguments.
- Propagate i / m / x and scoped inline modifiers consistently into matching, source,
  options, casefold?, encoding, and fixed_encoding?.
- Match the inventory scope for ==, eql?, hash, inspect, to_s, escape/quote, union,
  try_convert, and linear_time?.
- Specify positive timeout validation, class-default inheritance, copy/override behavior,
  and the dedicated timeout exception. Comprehensive ReDoS controls remain v2 scope.

Acceptance test: A table-driven constructor/utility acceptance test exercises every argument
form and compares source, options, formatting, equality, and exceptions with MRI. Instance
timeout and class-default changes produce the expected result through copy and override
cases.

### V1-006 — Complete MatchData observable values and error compatibility [Complete]

- Priority: P1
- Dependencies: V1-003, V1-004, V1-005
- Cover [], captures, to_a, values_at, character and byte offset methods, match_length,
  integer/Float/Range indexes, String/Symbol names, negative indexes, and unmatched
  captures.
- Cover string, regexp, pre_match, post_match, names, named_captures, deconstruct,
  deconstruct_keys, inspect, equality, and hash with multibyte, nested, repeated,
  duplicate-named, and unmatched captures.
- Match match / match? position argument coercion, negative positions, out-of-range
  positions, and type errors.

Acceptance test: Every MatchData inventory method is compared with MRI using full, nested,
repeated, unmatched, named, and multibyte captures. Unknown names, out-of-range indexes,
and invalid types raise the same exception class; character and byte positions match
independently.

### V1-007 — Establish the cross-runtime execution contract [Complete]

- Priority: P1
- Dependencies: V1-003, V1-004
- Pin v1 target versions for MRI, JRuby, TruffleRuby, and mruby, and add CI jobs running
  the same acceptance and differential suites.
- Verify that DFA dispatch publication, mutable specialization pointers, memory budgets,
  and NFA fallback do not change public results on any target runtime.
- Keep VM-specific classes and object identity out of the API contract.

Acceptance test: Each CI job completes the v1 corpus, encoding corpus, and package smoke
test. With specialization disabled, at the budget limit, and after warm-up, match, capture,
offset, and exception results remain identical.

### V1-008 — Add reproducible property-based/fuzz testing and regression management [Complete]

- Priority: P1
- Dependencies: V1-002, V1-003, V1-004
- Add a constrained generator for patterns, options, and encoded inputs with a reproducible
  seed format.
- Use MRI as the differential oracle and classify timeout, crash, result, and exception
  mismatches.
- Convert minimized failures into deterministic tests under test/regression/; retain
  non-minimized seeds in corpus metadata.

Acceptance test: A fixed-seed smoke fuzz run reproduces the same case count and results. An
intentional mutant produces a differential failure with its seed. All recorded regression
seeds run from the normal test suite.

### V1-009 — Publish the compatibility report, limitations, and usage documentation [Complete]

- Priority: P1
- Dependencies: V1-001 through V1-008
- Report pass/partial/excluded status for every inventory item with the baseline and source
  revision.
- Document String/Symbol implicit integration, global match variables, regex-literal
  encoding modes, JSON extensions, and v2's comprehensive ReDoS controls as unsupported.
- Add README examples for the opt-in constructor, matching, MatchData, scan/gsub, encoding,
  and timeout APIs, including known MRI differences.

Acceptance test: A documentation acceptance test runs README examples after clean gem
installation and verifies that every inventory item is classified exactly once. An
unsupported API marked as supported causes the test to fail.

### V1-010 — Pass the v1 release gates with a clean package

- Status: [Complete]
- Priority: P0
- Dependencies: V1-005, V1-006, V1-007, V1-008, V1-009
- Verify zero runtime dependencies and the absence of C extensions, FFI, and external
  regexp libraries in gem metadata and package contents.
- Make the MRI baseline suite, differential suite, cross-runtime suite, RuboCop, gem build,
  clean gem installation, and installed-gem smoke test required CI gates.
- Store benchmarks as regression data without making a fixed throughput threshold a v1 gate.
- Document the atomic PR, squash-merge, auto-merge, and tagging procedure.

Acceptance test: In a temporary GEM_HOME, the installed v1 gem passes require onibi,
constructor, match, MatchData, and scan/gsub smoke tests plus the complete acceptance suite.
The release checklist cannot pass unless every required CI status is green.

## Explicitly out of scope for v1

- Regexp.last_match, $~, $&, $1, and other global match state.
- String/Symbol-side implicit match, scan, gsub, and sub integration.
- /u, /e, /s regex-literal parsing and interpolation.
- JSON gem as_json, json_create, and to_json integration.
- Comprehensive ReDoS protection, CPU/step budgets, input/pattern limits, cancellation,
  interruption, and operational observability.
- A fixed throughput guarantee.

## Per-task checklist

- [ ] Dedicated worktree and branch used.
- [ ] Acceptance test added before implementation and confirmed failing.
- [ ] Focused, complete, and applicable differential tests pass.
- [ ] Target-runtime CI tests pass.
- [ ] RuboCop and formatting checks pass.
- [ ] New fuzz failures became deterministic regression tests or recorded seeds.
- [ ] Change is in one atomic PR and is squash-merged only after required checks pass.
