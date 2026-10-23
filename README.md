# Onibi

Onibi is an MRI-only regular-expression engine for Ruby.
The current proof of concept is a Ruby gem with a C extension.

The gem provides `Onibi::Regexp`.
It does not replace Ruby's built-in `::Regexp` class.
It follows MRI for its declared API subset.

## Current API boundary

The declared Ruby API is in [`sig/onibi.rbs`](sig/onibi.rbs).
Onibi uses MRI for explicit unsupported pattern, input, or replacement cases.

For a supported native match, `Onibi::Regexp#match` returns `Onibi::MatchData`.
An explicit fallback can return MRI `::MatchData`.
`Onibi::MatchData` is not an MRI `MatchData` object.

Native match results do not enter MRI backreference storage.
Do not expect them in `$~` or `Regexp.last_match`.
Use Ruby's built-in `::Regexp` when code needs MRI backreferences.

`String#=~` delegates to `Onibi::Regexp#=~`.
The tested `String#match`, `match?`, `scan`, `split`, `[]`, `sub`, and `gsub` methods do not accept `Onibi::Regexp`.

Use Onibi from the main Ractor only.
Onibi objects are not shareable, and child-Ractor C calls are unsafe.

## Architecture

Onibi compiles a pattern to prioritized Glushkov IR, called G-IR.
It then lowers G-IR to the compact RSeq format.

```text
pattern + options -> AST -> tagged epsilon NFA -> G-IR -> RSeq
  -> REGULAR_FAST C interpreter
  -> TAGGED_ORDERED C interpreter
  -> DYNAMIC C interpreter
```

Each C interpreter handles one execution class.
The compiler selects the class from pattern semantics.

ZJIT integration is a later MRI integration milestone.
The gem proof of concept does not include native-code generation.

## Development stage

Git history retains the previous Pure Ruby prototype and its tests.
New production work follows the G-IR design and the C extension plan.
Use focused public E2E tests for accepted behavior.
The complete test suite is not an early PoC gate.

See these documents:

- [`docs/gir.md`](docs/gir.md) for the engine design;
- [`docs/development.md`](docs/development.md) for the current contract and checks;
- [`docs/README.md`](docs/README.md) for document scope and status;
- [`docs/remaining-work.md`](docs/remaining-work.md) for open tasks;
- [`docs/execution-ledger.md`](docs/execution-ledger.md) for accepted work;
- [`AGENTS.md`](AGENTS.md) for repository work rules.

## Current commands

```sh
bundle check
(cd ext/onibi && ruby extconf.rb && make)
bundle exec rubocop
```

Use the focused E2E commands in [`docs/development.md`](docs/development.md).
Run `make distclean` in `ext/onibi` after a build.

Onibi is licensed under Apache License 2.0.
