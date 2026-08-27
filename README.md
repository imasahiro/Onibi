# Onibi

Onibi is an MRI-only regular-expression engine.
The first proof of concept is a Ruby gem with a C extension.

The gem provides `Onibi::Regexp`.
This class follows the MRI `Regexp` API for each implemented feature.
The PoC does not replace the built-in `Regexp` class.

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
The gem PoC does not include native-code generation.

## Development stage

Git history retains the previous Pure Ruby prototype.
The legacy tests remain as reference material.
Git history retains the old documents.
New production work follows the G-IR design and the C extension plan.

Early work starts with small unit tests.
The complete legacy test suite does not have to pass during early PoC work.
Focused tests must cover supported public behavior and match MRI.

See these documents:

- [`docs/gir.md`](docs/gir.md) for the engine design;
- [`docs/development.md`](docs/development.md) for the PoC plan;
- [`docs/README.md`](docs/README.md) for document status;
- [`AGENTS.md`](AGENTS.md) for repository development rules.

## Current commands

```sh
bundle install
bundle exec rubocop
bundle exec rake build
```

The legacy tests cannot run until the C extension adds a new loader.
The build tasks will change when the C extension scaffold is added.

Onibi is licensed under Apache License 2.0.
