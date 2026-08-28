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

Compilation is an initialization-time operation. The tokenizer reads the
source once. The parser, GIR compiler, and RSeq lowerer consume that token
stream. Match entry points consume the published immutable RSeq only. They
MUST NOT inspect or rescan the regexp source. Compatibility pipeline views
are diagnostic adapters and are not execution inputs.

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

Only `Onibi::Regexp` and its MRI-compatible support classes are public. Lexer,
parser, compiler, RSeq, and VM objects are anonymous C implementation objects.
They have no Ruby constants and are not part of the public API.

Token, AST, and GIR Ruby containers are compile-time temporaries. The Regexp
object releases them after initialization. RSeq physical data uses typed C
structures and an immutable blob. The regular VM stores repeat counters in a
fixed C array. Captures and tag history remain Ruby `VALUE`s only where the
GC and MatchData boundary requires them.

The Ruby data decision is:

| Data | Owner | Reason |
| --- | --- | --- |
| source, options, names, named captures | Ruby `VALUE` | Regexp public API and MRI encoding rules |
| tokens, AST, GIR | C compiler scope | Compile-time only; feature scanning uses a typed C token view; never retained by Regexp |
| RSeq blob, states, edges, descriptors | C structs | Immutable VM contract |
| regular repeat counters | C array | Numeric VM slots; no Ruby identity |
| regular VM visited set | C bitset | State/position pairs have no Ruby-visible identity |
| lookaround predicate kind | C enum adapter | Byte/bitmap/any dispatch has no Ruby-visible identity |
| tagged captures and tag history | Ruby `VALUE` | GC safety and MatchData materialization |
| execution class | C enum | Internal dispatcher choice |

The parser result adapter contains only options and AST.
The tokenizer array is passed directly to the parser and is not retained in
that result. This avoids a second Ruby reference to the compile-time token
stream.

The remaining compiler containers have three separate roles:

| Container | Current role | Migration order |
| --- | --- | --- |
| fragment `starts`/`exits` | Ordered state-ID sets | First; C dynamic vector |
| fragment action arrays | Ordered semantic actions | Second; typed action vector |
| capture and exit guards | State-ID lookup during edge creation | Third; C map with explicit ownership |
| GIR `states`/`edges` | Published semantic snapshot for RSeq lowering | Last; convert at the RSeq boundary only |

Detailed ownership review:

The current source has 90 `rb_hash_new` calls and 80 `rb_ary_new` calls.
These counts include public result objects, semantic payloads, and temporary
compiler adapters. They are not all migration targets. The table below gives
the required classification for each data family.

The migration boundary is incremental. C vectors are used first where the
consumer needs only ordered numeric IDs or fixed token fields. Ruby adapters
remain where the parser must retain variable payloads such as names, ranges,
and nested children. The next boundary is the parser input view; it will carry
fixed token fields in C and keep only payload references at the adapter edge.

| Container | Ruby API required | C-struct decision | Reason |
| --- | --- | --- | --- |
| token stream (`Array<Hash>`) | No | Convert to a token vector | Each item has a fixed kind, byte span, and optional payload. The parser is the only consumer. |
| AST (`Hash`/`Array`) | No | Convert to typed nodes | Node kinds and links are fixed. Ruby Hash lookup is not needed after parsing. |
| parser result | No | Converted to `OnibiParsed` | It contains only AST and option bits. |
| GIR builder state and edge arrays | No | Convert after fragment migration | The builder mutates them during compilation. The RSeq boundary needs a stable snapshot only. |
| fragment start/exit IDs | No | Convert to `OnibiIdVector` | IDs are numeric and ordered. Ruby Array gives no semantic value. Final GIR exit connections, including lazy ordering, now consume the C vector. |
| fragment action lists | No for shape; yes for payload values | Use typed action records with Ruby payload fields | Action order is semantic, but names and bitmaps still cross the GC boundary. |
| RSeq semantic program | No public API | Convert to an immutable C program owner | VM reads the same fields on every match. The blob and descriptors already use C types. |
| regular VM visited set | No | Converted to a bounded C bitset | Numeric state/position pairs do not need Ruby Hash keys. Large or counter-bearing paths retain a safe fallback. |
| lookaround predicate kind | No | Numeric `predicate_code` enum | The Symbol name remains diagnostic; VM dispatch uses the numeric code. |
| captures and tag history | Yes at MatchData boundary | Keep Ruby `VALUE` | Ruby owns the result objects and GC must see them. |

The first conversion is complete for parser and compiler result adapters. The
remaining token, AST, fragment, GIR, and RSeq conversions stay separate so
each change can preserve ordering and GC tests.

Feature classification now copies the fixed token fields into a short-lived
`OnibiFeatureTokenVector`. The scanner compares enum kinds, numeric bytes, and
precomputed property IDs and flags from this C view. The vector has no Ruby
`VALUE` fields; source token Hashes remain the sole temporary Ruby objects.
The tokenizer records each optional name as `name_id` once, so later feature
classification does not intern the same name again.

GIR actions now carry a numeric `action_code` enum beside their diagnostic
Symbol name. Validation and RSeq lowering use this enum; the Symbol remains
only as a semantic adapter until the typed action vector conversion.

The compiler must not expose these containers through Ruby constants. Ruby
objects can remain temporary adapters until each C owner has a complete
conversion path and focused ordering tests.

The tokenizer publishes frozen semantic tokens with byte spans. The parser
publishes a frozen regular-core AST. The compiler consumes only that AST and
publishes a frozen G-IR graph with ordered start edges and edge actions.

Parser and compiler opcode checks use initialization-time ID values. They do
not call `rb_intern` during GIR validation, RSeq lowering, or VM dispatch.
AST field keys in parser construction also use cached IDs. This removes
repeated string-to-symbol work while the token and AST vector migrations are
implemented in separate steps.

The string-scan audit is now explicit. The active matcher has no `strcmp` or
`strncmp` calls. Its remaining `rb_intern_str` calls are limited to option
normalization and compile-time property-name resolution. Feature scanning uses
the precomputed token IDs, so matching does not repeat those conversions.

RSeq lowering preserves state, edge, start-edge, and action order. It publishes
an immutable semantic view, an immutable physical execution view, and a
validated, aligned, relocatable v1 blob. The physical view is built during
RSeq lowering. Match calls do not rebuild it or rescan the pattern. The blob
contains the header, state, edge, action, class, and literal descriptor
sections. The semantic and physical headers and cached view are checked once
before publication. VM entry points remain internal and receive only compiled
programs created by `Onibi::Regexp`.
Compiled `Onibi::Regexp` objects use the validated immutable view directly.

The C executor supports literals, alternation, classes, POSIX classes, common
escapes, anchors, bounded repeats, captures, word boundaries, search-origin
assertions, fixed-width lookarounds, match reset, and numeric or named
backreferences. Fixed-width lookarounds use immutable literal, class, escape,
and wildcard predicates. The dispatcher has separate C entry points for all
three execution classes. They share graph walkers while their dispatch
contracts and RSeq validation are explicit.

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
benchmark contract suite has 172 cases and 796 assertions after an explicit C
build. Character-class range and GIR resource validation are parser/compiler
gates.

Deterministic capture conditionals lower to ordered `TEST_CAPTURE` guarded
edges. Branch capture actions use the same tag history. Conditional branches
with unsupported internal actions remain an explicit MRI boundary.

The RSeq physical opcode contract preserves `G_CALL`, `G_ATOMIC`, and
`G_ABSENT` state identifiers. The flat graph VM rejects these states until
their subprogram call-frame executor is available.

Remaining gates are complete option and encoding semantics, atomic backtracking
states, variable-width lookaround subprograms, and complete tag-history sharing.

The benchmark contract tests compare both paths with MRI. The regex-redux
benchmark output is identical for Ruby and Onibi.

The complete legacy suite currently reaches 857 tests and 4555 assertions.
It still reports failures for legacy Ruby AST APIs, ClassPredicates, full
encoding compatibility, and unsupported dynamic features. These failures are
tracked separately from the focused C pipeline contract.
