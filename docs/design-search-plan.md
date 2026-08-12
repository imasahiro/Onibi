# Search-plan design

## Status and scope

This document defines the implementation contract for making candidate-start
search aware of facts computed by `Onibi::Codegen::Analyzer`. It is an
independent work package. It does not change the matching semantics inside a
single start position and does not introduce another matcher backend.

The owner may change `lib/onibi/codegen.rb`, analyzer tests, generated-program
tests, and the profiling benchmark. Changes to syntax semantics require the
normal MRI differential tests.

## Problem

`Codegen::GeneratedProgram#search` currently calls the generated entrypoint at
every position from `position` through `input.length`. This is incorrect for
performance-sensitive constraints such as `\A`, and repeats work when a
literal or character-set precondition proves that a position cannot match.

## Contract

`Analysis` must publish immutable search facts:

- `anchor_start`: the pattern can only start at the beginning of the logical
  input (including the distinction between `^` and `\A` under multiline mode);
- `anchor_end`: the pattern can only finish at the logical input end;
- `minimum_width`: the minimum number of logical characters consumed;
- `first_set`: a conservative set of first input atoms, or `unknown`;
- `required_literal`: an optional literal that must occur in every match;
- `nullable_prefix`: whether zero-width nodes can precede the first consuming
  node;
- `search_mode`: `:anchored`, `:literal_skip`, `:first_set`, or `:scan`.

Facts must be conservative: a false positive only reduces an optimization;
they must never skip a valid MRI match. Unknown, backreference, subexpression
call, encoding-sensitive, or option-dependent cases use `:scan`.

`GeneratedProgram#search(input, position, capture:)` remains the compatibility
entrypoint. It consumes the plan and invokes the existing generated entrypoint
only at positions admitted by that plan.

## Search algorithm

1. Normalize `position` to a logical character boundary.
2. For `anchor_start`, attempt exactly `position` (or zero when the API
   contract requires it) and return failure without scanning later positions.
3. For `required_literal`, use `String#index`/a precomputed literal iterator,
   then verify the candidate with the generated matcher. Do not use this path
   when case folding or encoding makes byte offsets ambiguous.
4. For `first_set`, advance to the next character accepted by the set; include
   the input-end candidate when the pattern is nullable.
5. Apply `minimum_width` before invoking the matcher so a suffix too short for
   a match is not attempted.
6. Preserve leftmost-first order and the caller's original search origin.

The plan must not alter capture rollback, greediness, or end-anchor behavior.

## Tests and acceptance criteria

Add tests before implementation for:

- `\Aneedle` on a long miss: one generated attempt, not one per character;
- `needle\z` with hits at the only legal end position;
- a literal miss and a first-set miss with inputs of 64, 1,024, and 16,384
  characters;
- nullable patterns (`a*`, `^`, empty source) including empty input;
- multiline `^`/`$`, UTF-8, ASCII-8BIT, ignorecase, and explicit positions;
- differential equivalence of result, offsets, and captures against MRI.

The scaling benchmark must report candidate attempts, wall time, allocation,
and GC deltas. The anchor-miss case must have O(1) candidate attempts; literal
and first-set misses must be O(number of admitted candidates), not O(input
length) when the precondition rules them out.

## Non-goals and risks

This work does not solve quadratic backtracking after a candidate is admitted;
that is the one-pass execution work package. It also does not make `scan` or
`gsub` allocation-free. Required-literal extraction must remain conservative,
especially for case folding, Unicode properties, assertions, and
subexpression calls.

