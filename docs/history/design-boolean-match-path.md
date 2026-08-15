# Boolean-only matching path

> **Historical design — superseded.** This proposal assumed a generated-Ruby
> matcher. Capture liveness remains relevant, but its current home is the HFA
> component/result design in [`../hfa-design.md`](../hfa-design.md) and tasks
> HFA-040/HFA-043 in [`../hfa-task-list.md`](../hfa-task-list.md).

## Status and scope

This work package makes `match?` avoid result-only state while retaining all
state required for matching semantics. It shares the generated control graph
with `match`; it does not create a second matcher implementation.

## Problem

The generated entrypoint currently allocates `captures = Array.new(capture_count)`
even when `capture: false`. It can also retain capture slots that are not read
by the pattern. This makes the boolean API pay for MatchData-oriented state.

## Analysis contract

`Analyzer` publishes immutable capture liveness facts for each capture group:

- `:observable`: returned by `match` or required by a public operation;
- `:semantic`: read by a backreference, conditional, subexpression call,
  assertion, or another matching operation;
- `:dead_in_boolean`: not observable and not read by boolean semantics.

The conservative rule is to retain a slot whenever proof is incomplete. A
pattern containing a backreference, conditional, subexpression call, or
capture-sensitive assertion must not use the reduced layout unless dedicated
analysis proves it safe.

## Runtime design

The generated entrypoint receives a result mode, such as `:boolean` or
`:offsets`. In boolean mode:

- do not allocate the capture array when `capture_count == 0`;
- allocate only the proven semantic slots, using a compact index map;
- do not construct `MatchData`, capture strings, names, or byte-offset tables;
- return the literal `true` on success and `false` on search exhaustion.

In offsets mode, preserve the existing fixed-shape
`[match_begin, match_end, capture_offsets]` protocol. The mode is invocation
local and does not mutate the frozen generated program.

## Tests and acceptance criteria

Start with failing allocation/result tests for literal, non-capturing group,
dead capture, live backreference, conditional capture, lookahead capture, and
named capture. Differentially compare `match?` and `match` for every case,
including explicit positions, empty matches, options, encodings, and errors.

The feature profiler must report allocations separately for `match?` and
`match`. For patterns with no semantic captures, `match?` must allocate no
capture array; for patterns with captures that are semantically required, the
result must remain identical to the baseline. Add a regression guard that
`match?` never invokes `MatchAdapter` or constructs `Onibi::MatchData`.

## Interaction with other work

The offset iterator may request `:offsets` or a specialized capture layout;
the search plan may call boolean mode for candidate rejection. One-pass
execution owns rollback representation. This package owns only result-mode and
capture-liveness decisions, so changes remain reviewable and independently
revertible.
