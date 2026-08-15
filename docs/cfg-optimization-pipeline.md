# CFG and optimization pipeline

## Status and decision

Onibi uses an immutable control-flow graph (CFG) as a compiler IR inside the
single HFA matcher pipeline. The CFG is not a second matcher and is
never interpreted at match time.

This is an active normative companion to [`hfa-design.md`](hfa-design.md).
Historical generated-Ruby terminology is superseded; the CFG feeds region
analysis, component decomposition, and HFA construction.

The initial compilation flow is:

```text
tokens -> AST -> early passes -> semantic analysis
                  |                       |
                  +-> late passes -> optimized AST -> lazy CFG
                                      |             |
                                      +-- compilation unit
                                                |
                                      region and effect analysis
                                                |
                                      decomposition + HFA construction
```

HFA lowering consumes the optimized AST paired with the CFG during migration.
The target is for all optimization eligibility and component boundaries to be
derived from CFG and semantic facts. The AST remains parser-authoritative; it
must not become a competing runtime matcher or a collection of public-API shape
routers.

## CFG contract

`Onibi::HybridAutomata::CFG` contains immutable graphs, blocks, operations,
terminators, and ordered edges. Sequence becomes a flow edge. Alternation
becomes a `choice` terminator whose `alternative` edges retain their
left-to-right priority. CFG materialization is lazy and memoized so ordinary
construction does not pay for diagnostic IR until a CFG pass or diagnostic asks
for it. Operations declare semantic effects such as `capture`,
`capture_read`, `assertion`, `choice`, `repeat`, `call`, and `cut`.

An optimization may move, combine, or remove an operation only when its effect
requirements permit it. In particular, capture writes, capture reads, cuts,
calls, and ordered choices are optimization barriers unless a pass proves the
relevant state is dead or equivalent. This is the regex equivalent of a
compiler preserving memory effects and exception/control dependencies.

Complex constructs are initially represented by typed high-level operations.
This is deliberate: prematurely expanding quantifiers, assertions, or calls
would make the graph larger and would risk losing MRI priority semantics.
Later lowering passes may expand one high-level operation at a time, with MRI
differential tests defining the contract.

## Pass manager

`Onibi::HybridAutomata::Optimization::Pipeline` owns an explicit, deterministic
pass order and publishes the executed pass names in the immutable compilation
unit. Production construction runs only shape-changing passes needed by
semantic analysis; HFA-stage normalization and lazy CFG publication happen
when the compiled program is first requested. This staging keeps ordinary
regexp construction from paying for unused HFA compilation.
Tests can run the default pipeline, select named passes, or construct an empty
pipeline while still producing a CFG.

The first pass set moves existing ad-hoc transformations behind this boundary:

1. `impossible_branch_elimination` removes branches containing an
   unconditionally failing negative empty assertion. If every branch fails it
   retains one failure, preserving failure semantics without an empty choice.
2. `duplicate_literal_branch_elimination` removes later identical all-literal
   alternatives while preserving the first branch and branch order.
3. `literal_coalescing` combines adjacent encoding-compatible literal nodes so
   an HFA or string component and the literal table can share one comparison
   unit.

Search planning, predicate-table construction, capture liveness, and specialized
regular runs remain later compiler phases. They should migrate behind the same
pass interface only when each phase declares the facts it requires and
invalidates; merely renaming a runtime heuristic as a pass would not make it a
safe transformation.

## Direct parser-to-CFG generation

The CFG `Builder` is shared by AST lowering and is intentionally independent of
the parser. A future parser can emit CFG fragments directly, but that change is
accepted only after all of these conditions hold:

- every supported syntax node has a typed CFG operation or lowering rule;
- capture numbering, named groups, option scopes, encodings, and source errors
  remain parser-authoritative;
- branch, greedy/lazy, atomic, and possessive priority is explicit in edges;
- analysis facts are computed from CFG or attached typed operands, rather than
  reconstructed from regexp text;
- HFA construction consumes CFG facts, and the AST-to-CFG differential suite
  shows identical observable behavior;
- removing the AST does not introduce a runtime interpreter or fallback.

Until those gates pass, AST-to-CFG lowering is the migration boundary. This
avoids keeping two independent semantic implementations while still allowing
new CFG analyses and transformations to be developed and tested now.

## Candidate compiler optimizations

The effect model makes conventional compiler techniques applicable in stages:

- unreachable-block and impossible-edge elimination;
- basic-block merging and jump threading for epsilon-only flow;
- literal constant folding and common literal/predicate table sharing;
- dominator-based required-literal extraction;
- data-flow capture liveness and dead capture-store elimination for `match?`;
- redundant checkpoint and capture-trail write elimination;
- loop-invariant predicate preparation around quantified regions;
- guarded specialization of ASCII, fixed-width, and regular subgraphs;
- layout and byte-class compression of head-DFA tables without changing edge
  priority;
- bounded head-DFA region selection and explicit border placement;
- mandatory-string cut-set extraction and component offset propagation;
- tagged-tail capture liveness and equivalent activation deduplication.

Every pass must preserve ordered choice, make its prerequisites explicit, be
independently testable against an unoptimized compilation unit, and pass MRI
differential tests. Performance acceptance additionally reports construction,
first-HFA compilation, warm API measurements, allocations, HFA table/component
sizes, and the benchmark environment required by the project guide. Exact
benchmark literal values cannot be pass prerequisites.
