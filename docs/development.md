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
| tokens, AST, GIR | C compiler scope | Compile-time only; tokens also have a retained fixed-field C view for dispatch metadata |
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

The active tokenizer and compiler use `rb_intern_str` only while they build
numeric name and property IDs. No string ID lookup occurs in the match loop;
runtime dispatch uses cached enum or ID fields.

The RSeq lowerer now reads C records for state, edge, action, payload, and
subprogram physicalization. Remaining Ruby array reads in that function are
limited to immutable semantic adapter validation and initial record import.

Public `Regexp` methods return Ruby values only at the API boundary. Match
results, named-capture maps, and converted source/options values remain Ruby
objects because callers can inspect them. Lexer tokens, AST nodes, GIR
states, compiler fragments, and RSeq semantic records have no public method;
their Ruby containers are adapters scheduled for C ownership.

The remaining compiler containers have three separate roles:

| Container | Current role | Migration order |
| --- | --- | --- |
| fragment `starts`/`exits` | Ordered state-ID sets | Owned `OnibiIdVector` values with explicit move and append operations |
| fragment action arrays | Ordered semantic actions | Second; typed action vector |
| capture and exit guards | State-ID lookup during edge creation | C guard vectors with C-owned action values and cached counts; Ruby action arrays are materialized only while creating an edge adapter |
| capture names, bodies, and subprogram indexes | No | C value maps with Ruby payload references | These maps exist only during compilation. Keys are AST-owned values or names; no Ruby API can inspect them. A temporary Ruby root array keeps malloc-backed entries visible to GC. |
| GIR `states`/`edges` | Published semantic snapshot for RSeq lowering | C vectors during construction; materialize frozen Ruby adapters once at the GIR boundary |

Detailed ownership review:

The current source has 81 `rb_hash_new` calls and 54 `rb_ary_new` calls.
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
| AST (`Hash`/`Array`) | No | Pending: typed C node arena; analysis flags are cached as an enum bitset in `OnibiParsed` | Node kinds and links are fixed. Required fields are `type_code`, `start`, `end`, `children`, `branches`, `body`, `atom`, `yes`, `no`, and typed scalar payloads. Initialization now computes AST safety flags once. |
| AST lifetime after initialization | No | Release the Ruby adapter; skip deep-freeze | Runtime matching uses published GIR/RSeq data. `onibi_build_program` releases the AST immediately after compiler and RSeq publication; the parsed AST is no longer retained. Internal AST generation does not deep-freeze or rescan the tree. |
| parser result | No | Converted to `OnibiParsed` | It contains only AST and option bits. |
| GIR builder state and edge arrays | No | C state/edge vectors with one Ruby snapshot | The builder mutates records during compilation. RSeq and validation need one stable frozen adapter only. |
| RSeq class and literal payload indexes | No | Typed C payload vectors during lowering | Payload identity is used only for deduplication and blob indexing. Class records cache bitmap and negation; literal records cache byte and ignorecase. Ruby arrays are not needed for these temporary indexes. |
| RSeq flattened actions | No | C `OnibiRSeqActionVector` until publication | Each record caches the Ruby payload, GIR opcode, physical opcode, operation ID, common boolean flags, assertion subtype, and numeric arguments. The frozen Ruby action array is materialized once for validation and diagnostics. |
| RSeq state records | No | C `OnibiGirStateVector` during lowering | Opcode and payload lookup uses fixed C fields. The frozen GIR state array remains as the semantic adapter. |
| RSeq state payload indexes | No | Cached `payload_index` in the C state record | Deduplication computes the class/literal index once. Physical state encoding does not repeat payload comparisons. |
| RSeq physical edges | No | C edge records during blob construction | Destination and action offsets are already available in the lowering records. Physicalization does not need another Ruby Hash scan. |
| GIR edge action counts | No | Cached `action_count` in `OnibiGirEdgeEntry` | Physical edge encoding needs only the count. It no longer queries the Ruby action array length for each edge. |
| RSeq physical actions | No | Read the C action vector during blob construction | Feature detection and opcode encoding use the flattened C order directly. The Ruby action array is only the published semantic adapter. |
| RSeq subprogram descriptors | No | `OnibiRSeqSubprogramVector` during lowering | Entry, accept, and flags are numeric execution fields. The Ruby descriptor array remains only as the semantic adapter. |
| RSeq physical execution view | No | Pending: `OnibiRSeqView`-backed VM entry | `onibi_rseq_physical_graph` still creates a Ruby Hash adapter for tagged and dynamic walkers, but it now copies action ranges from cached edge lengths. Regular fast paths already read the blob directly; capture walkers still require a C view migration. |
| fragment start/exit IDs | No | `OnibiIdVector` | IDs are numeric and ordered. Fragment composition, guard insertion, and GIR connections use C vectors. Ruby arrays are not used for fragment state IDs. |
| fragment action lists | No for shape; yes for payload values | Use typed action records with Ruby payload fields | Action order is semantic, but names and bitmaps still cross the GC boundary. Guard action lists now use C-owned VALUE vectors; fragment lists remain the next migration boundary. |
| RSeq semantic program | No public API | Partial C lowering records; immutable Ruby adapter at publication | VM reads the physical blob. Payload indexes and temporary edge records use C vectors; semantic arrays remain only for validation and diagnostics. |
| regular VM visited set | No | C bitset with owned large-set storage | Numeric state/position pairs use a C bitset. Sets up to 64 MiB use owned C memory when stack storage is too large; counter-bearing paths retain a safe Ruby fallback. |
| tagged VM counter maps | No | Pending: C counter snapshots | Counter slots are numeric and private. Current Ruby Hash use occurs in call frames and ordered edge branches; one migration must cover both paths and the visited-key identity. |
| lookaround predicate kind | No | Numeric `predicate_code` enum | The Symbol name remains diagnostic; VM dispatch uses the numeric code. |
| position assertion subtype | No | Numeric `assert_kind` code | VM position checks and RSeq physicalization use the numeric subtype; `op` remains only for semantic adapter details. |

The two largest remaining migrations are staged at explicit ownership
boundaries:

1. The token stream will use a C record for kind, byte, span, numeric name
   ID, and option flags. Name strings, capture names, and multibyte literal
   bytes remain Ruby payload references until the parser no longer needs the
   adapter. This keeps the parser order stable while removing fixed-field
   Hash lookups first.
2. The AST will use a C node arena after the token view is complete. Each node
   will store numeric type and span fields plus C child indexes. Ruby values
   will remain only for variable payloads that cross the compiler boundary.
   The arena will own node lifetime; the published GIR adapter will be the
   only Ruby snapshot.

These migrations are not combined. The token view must preserve exact source
spans before AST links can replace Ruby array indexes. The AST arena must keep
all Ruby payloads rooted until GIR publication, so its owner and release path
are verified separately.

### AST field audit

The AST is not part of the `Regexp` public API. The compiler uses these fields:

| Field | Type needed by compiler | C-node decision |
| --- | --- | --- |
| `type_code` | fixed enum | `OnibiAstKind` member |
| `start`, `end` | byte offsets | `long` members |
| `children`, `branches` | ordered node lists | C vectors of node IDs |
| `body`, `atom`, `yes`, `no` | optional node links | node IDs, with `-1` for absent |
| `byte`, `min`, `max`, `slot`, `capture`, `subprogram` | integer scalars | fixed integer members |
| `name`, `name_id`, `bytes`, `ranges`, `predicates` | Ruby or encoded payloads | owned VALUE payload fields until GIR publication |

The first AST migration unit is the node arena and its ordered child vectors.
Payload VALUE fields stay GC-rooted in the arena. No Ruby AST adapter is
created by the `Regexp` public API; diagnostics use the C analysis fields.

The tagged VM counter migration is separate from capture maps. Capture maps
can become public match data, but counter slots never cross the `Regexp` API.
The replacement must use a fixed C array per frame and include the counter
snapshot in visited-state identity without allocating a Ruby Hash.
| captures and tag history | Yes at MatchData boundary | Keep Ruby `VALUE` | Ruby owns the result objects and GC must see them. |

The first conversion is complete for parser and compiler result adapters. The
remaining token, AST, fragment, GIR, and RSeq conversions stay separate so
each change can preserve ordering and GC tests.

Feature classification now copies the fixed token fields into an immutable
`OnibiFeatureTokenVector` owned by each compiled regexp. The scanner compares
enum kinds, numeric bytes, and precomputed property IDs, property kinds, and flags from this C
view. The vector has no Ruby `VALUE` fields; source token Hashes remain only
the parser adapter. POSIX class dispatch also consumes the cached token
`name_id`; class bitmap construction, including child escapes, does not
intern a class name during compilation.
The tokenizer records each optional name as `name_id` once, so later feature
classification does not intern the same name again. It also records the
inline-ignorecase flag once, so feature classification does not scan the name
string again.
AST nodes retain this numeric `name_id` for escape properties, so compiler
validation and class bitmap construction can reuse the token ID without
another string-to-ID conversion.
Compiled class payloads also cache a numeric match mode for UTF-8
intersections, so the VM does not inspect the AST kind on every character.

GIR actions now carry a numeric `action_code` enum beside their diagnostic
Symbol name. Position assertions also carry a numeric `assert_kind` subtype.
Validation, VM dispatch, and RSeq lowering use these numeric fields; the
Symbol remains only as a semantic adapter until typed action vectors exist.

The action Symbol is still required for assertion-specific ordering flags and
semantic adapters. `assert_kind` identifies each position assertion, but the
full action record still carries Ruby payloads. Remove the Symbol only after
those payloads have typed C ownership.

The compiler must not expose these containers through Ruby constants. Ruby
objects can remain temporary adapters until each C owner has a complete
conversion path and focused ordering tests.

The tagged counter map is a deliberate later boundary. A C replacement must
copy counters when a frame branches, preserve values across subroutine calls,
and keep capture/tag history independent. Converting only the entry map would
leave edge branches on Ruby Hash and would not remove the repeated copy cost.

Capture and exit guard maps have the same constraint. Their keys are numeric
state IDs, but their values are ordered, mutable action lists. Keep the Ruby
adapter until a C map has an explicit exception-safe owner for those lists.

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
