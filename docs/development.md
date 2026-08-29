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

The current C pipeline includes tokenization, parsing, a tagged epsilon-NFA,
epsilon elimination, ordered G-IR states and edges, RSeq lowering, and three VM
entry points for a tested ASCII subset. The
VM covers literals, alternation, character classes, wildcard sequences, wildcard
repeats, bounded repeats, captures, boundary assertions, and match reset.
Other syntax remains outside this subset.

The C source is split into pipeline modules. `onibi.c` is an amalgamated entry
unit that includes `token.c`, `ast.c`, `parser.c`, `nfa.c`, `gir.c`,
`compiler.c`, `rseq.c`, `rseq_verify.c`, the three execution modules, and
`match.c`. The include order is the dependency order. Passes use C vectors.
The compiler publishes one immutable RSeq blob without a Ruby graph mirror.
No legacy `#if 0` code remains in these modules.

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

Compilation is an initialization-time operation. The tokenizer reads the
source once. The parser, GIR compiler, and RSeq lowerer consume that token
stream. Match entry points consume the published immutable RSeq only. They
MUST NOT inspect or rescan the regexp source. Compatibility pipeline views
are diagnostic adapters and are not execution inputs.

The compiler keeps the final GIR state and edge vectors in C. RSeq lowering
reads these vectors directly. It does not rebuild GIR records from the Ruby
debug mirror. Regular and action-free tagged execution read the relocatable
RSeq blob through `OnibiRSeqView`. `Onibi::Regexp` creates this native view
once during initialization. Match calls reuse the sidecar.

RSeq publication validates section offsets, state ranges, edge destinations,
action offsets, opcodes, and payload descriptors directly from the blob. The
runtime validator does not compare the blob with the Ruby semantic mirror.

The native blob walker executes ordered action-free cycles, classes,
wildcards, graphemes, position assertions, captures that do not affect
acceptance, and bounded-repeat counters. It keeps one counter vector for each
native backtracking frame.

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

Only `Onibi::Regexp` is public. Tokenizer, parser, compiler, GIR, RSeq, and
VM types stay inside the C extension.

The active ownership rules are:

| Data | Representation | Lifetime |
| --- | --- | --- |
| source, options, names | Ruby values | Public `Regexp` object |
| token stream | `OnibiTokenVector` | Tokenizer and parser |
| AST | `OnibiAstArena` | Parser and compiler |
| tagged epsilon NFA | C state and edge vectors | Compiler |
| GIR states and edges | C records | Compiler and RSeq lowering |
| GIR actions | `OnibiGActionVector` | Compiler and RSeq lowering |
| subprogram descriptors | C records | Compiler, blob, and VM |
| RSeq | One immutable relocatable blob | Published program |
| runtime view | Cached `OnibiRSeqView` | Public `Regexp` object |
| counters, captures, call frames | C arrays | One VM traversal |

The compiler does not publish a Ruby GIR mirror. GIR state payloads contain
numeric values, flags, and fixed 256-bit class maps. GIR edges own typed C
action vectors. RSeq lowering copies these records directly into the blob.

The compiler uses enum values for GIR state and action operations. It does not
compare operation names. Ruby symbols exist only at Ruby API boundaries.

RSeq publication validates all section offsets and record ranges once.
Initialization prepares one cached runtime view. Match operations do not
rebuild the view or scan the state and action tables. The hot path reads the
cached execution flag.

The native blob walker supports regular cycles, ordered alternatives,
character classes, wildcard, grapheme clusters, assertions, repeat counters,
captures, backreferences, conditionals, and subprogram calls. It uses a bounded
C return stack for recursive calls.

Atomic groups, absence groups, and lookaround predicates currently use the
compiled MRI compatibility boundary. They do not create a Ruby execution
graph. This boundary preserves public behavior until their C blob operations
are complete.

The runtime never creates `physical_graph`, `execution_graph`, or another
Ruby state graph. Debug data must be generated only on request.

## Current verification

Use the Homebrew MRI toolchain for the extension build:

```sh
cd ext/onibi
ruby extconf.rb
make
cd ../..
ruby -Ilib -Itest test/features/syntax/syntax_differential_contract_test.rb
ruby -Ilib -Itest test/features/syntax/advanced_syntax_differential_test.rb
ruby -Ilib -Itest test/features/syntax/subexpression_call_test.rb
ruby -Ilib -Itest test/features/compatibility/fuzz_test.rb
```

Use `make distclean` after verification. Do not remove generated files with
manual recursive deletion.
