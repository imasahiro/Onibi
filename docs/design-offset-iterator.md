# Internal offset iterator for repeated-match APIs

## Status and scope

This document specifies the internal execution surface used by `scan`, `gsub`,
and replacement. It is an optimization of the existing generated matcher and
does not expand the public API or change Ruby-compatible empty-match rules.

## Problem

`RegexpScanGsub#each_match` repeatedly calls public `match`. Each call performs
candidate search, allocates capture arrays, converts the input with `chars`,
and creates `Onibi::MatchData`, even when the consumer only needs offsets. This
is the dominant design-level cost in regex-redux replacement workloads.

## Interface

Add an internal immutable result protocol, for example:

```ruby
each_match_offset(input, position:, capture: :required) do |span|
  # span: [begin_offset, end_offset, capture_offsets]
end
```

The iterator may instead return an Enumerator, but it must be lazy and must not
materialize all matches. It calls the generated program directly and yields
logical character offsets. `capture: :none` is permitted only when the caller
does not expose captures; `scan` and replacement with capture references use
`:required`.

After each yield, advance to the end offset. For a zero-length match, advance
by one logical character exactly as MRI does, including the input-end case.
The iterator must preserve the original search origin and stop at the first
failure.

## Consumers

- `scan` converts a span to strings/capture arrays only at the yield boundary.
- `gsub` appends the untouched input slice and expands the replacement from
  offsets; it creates `MatchData` only for block/replacement semantics that
  require the public object.
- A future internal replacement callback may consume spans directly.

`MatchAdapter` remains the single public-object builder. No consumer may
duplicate capture naming, offset, or encoding logic.

## Encoding and ownership

The iterator uses the same `InputView` and logical offsets as `match`. It must
not expose a mutable input buffer or retain an invocation-local state after a
yield. A regexp can be used concurrently by independent iterators.

## Tests and acceptance criteria

Add failing tests for literal, capture, named-capture, empty, zero-length,
block replacement, replacement tokens, and no-match cases. Differentially
compare `scan`/`gsub` values and resulting encodings against MRI.

Add counters for generated entrypoint calls, MatchData constructions, and
input-character materializations. On dense `a` inputs, `scan` and `gsub` must
not construct one `MatchData` per internal match unless the public operation
requires it, and allocations must grow approximately with the output rather
than with repeated full-input materialization.

## Non-goals

Do not change replacement syntax, block arity, match-global-variable behavior,
or public `Onibi::MatchData`. Do not hide semantic differences behind the
iterator; all existing differential tests remain mandatory.

