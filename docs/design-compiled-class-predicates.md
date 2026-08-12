# Compiled character-class predicates

## Status and scope

This work package moves character-class parsing and intersection evaluation out
of the per-character hot path. It preserves the existing leaf-helper rule:
the helper answers a predicate and never interprets AST nodes or selects a
matcher backend.

## Problem

`ClassPredicates.matches?` currently reparses class source, intersections,
ranges, and atoms for every tested character. TracePoint shows repeated
`intersection_state`, `intersection_marker?`, `atom`, and `range_matches?`
calls. This is a large constant cost and amplifies backtracking allocation.

## Design

The analyzer/code generator creates an immutable `PredicateTable` once per
regexp and passes it to generated code. A table entry contains:

- encoding and ignorecase mode;
- normalized positive/negative ranges or scalar sets;
- intersection operands and their boolean operation;
- Unicode property handles or compiled property identifiers;
- multibyte/case-fold alternatives that consume more than one logical unit.

The runtime API is a small leaf interface:

```ruby
PredicateTable#match?(predicate_id, input_view, cursor)
PredicateTable#candidates(predicate_id, input_view, cursor)
```

`candidates` returns all legal end cursors for case folds such as `ß`/`SS`;
the common ASCII one-character path returns without allocating. Tables and
range arrays are deeply frozen before publication.

The table compiler must preserve POSIX class behavior, negation, intersection,
encoding errors, ignorecase, and invalid-byte behavior. If a class cannot be
compiled safely, retain a conservative source-backed leaf for that predicate
and record the fallback in diagnostics; do not silently broaden the set.

## Tests and acceptance criteria

Write failing tests for ranges, negated classes, intersections, nested
intersections, POSIX classes, Unicode properties, ignorecase, ASCII-8BIT, and
case folds. Compare matches, offsets, and captures with MRI.

Add a table-build benchmark and warm predicate benchmark. Warm runs must show
zero class-source parsing calls and no per-character range-array construction.
Measure both hit and miss cases at input lengths 64 through 16,384; record
time, allocations, and GC. This package is successful when the class benchmark
constant drops substantially without changing its algorithmic scaling.

## Non-goals and risks

This does not solve suffix re-scanning or public `scan`/`gsub` allocation. It
must not use Ruby's built-in `Regexp` as a predicate oracle, because that would
violate the independent-engine boundary and make performance incomparable.

