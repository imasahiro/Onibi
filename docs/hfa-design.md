# Onibi Hybrid Finite Automata Design

## Document status

- **Status:** normative architecture specification
- **Effective date:** 2026-08-15
- **Compatibility baseline:** MRI Ruby 4.0.6
- **Supersedes:** generated-Ruby matcher designs, the adaptive-cache PoC, and
  benchmark-shaped direct matcher designs
- **Implementation state:** target architecture; migration is tracked in
  [`hfa-task-list.md`](hfa-task-list.md)

This document is the authority for matcher architecture. If another document
conflicts with it, this document wins. Historical documents explain past
decisions or measurements and are not implementation requirements.

## 1. Definition of HFA in Onibi

In Onibi, a **hybrid finite automaton (HFA)** is one finite-automaton component
with both of the following regions:

1. a bounded, eagerly compiled **head DFA** that starts at the component entry;
2. one or more **tail NFAs** activated by transitions leaving the retained DFA
   region.

The transition from a retained head state to a tail is a **border**. A border
records the NFA subset, component offset, priority, and semantic/tag context
needed to continue without restarting the expression. The head and tails are
therefore parts of one automaton, not alternative matcher backends.

The degenerate cases are valid:

- an empty head means the component begins in its tail NFA;
- an empty tail means the bounded DFA covers the complete regular component.

The term HFA does **not** mean any of the following:

- a runtime choice between unrelated DFA and NFA engines;
- a lazy cache that happens to memoize NFA subset transitions;
- a collection of literal-specific Ruby loops;
- a pattern-text router selecting benchmark-specific algorithms;
- a generic label for every mixture of string matching and automata.

## 2. Formal model

Let a regular component first be lowered to an epsilon-free position NFA

```text
N = (Q, Sigma, delta, I, F)
```

where `Q` is the finite position set, `Sigma` is the input alphabet, `I` is the
initial subset, `F` is the accepting subset, and

```text
delta(S, a) = union(delta(q, a) for q in S)
```

for NFA subset `S` and input symbol `a`.

The head is a partial subset construction

```text
D_h = (Q_h, Sigma, delta_h, q_h0, F_h)
```

where every `q_h` represents an NFA subset and `|Q_h|` is bounded by the
program's DFA-row budget. For a retained transition,

```text
delta_h(q_h, a) = encode(delta(decode(q_h), a))
```

If the successor subset is not retained because the budget is exhausted or
the transition reaches a semantic or priority barrier, the compiler emits

```text
border(q_h, a) = (tail_id, entry_subset, continuation_metadata)
```

instead. Runtime tail execution applies the original NFA transition relation
from `entry_subset`. No input is replayed and no whole-pattern verifier is
started at the border.

For a position NFA, each consuming syntax position has one stable state ID.
`first`, `last`, `follow`, nullable, and per-symbol reach sets define the
topology. Bit-parallel masks are an implementation of the NFA subset, not a
different semantics. Onibi initially limits one mask segment to 512 positions;
larger NFAs use multiple segments.

## 3. Onibi HFA versus Hyperscan

Hyperscan is an important source for decomposition, necessary-string
extraction, event coordination, and compact regular engines. Its production
architecture coordinates multiple engine families for high-throughput,
multi-pattern scanning. It is not the definition of Onibi's HFA.

| Topic | Onibi HFA | Hyperscan-inspired layer in Onibi |
| --- | --- | --- |
| Unit being defined | one FA component | graph of string, FA, and semantic components |
| Hybrid boundary | bounded head DFA to tail NFA | event/offset edge between components |
| Primary semantics | MRI leftmost-first matches and captures | conservative candidate activation |
| String matching | optional mandatory-string component | FDR/Teddy/Rose ideas adapted to `String#index` |
| Nonregular syntax | typed semantic component in the same graph | not delegated to a second verifier |
| Runtime implementation | pure Ruby | pure Ruby; no SIMD, C, or FFI assumption |
| Match reporting | ordered full results and captures | events constrain where successors may run |

Onibi adopts the architectural lesson that a regexp can be decomposed into
coordinated components. It does not claim Hyperscan's SIMD performance, engine
portfolio, streaming database semantics, or end-offset-only reporting model.

## 4. Canonical pipeline

```text
pattern and options
  -> lexer and parser
  -> AST
  -> semantic analysis
  -> optimized immutable CFG
  -> regular/effect region analysis
  -> regexp decomposition
  -> immutable component graph
       |- mandatory string components
       |- HFA components (head DFA + tail NFA)
       |- tagged tail-NFA components
       `- typed semantic components
  -> lazily published immutable HFA program
  -> common ordered result iterator
  -> match? / match / scan / gsub
  -> MatchData or replacement result
```

There is one production architecture and one compiled program per
`Onibi::Regexp`. The program can contain different component kinds, but there
is no public backend selector, pattern-text dispatch, or silent whole-pattern
fallback.

## 5. Compiler representations

### 5.1 AST and semantic facts

The parser remains authoritative for syntax errors, capture numbering, named
groups, option scopes, and source encoding. Semantic analysis publishes frozen
facts rather than requiring later phases to reinterpret source text:

- nullability;
- minimum and maximum consumed width, including unbounded width;
- byte or character width mode;
- first and last symbol sets, including unknown;
- capture reads and writes;
- assertion, ordered-choice, repeat, cut, call, and match-reset effects;
- encoding and option scope;
- priority sensitivity and capture liveness.

Unknown facts are conservative. An optimization may decline to apply; it may
not guess.

### 5.2 CFG

The CFG is the optimization IR. Its ordered edges preserve alternation and
greedy/lazy priority. Operations carry typed operands and explicit state
effects. It is never parsed from regexp source and is not interpreted as a
second production matcher.

Passes declare required and invalidated facts. Capture reads/writes, observable
assertions, ordered choices, cuts, calls, and match reset are barriers unless a
pass proves the affected state dead or equivalent.

### 5.3 Regions

The compiler partitions the optimized CFG into maximal regions:

- `regular_effect_free`: eligible for a head DFA when priority-insensitive;
- `regular_tagged`: regular language with observable tag/priority state;
- `semantic`: requires input- or path-dependent behavior not representable by
  an ordinary finite state alone.

Only `regular_effect_free` regions can be freely determinized. A
`regular_tagged` region runs as a tagged tail NFA unless a separate proof shows
that determinization preserves all visible tag and priority distinctions.

### 5.4 Component graph

One immutable component graph represents the entire pattern:

- `StringComponent` reports occurrences of mandatory literal alternatives;
- `HeadDFAComponent` stores deterministic transition rows and border actions;
- `TailNFAComponent` stores position topology, tag mode, and accept reports;
- `SemanticComponent` implements a typed nonregular operation.

Edges carry minimum and maximum offsets, activation type, CFG priority, and
effect-state tokens. The graph owns its entry and accept reports. Public API
methods do not build their own pattern classifiers.

## 6. Classical head DFA and tail NFA construction

Each regular region is first represented as one position NFA. Subset
construction begins at the region entry and retains complete DFA rows while
all of these conditions hold:

- the program DFA-row budget is available;
- the successor remains in a head-eligible region;
- merging paths cannot erase observable priority, captures, or semantic state.

The initial program budget is 4,096 DFA rows. This is a memory bound, not a
semantic threshold. Any transition not retained becomes a border activation.
Budget values including zero must produce the same public result.

Unlike an adaptive transition cache, head construction is complete before the
program is published. Match operations never mutate DFA rows. The same regexp
therefore has stable compiled state before and after warmup.

## 7. Regexp decomposition and string matching

String extraction is a compiler proof, not a source-shape heuristic. A string
or finite string cut-set may become a component only when dominator or
equivalent graph analysis proves every relevant accepting path crosses it.

The initial admission limits are:

- mandatory ASCII strings of at least four bytes;
- no more than eight expanded alternatives;
- no semantic effect inside the extracted string;
- statically representable offset bounds to adjacent components;
- no reordering of MRI alternatives.

A string event reports component ID, alternative ID, start, and end. Event
cursors move monotonically. A successor is activated only inside its edge's
inclusive offset window. Confirmed bytes initialize the successor after the
literal; they are not rescanned through the NFA.

Literal values are data. Production code must not select an algorithm because
the value equals a benchmark token, URL fragment, log delimiter, email token,
or Regex Redux expression. Selectivity may influence a documented general
profitability decision only when it is measured independently of literal
identity and correctness never depends on it.

## 8. Captures, ordering, and semantic components

MRI-visible behavior has priority over determinization.

Tagged tail-NFA transitions represent capture start/end operations. Surviving
paths carry persistent capture history or an equivalent rollback-safe state.
Acceptance uses a total order derived from:

1. earliest candidate start;
2. ordered CFG choice;
3. greedy or lazy repetition decision;
4. report sequence within an otherwise equivalent path.

Atomic and possessive cuts discard only paths in their declared cut scope.
Boolean matching may omit capture state only when liveness proves it is neither
observable nor read by a backreference, conditional, call, or assertion.

Backreferences, stateful lookarounds, subexpression calls, conditionals,
absence, and match reset lower to typed semantic components. Such a component
receives cursor, tags, priority, call/cut state, and successor activations. It
may inspect input, but it must not parse source text, restart a whole-pattern
matcher, or select another backend.

## 9. Runtime and public APIs

The compiled program is created lazily on first matching use. Compilation uses
invocation-local mutable builders, freezes the complete graph and tables, then
publishes one memoized value. A concurrent caller observes either no program or
the fully initialized immutable program.

Runtime state is invocation-local and includes:

- active head state per head component;
- border activation records;
- active tail-NFA bitset segments;
- candidate start and component offsets;
- capture/tag, priority, call, cut, and assertion state;
- pending ordered accept reports;
- timeout and resource accounting.

One internal iterator yields raw results:

```text
[match_start_byte, match_end_byte, capture_byte_ranges]
```

`match?` consumes the first report and may elide proven-dead result state.
`match` constructs one `Onibi::MatchData`. `scan` and `gsub` consume the same
iterator and apply MRI empty-match advancement and replacement rules. API
implementations must not contain independent AST-shape dispatch tables.

## 10. Resource and concurrency invariants

- Runtime dependencies remain zero; C extensions and FFI are prohibited.
- DFA rows are bounded per program; the default is 4,096.
- One tail bitset segment contains at most 512 position states; more segments
  extend capacity without rejecting the pattern.
- Tail activations are deduplicated only when start, tags, semantic state,
  priority, and report behavior are equivalent.
- Timeout, step, tail-activation, capture-trail, call-stack, and cut/checkpoint
  accounting are explicit and cannot change match choice.
- Compiled objects are immutable after publication.
- Concurrent invocations share only immutable compiler output.

## 11. Optimization admission

An optimization is acceptable only when:

1. eligibility is expressed through semantic, CFG, region, or automaton facts;
2. its proof explains why removed positions or transitions cannot contribute
   to an MRI-visible result;
3. seeded metamorphic tests vary literal values, class members, widths, and
   event density while preserving the structural fact;
4. public differential tests cover results, captures, offsets, encodings, and
   errors as applicable;
5. lifecycle-specific benchmarks include unrelated development and holdout
   families and report negative results.

The benchmark protocol and statistical thresholds live in
[`hfa-task-list.md`](hfa-task-list.md). Macro benchmarks and Regex Redux are
observational workloads. Their exact patterns are never optimization contracts.

## 12. Migration state

The repository currently contains an experimental bit-parallel Glushkov NFA,
an adaptive lazy subset-transition cache, and many direct `hfa_*` AST-shape
specializations. Some structural ideas and leaf routines are reusable, but
this is not yet the completed architecture defined here:

- the adaptive cache is not a bounded precompiled head DFA;
- direct API-specific scanners bypass a common result iterator;
- some eligibility checks are application- or benchmark-shaped;
- full captures, priority, and semantic components are not uniformly carried
  by one component graph.

During migration these paths are implementation facts, not permission to add
more direct routing. New work follows the target architecture and removes a
legacy path as its general replacement becomes available. Completion criteria
and atomic task order are in [`hfa-task-list.md`](hfa-task-list.md).

## 13. Rejected architectures

- **Generated Ruby source as the production matcher:** rejected. It adds host
  source-evaluation constraints and is not the HFA defined here.
- **Whole-pattern backend selection:** rejected. It duplicates semantics and
  makes support depend on routing.
- **Adaptive DFA cache as HFA:** rejected as a definition. It can be a
  transitional optimization, but it mutates at runtime and has no explicit
  head/tail border.
- **Benchmark-token recognizers:** rejected. They are not general regexp
  optimizations.
- **Whole-pattern semantic verifier after prefiltering:** rejected. Semantic
  work belongs in typed components of the same graph.
- **Unbounded full determinization:** rejected because state explosion conflicts
  with predictable pure-Ruby memory use.

## 14. Document map

- [`onibi-design.md`](onibi-design.md): product scope, compatibility, and
  top-level architecture.
- [`cfg-optimization-pipeline.md`](cfg-optimization-pipeline.md): CFG contracts,
  analyses, and pass rules.
- [`hfa-task-list.md`](hfa-task-list.md): ordered migration plan and acceptance
  criteria.
- [`regexp-feature-coverage.md`](regexp-feature-coverage.md): current public
  compatibility snapshot.
- [`history/README.md`](history/README.md): index of completed and superseded
  records.

## References

- [A Hybrid Finite Automaton for Practical Deep Packet Inspection](https://doi.org/10.1145/1364654.1364656)
- [Hyperscan NSDI 2019 paper](https://www.usenix.org/system/files/nsdi19-wang-xiang.pdf)
- [Hyperscan developer reference](https://intel.github.io/hyperscan/dev-reference/)
- [Ruby source repository](https://github.com/ruby/ruby/)
