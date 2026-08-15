# Onibi HFA Architecture Migration Task List

## Status and purpose

This is the implementation plan for replacing the current collection of
benchmark-shaped direct matchers and adaptive NFA/DFA transition cache with a
general hybrid finite automaton architecture.

In this document, **HFA** has its classical meaning: a bounded head DFA whose
border states activate one or more tail NFAs. Onibi adds a separate, upper
decomposition layer inspired by Hyperscan: mandatory strings and regular or
semantic subgraphs become coordinated components. The decomposition layer does
not change the definition of the HFA inside an FA component.

The target pipeline is:

```text
source
  -> tokens
  -> AST
  -> semantic analysis
  -> optimized CFG
  -> regular/effect region analysis
  -> regexp decomposition
  -> immutable component graph
       |- string components
       |- head-DFA components
       |- tail tagged-NFA components
       `- typed semantic components
  -> lazily compiled immutable HFA program
  -> common result iterator
  -> match? / match / scan / gsub
```

This list is ordered. An agent must not start a task until all listed
dependencies have merged into `main`.

## Fixed architectural decisions

- One `Onibi::Regexp` compiles to one immutable component graph and one HFA
  program. There is no public backend selector or pattern-text router.
- Each regular FA component uses a classical head-DFA/tail-NFA layout. A DFA
  budget overflow creates a border and leaves the remaining paths in tail
  NFAs; it does not select a different matcher backend.
- The component graph is built from compiler facts published by the optimized
  CFG. Public API methods must not independently recognize AST shapes.
- Head DFA regions must be regular, effect-free, and priority-insensitive.
  Capture writes or reads, ordered choices whose path affects the result,
  assertions with observable state, cuts, calls, and backreferences are
  barriers.
- Barrier regions execute as ordered/tagged tail NFAs or typed semantic
  components in the same graph. A second whole-pattern verifier is prohibited.
- Initial head-DFA capacity is 4,096 rows per program. A tail-NFA bitset segment
  contains at most 512 position states. Larger tails use multiple segments;
  they are not rejected because of the internal segment size.
- The HFA program is compiled on first use, fully initialized before
  publication, memoized per regexp, immutable after publication, and safe for
  concurrent calls.
- Initial string decomposition is restricted to mandatory ASCII strings at
  least four bytes long, no more than eight expanded alternatives, and edges
  with statically representable offset bounds.
- A literal value may be stored in a string component and searched. Its value
  must not decide which optimization implementation is selected. Production
  code must not recognize benchmark tokens such as `http`, `://`, or the Regex
  Redux line-removal expression.
- The implementation remains pure Ruby with no runtime dependencies, C
  extensions, FFI, or generated-Ruby backend.
- MRI Ruby 4.0.6 remains the compatibility oracle until a separate milestone
  changes the baseline.

## Global completion rule

Every behavior-changing task follows the repository TDD and delivery process:

1. Create a dedicated worktree and `codex/<task-id>-<description>` branch from
   current `main`.
2. Add the public acceptance or MRI differential test named by the task.
3. Run it and record that it fails for the expected architectural or behavior
   reason.
4. Add supporting unit tests only where they clarify compiler facts or runtime
   state; they do not replace the public acceptance test.
5. Implement the smallest complete slice described by the task.
6. Run the focused tests, complete suite, applicable cross-runtime contract,
   RuboCop, gem build, clean installation, and smoke test.
7. Commit one atomic change, push it, and open one pull request.
8. Wait for every configured check. Enable squash auto-merge only after all
   checks are complete and successful, then remove the worktree.

For each task, use the same selected Ruby installation for Ruby, Bundler,
Rake, RuboCop, and `gem`:

```sh
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
ruby -v
command -v ruby
bundle -v
```

Unless a task narrows the commands further, its final local gates are:

```sh
bundle exec rake test
bundle exec rubocop
bundle exec rake build
bundle exec ruby script/cross_runtime_contract.rb
```

## Optimization admission rule

An optimization may merge only when all of the following are true:

1. Its eligibility is expressed entirely in CFG, semantic-analysis, or
   automaton facts.
2. The correctness proof states why skipped input positions or transitions
   cannot participate in an MRI-visible match.
3. A seeded metamorphic family changes literals, class members, prefix and
   suffix lengths, repeat widths, and input density while retaining the same
   structural property.
4. Public MRI differential tests pass for every family member, including
   captures and offsets when applicable.
5. At least two unrelated pattern families show a bootstrap 95% confidence
   interval lower bound of 1.02 for speedup over ten or more independent
   samples.
6. A dense-event holdout family has a speed ratio confidence interval lower
   bound of at least 0.95.
7. The report records commit SHA, Ruby/runtime configuration, corpus seed,
   input sizes, operation, warmup, iterations, wall time, allocations, and GC
   deltas.

Macro benchmarks and Regex Redux remain observational workloads. Passing or
improving one of their exact expressions is never sufficient evidence for an
optimization.

## Task dependency map

```text
HFA-000
  |
HFA-001
  |
HFA-010 -> HFA-011 -> HFA-012
                         |
          +--------------+--------------+
          |                             |
       HFA-020                        HFA-030
          |                             |
       HFA-021                        HFA-031
          |                             |
       HFA-022                        HFA-032
          |                             |
       HFA-023 -------------------------+
          |
       HFA-040 -> HFA-041 -> HFA-042 -> HFA-043
                                          |
                 HFA-050 -> HFA-051 -> HFA-052
                                          |
                 HFA-060 -> HFA-061 -> HFA-062
```

## Phase 0: establish the contract and stop benchmark coupling

### HFA-000 - Publish the canonical HFA design [Complete]

- **Priority:** P0
- **Dependencies:** none
- **Change type:** documentation only

Published `docs/hfa-design.md` as the canonical architecture document. It
define the head DFA, border state, tail NFA activation, component graph,
decomposition correctness conditions, semantic barriers, runtime state,
resource budgets, and concurrency model. Include the mathematical NFA
transition and the head-DFA subset construction.

The canonical design overview, CFG pipeline, README, and development guide now
point to it. Superseded hybrid-backend, Hyperscan, generated-Ruby work-package,
MVP, and v1 documents live under `docs/history/`. Missing generated-Ruby design
references and claims that production must not execute an NFA or DFA were
removed from active documentation.

**Completion evidence:** all internal documentation links resolve; the full
test, lint, and package gates pass without a library behavior change.

### HFA-001 - Freeze, inventory, and remove benchmark-literal recognizers [Complete]

- **Priority:** P0
- **Dependencies:** HFA-000

Add MRI differential cases that mutate every literal in the URL-shaped and
Regex-Redux-shaped expressions while retaining their structure. Confirm the
tests expose that only the original literal values enter the direct path.

Remove the recognizers that explicitly require:

- `http`, optional `s`, `://`, and `/` in the URL capture scanner;
- the exact `>.*\n|\n` alternation in the line-removal scanner.

Do not replace them with another direct recognizer. Route them through the
existing general matcher until later HFA tasks provide a structural
optimization.

Create an inventory table in the canonical design appendix for every remaining
direct specialization. Classify each entry mechanically:

- **remove:** eligibility compares a literal to a benchmark/application token;
- **migrate:** eligibility depends only on general AST structure and has an
  expressible CFG fact;
- **temporary semantic bridge:** required for MRI behavior not yet represented
  by the generic HFA.

**Acceptance:** mutated URL and line-removal families produce identical
`match?`, `match`, `scan`, and `gsub` results under MRI and Onibi. No production
condition contains the removed benchmark literals.

## Phase 1: make compiler facts authoritative

### HFA-010 - Publish semantic and width facts on the compilation unit [Complete]

- **Priority:** P0
- **Dependencies:** HFA-001

Add immutable analysis facts for every CFG operation and block:

- nullable;
- minimum and maximum consumed width, with an explicit unbounded value;
- byte/character width mode;
- first and last character sets, including unknown;
- capture reads and writes;
- assertion, choice, repeat, cut, and call effects;
- option and encoding scope.

Facts are computed once from typed operands and propagated through sequence and
ordered choice. Unknown or encoding-dependent values must remain conservative.

**First failing acceptance test:** public MRI differential patterns combine
nullable branches, scoped options, captures, and bounded/unbounded repeats.
Expose the compilation unit only to a supporting test and confirm each public
result remains unchanged after analysis is enabled.

**Completion:** every fact object is frozen; analysis never reconstructs or
parses regexp source text.

### HFA-011 - Compute regular regions and semantic barriers [Complete]

- **Priority:** P0
- **Dependencies:** HFA-010

Partition the optimized CFG into maximal regions with these classifications:

- `regular_effect_free`;
- `regular_tagged`;
- `semantic`.

A region may be a head-DFA candidate only when it is
`regular_effect_free` and priority-insensitive. Capturing groups,
backreferences, subexpression calls, absence operators, observable assertions,
atomic cuts, and ambiguous ordered alternatives must split or downgrade a
region.

**First failing acceptance test:** use pairs whose accepted language is the
same but MRI result differs by priority or capture, such as prefix-related
alternatives and captures under greedy repetition. Verify that enabling region
analysis never changes full match or capture offsets.

**Completion:** every CFG block belongs to exactly one region; region boundaries
preserve all incoming and outgoing priority/effect information.

### HFA-012 - Introduce the immutable component graph [Complete]

- **Priority:** P0
- **Dependencies:** HFA-011

Add an internal immutable graph with these node contracts:

- `StringComponent`: literal alternatives and their consumed widths;
- `HeadDFAComponent`: deterministic table and border activations;
- `TailNFAComponent`: position topology, tag mode, and accept reports;
- `SemanticComponent`: typed operand plus state effects.

Edges carry minimum/maximum offset, activation kind, source priority, and
effect-state tokens. The graph owns entry and accept reports. Do not expose the
graph through the public `Onibi::Regexp` API.

Initially lower the whole pattern to one placeholder tail component so this
task changes representation without changing execution.

**First failing acceptance test:** compile and execute structurally unrelated
literal, alternation, quantified, capture, assertion, and backreference
patterns through the public API. The supporting test verifies graph immutability
and complete CFG-region coverage.

## Phase 2: implement classical head-DFA/tail-NFA execution

### HFA-020 - Lower regular regions to Glushkov position NFAs [Complete]

- **Priority:** P0
- **Dependencies:** HFA-012

Build an epsilon-free position NFA for each regular region. Publish first,
last, follow, nullable, and per-symbol reach sets. Assign stable state IDs in
CFG order and encode follow edges as span masks when profitable without making
span layout part of semantics.

Support multiple 512-position bitset segments. A region larger than one segment
must continue matching correctly; `UnsupportedPattern` is not permitted solely
because of the segment limit.

**First failing acceptance test:** generate concatenations and bounded
alternations crossing 511, 512, and 513 position states and compare `match?`
and `match` with MRI.

### HFA-021 - Build a bounded head DFA and border states [Complete]

- **Priority:** P0
- **Dependencies:** HFA-020

Perform subset construction from each eligible region entry. Stop expanding a
subset when adding its transition rows would exceed the remaining 4,096-row
program budget or enter a non-head-eligible region. Mark that subset as a
border state and attach the corresponding tail-NFA entry subset.

The head DFA table must be complete for all retained states. It may use byte
class compression internally, but a missing table entry must not trigger
runtime subset construction.

**First failing acceptance test:** compile the same public patterns with test
budgets 0, 1, a boundary value, and 4,096. Results, captures, and offsets must
remain identical before and after warmup.

### HFA-022 - Execute border activations and concurrent tail NFAs [Complete]

- **Priority:** P0
- **Dependencies:** HFA-021

Implement runtime state as:

- one head-DFA state per active head component;
- an activation set for border occurrences;
- one or more active bitset segments per tail activation;
- candidate start and component offset metadata;
- pending accept reports.

Process each input unit in deterministic component and priority order. Deduplicate
equivalent tail activations only when start, tags, semantic state, and required
report behavior are identical.

**First failing acceptance test:** inputs repeatedly reach the same border with
overlapping starts and multiple tail activations. Compare hit, miss, earliest
start, and accepted end offsets with MRI.

### HFA-023 - Lazily publish an immutable HFA program [Complete]

- **Priority:** P0
- **Dependencies:** HFA-022

Move HFA compilation behind the first matching operation. Build the complete
component graph and head tables in invocation-local state, freeze them, then
publish one memoized program. A concurrent caller must see either no program or
the fully initialized program.

Remove runtime mutation of DFA rows from the new path. Keep the old adaptive
cache only as a temporary route for not-yet-migrated semantic shapes.

**First failing acceptance test:** multiple threads call all four public API
families on one regexp during first use. Every result matches a serial MRI
oracle and only one immutable program becomes observable internally.

## Phase 3: add regexp decomposition and string events

### HFA-030 - Implement mandatory-string extraction [Complete]

- **Priority:** P1
- **Dependencies:** HFA-012

Replace the no-op dominance pass with real dominator and post-dominator facts.
Extract a string only when a graph proof shows that every path from region entry
to every relevant accept crosses that string or one member of a finite string
cut-set.

Initial eligibility is:

- ASCII literal length at least four bytes;
- at most eight expanded alternatives;
- no capture/effect boundary inside the extracted string;
- known position relative to adjacent components;
- extraction does not reorder MRI alternatives.

**First failing acceptance test:** include optional, nullable, alternation, loop,
and assertion patterns where a visually present literal is not mandatory. A
false extraction must cause the test to fail through public behavior, not only
through plan inspection.

### HFA-031 - Add monotonic string-event sources [Complete]

- **Priority:** P1
- **Dependencies:** HFA-030

Implement immutable event sources using `String#index`. An event reports
component ID, start, end, and alternative ID. Event cursors move monotonically
and do not allocate a MatchData or substring.

For a confirmed literal event, initialize the successor FA from the state that
represents the already-consumed literal. Do not rescan the literal through the
NFA.

**First failing acceptance test:** seeded families vary literal content and
density, include overlapping literals, non-zero origins, empty suffixes, and
late hits. Compare all public results with MRI.

### HFA-032 - Coordinate component activation and offset windows [Complete]

- **Priority:** P1
- **Dependencies:** HFA-023, HFA-031

Add an ordered event coordinator. An edge may enable a successor only when the
predecessor completed and the event lies in the edge's inclusive
minimum/maximum offset window. Unbounded maxima are explicit. Event queues are
ordered by input position and CFG priority.

If decomposition is ineligible, compile one unsplit HFA component. Do not use a
runtime engine selector based on a benchmark pattern or application name.

**First failing acceptance test:** literal-gap-literal chains cover exact,
bounded, unbounded, greedy, lazy, sparse, and dense events. Verify leftmost
start and end choices, not only boolean acceptance.

## Phase 4: preserve MRI captures and priority in the component graph

### HFA-040 - Add tagged tail-NFA capture state [Complete]

- **Priority:** P0
- **Dependencies:** HFA-032

Represent capture start/end writes as ordered tag operations on tail-NFA
transitions. Each surviving path carries persistent capture history or an
equivalent rollback-safe representation. Boolean matching may elide a tag only
when liveness proves it cannot affect a backreference, conditional, call, or
public result.

**First failing acceptance test:** nested, repeated, optional, unmatched,
duplicate-named, and multibyte captures compare values and character/byte
offsets with MRI before and after HFA compilation.

### HFA-041 - Preserve ordered choice and quantifier priority [Complete]

- **Priority:** P0
- **Dependencies:** HFA-040

Carry CFG edge priority through tail-thread ordering and accept-report
selection. Define an explicit total ordering using candidate start, CFG choice
priority, greedy/lazy repeat decisions, and report sequence. Atomic and
possessive cuts discard only paths within their declared cut scope.

Do not determinize a region if merging paths would erase a distinction required
by this ordering.

**First failing acceptance test:** cover prefix alternatives, nested greedy and
lazy repeats, atomic alternatives, possessive repeats, and equal-end matches
with different captures.

### HFA-042 - Lower nonregular constructs to typed semantic components [HFA-042a/b/c Complete]

- **Priority:** P1
- **Dependencies:** HFA-041

Implement semantic components for backreferences, lookarounds that require
state, subexpression calls, conditionals, absence constructs, and match reset.
Each component receives and returns cursor, tag state, call/cut state, and
ordered successor activations. It may inspect input but must not parse regexp
source or re-run the whole pattern.

Migrate one construct family per atomic PR under this task ID with a suffix,
for example `HFA-042a` for backreferences and `HFA-042b` for lookarounds.

**First failing acceptance test:** each subtask begins with the existing MRI
differential corpus plus at least one interaction with a string component and
one interaction with a DFA border.

### HFA-043 - Unify public APIs on one result iterator [Complete]

- **Priority:** P0
- **Dependencies:** HFA-042

Create one internal iterator yielding complete raw results:

```text
[match_start_byte, match_end_byte, capture_byte_ranges]
```

`match?` consumes only the first accepted report and may use proven capture
liveness. `match` builds MatchData from the first report. `scan` and `gsub`
consume reports while applying MRI empty-match advancement and replacement
rules. No API keeps a separate AST-shape whitelist.

**First failing acceptance test:** run the same pattern/input table through all
four APIs and compare report order, captures, empty matches, block behavior,
replacement expansion, and encodings with MRI.

## Phase 5: migrate useful general optimizations and delete direct paths

### HFA-050 - Migrate literal and class-run optimizations [Complete]

- **Priority:** P1
- **Dependencies:** HFA-043

Express exact literals, first-byte sets, literal-class-literal sequences,
adjacent class runs, fixed repeats, and delimited class runs as compiler facts
or component-graph layouts. Apply the optimization to arbitrary literals and
classes satisfying the proof.

After each family migrates, delete its old spec builder, public-API dispatch
branch, and duplicated result iterator in the same PR.

**First failing acceptance test:** seeded metamorphic families vary all literal
bytes, class membership, run length, delimiter, origin, encoding, and capture
placement.

### HFA-051 - Migrate alternation and capture-sequence optimizations

- **Priority:** P1
- **Dependencies:** HFA-050

Use CFG branch threading, finite cut-sets, and common-prefix/suffix facts for
literal alternations and straight-line capture sequences. Preserve source
branch priority when alternatives overlap. A capture sequence may use a
delimiter event only when exclusion and width facts prove the delimiter cannot
be consumed by the preceding class.

Remove the application-shaped alternation, structured-log, email, and
identifier scanners as their general equivalents land.

**First failing acceptance test:** transform application examples into
unrelated alphabets and layouts while retaining the same CFG property; include
overlapping branches and delimiter-inside-class negative cases.

### HFA-052 - Remove facade shape routing and the adaptive-cache runtime

- **Priority:** P0
- **Dependencies:** HFA-051

Delete remaining `hfa_*_safe?` whitelists, AST-shape flags initialized by
`Onibi::Regexp`, API-specific direct scanners, and specialized runtime branches
whose semantics are now represented in the component graph. Remove the old
runtime lazy-DFA row mutation after no public pattern depends on it.

Keep only leaf services that do not choose a matching algorithm: character
predicates, Unicode tables, encoding conversion, timeout checks, replacement
expansion, and MatchData construction.

**First failing acceptance test:** the full MRI differential suite runs with a
test hook that fails if any legacy matcher entrypoint is called. Public behavior
and cross-runtime results remain unchanged.

## Phase 6: enforce generality and complete the migration

### HFA-060 - Add the optimization genericity harness

- **Priority:** P1
- **Dependencies:** HFA-052

Add a seeded generator for structurally equivalent pattern families and sparse,
dense, early-hit, late-hit, and miss corpora. The harness records which compiler
facts and passes apply without inspecting production source files. It verifies
MRI equivalence first, then measures performance outside the normal correctness
suite.

Keep benchmark runners under `benchmark/` or profiling tools under `script/`.
Tests under `test/` may verify only library behavior and deterministic MRI
equivalence, not benchmark thresholds or file presence.

**Acceptance:** changing only literal values never changes the selected pass or
component kinds unless a documented alphabet/encoding/selectivity fact changes.

### HFA-061 - Publish the lifecycle and holdout benchmark report

- **Priority:** P1
- **Dependencies:** HFA-060

Measure separately:

- construction before HFA compilation;
- first operation including lazy compilation;
- warm `match?`;
- warm `match`;
- `scan`;
- `gsub`;
- allocations and GC deltas for each.

Use at least two development families and two holdout families for each
optimization class. Include Regex Redux and application macro workloads only as
additional observations. Report negative results and disable any optimization
that fails the admission rule.

**Completion:** checked-in documentation records the required environment and
reproduction commands; correctness is checked before any timing is reported.

### HFA-062 - Make the new HFA the sole production architecture

- **Priority:** P0
- **Dependencies:** HFA-061

Remove transitional documentation and implementation terminology that calls
the former adaptive subset cache or direct string scanners an HFA. Retain PoC
documents only with explicit historical headers. Update architecture diagrams,
compatibility notes, performance guidance, and the task list statuses.

Run the full test suite, cross-runtime contract, fuzz/property tasks, RuboCop,
gem build, clean installation, and smoke test. Confirm the gem contains no old
backend or missing-design references.

**Definition of migration complete:**

- every supported pattern executes through one component graph;
- every regular FA component has a head-DFA/tail-NFA representation, including
  the valid degenerate cases of an empty head or empty tail;
- string events come only from mandatory decomposition proofs;
- captures and MRI priority use tagged/semantic graph state rather than API
  shape routing;
- changing benchmark literals cannot select a different implementation except
  through documented general compiler facts;
- all required CI and package gates are green.

## Per-task handoff template

Every agent should include this information in its pull request description:

```markdown
## Task

HFA-NNN - task title

## Failing acceptance test

- Test file and method:
- Expected pre-change failure:
- MRI behavior protected:

## Compiler/runtime change

- New or changed facts:
- Affected component types:
- Correctness argument:
- Resource-budget behavior:

## Validation

- Focused test:
- Full suite:
- Cross-runtime contract:
- RuboCop:
- Gem build/install/smoke:

## Performance evidence

- Commit SHA:
- Ruby/runtime:
- Pattern families and seeds:
- Input distributions and sizes:
- Iterations and warmup:
- Time/allocation result:
- Holdout regression result:
```

If an agent discovers that a task requires an architectural decision not fixed
above, it must stop and propose an amendment to the canonical design and this
task list. It must not encode the decision as another direct specialization.
