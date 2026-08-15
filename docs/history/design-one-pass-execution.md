# One-pass execution and backtracking-state design

> **Historical design — superseded.** This proposal explicitly excluded
> NFA/DFA execution and assumed generated Ruby. Its regular/stateful analysis
> lessons are carried forward by HFA region analysis in
> [`../hfa-design.md`](../hfa-design.md).

## Status and scope

This work package removes repeated suffix rescans for regular subgraphs while
keeping the generated-Ruby matcher as the sole production engine. It may add
generated templates and immutable analysis metadata, but it must not add an
NFA, DFA, bytecode interpreter, or runtime matcher selector.

## Problem

The current quantifier lowering stores complete copies of the capture array for
each candidate. A pattern such as `[a-z]+[0-9]+` on an all-letter input first
consumes a growing prefix, then retries the suffix from every earlier prefix.
The measured behavior is O(n²) time and allocation. Copying captures less often
reduces constants but cannot change this order.

## Design

Analyzer classifies each AST region as:

- `:regular`: no backreference, subexpression call, capture-visible assertion,
  conditional read, or other operation requiring path-dependent Ruby state;
- `:stateful`: must use the existing prioritized backtracking lowering.

For `:regular` sequences and quantifiers, the generator emits a one-pass loop
with cursor/state transitions and a compact frontier. A transition records only
the logical cursor, branch priority, and required capture-trail checkpoint. It
does not duplicate all captures. When a suffix fails, the loop resumes from the
next frontier transition instead of re-running the entire prefix.

For `:stateful` regions, use `InvocationState`'s persistent capture trail and
checkpoint tops. The stateful path remains the semantic fallback within the
same generated program, not a separate matcher.

## Correctness invariants

- Leftmost start and branch priority are unchanged.
- Greedy quantifiers enumerate longer candidates before shorter candidates;
  lazy quantifiers use the inverse order.
- A capture write is visible only after its transition commits and is rolled
  back through the trail on failure.
- Empty-body repetition cannot enqueue the same `(node, cursor, state)` twice.
- Backreferences, conditionals, lookarounds, atomic groups, and subexpression
  calls force the containing region to `:stateful` unless an explicit proof is
  added.

## Tests and benchmarks

Begin with failing regression tests for `[a-z]+[0-9]+` at lengths 64, 128, 256,
and 512, asserting MRI-equivalent result and captures. Add priority cases
`(a|aa)b`, `(a*)(a*)`, `(.*)(.*)`, lazy/greedy pairs, empty repetition, and
captures crossing the regular/stateful boundary.

Run `script/profile_regexp_scaling.rb` with `match?`, `match`, `scan`, and
`gsub`, recording time, allocation, and GC. The class-quantifier miss must be
approximately linear over the measured range; a constant-factor improvement
alone does not satisfy this design. Add a guardrail that aborts rather than
running unbounded input when a case exceeds its time budget.

## Rollout

Implement analysis classification first, then one-pass lowering behind an
internal feature flag. Compare both paths with the full differential corpus,
fuzz seeds, and cross-runtime source-compilation checks. Remove the flag only
after the regular-region corpus and scaling guardrails pass on MRI, JRuby,
TruffleRuby, and mruby profiles.
