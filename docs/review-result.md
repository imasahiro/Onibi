# Onibi GIR branch — Architecture / Design / Performance / Readability Code Review

## 0. Review scope

**Reviewed revision**

* Repository: `imasahiro/Onibi`
* Branch: `GIR`
* Commit: `bbb6017a3c0afa8092f616557bfc86091619cbc9`
* Commit message: `Add diagnostic executor error injection`

**Primary specification**

* `docs/gir.md`

**Primary implementation**

* `ext/onibi/*.c`
* `ext/onibi/onibi_ir.h`
* `ext/onibi/onibi_vector.h`

**Relevant tests inspected**

* executor dispatch
* subexpression calls
* nesting limit
* Unicode properties
* test tree / differential-test structure

The review treats `gir.md` as the intended architecture rather than treating the current fallback behavior as the desired end state.

---

# 1. Executive summary

The current implementation is a useful prototype, but there is a substantial gap between **“GIR-shaped code exists”** and **“G-IR is actually the canonical semantic program”**.

The five most important findings are:

1. **Canonical G-IR is not yet canonical.**
   Production compiler paths still construct and consume Ruby `Hash`, `Array`, `String`, and `VALUE` records as semantic intermediates. `gir.md` explicitly requires compiler passes to use typed C semantic records instead.

2. **The documented compiler pipeline is largely declarative rather than real.**
   Resolve/normalize/analyze records exist, but option resolution and substantial semantic work still happen inside recursive lowering. The supposed tagged ε-NFA is constructed *after* GIR-like states/edges and all existing transitions are labelled `CONSUME`, so ε-elimination currently has little architectural meaning.

3. **The three-executor experiment is not yet implemented.**
   `TAGGED` calls `DYNAMIC`, and `DYNAMIC` first requires `regular_capable`, causing actual dynamic programs to fall back to MRI. The tests explicitly encode this interim fallback behavior.

4. **Encoding and byte-position semantics are not consistently separated from Ruby API character positions.**
   There are concrete byte/character-offset hazards, byte-oriented Unicode property matching, and a `\X` helper that uses byte positions as `rb_str_substr` character positions.

5. **Timeout/interrupt, transactional semantic state, verifier coverage, exception safety, and memory architecture are not yet strong enough to safely enable TAGGED/DYNAMIC.**

Therefore I **do not recommend enabling currently-fallback features one by one**. Doing so would expose latent semantic bugs that are currently hidden by MRI fallback.

The correct sequence is:

> canonicalize compiler semantics → strengthen GIR/RSeq verification → complete physical semantic representation → implement true TAGGED → implement true DYNAMIC → repair API/encoding boundary → remove unnecessary MRI dependence → optimize.

---

# 2. Severity convention

| Severity | Meaning                                                                                                         |
| -------- | --------------------------------------------------------------------------------------------------------------- |
| **P0**   | Semantic correctness or architectural blocker. Must be addressed before claiming the GIR design is implemented. |
| **P1**   | Serious robustness, performance, resource-management, or future correctness risk.                               |
| **P2**   | Maintainability/readability problem that materially increases future bug risk.                                  |
| **P3**   | Local cleanup / naming / mechanical quality issue.                                                              |

Agent allocation used below:

* **Codex 5.6 Sol** — cross-module semantic work, compiler/runtime architecture, correctness-sensitive algorithms.
* **Codex 5.6 Luna** — bounded refactoring, verification expansion after contracts are fixed, local performance improvements, mechanical cleanup.

---

# 3. Architecture findings

## A-01 — Production compiler still uses Ruby objects as semantic IR

**Severity:** P0
**Category:** Architecture
**Owner:** **Sol**

`onibi_compile_node()` accepts a `VALUE`; compiler code supports either a C AST ID or Ruby semantic object. Class normalization and terminal lowering manufacture Ruby hashes/arrays/strings which are then consumed by later compiler code. The builder also owns several `OnibiValueMap` structures containing Ruby `VALUE`s.

This directly weakens one of the most important goals in `gir.md`: G-IR should be a **typed C semantic representation**, not a Ruby-object-shaped intermediate.

### Why this matters

This is not just allocation overhead.

It means:

* compiler invariants are represented dynamically rather than in C types;
* Ruby GC and exceptions remain part of semantic lowering;
* later ZJIT/MRI integration cannot treat GIR as a clean C interface;
* ownership rules become ambiguous;
* semantic fields can silently disappear between Ruby hashes;
* debug representation and canonical representation become conflated.

The comment in `diagnostics.c` says Ruby Hash records are diagnostic-only, while the compiler currently has production paths using the same representation. That comment is therefore misleading.

### Developer review comment

> Do not optimize or extend the current Ruby-Hash semantic adapter. Remove it from the production compiler path. Define typed C payloads for literals, character classes, assertions, calls, repeats, captures and option environments. Ruby object generation should happen only when diagnostics explicitly request a debug view.

### Required direction

Introduce a semantic layer similar to:

```text
AST
  ↓ resolve
ResolvedAST / SemanticAST
  ↓ normalize
NormalizedSemanticAST
  ↓ lower
TaggedNFA
  ↓ epsilon elimination
GIR
```

Every arrow should exchange C-owned structures.

---

## A-02 — Compiler pass objects currently describe boundaries that do not really exist

**Severity:** P0
**Category:** Architecture / Readability
**Owner:** **Sol**

`OnibiParseOutput`, `OnibiResolveOutput`, `OnibiNormalizeOutput`, `OnibiAnalyzeOutput`, etc. suggest an explicit pass pipeline, but current `onibi_compiler_compile()` mostly aliases the same AST through these records. Resolve and normalize do not perform their documented transformations. Analyze reports `min_width = 0` and `max_width = -1` rather than performing the intended analysis.

### Why this matters

A named pass boundary is valuable only if it establishes an invariant.

Right now a future developer can reasonably assume:

> “inline options have already been normalized here”

when in fact they have not.

This is more dangerous than having no pass abstraction at all.

### Developer review comment

> Each pass type must document and enforce an output invariant. Do not keep pass structs merely to make the control flow look like the design document. Either implement the transformation or remove the false boundary until it exists.

---

## A-03 — Inline regexp options are resolved during lowering instead of before GIR

**Severity:** P0
**Category:** Semantic architecture
**Owner:** **Sol**

`ONIBI_AST_OPTION_GLOBAL` and `ONIBI_AST_OPTION_SCOPE` mutate:

```text
builder->ignorecase
builder->multiline
```

while recursive lowering is in progress.

This conflicts with the intended architecture where lexical options are resolved before canonical GIR.

### More serious consequence: subexpression calls

Capture bodies are stored as AST IDs. Named subprograms are compiled later by calling `onibi_compile_node(body, builder)` using the **current builder option state**.

Therefore a capture's lexical option environment is not intrinsically attached to its definition.

A particularly important differential case is structurally like:

```ruby
(?i:(?<x>a))(?-i:\g<x>)
```

The called definition must retain the lexical options under which it was defined. The current representation makes call-site option contamination possible.

Existing subexpression tests verify reuse and capture spans, but do not cover this lexical-option invariant.

### Developer review comment

> Resolve an explicit immutable `OptionEnv` for every semantic AST node before subprogram extraction. A subprogram must carry its definition-site environment. Never rely on mutable compiler-global option fields while recursively compiling a referenced body.

---

## A-04 — Tagged ε-NFA stage is presently a façade

**Severity:** P0
**Category:** Compiler architecture
**Owner:** **Sol**

Current lowering first builds GIR-like states and edges. It then transfers those edges into `OnibiTaggedNfa`, assigning every existing transition:

```c
ONIBI_NFA_CONSUME
```

The comment explicitly says future zero-width lowering may introduce ε transitions.

`nfa.c` contains a genuine ε-closure algorithm, but the current compiler does not produce the intended ε-NFA as its primary lowering representation.

### Why this matters

The ordering should be:

```text
semantic AST
→ tagged epsilon NFA
→ ordered epsilon elimination
→ epsilon-free GIR
```

Current structure is approximately:

```text
semantic AST
→ GIR-like graph
→ wrap graph as NFA with CONSUME edges
→ epsilon elimination
→ GIR
```

That means one of the most important normalization boundaries in the design is not presently validating what it is supposed to validate.

### Developer review comment

> Make `OnibiTaggedNfa` the actual output of semantic lowering. Zero-width constructs, captures and ordering should exist there in their natural representation. GIR state creation should happen only after ordered ε-elimination.

---

## A-05 — TAGGED executor is not a TAGGED executor

**Severity:** P0
**Category:** Runtime architecture
**Owner:** **Sol**

Current implementation:

```c
static OnibiExecStatus
onibi_exec_tagged(OnibiExecCtx *ctx)
{
    onibi_diagnostics.tagged++;
    return onibi_exec_dynamic(ctx);
}
```

The test suite explicitly expects a tagged assertion to also increment DFS.

### Why this matters

The central architectural experiment in `gir.md` is that the same semantic program can be interpreted through separate strategies:

* REGULAR_FAST
* TAGGED_ORDERED
* DYNAMIC

A tagged program going through a DFS compatibility traversal does not test that hypothesis.

### Developer review comment

> Implement TAGGED as an ordered-frontier interpreter. It must preserve edge priority and semantic thread state without DFS/backtracking. Do not derive it by adding conditions to the compatibility walker.

---

## A-06 — DYNAMIC is currently gated by `regular_capable`

**Severity:** P0
**Category:** Runtime architecture
**Owner:** **Sol**

`onibi_rseq_backtracking_match()` immediately returns failure unless:

```c
view->regular_capable
```

is true.

But `regular_capable` rejects counters, calls and other dynamic constructs.

The result is that constructs that cause DYNAMIC classification commonly enter DYNAMIC only to fall back to MRI.

Existing tests explicitly encode this for backreferences.

### Developer review comment

> Separate “RSeq structurally valid”, “regular-frontier-capable”, “tagged-capable” and “dynamic-capable”. DYNAMIC must not depend on REGULAR eligibility.

---

## A-07 — Dynamic thread deduplication ignores semantic state

**Severity:** P0
**Category:** Runtime semantics
**Owner:** **Sol**

The compatibility DFS maintains:

```text
visited[state, position]
```

and comments that capture actions should not allow revisits.

But the design requires dynamic execution identity to include relevant semantic state, such as:

* captures used by backreferences/conditionals;
* counters;
* call stack;
* atomic/absence state;
* potentially reported start.

Two threads at the same `(state, position)` can have different future behavior.

### Consequence

If the `regular_capable` gate is simply removed as an “easy fix”, DYNAMIC can become semantically incorrect.

### Developer review comment

> Do not enable the current DFS walker for dynamic programs. Define `DynamicThreadKey` from actual future-observable semantic state and use that contract when deduplicating.

---

## A-08 — Transactional action semantics are not represented as per-thread state

**Severity:** P0
**Category:** Runtime semantics
**Owner:** **Sol**

`ONIBI_RA_MATCH_RESET` currently performs:

```c
onibi_active_exec_ctx->reported_start = pos;
```

inside edge action execution.

That field belongs to the entire execution context rather than a candidate thread.

### Why this is wrong architecturally

Action effects must be transactional:

1. start with a thread's semantic state;
2. apply actions;
3. if an assertion/test fails, discard the resulting state;
4. publish the new state only with the successor thread.

`MATCH_RESET` cannot be global if two alternatives can execute independently.

The same general rule applies to:

* semantic capture registers;
* repeat counters;
* progress markers;
* call stack;
* atomic/absence boundaries.

### Developer review comment

> Implement one transactional action API whose input is immutable/current thread semantic state and whose output is either `FAIL` or a successor state. No semantic action should mutate global execution context before its branch commits.

---

## A-09 — `OnibiExecCtx` describes an architecture that the interpreters do not actually use

**Severity:** P1
**Category:** Architecture / Readability
**Owner:** **Sol**

`OnibiExecCtx` contains:

* current/next frontiers;
* tag arena;
* semantic capture file;
* counter file;
* call stack;
* poll budget.

But major interpreters instead allocate local stacks/arrays and branch-specific pools.

### Why this matters

The execution ABI should be the real owner of match-local memory. Otherwise:

* restartability is harder;
* timeout polling cannot preserve a coherent state boundary;
* memory reuse between attempts is lost;
* the declared architecture and actual architecture diverge.

### Developer review comment

> Make `OnibiExecCtx` the real owner of reusable runtime arenas. Delete fields that are not part of the actual ABI; do not retain aspirational fields indefinitely.

---

# 4. Semantic representation and RSeq findings

## R-01 — RSeq does not yet contain complete semantics for several supported GIR opcodes

**Severity:** P0
**Category:** IR design
**Owner:** **Sol**

RSeq defines states for:

* `GRAPHEME`
* `CALL`
* `ATOMIC`
* `ABSENT`
* `BACKREF`

but the compatibility walker handles only a subset. `ATOMIC` and `ABSENT` do not have executable semantics there.

Lookaround lowering is especially problematic: the compiler builds semantic predicate information in Ruby objects, but the physical action contains only compact scalar fields. The full predicate program is not present in RSeq.

### Developer review comment

> For every GIR opcode/action, document exactly what information survives serialization. Add a round-trip semantic completeness test: GIR → RSeq must retain everything an interpreter needs without AST/Ruby-object access.

---

## R-02 — RSeq verifier is substantially weaker than the stated contract

**Severity:** P0
**Category:** Verification
**Owner:** **Sol**

Current verifier checks useful structural properties, including ranges and some payload bounds, but it does not fully validate:

* every action program reaches `RA_END`;
* capture operands are in range;
* counter operands are in range;
* action flag/op combinations;
* all section alignment requirements;
* action program starting-boundary validity;
* subprogram semantic invariants;
* call targets versus subprogram count;
* atomic/absence-specific requirements;
* semantic capture metadata consistency.

### Developer review comment

> Treat RSeq validation as an executable specification. The executor must be able to assume all operand and section invariants after validation. Runtime hot loops should not repeatedly compensate for malformed internal programs.

---

## R-03 — GIR verifier currently only validates edge state ranges

**Severity:** P0
**Category:** Verification
**Owner:** **Sol**

`onibi_compiler_pass_verify_gir()` currently checks essentially only edge source/destination ranges.

That is insufficient for a canonical semantic IR.

### Required checks

At minimum:

* state IDs contiguous/valid;
* opcode payload invariants;
* edge order preservation;
* action opcode validity;
* capture slots;
* counter slots;
* subprogram references;
* semantic capture references;
* repeat/progress invariants;
* start edges;
* accept-state properties;
* lookaround subprograms;
* absence/atomic subprogram properties;
* option environments already resolved;
* no forbidden Ruby semantic dependency.

### Developer review comment

> GIR verification should fail close to the producer of invalid semantics. Do not delegate semantic consistency to RSeq lowering.

---

## R-04 — `uint16_t` action operand can truncate capture/counter slots

**Severity:** P0
**Category:** IR correctness
**Owner:** **Sol**

`OnibiRAction.arg16` and `OnibiGAction.slot` use 16-bit storage, while capture counts in the program are 32-bit.

Compiler code explicitly casts capture tag positions:

```c
(uint16_t)(2 * capture_id)
(uint16_t)(2 * capture_id + 1)
```

### Developer review comment

> Either formally cap capture/counter counts before GIR and reject larger programs, or widen physical operands. Never rely on an implicit narrowing cast.

---

## R-05 — Large bounded repeats contradict the documented counter design

**Severity:** P0
**Category:** Compiler semantics / scalability
**Owner:** **Sol**

The design intends small repeats to be unrolled and large repeats to use semantic counters.

Current feature detection treats `> 8` as “large repeat”, and current tests explicitly expect `a{9}` to have no RSeq.

The compiler contains counter machinery, but the published behavior still excludes exactly the case counters are supposed to solve.

### Developer review comment

> Implement one repeat-normalization pass: `0..UNROLL_LIMIT` may unroll; larger finite ranges become counter-based GIR; unbounded nullable repeats receive progress guards. Update tests so `a{9}` validates the counter path rather than fallback.

---

## R-06 — Possessive repeat support is structurally incomplete

**Severity:** P1
**Category:** Semantic lowering
**Owner:** **Sol**

Current compiler rejects variable possessive quantifiers rather than lowering them to an atomic semantic form.

### Developer review comment

> Normalize possessive repetition into explicit atomic semantics before NFA/GIR lowering. Do not special-case every possessive syntax form in the executor.

---

## R-07 — Physical class representation is effectively an 8-bit bitmap only

**Severity:** P0
**Category:** Encoding / IR design
**Owner:** **Sol**

`OnibiClassDesc.kind` exists, but serialization currently writes:

```text
kind = 0
data_length = 32
```

for 256-bit classes.

`onibi_class_bitmap()` implements properties by iterating `0..255` using ASCII predicates.

This is not sufficient for the intended encoding-aware class model.

### Developer review comment

> Implement explicit descriptor kinds such as ASCII bitmap, codepoint ranges, MRI encoding ctype, and mixed descriptors. The executor should ask the selected MRI encoding callbacks about a decoded character rather than classifying arbitrary encoded bytes.

---

# 5. Concrete encoding / API correctness findings

## E-01 — Unicode property programs can enter a byte-oriented executor

**Severity:** P0
**Category:** Correctness
**Owner:** **Sol**

This is one of the highest-risk concrete issues found.

`onibi_vm_input_eligible()` explicitly permits valid UTF-8 subjects when the regexp has `ONIBI_FEATURE_UNICODE_PROPERTY`.

But the current class bitmap for `Alpha`, `Lower`, `Word`, etc. is generated using ASCII-only membership over values `0..255`.

The repository tests expect examples such as:

```ruby
\p{Lower}  =~ "é"
\p{Alpha}  =~ "あ"
\p{Word}   =~ "あ"
```

to behave like MRI.

### Risk

A UTF-8 multibyte character reaches a byte-bitmap matcher whose semantic unit is not the decoded character.

### Developer review comment

> Until encoding-aware class descriptors are implemented, Unicode-property RSeq must not claim UTF-8 execution eligibility. The permanent fix is not another feature gate; it is character decoding + MRI encoding predicate semantics.

---

## E-02 — Word-boundary logic is ASCII-byte based

**Severity:** P0/P1
**Category:** Encoding semantics
**Owner:** **Sol**

`onibi_rseq_word_byte()` defines “word” as ASCII letters, digits and `_`, and assertions inspect the bytes immediately adjacent to `pos`.

This is not a valid general implementation of MRI encoding-aware word boundary behavior.

### Developer review comment

> Word classification must operate on previous/current encoded characters using MRI's encoding/ctype facilities. Do not inspect `pos - 1` as if it were necessarily the previous character.

---

## E-03 — Ruby-visible character positions and internal byte positions are mixed

**Severity:** P0
**Category:** API correctness
**Owner:** **Sol**

The design correctly wants VM positions to be byte offsets.

However Ruby APIs use character-oriented indexing in several places, and wrappers currently reuse internal byte positions directly.

Examples:

* `Regexp#match(..., pos)` normalization uses `RSTRING_LEN` bytes;
* `scan` calls `rb_str_substr(str, start, end - start)`;
* `gsub` block matching similarly uses `rb_str_substr`;
* MRI rematerialization receives offsets produced by the VM.

The tokenizer itself contains a good comment explicitly recognizing that `rb_str_substr` uses character offsets while tokenizer positions are byte offsets.

That same rule has not been consistently applied in the public API layer.

### Developer review comment

> Establish a hard boundary:
>
> * VM / RSeq / captures: `OnigPosition` byte offsets.
> * Ruby `pos` arguments and Ruby substring APIs: convert explicitly at the wrapper.
> * Raw byte slicing: use byte-copy APIs rather than `rb_str_substr`.

---

## E-04 — Position types are inconsistent

**Severity:** P1
**Category:** Type safety / Readability
**Owner:** **Luna**

`OnibiExecCtx` uses `OnigPosition` for several input positions, but:

* captures use `long *`;
* counters use `long *`;
* `matched_end` is `long`;
* runtime frame `pos` is `long`;
* many APIs accept `long`.

### Developer review comment

> Introduce explicit typedefs:
>
> * `OnibiBytePos` / `OnigPosition` for subject positions;
> * fixed-width state IDs;
> * signed repeat counters where required.
>
> Avoid generic `long` for semantically distinct quantities.

---

## E-05 — Manual UTF-8 codec duplicates MRI encoding responsibilities

**Severity:** P1
**Category:** Architecture
**Owner:** **Sol**

`onibi_common.c` contains local UTF-8 decode/encode routines.

### Developer review comment

> Canonical semantic lowering should use MRI encoding callbacks / Onigmo encoding APIs. A bespoke UTF-8 implementation creates a second encoding engine and will diverge on invalid sequences, case folding, code ranges and non-UTF-8 encodings.

---

## E-06 — `\X` helper cannot become a production executor primitive in its current form

**Severity:** P1
**Category:** Performance / Correctness
**Owner:** **Sol**

For each grapheme check it:

* allocates a Ruby String for `"\\X"`;
* constructs a Ruby Regexp;
* creates a substring;
* executes MRI regexp;
* manipulates `$~`.

It also gives `rb_str_substr` a byte-based `pos`.

### Developer review comment

> Keep `\X` disabled until it is represented as a genuine encoding-aware primitive or dedicated semantic subprogram. Do not merely remove the current compiler rejection.

---

# 6. Runtime / performance / robustness findings

## P-01 — Timeout and interrupt polling is outside the hot interpreter loops

**Severity:** P0
**Category:** Runtime robustness
**Owner:** **Sol**

`onibi_vm_search_body()` checks:

```c
rb_thread_check_ints();
onibi_check_deadline();
```

once before each candidate execution.

Neither the REGULAR frontier loop nor DYNAMIC DFS loop performs bounded-work polling.

`OnibiExecCtx.work_before_poll` exists, but the deadline helper merely decrements it; no interpreter work accounting implements the documented ~128-unit polling discipline.

### Consequence

A single expensive candidate can run for a long time without:

* timeout enforcement;
* interrupt handling;
* cooperative VM responsiveness.

### Developer review comment

> Add a common `onibi_exec_charge_work(ctx, n)` API used from every executor. When the budget reaches zero, store coherent thread/frontier state, call the MRI interrupt checker, test the deadline, reload subject-derived pointers, reset the budget, and continue.

---

## P-02 — DYNAMIC uses large `alloca` pools proportional to state × subject × semantic state

**Severity:** P0/P1
**Category:** Memory safety / Performance
**Owner:** **Sol**

The DFS walker constructs:

```text
visited_size = state_count * (subject_bytes + 1)
```

then stack-allocates:

* visited bitmap;
* traversal frames;
* counter pool per possible frame;
* capture pool per possible frame;
* optional return-stack pool.

There is a `visited_size <= 65536` cutoff, but multiplication by capture and counter counts can still produce very large stack allocations.

### Developer review comment

> Move match-local arenas to heap-backed reusable sidecars owned by `OnibiExecCtx`. Use copy-on-write or persistent semantic state rather than copying the entire capture/counter file for every branch.

---

## P-03 — Dynamic branch cloning copies entire capture/counter state

**Severity:** P1
**Category:** Runtime performance
**Owner:** **Sol**

Every DFS successor copies whole counter and capture arrays.

### Consequence

Branch cost becomes proportional to total semantic register count rather than the number of modified registers.

### Developer review comment

> Use persistent/COW state: immutable parent snapshot + compact deltas, or generation-numbered register banks. Materialize only when needed.

---

## P-04 — Search repeatedly attempts every byte position

**Severity:** P1
**Category:** Search performance
**Owner:** **Sol**

The search loop walks:

```c
for (long start = search_origin;
     start <= RSTRING_LEN(str);
     start++)
```

and rejects non-character boundaries afterward.

It has a small prefix/first-byte prefilter, but no general character-step candidate iterator.

### Developer review comment

> Advance directly via encoding character widths unless a byte-level encoding mode explicitly requires otherwise. Then integrate prefix/bitmap/anchor search metadata on top of that iterator.

---

## P-05 — RSeq prefix extraction has O(states × edges) behavior

**Severity:** P1
**Category:** Compile-time performance
**Owner:** **Luna**

For every state in a candidate literal prefix it scans the complete edge vector to:

1. count outgoing edges;
2. find the next edge.

### Developer review comment

> Prefix analysis should use the already-grouped `edge_base/edge_count` representation or construct an adjacency index once.

---

## P-06 — Literal descriptor offset construction is O(number_of_literals²)

**Severity:** P1
**Category:** Compile-time performance
**Owner:** **Luna**

Each literal descriptor computes its data offset by re-summing every prior literal length.

### Developer review comment

> Maintain a running `literal_data_cursor`.

---

## P-07 — Class and literal deduplication use repeated linear search

**Severity:** P1
**Category:** Compile-time performance
**Owner:** **Luna**

RSeq lowering compares every class/literal against all previously seen payloads.

### Developer review comment

> Use hash-consing keyed by `(kind, flags, bytes/ranges)` after canonical class/literal normalization. Preserve deterministic insertion order.

---

## P-08 — Action programs are duplicated rather than interned

**Severity:** P1
**Category:** RSeq size / cache locality
**Owner:** **Luna**

Each edge's action vector is appended independently to the physical action section.

### Developer review comment

> After semantic normalization, hash-cons identical immutable action programs. Keep action IDs in GIR and physical offsets only in RSeq.

---

## P-09 — ε-closure implementation scales poorly

**Severity:** P1
**Category:** Compiler performance
**Owner:** **Luna** after A-04

For each closure node, `onibi_nfa_emit_closure()` scans the entire edge vector once for ε edges and again for consuming edges. Every emitted edge is deduplicated by linear search over the result. Action vectors are concatenated/copied during traversal.

### Developer review comment

> Once the real ε-NFA exists, build adjacency ranges by source state and use a keyed dedup table. Preserve edge priority explicitly; do not use an unordered structure for traversal order.

---

## P-10 — Parser repeatedly scans for matching delimiters

**Severity:** P2
**Category:** Compile-time performance / readability
**Owner:** **Luna**

Parsing a group calls `onibi_c_find_close`, and nested classes/groups recursively repeat range scans.

The repository intentionally caps regexp nesting at 256, which prevents unbounded C recursion but does not remove needless repeated work.

### Developer review comment

> Tokenization should record matching delimiter indices, or parser should construct them in one stack pass. Parser recursion can remain bounded, but delimiter discovery should be O(n).

---

## P-11 — `OnibiValueMap` design causes linear lookup and Ruby allocation churn

**Severity:** P1/P2
**Category:** Compiler performance
**Owner:** **Luna** after A-01

Capture collection creates Ruby strings for numeric capture keys and stores symbol/name information in generic Ruby-value maps.

### Developer review comment

> Use typed maps:
>
> * capture number → AST ID: indexed vector;
> * capture name slice → capture definition list: C hash table;
> * subprogram ID → descriptor: vector.
>
> Do not stringify numeric IDs.

---

## P-12 — Arbitrary names are interned during tokenization

**Severity:** P1
**Category:** Resource behavior
**Owner:** **Luna**

Tokenizer calls `rb_intern2()` for parsed names/properties.

### Developer review comment

> Avoid interning arbitrary user-controlled capture/property text. Keep source slices or hashed byte strings, and only map known built-in property names to pre-interned IDs.

---

# 7. Error handling / ownership findings

## M-01 — Compiler exception cleanup is not structured

**Severity:** P0/P1
**Category:** Resource management
**Owner:** **Sol**

`onibi_compiler_compile()` owns many C vectors/maps in a stack-local builder and frees them only on normal completion. Most helper functions may `rb_raise`.

A Ruby non-local jump therefore bypasses ordinary cleanup.

### Developer review comment

> Introduce one compiler owner object plus `rb_ensure`/protected cleanup boundary. Every pass-owned allocation must either be transferred or freed by that owner.

The same principle applies to temporary vectors in RSeq lowering.

---

## M-02 — Compile failures are caught too broadly and silently converted into MRI fallback

**Severity:** P0
**Category:** Error architecture
**Owner:** **Sol**

Initialization executes compiler construction under `rb_protect`. If it fails, the code clears the exception and marks the program dynamic/fallback.

### Why this is dangerous

“Unsupported by the current Onibi engine” and:

* internal compiler bug;
* verifier failure;
* malformed invariant;
* allocation failure;
* unexpected Ruby exception

are not equivalent conditions.

Broad fallback hides the difference.

### Developer review comment

> Define explicit compile outcomes:
>
> * `ONIBI_COMPILE_OK`
> * `ONIBI_COMPILE_UNSUPPORTED(feature/reason)`
> * `ONIBI_COMPILE_INVALID_PATTERN`
> * `ONIBI_COMPILE_INTERNAL_ERROR`
>
> Only `UNSUPPORTED` may intentionally select MRI compatibility execution. Re-raise resource and internal failures.

---

## M-03 — Runtime `-1` also conflates unsupported conditions and internal failures

**Severity:** P1
**Category:** Error architecture
**Owner:** **Luna** after executor redesign

DYNAMIC converts a negative traversal result into `FALLBACK`.

The traversal returns the same negative value for several resource/structural conditions.

### Developer review comment

> Use typed executor status codes. “Program unsupported by this executor” is a dispatch decision made before execution, not a generic runtime error path.

---

## M-04 — Thread-local compiler/runtime ambient state is overused

**Severity:** P1
**Category:** Architecture
**Owner:** **Sol**

Globals include:

* `onibi_deadline_ns`
* `onibi_compile_encoding`
* `onibi_active_exec_ctx`
* diagnostic state
* diagnostic capture pointer.

The match path at least uses `rb_ensure` to restore nested execution context/deadline.

Compiler encoding state has no equivalent scoped owner.

### Developer review comment

> Keep transient state in explicit compiler/execution contexts. TLS should be reserved for integration requirements that cannot be passed explicitly.

---

# 8. Public API / MRI dependency findings

## API-01 — Onibi still retains a complete MRI Regexp for every object

**Severity:** P1
**Category:** Architecture / Memory
**Owner:** **Sol**

`onibi_regexp_t` stores both the RSeq and an MRI `Regexp`.

The MRI object is used for:

* fallback;
* MatchData construction;
* names/named captures;
* inspect/to_s/encoding;
* some compatibility methods.

### Why this matters

It:

* doubles compiled-regexp representation;
* hides incomplete Onibi semantics;
* makes memory comparisons unfair;
* prevents the implementation from demonstrating that RSeq is sufficient.

### Developer review comment

> Keep MRI Regexp as a temporary compatibility boundary during the PoC, but make the dependency explicit and measurable. The target should be metadata + RSeq, with MRI invoked only by a clearly identified unsupported fallback path.

---

## API-02 — MatchData and capture materialization re-run MRI

**Severity:** P1
**Category:** Performance / semantic validation
**Owner:** **Sol**

After the Onibi VM selects a match, `match` invokes MRI again to create MatchData. `scan` similarly invokes MRI for captures.

### Problems

* matching work is duplicated;
* Onibi capture semantics are not what user APIs actually expose;
* differential errors can be hidden because MRI “repairs” result materialization;
* `match?` and `match` exercise different amounts of Onibi semantic state.

### Developer review comment

> Introduce a real `OnibiRawMatch` containing byte ranges. Use it as the sole result of all interpreters. Then implement one Ruby-facing materializer from that result.

---

## API-03 — Feature classification has multiple sources of truth

**Severity:** P1
**Category:** Architecture / Readability
**Owner:** **Sol**

There are at least three related classification mechanisms:

1. `onibi_token_features()` from lexical tokens;
2. compiler `VerifiedGIRAnalysis`;
3. runtime `onibi_rseq_regular_capable()`.

`onibi_initialize()` then contains additional overrides such as special handling for subroutines.

### Developer review comment

> Syntax feature flags may remain diagnostic metadata, but **execution class must be derived once from verified semantic GIR**. RSeq lowering must preserve that decision; runtime must only assert compatibility, not independently reclassify semantics.

---

# 9. Readability / module-boundary findings

## C-01 — Amalgamated translation unit creates hidden dependencies

**Severity:** P2
**Category:** Readability / maintainability
**Owner:** **Luna**

`onibi.c` directly includes implementation `.c` files in an intentionally ordered sequence.

The design document permits a small amalgamated TU during the PoC, so this is **not itself a design violation**.

The issue is that implementation modules use symbols declared by previously included `.c` files rather than explicit private interfaces.

### Developer review comment

> Keep the amalgamated build if useful, but introduce private headers defining module contracts. Include order should affect compilation convenience, not semantic visibility.

---

## C-02 — `onibi_common.c` is a god-module

**Severity:** P2
**Category:** Readability
**Owner:** **Luna**

It currently hosts:

* public object structure;
* executor ABI;
* tokenizer/AST types;
* global IDs;
* encoding helpers;
* timeout helpers;
* feature flags;
* forward declarations.

### Developer review comment

> Split *contracts*, not merely files:
>
> * `onibi_ast_internal.h`
> * `onibi_gir_internal.h`
> * `onibi_rseq_internal.h`
> * `onibi_exec_internal.h`
> * `onibi_encoding_internal.h`
> * `onibi_ruby_api_internal.h`

---

## C-03 — Vector utility has hidden Ruby dependency

**Severity:** P2
**Category:** Low-level design
**Owner:** **Luna**

`onibi_vector.h` includes only standard headers, but its macros call:

* `rb_raise`
* `REALLOC_N`
* `xfree`.

Its compilation therefore depends on include ordering.

### Developer review comment

> Either make this explicitly a Ruby allocator utility and include the correct headers, or make it a plain-C allocator abstraction with error returns.

---

## C-04 — Vector append has an undocumented aliasing hazard

**Severity:** P2
**Category:** Low-level correctness
**Owner:** **Luna**

`ONIBI_VECTOR_APPEND` captures `SourceCount`, then may reallocate the destination before dereferencing `SourceData`. If source aliases destination storage, that source pointer can become invalid.

### Developer review comment

> Either explicitly forbid aliasing with assertions/documentation or make self-append safe by calculating source offset before reserve.

---

## C-05 — Vector insert silently clamps invalid indices

**Severity:** P2
**Category:** Invariant visibility
**Owner:** **Luna**

Out-of-range insert becomes append:

```c
if (index > Count)
    index = Count;
```

### Developer review comment

> Internal IR containers should fail loudly on invariant violations. Silent repair makes compiler bugs harder to locate.

---

## C-06 — Tokenizer is an oversized state machine

**Severity:** P2
**Category:** Readability
**Owner:** **Luna**

`onibi_tokenize_internal` performs:

* inline modifiers;
* named groups;
* lookaround;
* class nesting;
* escapes;
* octal/hex decoding;
* backrefs;
* subroutine syntax;
* nesting management;
* property parsing

in one large control flow.

### Developer review comment

> Split token recognition by concern, but retain one scanner cursor and explicit scanner state. Avoid extracting tiny helpers that merely move complexity around; extract complete grammar decisions.

---

## C-07 — Type naming is inconsistent across IR layers

**Severity:** P3
**Category:** Readability
**Owner:** **Luna**

Examples:

* `OnibiStateId` is `uint32_t`;

* `OnibiNfaStateId` is `long`;

* GIR builder uses `long from/to`;

* AST IDs use `uint32_t`.

### Developer review comment

> Use layer-specific fixed-width IDs and explicit checked conversion at layer boundaries.

---

## C-08 — Comments sometimes describe the target architecture rather than current behavior

**Severity:** P2
**Category:** Readability / trustworthiness
**Owner:** **Luna**

Examples include:

* diagnostic Ruby hashes claimed to be non-canonical while similar hashes are used by the production compiler;
* execution-context fields described as owned runtime state even though interpreters use local `alloca` storage;
* “tagged epsilon NFA boundary” even though all current transferred edges are consuming.

### Developer review comment

> Comments should state current invariants. Put planned architecture in `gir.md` or TODOs, not in comments that appear to certify behavior that is not yet true.

---

# 10. Ractor / immutability finding

## RC-01 — Frozen object does not by itself establish the intended Ractor contract

**Severity:** P1
**Category:** Runtime architecture
**Owner:** **Sol**

`Onibi::Regexp` uses typed data with `RUBY_TYPED_FREE_IMMEDIATELY`, and is frozen after initialization.

At the same time there is process/global mutable configuration such as `onibi_default_timeout` and substantial C-side ambient state.

### Developer review comment

> Add an explicit Ractor audit rather than assuming `rb_obj_freeze` is sufficient. Verify typed-data shareability, retained Ruby objects, default-timeout semantics, cached RSeq view pointers, and all mutable globals.

---

# 11. Existing tests reveal important architectural debt

The test structure itself is good: the branch already contains differential, fuzz, encoding, executor, capture and benchmark categories.

However some current assertions intentionally certify interim behavior:

* dynamic backreference → MRI fallback;

* large repeat → no RSeq;

* tagged assertion → DFS;

* subexpression tests omit definition-site lexical option cases.

These tests should not simply be preserved during the architecture work. They must evolve with the contract.

---

# 12. Things that should **not** be done

These are particularly important for Codex subagents.

### Do not “fix” TAGGED by removing the `regular_capable` check

That would expose the semantic-state dedup and transactional-state problems.

### Do not “fix” Unicode properties by extending the 256-byte bitmap

Unicode/encoding semantics require character decoding and MRI encoding predicates, not a larger byte table.

### Do not remove `\X` rejection and rely on `onibi_grapheme_width`

That implementation allocates Ruby objects in the hot loop and uses an incorrect offset domain.

### Do not increase the repeat unroll limit

`8 → 64` or `8 → 1000` merely moves the blow-up threshold. Large repeats need counters.

### Do not add more conditions to `onibi_token_features`

Execution classification belongs to verified semantic GIR.

### Do not retain Ruby Hash semantic IR while merely wrapping it in typed helper functions

The Ruby object itself is the problem.

### Do not split every `.c` file before defining interfaces

Physical file separation without ownership contracts would only create more private headers with the same coupling.

---

# 13. Codex 5.6 implementation plan

The following tasks are deliberately ordered. Tasks in later phases must not bypass invariants established by earlier phases.

---

## Phase 0 — Freeze semantic contracts with failing tests

### TASK-00 — Semantic regression matrix

**Agent:** **Sol**
**Issues:** A-03, A-05, A-06, A-07, A-08, E-01, E-03, P-01
**Dependencies:** none

**Goal**

Create tests that express `gir.md` semantics independently of current fallback behavior.

**Add differential cases for**

* definition-site options on subexpression calls;
* `\K` on failed versus successful alternatives;
* Unicode properties on UTF-8;
* word boundaries adjacent to multibyte characters;
* match positions on strings with multibyte prefixes;
* `scan`/`gsub` byte-versus-character slicing;
* nullable large repeats;
* lazy/greedy priority with captures;
* counter state on converging threads;
* interrupts/timeouts during one long candidate.

**Must not**

* modify executor code;
* mark current fallback as expected unless the feature is explicitly outside the GIR scope.

**Acceptance**

Tests clearly distinguish:

```text
semantic correctness
execution strategy
fallback
```

as separate properties.

---

## Phase 1 — Establish a canonical semantic compiler

### TASK-10 — Introduce explicit resolved semantic AST

**Agent:** **Sol**
**Issues:** A-01, A-02, A-03, API-03
**Dependencies:** TASK-00

**Goal**

Create a C-only semantic AST/normalized representation.

**Required invariants**

Every node reaching lowering already has:

* resolved lexical option environment;
* resolved capture reference;
* resolved subprogram reference;
* normalized repeat form;
* normalized assertion kind;
* encoding semantic descriptor;
* source span used only for diagnostics.

**Files expected**

```text
ast.c
parser.c
compiler.c
gir.c
onibi_*_internal.h
```

**Must not**

* add Ruby Hash fields to carry new semantics;
* use mutable global `builder->ignorecase/multiline` as semantic state.

---

### TASK-11 — Remove Ruby semantic payloads from production GIR compilation

**Agent:** **Sol**
**Issues:** A-01, P-11, C-08
**Dependencies:** TASK-10

**Goal**

`onibi_compile_node` takes typed IDs/pointers, not `VALUE`.

**Acceptance**

Production compiler does not call:

```text
rb_hash_new
rb_hash_aset
rb_ary_new
rb_str_new
```

for semantic IR construction, except explicit diagnostics/error-message paths.

---

### TASK-12 — Replace generic Ruby value maps with typed compiler indexes

**Agent:** **Luna**
**Issues:** P-11, P-12
**Dependencies:** TASK-10

**Implement**

* capture-index vector;
* name → ordered capture-definition list;
* subprogram-name → subprogram ID;
* active recursion set;
* avoid arbitrary `rb_intern2`.

**Acceptance**

Large capture/name corpora show approximately linear expected compile behavior.

---

### TASK-13 — Make tagged ε-NFA the actual lowering output

**Agent:** **Sol**
**Issues:** A-04, P-09
**Dependencies:** TASK-10, TASK-11

**Goal**

Semantic lowering outputs `OnibiTaggedNfa` directly.

**Acceptance**

Unit tests can inspect an internal pre-elimination NFA and observe real ε transitions for zero-width structure.

---

### TASK-14 — Implement deterministic ordered ε-elimination

**Agent:** **Sol**
**Issues:** A-04, P-09
**Dependencies:** TASK-13

**Requirements**

* preserve edge priority;
* concatenate actions in semantic order;
* detect/normalize nullable cycles without rejecting valid Ruby patterns;
* use source-indexed adjacency;
* avoid repeated O(E) whole-graph scans.

---

### TASK-15 — Compiler resource owner / exception safety

**Agent:** **Luna**
**Issues:** M-01, M-04
**Dependencies:** TASK-10

**Goal**

One scoped compiler owner controls every temporary arena/vector/map.

**Acceptance**

Injected exceptions at each pass leave no C-owned allocations or TLS state behind.

---

## Phase 2 — Make GIR/RSeq a complete verified semantic program

### TASK-20 — Full GIR verifier

**Agent:** **Sol**
**Issues:** R-03, R-04
**Dependencies:** TASK-14

**Verifier inputs**

Only typed C GIR.

**Acceptance**

Each invariant has a negative unit test.

No executor or RSeq lowerer needs to rediscover GIR semantic validity.

---

### TASK-21 — Redesign action operands

**Agent:** **Sol**
**Issues:** R-04, A-08
**Dependencies:** TASK-20

Decide explicitly between:

1. formal 16-bit semantic limits, or
2. widened physical operands.

The choice must be documented in RSeq v1.

---

### TASK-22 — Encoding-aware class descriptors

**Agent:** **Sol**
**Issues:** R-07, E-01, E-02, E-05
**Dependencies:** TASK-10, TASK-20

**Required descriptor families**

```text
ASCII_BITMAP
CODEPOINT_RANGE_SET
ENCODING_CTYPE
MIXED
```

**Acceptance**

`\p{Lower}`, `\p{Alpha}`, `\p{Word}`, POSIX classes, negation and intersections match MRI across the supported encoding matrix.

---

### TASK-23 — Complete subprogram/assertion representation in RSeq

**Agent:** **Sol**
**Issues:** R-01, A-03
**Dependencies:** TASK-20

Represent complete executable semantics for:

* lookahead;
* lookbehind;
* call;
* atomic;
* absence;
* grapheme if enabled.

**Acceptance**

No executor needs AST or compile-time Ruby objects.

---

### TASK-24 — Strengthen physical RSeq verifier

**Agent:** **Luna**
**Issues:** R-02
**Dependencies:** TASK-21, TASK-22, TASK-23

Validate:

* sections/alignment;
* action termination;
* every operand range;
* descriptor ranges;
* subprogram ranges/flags;
* semantic feature consistency;
* execution class consistency.

---

### TASK-25 — Linearize RSeq serialization

**Agent:** **Luna**
**Issues:** P-05, P-06, P-07, P-08
**Dependencies:** TASK-24

**Implement**

* running literal offsets;
* hash-consed descriptors;
* hash-consed action programs;
* adjacency-based prefix extraction.

**Acceptance**

RSeq lowering has expected O(states + edges + payload bytes) behavior aside from explicit hash costs.

---

## Phase 3 — Implement the actual three executors

### TASK-30 — Shared transactional semantic-state API

**Agent:** **Sol**
**Issues:** A-07, A-08, P-03
**Dependencies:** TASK-21, TASK-23

**Define**

```text
SemanticState
  reported_start
  semantic_capture_file
  repeat_counter_file
  progress_state
  call_stack
  atomic/absence state
  capture tag history
```

and:

```text
apply_action_program(old_state, action_program, position)
    -> FAIL | new_state
```

**Must not**

write semantic effects into global/TLS execution state.

---

### TASK-31 — Real TAGGED_ORDERED interpreter

**Agent:** **Sol**
**Issues:** A-05, A-09
**Dependencies:** TASK-30

**Algorithm**

Ordered frontier with:

* state membership;
* semantic thread payload;
* deterministic priority;
* accept fallback;
* capture history;
* counters/progress;
* assertion actions.

**Explicit prohibition**

No DFS stack.

**Acceptance**

Existing “tagged increments dfs” test must be changed to require:

```text
tagged == 1
dfs == 0
fallback == 0
```

for supported tagged constructs.

---

### TASK-32 — Real DYNAMIC interpreter

**Agent:** **Sol**
**Issues:** A-06, A-07, P-02, P-03
**Dependencies:** TASK-30

Implement explicit semantic call/choice machinery supporting:

* backreferences;
* recursive/subexpression calls;
* atomic groups;
* absence;
* conditionals;
* dynamic assertions.

**Dedup**

Must key on future-observable semantic state, not `(state,pos)` alone.

---

### TASK-33 — Execution arenas and reusable buffers

**Agent:** **Luna**
**Issues:** P-02, A-09
**Dependencies:** TASK-31, TASK-32

Move large runtime data from `alloca` to `OnibiExecCtx` sidecars.

Reuse memory between candidate starts.

---

### TASK-34 — Work-budget timeout/interrupt polling

**Agent:** **Luna**
**Issues:** P-01
**Dependencies:** TASK-31, TASK-32

Implement one common polling mechanism used by all interpreters.

**Test**

A single anchored/greedy candidate over a very large input must remain interruptible and respect timeout without requiring the executor to return to the outer search loop.

---

## Phase 4 — Correct Ruby API boundaries

### TASK-40 — Centralize byte ↔ character position conversion

**Agent:** **Sol**
**Issues:** E-03, E-04
**Dependencies:** TASK-31

Introduce an explicit API adapter.

**Internal**

```text
OnigPosition == byte offset
```

**Ruby API**

Convert only at ingress/egress where Ruby semantics require character indices.

Replace inappropriate `rb_str_substr` usage with correct byte slicing or conversion.

---

### TASK-41 — Introduce `OnibiRawMatch`

**Agent:** **Sol**
**Issues:** API-02
**Dependencies:** TASK-30, TASK-40

Suggested shape:

```text
OnibiRawMatch
  matched
  begin_byte
  end_byte
  capture_byte_ranges[]
```

All executors produce the same object.

---

### TASK-42 — Stop re-running MRI for supported matches

**Agent:** **Sol**
**Issues:** API-01, API-02
**Dependencies:** TASK-41

First remove MRI from capture extraction for internally-supported matches.

Then progressively reduce retained MRI Regexp dependency.

MRI fallback can remain for explicitly unsupported syntax.

---

### TASK-43 — Typed fallback/error reasons

**Agent:** **Luna**
**Issues:** M-02, M-03
**Dependencies:** TASK-24, TASK-31, TASK-32

No generic `rb_protect` swallowing.

Diagnostics should report:

```text
unsupported_reason
compile_error_kind
executor_error_kind
fallback_reason
```

rather than only `fallback++`.

---

## Phase 5 — Performance architecture

### TASK-50 — Single execution-class classifier

**Agent:** **Sol**
**Issues:** API-03
**Dependencies:** TASK-20, TASK-31, TASK-32

`VerifiedGIRAnalysis` becomes authoritative.

Tokenizer features remain diagnostics only.

Runtime may assert header consistency but not re-decide semantics.

---

### TASK-51 — Search candidate iterator and metadata

**Agent:** **Sol**
**Issues:** P-04, P-05
**Dependencies:** TASK-22, TASK-50

Implement:

* character-aware candidate iteration;
* anchored search shortcuts;
* first-set bitmap;
* fixed prefix;
* safe literal skipping.

---

### TASK-52 — Parser delimiter indexing

**Agent:** **Luna**
**Issues:** P-10
**Dependencies:** none; can run parallel to Phase 1 if AST behavior remains unchanged

Record matching group/class delimiters in one pass.

Do not change syntax semantics in this task.

---

### TASK-53 — Module-interface cleanup

**Agent:** **Luna**
**Issues:** C-01..C-08
**Dependencies:** Phase 1/2 contracts stable

Create private headers and shrink `onibi_common.c`.

Preserve amalgamated `onibi.c` if it is still useful.

---

### TASK-54 — Vector invariant cleanup

**Agent:** **Luna**
**Issues:** C-03, C-04, C-05
**Dependencies:** none

* explicit allocator dependency;
* alias-safe or alias-forbidden append;
* reject invalid insert indices;
* document element ownership.

---

### TASK-55 — Ractor/shareability audit

**Agent:** **Sol**
**Issues:** RC-01, M-04
**Dependencies:** TASK-42, TASK-53

Verify the final immutable object graph and typed-data flags under actual Ractor sharing.

---

# 14. Recommended subagent execution graph

```text
TASK-00  Sol
   │
   ├── TASK-10  Sol
   │      ├── TASK-11  Sol
   │      ├── TASK-12  Luna
   │      ├── TASK-15  Luna
   │      └── TASK-13  Sol
   │             └── TASK-14 Sol
   │                    └── TASK-20 Sol
   │                          ├── TASK-21 Sol
   │                          ├── TASK-22 Sol
   │                          └── TASK-23 Sol
   │                                  │
   │                         TASK-24 Luna
   │                                  │
   │                         TASK-25 Luna
   │
   └──────────────────────── TASK-30 Sol
                               │
                         ┌─────┴─────┐
                         │           │
                   TASK-31 Sol  TASK-32 Sol
                         │           │
                         └─────┬─────┘
                               │
                         TASK-33 Luna
                         TASK-34 Luna
                               │
                         TASK-40 Sol
                               │
                         TASK-41 Sol
                               │
                         TASK-42 Sol
                               │
                         TASK-43 Luna
                               │
                         TASK-50 Sol
                               │
                         TASK-51 Sol
```

Parallel low-risk tracks:

```text
TASK-52 Luna  parser indexing
TASK-54 Luna  vector safety
```

`TASK-53` should wait until the semantic interfaces have stabilized; otherwise module splitting will create unnecessary churn.

---

# 15. Definition of Done for the GIR architecture

I would not consider the architecture described by `gir.md` substantially implemented until all of the following are true.

## Compiler

* No Ruby Hash/Array semantic IR in production passes.
* Inline options resolved before NFA/GIR lowering.
* Subprograms preserve definition-site lexical environment.
* Actual tagged ε-NFA exists.
* ε-elimination preserves deterministic priority.
* Large bounded repeats lower to counters.
* GIR verifier enforces complete semantic invariants.

## RSeq

* Single immutable relocatable blob is semantically complete.
* No AST/Ruby semantic object is needed at runtime.
* Class representation is encoding-aware.
* All action operands have formally checked ranges.
* Physical verifier validates every executor precondition.

## REGULAR

* ordered frontier;
* no DFS;
* captures via tag history;
* `match?` can avoid capture materialization;
* bounded polling.

## TAGGED

* independent ordered interpreter;
* no delegation to DYNAMIC;
* assertions/counters/progress supported;
* transactional semantic state;
* bounded polling.

## DYNAMIC

* explicit VM stack, not C semantic recursion;
* backrefs/calls/atomic/absence supported;
* semantic-state-aware dedup;
* COW/persistent registers instead of complete array copy;
* bounded polling.

## Ruby API

* byte offsets remain internal;
* Ruby position APIs use correct character semantics;
* `scan`/`gsub` slicing is correct for multibyte strings;
* RawMatch is generated by Onibi rather than repaired by re-running MRI.

## Robustness

* compiler errors cannot leak C arenas;
* OOM/internal verifier failures are not silently converted to fallback;
* explicit fallback reason exists;
* Ractor sharing contract tested.

## Performance

Record at least:

```text
compile_time
rseq_blob_bytes
states
edges
actions
class_descriptors
action_programs
max_frontier
tag_events
dynamic_frames
capture_state_bytes
counter_state_bytes
candidate_attempts
work_polls
MRI_fallback_count
```

and compare those between commits.

---

# 16. Priority order

If development capacity is limited, the recommended order is:

| Priority | Work                                                                             |
| -------- | -------------------------------------------------------------------------------- |
| **1**    | A-01/A-02/A-03 — canonical typed semantic compiler and lexical option resolution |
| **2**    | A-04 — real tagged ε-NFA                                                         |
| **3**    | R-03/R-02/R-04 — strong GIR/RSeq verification                                    |
| **4**    | E-01/E-03 — encoding and byte/character correctness                              |
| **5**    | A-08 — transactional semantic-state model                                        |
| **6**    | A-05 — true TAGGED executor                                                      |
| **7**    | A-06/A-07 — true DYNAMIC executor                                                |
| **8**    | P-01 — bounded interrupt/timeout polling                                         |
| **9**    | API-02 — RawMatch and removal of MRI re-execution                                |
| **10**   | serialization/search/compiler performance work                                   |
| **11**   | module/readability cleanup                                                       |

This ordering is important.

Implementing DYNAMIC before fixing semantic state, or enabling Unicode execution before fixing the class representation, is likely to create apparently-working code that has subtle MRI incompatibilities.

---

# 17. Overall review conclusion

The current `GIR` branch should be viewed as:

> **a prototype containing several important pieces of the target architecture, but not yet an implementation of the architecture described by `gir.md`.**

The strongest existing pieces are:

* compact immutable RSeq direction;
* clear physical state/edge/action structures;
* explicit execution-class concept;
* ordered regular frontier;
* capture tag-history direction;
* good diagnostic hooks;
* extensive differential/feature test organization;
* deliberate nesting limit;
* explicit compatibility fallback boundary.

The weakest point is not an individual function. It is the **semantic ownership boundary**.

At present, semantics are distributed among:

```text
tokens
AST
mutable compiler flags
Ruby Hash payloads
GIR vectors
token feature bits
VerifiedGIRAnalysis
RSeq fields
runtime regular_capable scanning
MRI fallback regexp
```

That distribution is the underlying cause of many of the visible problems.

The architectural correction should therefore be:

```text
                 ┌──────────────────────────┐
source → tokens →│ resolved semantic C AST │
                 └────────────┬─────────────┘
                              │
                     tagged epsilon-NFA
                              │
                     ordered elimination
                              │
                        verified GIR
                              │
                    classify exactly once
                              │
                        optimize GIR
                              │
                        verified RSeq
                              │
              ┌───────────────┼───────────────┐
              │               │               │
          REGULAR          TAGGED          DYNAMIC
              │               │               │
              └───────────────┼───────────────┘
                              │
                         RawMatch
                              │
                       Ruby API adapter
```

Once that ownership model is true in the code—not just represented by comments and pass names—the remaining performance work becomes considerably safer and easier to reason about.

The key instruction to every implementation subagent should be:

> **Do not preserve an existing implementation detail merely because current tests depend on its fallback behavior. Preserve MRI semantics and the invariants in `gir.md`. When an existing test encodes an interim fallback, replace that expectation only after the corresponding semantic implementation and differential tests exist.**
