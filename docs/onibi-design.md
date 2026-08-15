# Onibi: Pure Ruby Regular Expression Engine

## Metadata

- **Status:** active product and architecture overview
- **Created:** 2026-08-09
- **Last architecture revision:** 2026-08-15
- **Current compatibility baseline:** MRI Ruby 4.0.6
- **Canonical matcher design:** [`hfa-design.md`](hfa-design.md)
- **License:** Apache License 2.0

## Objective

Onibi is a pure Ruby regular expression engine providing opt-in,
Ruby-compatible `Regexp` and `MatchData` APIs. It is a research and validation
platform today and is intended to become capable of replacing MRI's regexp
implementation in a later milestone.

MRI's current regexp behavior and tests are the compatibility authority.
Onigmo 6.2.0 remains a historical implementation reference, not the final
specification, because regexp development continued in Ruby itself.

## Goals

- Ship a pure Ruby gem with no runtime dependencies, C extension, or FFI.
- Provide `Onibi::Regexp` and `Onibi::MatchData` with documented MRI-compatible
  results, captures, offsets, encodings, errors, and block behavior.
- Use the HFA architecture in [`hfa-design.md`](hfa-design.md) as the sole
  production matcher architecture.
- Preserve MRI leftmost-first priority and capture semantics across all
  compiler optimizations.
- Keep compiled programs immutable and mutable execution state invocation-local.
- Develop every behavior change through public acceptance and MRI differential
  tests.
- Build toward MRI replacement in v2 and future JRuby integration work.

## Non-goals

- Replacing Ruby's global `Regexp` or monkey-patching core classes in v1.
- Implicit `String`/`Symbol` regexp integration in v1.
- Treating performance as permission to weaken compatibility.
- Complete operational ReDoS protection in v1.
- Runtime native dependencies.
- A public engine selector, pattern-text router, generated-Ruby matcher, or
  silent whole-pattern fallback.

## Milestones

### Core MVP (`0.x.y`) — complete

The MVP delivered the gem, explicit constructors, `match`, `match?`, initial
UTF-8/ASCII-8BIT behavior, core syntax, captures, and differential tests. Its
implementation sequence is preserved in
[`history/core-mvp-task-list.md`](history/core-mvp-task-list.md). Architecture
requirements in that record are not current requirements.

### v1 Ruby-compatible opt-in library — compatibility implementation complete,
validation remains continuous

The explicit `Onibi::Regexp`/`Onibi::MatchData` API and extended syntax work
are recorded in [`history/v1-task-list.md`](history/v1-task-list.md). Current
coverage and remaining compatibility qualifications live in
[`regexp-feature-coverage.md`](regexp-feature-coverage.md).

### HFA architecture migration — active

Replace transitional adaptive-cache and direct pattern-shape paths with the
formally defined component graph, bounded head DFA, tail NFAs, mandatory-string
events, tagged state, semantic components, and common result iterator. The
ordered plan is [`hfa-task-list.md`](hfa-task-list.md).

### v2 MRI replacement compatibility — future

- Validate against the regexp implementation in the selected MRI revision.
- Define and implement VM integration without changing observable behavior.
- Add replacement-grade resource controls and operational diagnostics.
- Reassess package boundaries only after integration cost is measured.

### v3 JRuby replacement direction — future

Define JRuby integration after the portable HFA and MRI replacement contracts
are stable.

## Public scope

Onibi remains explicit and opt-in:

```ruby
require "onibi"

regexp = Onibi::Regexp.new("(?<word>a+)", Onibi::Regexp::IGNORECASE)
match = regexp.match("xxAAA")

regexp.match?("xxAAA")
match["word"]
match.offset("word")
regexp.scan("a1 a2")
regexp.gsub("a1 a2", "b")
```

The v1 inventory includes documented public `Regexp` and `MatchData` behavior
observable through this explicit API. Global match variables,
`Regexp.last_match`, regexp-literal encoding syntax, and implicit core-class
integration are excluded until a replacement milestone explicitly adds them.

## Canonical architecture

```text
pattern + options
  -> tokens -> AST -> semantic analysis
  -> optimized immutable CFG
  -> regular/effect regions and regexp decomposition
  -> immutable component graph
       |- mandatory strings
       |- HFA components: bounded head DFA + tail NFA
       |- tagged tail NFA
       `- typed semantic components
  -> lazily published immutable HFA program
  -> ordered raw-result iterator
  -> match? / match / scan / gsub
  -> MatchData / replacement result
```

The formal definitions, construction algorithm, runtime state, resource
budgets, and concurrency invariants are normative in
[`hfa-design.md`](hfa-design.md). This overview records product-level
boundaries.

### Frontend and semantic analysis

1. The lexer tokenizes the pattern.
2. An iterative guard rejects excessive syntactic nesting before recursive
   descent.
3. The parser validates syntax, option scopes, group numbering, and builds an
   AST.
4. Semantic analysis computes immutable width, nullability, character-set,
   capture, effect, option, encoding, and priority facts.
5. Deterministic CFG passes optimize structure while preserving ordered edges
   and explicit semantic effects.

### HFA compilation

1. Region analysis separates effect-free regular, tagged regular, and semantic
   regions.
2. Decomposition extracts only strings proven mandatory by graph facts.
3. Every regular FA component is first lowered to a position NFA.
4. Bounded subset construction creates a head DFA. Unretained transitions are
   explicit borders that activate tail NFA subsets.
5. Capture-sensitive regular regions retain tags and priority in their tails.
6. Nonregular operations become typed semantic components in the same graph.
7. The complete program is frozen before lazy memoized publication.

An HFA head/tail boundary is not backend selection. String components are an
upper decomposition layer inspired by Hyperscan and are not themselves the
definition of HFA.

### Execution and results

One invocation-local runtime coordinates string events, head states, border
activations, tail subsets, tags, semantic state, resource counters, and ordered
accept reports. It does not generate or evaluate Ruby source and does not
restart another matcher for semantic verification.

All public matching APIs consume one raw-result iterator. `match?` may omit
only state proven irrelevant; `match` builds `Onibi::MatchData`; `scan` and
`gsub` preserve MRI's empty-match progression and capture/replacement rules.

## Compatibility contract

### Semantic compatibility

The v1 target is equality of observable behavior through the documented
opt-in API, including:

- leftmost-first search and branch priority;
- greedy, lazy, atomic, and possessive behavior;
- numbered/named captures and unmatched captures;
- character and byte offsets;
- anchors, options, Unicode, encodings, and invalid bytes;
- source/options/inspection behavior;
- documented block and replacement behavior.

Internal AST, CFG, component layout, DFA budget, tail segmentation, and
optimization choices are not public behavior. Changing any internal budget or
warming a regexp must not change results.

### Error compatibility

Where MRI has an equivalent, Onibi matches whether an exception is raised, its
public class, observable call timing, and a semantically equivalent message
after implementation-specific details are normalized.

### Differential testing

MRI Ruby 4.0.6 is the current oracle. Tests compare patterns, options, inputs,
matches, captures, offsets, encodings, returns, and exceptions. A later
milestone may update the baseline only when the API inventory, differential
corpus, encoding matrix, and CI configuration are updated together.

## Testing and delivery

Every public behavior change begins with a failing acceptance test. An MRI
equivalent requires a differential assertion. After the focused test passes,
the complete suite, RuboCop, package build, clean install/smoke, and applicable
cross-runtime contract must pass before merge.

Tests under `test/` protect library behavior. Benchmark thresholds, workflow
file contents, package file inventories, and development harness internals are
validated by their own tooling rather than pseudo-feature tests.

## Performance policy

Correctness precedes speed. Compiler optimizations must be derived from
semantic, CFG, region, or automaton facts and apply to unrelated patterns with
the same proven structure. Literal identity, application name, or presence in
a checked-in benchmark cannot select an implementation.

Reports separate:

- construction before lazy HFA compilation;
- first operation including compilation;
- warm `match?` and `match`;
- `scan` and `gsub`;
- time, allocations, and GC effects.

Every optimization uses correctness-checked development and holdout families,
including sparse and dense inputs. Exact Regex Redux and macro-benchmark cases
are observations, never optimization specifications. Detailed admission rules
are in [`hfa-task-list.md`](hfa-task-list.md).

## Security and resource limits

HFA is not by itself a ReDoS guarantee. Onibi retains public timeout behavior
and requires explicit accounting for steps, active tails, tag/capture trails,
call state, and checkpoints. DFA rows and bitset segment sizes are bounded.
Resource limits may stop execution with the documented error; they may not
silently choose a different result or matcher.

## Dependencies and platforms

- Runtime dependencies: none.
- C extensions: prohibited.
- FFI: prohibited.
- Current authoritative runtime: MRI Ruby 4.0.6.
- JRuby, TruffleRuby, and selected mruby profiles receive compatibility
  coverage without becoming semantic authorities.

## Current limitations and open work

1. Complete the HFA migration and remove transitional direct AST-shape/API
   routers and the mutable adaptive DFA cache.
2. Complete a single tagged/semantic component model for captures,
   backreferences, assertions, calls, cuts, and match reset.
3. Validate the full selected encoding inventory and baseline-update process.
4. Tune replacement-grade timeout and resource controls.
5. Define MRI integration for v2 after the standalone engine is stable.

These are tracked as architecture migration tasks, compatibility coverage, or
future milestones; obsolete implementation plans are not reopened.

## Document governance

Active normative documents are:

- this product overview;
- [`hfa-design.md`](hfa-design.md);
- [`cfg-optimization-pipeline.md`](cfg-optimization-pipeline.md);
- [`hfa-task-list.md`](hfa-task-list.md);
- [`regexp-feature-coverage.md`](regexp-feature-coverage.md).

Completed plans, rejected designs, and benchmark PoCs live under
[`history/`](history/README.md). Historical records retain their original
technical claims with a header stating what supersedes them. They are not
current implementation guidance.

## References

- [Ruby source repository](https://github.com/ruby/ruby/)
- [Onigmo 6.2.0 reference commit](https://github.com/k-takata/Onigmo/commit/9e0f7ceee0c5182d2e930334ca9d298e69d389d9)
- [Hyperscan NSDI 2019 paper](https://www.usenix.org/system/files/nsdi19-wang-xiang.pdf)
- [RE2 benchmark source](https://code.googlesource.com/re2/%2B/refs/heads/main/re2/testing/regexp_benchmark.cc)
