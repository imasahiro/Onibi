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
entry points. The compiler and runtime checks select which patterns and inputs
can use native execution. Do not read a feature name as proof that every form is
supported.

The wrapper uses the retained MRI regexp only for an explicit fallback. The
compiler records unsupported features. Runtime checks can also reject an input.
These compile and input checks run before the native executor starts.
`gsub` can also use MRI when its replacement parser rejects a form.
A malformed RSeq or native executor error raises an error; it does not select fallback.

The C source is split into pipeline modules. `onibi.c` is an amalgamated entry
unit. It includes the current implementation files in dependency order.
`rseq_runtime.c` owns RSeq validation. `exec_dynamic.c` contains the three C
interpreter entry points. Passes use C vectors. The compiler publishes one
immutable RSeq blob without a Ruby graph mirror. No legacy `#if 0` code remains
in these modules.

## Execution engines

The compiler assigns one execution class to each compiled pattern.
Each class has one C interpreter.

| Execution class | Main use |
| --- | --- |
| `REGULAR_FAST` | Regular matching without semantic capture state |
| `TAGGED_ORDERED` | Ordered threads, output captures, and regular side effects |
| `DYNAMIC` | Backreferences, calls, conditions, and other runtime semantic state |

All interpreters execute RSeq and return one common raw match result.
Native `match` builds `Onibi::MatchData` from the raw byte ranges.
Native `scan` builds strings or capture arrays from those ranges.
Native `gsub` builds its result from native ranges and replacement rules.
An explicit fallback uses the retained MRI regexp.

### Public API subset

The declared public method subset is in [`../sig/onibi.rbs`](../sig/onibi.rbs).
It includes the current `Onibi::Regexp` and `Onibi::MatchData` signatures.
The accepted MatchData subset contains 27 public methods.

For a supported native result, `Onibi::Regexp#match` returns
`Onibi::MatchData`. An explicit fallback can return MRI `::MatchData`.
The custom object is C typed data. It is not an MRI `MatchData` object.
It does not pass MRI type checks for `RUBY_T_MATCH` or `RMATCH_REGS`.
Its `regexp` method returns the owning `Onibi::Regexp`.

RBS 4.1.2 checked syntax, names, and type arity.
Steep was not installed, so no static source type check is claimed.
Source review maps all 27 accepted MatchData methods to C registrations.

### MRI caller and backreference limits

MRI `String#=~` delegates to `Onibi::Regexp#=~`.
The tested `String#match`, `match?`, `scan`, `split`, `[]`, `sub`, and `gsub`
methods reject `Onibi::Regexp`. Onibi does not patch these String methods.
StringScanner and other MRI C callers remain outside this gem boundary.

A native match result does not enter MRI backreference storage.
Native `Onibi::Regexp#match` success leaves the prior MRI `$~` unchanged.
`Onibi::Regexp.last_match` reads MRI backreference state.
Explicit MRI fallbacks can use MRI's own state.
Onibi does not promise full caller-local backreference behavior.

### Ractor limit

The current contract is main-Ractor only.
Onibi objects are not shareable. Calls to the extension from child Ractors
fail because the methods are Ractor-unsafe. MRI 4.0.6 reports
`Ractor::UnsafeError` as the cause.
The extension does not enable the Ractor-safe boundary.

### Open acceptance work

Binary `MatchData#names` encoding remains open.
The explicit fallback path for `~` with `\K` and match reset remains untested.
Public caller, GC, timeout, interrupt, Ractor, CI, and package gates remain open.
See [`remaining-work.md`](remaining-work.md) for the current task order.
The gem has not passed all eight PoC conditions in GIR section 133.1.

Compilation is an initialization-time operation. The tokenizer reads the
source once. The parser, GIR compiler, and RSeq lowerer consume that token
stream. Match entry points consume the published immutable RSeq only. They
MUST NOT inspect or rescan the regexp source. Compatibility pipeline views
are diagnostic adapters and are not execution inputs.

The compiler keeps the final GIR state and edge vectors in C. RSeq lowering
reads these vectors directly. It does not rebuild GIR records from the Ruby
debug mirror. All three interpreters read the relocatable RSeq blob through
`OnibiRSeqView`. `Onibi::Regexp` creates this native view once during
initialization. Match calls reuse the sidecar.

RSeq publication validates section offsets, state ranges, edge destinations,
action offsets, opcodes, and payload descriptors directly from the blob. The
runtime validator does not compare the blob with the Ruby semantic mirror.

### Folded capture and sensitive backreference search

One narrow UTF-8 form has a scoped ignorecase capture around one direct scalar,
one case-sensitive reference to that capture, and a final `\z`. The compiler
uses encoding fold data to prove MRI's expansion-overflow case. It stores the
normalized widths and end-search distances in RSeq v6. This form uses native
`DYNAMIC` execution.

The matcher compares `Dmin` with the full subject length. It applies `Dmax` to
the lower candidate bound and keeps MRI's raw exclusive upper range and its
equal-origin case. It does not compare the remaining suffix with `Dmin`.

The physical verifier checks the certificate fields, equations, feature
conflicts, and exact RSeq shape. It cannot prove the source fold or normalized
text. The compiler proves those source-level facts. Other AST forms stay
outside this native profile.

The native interpreters execute ordered actions, cycles, classes, wildcards,
graphemes, position assertions, captures, bounded-repeat counters,
backreferences, conditions, calls, atomic groups, absence, and lookarounds for
patterns that pass the native support checks.
The DYNAMIC interpreter keeps semantic state in each explicit C stack frame.

## Milestones

### 1. C extension foundation

- Add `ext/onibi/extconf.rb` and a minimal extension entry point.
- Load the extension through `lib/onibi.rb`.
- Define `Onibi::Regexp`.
- Replace cross-runtime CI with an MRI-only extension build.
- Verify loading, allocation, initialization, and errors through the public API.

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

Prefer tests that run the public API through the C compiler and native engine.
Use existing E2E and MRI differential coverage before adding another test.
Do not write unit tests after implementation.
If an isolated test is necessary, first list its failure cases, then write code.

Keep isolated tests when they catch failures that E2E tests cannot reach.
Examples include malformed RSeq, allocation failure, integer limits, and state collisions.
Do not test source spelling, file placement, or obsolete Ruby compiler objects.
Record repeatable commands and results with each test review.

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
Git history also retains the legacy tests for historical comparison.
Git history retains the old documents.
Neither source defines the new production architecture.

Do not restore the Ruby matcher as production code.

## Current architecture audit

`Onibi::Regexp` and `Onibi::MatchData` are public. Tokenizer, parser, compiler,
GIR, RSeq, and VM types stay inside the C extension.

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

Atomic groups, absence groups, and lookaround predicates use compiled RSeq
subprograms. They do not create a Ruby execution graph. The DYNAMIC
interpreter applies their semantic transactions in native code.

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
