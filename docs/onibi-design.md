# Onibi: A Pure Ruby Regular Expression Engine for Replacing Ruby's Regexp Implementation

## Metadata

- **Status:** Draft
- **Author:** TBD
- **Created:** 2026-08-09
- **Last architecture revision:** 2026-08-11
- **Current baseline:** MRI Ruby 4.0.6
- **License:** Apache License 2.0
- **Repository:** Onibi

## Objective

Build a pure Ruby regular expression engine that provides Ruby-compatible `Regexp` and `MatchData` APIs, reaches semantic and error compatibility in v1, and can eventually replace MRI's Onigumo implementation.

## Background

Ruby's regexp implementation is backed by the Onigumo/Onigmo lineage and is implemented inside Ruby's runtime. Onigmo 6.2.0 is a useful historical reference, but its standalone development stopped at that release. Ruby has continued to apply regexp-related patches in its own source tree. Therefore, Onibi will use the current MRI implementation and tests as its compatibility reference rather than treating the old Onigmo release as the final specification.

Onibi is initially intended for regexp-engine research and experimentation, and for test and validation workflows that need an opt-in Ruby-compatible API. The long-term goal is to replace the MRI implementation without requiring applications to change their regexp behavior.

## Goals

- Provide a pure Ruby `onibi` gem with zero runtime dependencies.
- Provide `Onibi::Regexp` and `Onibi::MatchData` APIs compatible with the documented Ruby API.
- Deliver a small Core MVP centered on `Regexp.new`, `Regexp.compile`, `Regexp#match`, and `Regexp#match?`.
- Reach API, semantic, and error compatibility for the documented `Regexp` and `MatchData` APIs in v1.
- Use Ruby 4.0.6 as the current MRI baseline and update the baseline at the beginning of the next milestone when a newer stable Ruby is selected.
- Use AST-to-Ruby code generation as the single production matcher architecture.
- Keep generated programs immutable and keep all mutable execution state invocation-local.
- Develop every feature using TDD, beginning with a failing test.
- Build toward MRI Onigumo replacement in v2 and future JRuby replacement work in v3.

## Non-goals

- Replacing Ruby's built-in `Regexp` globally in the MVP or v1.
- Monkey-patching `Regexp`, `String`, or other core classes in the MVP or v1.
- Supporting `String`'s implicit regexp integration in the MVP or v1. This includes `String#match`, `scan`, `gsub`, and `sub` using Onibi automatically.
- Adding `String`'s implicit integration remains out of scope; the v1 opt-in API may expose equivalent operations on `Onibi::Regexp` directly.
- Making performance a v1 release gate.
- Providing complete ReDoS and resource-exhaustion protection in v1.
- Supporting Ruby versions other than the selected latest stable baseline as a compatibility guarantee.
- Using C extensions, FFI, or external regexp libraries at runtime.

## Milestones

### `0.x.y`: MVP

- Publish the `onibi` gem.
- Support MRI Ruby at the current baseline.
- Provide the Core MVP API:
  - `Onibi::Regexp.new`
  - `Onibi::Regexp.compile`
  - `Onibi::Regexp#match`
  - `Onibi::Regexp#match?`
- Support UTF-8 and ASCII-8BIT.
- Implement the Core MVP syntax subset.
- Provide the initial `Onibi::MatchData` needed by the Core MVP.
- Keep use explicitly opt-in through `Onibi::Regexp`.

### `1.0.0`: Ruby-compatible library

- Support the documented `Regexp` and `MatchData` APIs in the latest stable Ruby baseline.
- Achieve observable semantic compatibility and error compatibility.
- Support all encodings supported by Onigumo in the selected Ruby baseline.
- Add JRuby, TruffleRuby, and a selected mruby build with runtime source-evaluation support using their latest stable versions.
- Run property-based and fuzz tests during the latter part of v1.

### `2.0.0`: MRI replacement compatibility

- Provide compatibility that can make Onibi a drop-in replacement for Onigumo on MRI.
- Compare Onibi against the regexp implementation included in the selected MRI source revision.
- Add the required MRI integration in the `onibi` gem initially. Reassess whether integration should be split into a separate package based on code size and complexity at this milestone.
- Add the more complete ReDoS and resource-exhaustion controls required for replacement use.

### `3.0.0`: JRuby replacement direction

Replace JRuby's regexp engine with Onibi. The exact integration design and acceptance criteria remain to be defined.

## Core MVP syntax

The Core MVP supports the following syntax and behavior:

- Literal and Unicode characters within the supported encodings.
- Concatenation and alternation, such as `a|b`.
- Capturing groups, such as `(abc)`, and numbered captures.
- Greedy quantifiers: `*`, `+`, `?`, and `{m,n}`.
- Character classes, negated classes, and ranges.
- Basic escapes such as `\d`, `\s`, `\w`, and escaped metacharacters.
- `^` and `$` anchors.
- Case-insensitive and multiline options.
- Match/no-match results and basic capture results.

The following are not required for the Core MVP and are implemented or completed in later work:

- Lookahead and lookbehind.
- Atomic groups and possessive quantifiers.
- Backreferences.
- Named captures.
- Unicode property classes.
- Complete encoding-specific behavior.
- Timeout, interrupt, and advanced resource-limit controls.

## Scenarios

### Research and experimentation

An engineer creates an `Onibi::Regexp`, runs it against strings, inspects the resulting `Onibi::MatchData`, and experiments with parser, AST analysis, and generated Ruby behavior without modifying the Ruby VM.

### Differential validation

An engineer runs the same pattern, options, and input through MRI's `Regexp` and `Onibi::Regexp`, then compares match results, captures, offsets, encoding behavior, and exceptions.

### Future MRI migration

At v2, an MRI build or integration mode allows existing Ruby code to continue using `Regexp` while Onibi provides the regexp implementation. The replacement is validated against the selected MRI/Onigumo baseline before release.

## Architecture

```text
pattern + options
        |
      Lexer
        |
   Token stream
        |
 syntactic nesting guard
        |
      Parser
        |
       AST
        |
 early optimization passes
        |
 Semantic analysis
        |
 late passes + lazy compiler CFG
        |
 Ruby source generation
        |
 capability-gated source compilation
        |
 immutable generated matcher
        |--------------------------|
      match?                    match
        |                          |
        +--- same control program-+
                   |
             offset result
                   |
            MatchData builder
        |
  Onibi::MatchData
```

### Compilation and execution

1. The lexer tokenizes the pattern.
2. An iterative token-stream guard rejects syntactic nesting above 256 before recursive descent; the parser then validates syntax and builds an AST from the guarded tokens.
3. Early ordered compiler passes perform shape changes needed before semantic analysis.
4. Semantic analysis computes capture tables, subexpression targets, option/encoding-aware width sets, nullability, option scopes, and deterministic labels.
5. Late normalization creates the compilation unit; its immutable CFG with explicit branch priority and semantic effects is materialized lazily when a CFG consumer requests it.
6. The Ruby code generator emits one regexp-specialized control program from the compilation unit. During the staged CFG migration it consumes the optimized AST paired with the CFG.
7. Portable Ruby compilation creates an immutable generated program on first use and memoizes it.
8. The generated program performs leftmost-first prioritized backtracking with invocation-local explicit stacks and capture rollback state. It does not use recursive Ruby matcher calls.
9. `match?` and `match` enter the same generated control graph. Boolean matching may omit only result work and captures proven irrelevant to matching semantics.
10. A successful matcher returns character-offset capture spans. The match-data builder creates the public `Onibi::MatchData` result and derives byte offsets as required.

The production matcher does not construct or execute NFA, DFA, or bytecode forms and does not route patterns to fallback matchers. Character predicates, Unicode tables, encoding conversion, timeout checks, and MatchData construction may remain shared leaf services, but they do not interpret the AST or select matching algorithms.

Generated source is deterministic and linear in AST size, never contains raw regexp text as Ruby syntax, and is compiled through a capability-tested host adapter. The selected mruby profile must provide runtime source evaluation; a minimal build without it is outside the v1 runtime matrix. All mutable matching state is local to an invocation, so concurrent calls on the same compiled regexp cannot corrupt one another. Detailed semantics, security boundaries, migration gates, and rejected alternatives are defined in [`regexp-ruby-codegen-design.md`](regexp-ruby-codegen-design.md).

## Interfaces

### MVP

```ruby
require "onibi"

regexp = Onibi::Regexp.new("a+")
regexp.match("aaa")
regexp.match?("aaa")
```

### v1 API inventory

The v1 inventory is derived from the documented public API in the selected latest stable Ruby documentation:

- Public `Regexp` class methods, instance methods, constants, aliases, arguments, and block behavior.
- Public `MatchData` instance methods and documented constants, if any.
- Documented observable return values and error behavior.

Private methods, undocumented implementation behavior, object identity, internal data structures, and `String`-side implicit integration are excluded from the v1 inventory.

## Compatibility

### Semantic compatibility

v1 requires equality of observable behavior through the documented public API, including:

- Search and leftmost-first semantics.
- Greedy and lazy quantifier results.
- Alternation precedence.
- Numbered and named capture values.
- Unmatched capture values.
- Capture offsets.
- Anchors and options.
- Unicode and encoding behavior.
- Documented `source`, `options`, and `inspect` output.
- Documented block behavior and match state.

Internal AST, generated labels/source, explicit-stack layout, allocation count, and compiler optimizations are not compatibility requirements.

### Error compatibility

v1 requires:

- The same decision about whether an exception is raised.
- The same exception class, such as `RegexpError`, `TypeError`, or `ArgumentError`.
- The same observable timing of the exception.
- A semantically equivalent message after excluding implementation-specific and variable details.

Onigumo- and Onibi-specific internal details are not compared.

### Differential testing

MRI's built-in `Regexp` is the v1 correctness oracle. The test harness supplies equivalent patterns, options, and inputs to both implementations and compares normalized observable results. The baseline is currently MRI Ruby 4.0.6. When a new Ruby stable version is adopted at the start of a later milestone, the baseline revision and test results are recorded before migration.

For v2, Onibi is additionally compared with the regexp implementation present in the selected MRI source revision. The historical Onigmo 6.2.0 commit `9e0f7ceee0c5182d2e930334ca9d298e69d389d9` is a reference point, not the current compatibility baseline.

## Testing and development workflow

All implementation follows TDD:

1. Create a failing test for one feature.
2. Create one worktree and branch for that feature.
3. Implement the smallest change that makes the test pass.
4. Run the feature tests and the existing suite.
5. Run RuboCop and formatting checks.
6. Open a GitHub Pull Request.
7. Merge through GitHub auto-merge using squash merge after required checks pass.

The `main` branch is protected from direct pushes.

### Test layers

- Unit tests for lexer, parser, AST analysis, Ruby code generation, generated control-flow invariants, encoding views, and match-data construction.
- Integration tests for `Onibi::Regexp` and `Onibi::MatchData`.
- Differential tests against the MRI baseline.
- Regression tests for every fixed defect.
- Property-based and fuzz tests added during the latter part of v1. Fuzz discoveries become deterministic regression tests.

### Required Pull Request checks for MVP and v1

- MRI latest baseline: Minitest, differential tests against Ruby 4.0.6, and RuboCop.
- Package validation: gem build, gem install, and a smoke test in a clean environment.

### Continuous `main` checks

- After push or merge: lightweight tests, other implementation smoke tests, and a smoke benchmark.
- Nightly: fuzz tests, long-running benchmarks, and the full encoding matrix.
- Weekly: larger fuzz corpus and Onigumo/Ruby baseline comparisons.
- Failures create or update a GitHub issue. Benchmark results are regression data, not v1 release blockers.

## Code quality and hooks

- Linting and formatting use RuboCop.
- Hook management uses `git config core.hooksPath` and scripts stored in the repository.
- The pre-commit hook identifies changed Ruby files, applies formatting, then runs lint.
- If formatting changes files, the commit stops so the developer can inspect and re-stage the changes.

## Dependencies and platforms

- Runtime dependencies: none.
- C extensions: forbidden.
- FFI: forbidden.
- Development dependencies may include Minitest, Rake, RuboCop, and libraries used for benchmarking or fuzzing.
- MVP target: MRI.
- v1 target: the latest stable MRI, JRuby, TruffleRuby, and source-eval-capable mruby build selected when the milestone begins.
- MRI is the authoritative concurrency and compatibility target for MVP. Other Ruby implementations receive explicit CI coverage in v1, but VM-specific internals are not part of Onibi's API contract.

## Performance and monitoring

Performance benchmarks are regression tests, not MVP or v1 release gates. The benchmark corpus should be informed by PCRE-JIT and RE2-style evaluations and should separate:

- compile, first-match, and warm-match costs;
- ordinary and pathological patterns;
- unoptimized and optimized generated control programs;
- input sizes and scaling behavior;
- throughput, allocations, generated source size, peak explicit-stack/trail memory, and compile time.

The initial directional target is roughly 0.5x Ruby `Regexp` throughput, but no fixed throughput threshold blocks v1. At v2, Onibi and the MRI/Onigumo baseline will be compared using the same corpus.

## Security and resource limits

AST-to-Ruby code generation does not eliminate ReDoS. Generated source is bounded linearly by AST size, numeric quantifiers are not unrolled, regexp text is never emitted as executable Ruby, and matching uses explicit step, deadline, backtrack, capture-trail, and call-stack accounting. The existing public timeout remains a required compatibility boundary. Comprehensive operational limit tuning remains v2 work, and known unsafe cases must be documented during v1 rather than hidden.

## Licensing and third-party material

Onibi is distributed under Apache License 2.0. The project may use Ruby and Onigmo behavior, tests, and documentation as compatibility references, but must not copy third-party source without preserving the applicable license and attribution. Any imported benchmark corpus or test case requires an explicit license review.

## Open issues

1. **Complete Ruby API inventory**
   - Generate and freeze the machine-readable inventory from the latest stable Ruby documentation.
   - Confirm aliases, constants, keyword arguments, and block behavior.

2. **Encoding inventory**
   - Identify the complete set of encodings supported by Onigumo in the selected MRI baseline.
   - Add representative and edge-case differential tests.

3. **Capture rollback and priority semantics**
   - Validate trail rollback and checkpoint ordering for greedy, lazy, possessive, alternation, named-capture, assertion, and unmatched-capture behavior against MRI.

4. **Non-regular syntax**
   - Complete generated explicit-stack semantics for backreferences, subexpression recursion, conditionals, and absence.
   - Keep these features in the same generated control program rather than adding a specialized interpreter.

5. **Generated program portability and Ractor behavior**
   - Validate the host source-compiler adapter, concurrent invocation, and the selected shared-regexp or per-Ractor construction contract on MRI, JRuby, TruffleRuby, and the selected mruby build during v1.

6. **MRI integration shape**
   - At v2, decide whether the integration remains in the `onibi` gem or is split after measuring code size, build complexity, ABI concerns, and maintenance cost.

7. **Ruby baseline update procedure**
   - Define the exact checklist and compatibility report format used when a new stable Ruby becomes the next milestone baseline.

## Alternatives considered

- **Global monkey patch in MVP:** rejected because it would make VM and gem compatibility failures difficult to isolate.
- **Immediate VM-level replacement:** deferred to v2 because it would expand the MVP beyond a pure Ruby research and validation gem.
- **NFA/DFA execution or NFA/DFA-to-Ruby generation:** rejected because maintaining automata, capture-aware variants, backend selection, and fallback paths conflicts with the single-matcher maintenance objective.
- **Permanent reference VM:** permitted only as a test oracle during the bounded migration and rejected in the final production architecture because it would preserve duplicate semantics.
- **CRuby instruction-sequence generation:** rejected as a production dependency because Onibi targets portable Ruby implementations; it may be used only in optional diagnostics.
- **Performance as a v1 gate:** rejected because v1 prioritizes API, semantic, and error compatibility; performance is initially regression data.
- **Runtime C extension or FFI:** rejected to preserve the pure Ruby implementation and zero runtime dependencies.

## References

- [How to Write an Effective Software Design Document](https://refactoringenglish.com/excerpts/write-an-effective-design-doc/)
- [Extending the PCRE Library with Static Backtracking Based Just-in-Time Compilation Support](https://doi.org/10.1145/2544137.2544146)
- [RE2 benchmark source](https://code.googlesource.com/re2/%2B/refs/heads/main/re2/testing/regexp_benchmark.cc)
- [Onigmo 6.2.0 reference commit](https://github.com/k-takata/Onigmo/commit/9e0f7ceee0c5182d2e930334ca9d298e69d389d9)
- [Ruby 4.0.6 release](https://github.com/ruby/ruby/releases/tag/v4.0.6)
- [Ruby source repository](https://github.com/ruby/ruby/)
