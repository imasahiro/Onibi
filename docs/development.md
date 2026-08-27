# Onibi Development Status

This document records the implementation audit against [`gir.md`](gir.md).

## Audit baseline

The audit checks the current C extension and the public Ruby load path.
The result below is the starting point for the replacement implementation.

| Stage | Current state | Design status |
| --- | --- | --- |
| Tokenizer | A private byte loop exists in `onibi_pipeline`. It now groups simple escapes, but it has no lexer object, token stream, encoding rules, or syntax errors. | Incomplete |
| Parser / AST | No `Onibi::Parser` or `Onibi::AST` is defined by the current load path. `pipeline[:ast]` is a source-shape heuristic. | Missing |
| Compiler | No compiler entry point exists. The pipeline creates one synthetic state per token. It does not compile an AST. | Missing |
| G-IR | The synthetic graph is linear, with special source-string cases for alternation and repeats. It is not a tagged Glushkov graph produced by epsilon elimination. | Incomplete |
| RSeq | `rseq_compact` is a Ruby array of hashes. There is no immutable relocatable RSeq blob or v1 header/state/edge contract. | Missing |
| VM | `vm_match_p` contains pattern-specific branches. `execution_class` only reports a label; three independent C interpreters do not exist. Most public matching delegates to MRI. | Incomplete |

The current public constants confirm the missing compiler stages:

```text
Onibi.constants => [:Regexp]
```

The v2 parser, compiler, and interpreter tests therefore cannot exercise the
current implementation. Their expectations describe the target architecture,
not current behavior.

## Acceptance gates

Each stage is complete only when all of these conditions hold:

1. The stage has a stable C data contract and a public test entry point.
2. The stage consumes the output of the previous stage, not the original source.
3. Invalid input produces a precise `RegexpError` or `ArgumentError`.
4. Tests cover positive, negative, boundary, and encoding cases.
5. The next stage can run without source-string pattern inspection.

The implementation order is:

```text
Tokenizer -> Parser/AST -> G-IR compiler -> RSeq lowering -> VM dispatch
```

The first implementation milestone is a complete regular core: literals,
sequences, alternation, character classes, wildcard, anchors, and bounded
quantifiers. Unsupported MRI features must use an explicit dynamic boundary;
they must not silently enter a partial fast path.

