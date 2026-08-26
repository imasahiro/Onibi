# Onibi design

## Status

This document describes the current compiler prototype.

## Objective

Onibi compiles Ruby-style regular-expression patterns in pure Ruby. The current
goal is to validate each compiler stage with exact intermediate results. A
future milestone may implement the validated design in C and connect it to
MRI. MRI YARV generation is not the current execution target.

## Canonical pipeline

```text
pattern + options
  -> lexer / parser
  -> AST
  -> semantic analysis
  -> optimized CFG
  -> regular / tagged / semantic region analysis
  -> Glushkov TNFA
  -> DFA or partial DFA
  -> dedicated Onibi bytecode
```

The parser owns syntax, option scopes, capture numbering, and source errors.
The compiler lowers AST nodes to CFG blocks and operations. Optimization passes
transform CFG to CFG and preserve ordered control semantics. Automata lowering
maps CFG facts to position-based TNFA states, then to a full or partial DFA.
IR generation emits immutable automaton instructions and a flat semantic
instruction stream. A flat-safe pattern uses one `semantic_flat` entry whose
operand contains only VM instructions and primitive metadata. The interpreter
does not retain a semantic tree on this path. Unsupported patterns still use
the transitional `semantic_match` compatibility entry.

The target instruction contract is defined in [`flat-vm-design.md`](flat-vm-design.md).

## Interfaces

The active internal interfaces are:

- `Onibi::Parser.parse(pattern, options)` returns a parse result with an AST.
- `Onibi::Compiler.compile(ast)` returns an optimized CFG.
- `Onibi::Compiler::Optimization::Pipeline` applies named CFG passes.
- `Onibi::Automata` lowers CFG to TNFA and DFA or partial DFA.
- `Onibi::IRGen` lowers automata to dedicated bytecode.

Production files are under `lib/onibi/`. Parser support is under
`lib/onibi/parser/`; lexer support is under `lib/onibi/lexer/`.

## Verification

Each stage has focused tests. Tests assert full structures, including node
values, edges, state sets, accepting states, transition opcodes, and complete
instruction order. Byte offsets are ignored only by a comparator for unstable
offset fields. DFA and NFA modes have separate expected instruction streams.

The current tests are compiler and representation tests. They do not claim
Ruby `Regexp` API compatibility. Compatibility work can start after the
dedicated bytecode design is stable.

## Constraints

- Runtime dependencies remain zero.
- C extensions and FFI are not used in the prototype.
- Do not add a second production backend or a pattern-text router.
- Optimizations must use semantic, CFG, or automaton facts.
- Ordered choice, captures, assertions, and repeat priority must remain
  explicit in the intermediate representations.

Superseded design records are kept under `docs/history/`.
