# Onibi development plan

## Current milestone

The current milestone is an MRI-only Ruby gem proof of concept.
The gem contains a C extension and provides `Onibi::Regexp`.

The class follows MRI `Regexp` behavior for its supported API.
It does not replace the built-in `Regexp` class during the PoC.

The PoC uses C for the compiler, program data, interpreters, and match results.
Ruby code loads the extension and provides small public wrappers when necessary.

ZJIT work starts after the PoC.
The PoC must not depend on ZJIT or MRI source-tree changes.

The current C pipeline includes tokenization, parsing, ordered G-IR states and
edges, RSeq lowering, and three VM entry points for a tested ASCII subset. The
VM covers literals, alternation, character classes, wildcard sequences, wildcard
repeats, bounded repeats, captures, boundary assertions, and match reset.
Other syntax remains outside this subset.

## Execution engines

The compiler assigns one execution class to each compiled pattern.
Each class has one C interpreter.

| Execution class | Main use |
| --- | --- |
| `REGULAR_FAST` | Regular matching without semantic capture state |
| `TAGGED_ORDERED` | Ordered threads, output captures, and regular side effects |
| `DYNAMIC` | Backreferences, calls, conditions, and other runtime semantic state |

All interpreters execute RSeq and return one common raw match result.
The public API converts that result to `Onibi` objects.

## Milestones

### 1. C extension foundation

- Add `ext/onibi/extconf.rb` and a minimal extension entry point.
- Load the extension through `lib/onibi.rb`.
- Define `Onibi::Regexp`.
- Replace cross-runtime CI with an MRI-only extension build.
- Add unit tests for loading, allocation, initialization, and errors.

### 2. Regular compiler and interpreter

- Add the minimum parser and AST needed for simple patterns.
- Build G-IR and RSeq for literals and basic regular operators.
- Implement the `REGULAR_FAST` interpreter in C.
- Compare supported results with MRI.

### 3. Tagged ordered interpreter

- Add ordered threads and tag history.
- Implement captures and ordered match priority.
- Implement the `TAGGED_ORDERED` interpreter in C.
- Compare complete match and capture byte offsets with MRI.

### 4. Dynamic interpreter

- Add runtime semantic capture state.
- Implement the `DYNAMIC` interpreter in C.
- Add non-regular features in small groups.
- Compare each supported feature group with MRI.

### 5. Gem PoC completion

- Expand the `Onibi::Regexp` API for the supported feature set.
- Verify memory ownership, interrupts, timeouts, and supported encodings.
- Run the selected compatibility suite without unexpected failures.
- Record remaining MRI feature gaps.

### 6. MRI and ZJIT integration

- Move the proven C design into an MRI integration branch.
- Connect RSeq compilation to the ZJIT low-level backend.
- Keep all three C interpreters as the non-JIT execution path.
- Apply the final acceptance criteria in [`gir.md`](gir.md).

## Test policy

Test-driven development is not required.
Developers can write tests before or after the first implementation.

Every completed behavior needs a focused test before review.
Start with unit tests that isolate one C API or one compiler operation.
Add exact G-IR and RSeq tests when these formats become stable.

Use MRI differential tests for public behavior.
Compare success, errors, byte offsets, captures, encodings, and option handling.

The complete existing suite is not an early PoC gate.
It can include unsupported features until their milestones start.
Do not weaken correct expectations to make the total result green.

Each milestone defines its required test set.
The complete MRI and Ruby Spec suites become gates during MRI integration.

## Review policy

Keep changes small enough to review one ownership or semantic rule at a time.
State the supported pattern subset in tests and public notes.

Review C changes for these properties:

- allocation ownership;
- bounds and integer overflow;
- immutable published programs;
- correct Ruby GC interaction;
- correct exception cleanup;
- byte-offset preservation;
- interrupt and timeout polling.

Use compiler warnings for all C builds.
Add ASAN and UBSAN jobs when the extension scaffold can run them.

## Legacy prototype

Git history retains the previous Pure Ruby implementation.
The legacy tests remain useful for historical comparison.
Git history retains the old documents.
Neither source defines the new production architecture.

Do not restore the Ruby matcher as production code.

## Current architecture audit

The C extension now defines `Onibi::Lexer`, `Onibi::Parser`, `Onibi::Compiler`,
`Onibi::RSeq`, and `Onibi::VM`.

The tokenizer publishes frozen semantic tokens with byte spans. The parser
publishes a frozen regular-core AST. The compiler consumes only that AST and
publishes a frozen G-IR graph with ordered start edges and edge actions.

RSeq lowering preserves state, edge, start-edge, and action order. It publishes
an immutable semantic view and a validated, aligned, relocatable v1 blob. The
blob contains the header, state, edge, action, class, and literal descriptor
sections. The semantic and physical headers are checked before VM execution.

The C executor supports literals, alternation, classes, POSIX classes, common
escapes, anchors, bounded repeats, captures, word boundaries, search-origin
assertions, match reset, and numeric or named backreferences. The dispatcher
has separate C entry points for all three execution classes. They share graph
walkers while their dispatch contracts and RSeq validation are explicit.

## Stage acceptance gates

Each stage is complete only when it has a stable C data contract, a focused
public test entry point, precise syntax errors, and tests for boundaries and
encodings. Each stage must consume the previous stage's output.

The implementation order is:

```text
Tokenizer -> Parser/AST -> G-IR compiler -> RSeq lowering -> VM dispatch
```

The first complete core will cover literals, sequences, alternation, character
classes, wildcard, anchors, and bounded quantifiers. Unsupported features must
cross an explicit dynamic boundary. They must not enter a partial fast path.

## Current C pipeline status

Focused tests cover tokenizer, parser, AST, GIR, RSeq, and VM contracts. The
benchmark contract suite has 82 cases and 436 assertions after an explicit C
build. Character-class range and GIR resource validation are parser/compiler
gates.

Remaining gates are complete option and encoding semantics, atomic backtracking
states, non-literal lookaround subprograms, and complete tag-history sharing.

The benchmark contract tests compare both paths with MRI. The regex-redux
benchmark output is identical for Ruby and Onibi.
