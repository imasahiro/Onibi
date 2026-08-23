# CFG and optimization pipeline

The CFG is the compiler IR between the AST and automata. It is immutable after
each pass and is not a separate runtime matcher.

```text
AST -> semantic facts -> CFG -> optimization passes -> optimized CFG
  -> Glushkov TNFA -> DFA or partial DFA -> dedicated bytecode
```

`Onibi::Compiler.compile` builds the initial CFG. Each
`Onibi::Compiler::Optimization::Pipeline` pass receives a CFG and returns a CFG. Passes
must preserve ordered edges, capture effects, assertions, cuts, calls, and
repeat priority unless a proof removes an effect safely.

Current pass tests compare complete expected CFGs. This makes each pass
independently reviewable and prevents an optimization from hiding a semantic
change in a later stage.

The active pass set includes impossible-branch elimination, duplicate-literal
branch elimination, literal coalescing, and CFG simplification. New passes
must state their required facts, invalidated facts, and semantic barriers.

The CFG builder is independent of the parser. AST lowering remains the
authoritative boundary until every supported node has a typed CFG lowering and
the differential pipeline tests show equivalent results.

The automata stage consumes optimized CFG and emits TNFA and DFA structures.
