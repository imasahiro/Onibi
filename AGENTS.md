# Onibi Development Guide

Onibi is a pure Ruby regular-expression compiler prototype. The active design
is in [`docs/onibi-design.md`](docs/onibi-design.md).

## Development rules

Use test-driven development for every behavior change:

1. Add a focused test.
2. Run it and confirm the expected failure.
3. Implement the smallest change.
4. Run focused tests, the available suite, RuboCop, and the package build.

Tests must check library behavior. Pipeline tests compare exact AST, CFG,
automaton, and dedicated-bytecode results. Do not test file lists or tooling
configuration as library behavior.

## Current pipeline

```text
pattern + options
  -> lexer / parser -> AST
  -> semantic analysis -> optimized CFG
  -> regular, tagged, and semantic region analysis
  -> Glushkov TNFA -> DFA or partial DFA
  -> dedicated Onibi bytecode
```

The dedicated bytecode is the current execution target. It proves that the
pipeline is feasible before a future C implementation and MRI integration.
The current milestone targets MRI as the reference environment. Other Ruby
implementations are outside this milestone.

## Repository layout

```text
lib/onibi.rb
lib/onibi/
  lexer.rb and lexer/       # lexer and lexer support
  parser/                   # parser and parser support
  ast.rb                    # AST nodes
  cfg.rb                    # compiler control-flow graph
  optimization.rb           # CFG optimization passes
  compiler.rb               # AST to optimized CFG
  automata.rb               # CFG to TNFA/DFA/partial DFA
  irgen.rb                  # automata to dedicated bytecode
test/features/v2/           # pipeline tests (namespace-free implementation)
test/features/syntax/       # syntax and parser behavior
docs/                       # current design and historical records
```

The parser, compiler, automata, and IR generator are internal interfaces. The
current repository focuses on compilation and bytecode generation.

## Commands

```sh
bundle install
bundle exec rake test
bundle exec rubocop
bundle exec rake build
ruby -Ilib -e 'require "onibi"; p Onibi::Parser.parse("a+").ast'
```

Run focused pipeline tests when changing one stage, then run the complete
available suite.

## Quality and safety

Keep runtime dependencies at zero. Do not add C extensions or FFI. Keep
optimizations derived from CFG, semantic, or automaton facts. Preserve ordered
choice and capture semantics. Compare complete generated instruction streams;
comparators may ignore unstable byte offsets only.

Use one atomic commit per change. Work on a feature branch and use a pull
request. Run formatting, lint, tests, and package checks before delivery.
