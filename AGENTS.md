# Onibi Development Guide

Onibi is an MRI-only regular-expression engine.
The active design is in [`docs/gir.md`](docs/gir.md).
The current milestone is a Ruby gem with a C extension.

## Product scope

The gem provides `Onibi::Regexp` under the `Onibi` namespace.
Its public API follows MRI `Regexp` behavior for each supported feature.
The PoC does not replace MRI `Regexp` or modify MRI.

The implementation supports MRI only.
Do not add support for JRuby, TruffleRuby, or mruby.

The PoC has three execution classes:

- `REGULAR_FAST`;
- `TAGGED_ORDERED`;
- `DYNAMIC`.

Implement each interpreter in C.
Keep their shared program format and match results consistent.

ZJIT integration starts after the gem PoC is complete.
Do not add a separate native-code generator during the PoC.

## Active pipeline

```text
pattern + options
  -> parser -> AST
  -> tagged epsilon NFA
  -> epsilon elimination
  -> G-IR
  -> RSeq
  -> execution-class dispatcher
       -> REGULAR_FAST C interpreter
       -> TAGGED_ORDERED C interpreter
       -> DYNAMIC C interpreter
```

G-IR is the canonical semantic form.
RSeq is the compact execution form.

## Development rules

Test-driven development is optional.
A change can start with a test, an implementation, or a small experiment.

Add focused tests for behavior that is ready for review.
Run the smallest useful test set during development.
Run broader checks when the change can affect more code.

The complete legacy suite does not have to pass during early PoC work.
Do not change a correct test only to hide an unsupported feature.
Record unsupported behavior clearly in test names, filters, or milestone notes.

Start with small unit tests.
Good first cases include extension loading, object creation, literals, and simple match results.
Add differential tests against MRI when public behavior becomes available.

## Implementation rules

Put production matcher and compiler code in the C extension.
Use Ruby only for gem loading, version data, and necessary public wrappers.
Do not implement a second production matcher in Ruby.

Keep runtime dependencies at zero.
Do not add FFI or an external regular-expression library.
Use MRI behavior as the compatibility reference.

Preserve ordered choice, capture boundaries, byte offsets, encodings, interrupts, and timeouts as features become supported.
Give each C allocation a clear owner and release path.
Use immutable compiled programs after publication.

Do not add ZJIT code during the PoC.
Keep the RSeq contract suitable for later ZJIT compilation.

## Repository direction

The planned PoC layout is:

```text
ext/onibi/                 # C extension and extconf.rb
lib/onibi.rb               # extension loader and public entry point
lib/onibi/version.rb       # gem version
test/unit/                 # focused compiler and interpreter tests
test/compatibility/        # MRI differential API tests
docs/gir.md                # active engine design
docs/development.md        # milestones and verification policy
```

The Pure Ruby production files have been removed.
Existing tests and documents remain as legacy reference material.
Do not restore the Ruby matcher as production code.

## Verification

Use the commands that the current `Rakefile` provides.
Update this section when C extension tasks become available.

```sh
bundle install
bundle exec rubocop
bundle exec rake build
```

The legacy tests cannot run until the C extension adds a new loader.

For C changes, enable compiler warnings.
Use ASAN and UBSAN when their build tasks become available.

Run focused tests before each commit.
Treat the complete suite as a progress report until its milestone makes it required.

## Change control

Commit every change as an atomic unit.
Do not combine unrelated changes in one commit.
Use a feature branch and a pull request.
Update the active documents when architecture or milestone rules change.
