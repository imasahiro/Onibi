# Onibi Design Document

**A Glushkov-based regular expression engine for MRI Ruby**

| Field | Value |
| --- | --- |
| Status | Active design specification |
| PoC target | MRI-only Ruby gem |
| Integration target | MRI mainline |
| PoC implementation language | C |
| Later JIT backend | ZJIT |
| Later integration languages | C and Rust |
| Document language | English |

---

## 1. Purpose

Onibi is a new regular expression engine for MRI Ruby.

The first proof of concept is a Ruby gem with a C extension.

The gem provides `Onibi::Regexp` under the `Onibi` namespace.

This class follows MRI `Regexp` behavior for each supported feature.

The PoC does not replace the built-in MRI `Regexp` class.

Onibi replaces the current backtracking execution model with a prioritized Glushkov NFA execution model.

Onibi must preserve Ruby regular expression behavior.

Onibi must support the complete Ruby `Regexp` feature set.

Onibi must support non-regular Ruby features such as:

- backreferences;
- named backreferences;
- subexpression calls;
- recursive subexpression calls;
- recursion-level backreferences;
- atomic groups;
- possessive quantifiers;
- lookahead;
- lookbehind;
- conditional groups;
- the absence operator;
- `\K`;
- `\G`.

Onibi must not require a separate architecture-specific JIT compiler.

The PoC must implement all three execution interpreters in C.

The PoC does not include native-code generation.

After the PoC, MRI integration must use the ZJIT low-level backend to generate native code.

MRI integration must use the ZJIT register allocator, machine-code emitters, executable-memory support, and C-call support.

MRI integration must not lower its automaton to YARV instructions before native code generation.

## 1.1 Delivery stages

Onibi has two delivery stages.

The gem PoC validates the C compiler, RSeq, three C interpreters, and namespaced API.

The PoC supports MRI only and can add `Regexp` features in small groups.

The complete existing test suite is not an initial PoC gate.

MRI integration starts after the PoC proves the execution design.

That stage connects RSeq to ZJIT and applies the complete MRI acceptance criteria.

---

# 2. Normative Language

The following words have a specific meaning in this document.

**MUST** specifies a required behavior.

**MUST NOT** specifies a prohibited behavior.

**SHOULD** specifies the preferred behavior.

**MAY** specifies an optional optimization.

An implementation that does not satisfy a MUST requirement does not conform to this design.

Requirements that name ZJIT or MRI integration apply after the gem PoC.

---

# 3. Compatibility Baseline

The compatibility target is MRI `master` behavior as of 2026-08-27.

The initial gem build target is MRI 4.0.6.

JRuby, TruffleRuby, and mruby are outside the project scope.

The following MRI files are primary compatibility references:

```text
doc/_regexp.rdoc
re.c
regint.h
regparse.c
regcomp.c
regexec.c
regenc.c
enc/unicode.c
include/ruby/onigmo.h
include/ruby/re.h
internal/re.h
include/ruby/internal/core/rregexp.h
include/ruby/internal/core/rmatch.h
insns.def
vm_insnhelper.c
zjit/src/backend/lir.rs
zjit/src/codegen.rs
zjit/src/asm/
zjit/src/virtualmem.rs
```

Ruby-level behavior is normative.

The current Onigmo implementation is the reference implementation during development.

When this document and Onigmo internal behavior differ, Ruby-visible behavior has priority.

---

# 4. Main Design Goals

Onibi has the following goals.

1. Regular patterns must not use a backtracking stack.
2. Regular patterns must have predictable execution cost.
3. Ruby match priority must remain compatible with MRI.
4. Ruby capture results must remain compatible with MRI.
5. Non-regular features must remain available.
6. The common regular path must use compact immutable data.
7. `Regexp#match?` must avoid capture materialization when captures do not affect matching.
8. The engine must support all MRI string encodings.
9. The engine must preserve byte-offset results.
10. The engine must support `Regexp.timeout`.
11. The engine must poll MRI interrupts.
12. The engine must integrate with `RRegexp` and `MatchData`.
13. The engine must support Ractor-safe immutable compiled programs.
14. All three interpreters and later native code must use the same semantic program.
15. Native code generation must use ZJIT.
16. Onibi must not contain x86-64 or AArch64 instruction encoders.
17. Onibi must not require YARV instruction expansion for each regexp state.

---

# 5. Non-Goals

Onibi does not define a new Ruby regexp syntax.

Onibi does not change Ruby regexp match priority.

Onibi does not change Ruby encoding rules.

Onibi does not change `MatchData`.

Onibi does not change `$~`, `$1`, `$&`, or related Ruby behavior.

Onibi does not make backreferences regular.

Onibi does not guarantee linear execution time for patterns with non-regular features.

Onibi does not expose its internal ISA as a public Ruby API.

Onibi does not provide a portable implementation for non-MRI Ruby runtimes.

RSeq is an internal Onibi format.

The gem must not expose or persist RSeq as a public format.

After integration, RSeq becomes an MRI internal format.

MRI must not persist RSeq or native Onibi code in Marshal data.

---

# 6. High-Level Architecture

Onibi uses the following pipeline.

```text
Regexp source
    |
    v
Onibi C parser
or later MRI parser adapter
    |
    v
Onibi AST
    |
    v
Tagged epsilon NFA
    |
    v
epsilon elimination
    |
    v
G-IR
Prioritized Glushkov IR
    |
    v
RSeq lowering
    |
    v
RSeq
    |
    v
execution-class dispatcher
    |
    +--> REGULAR_FAST C interpreter
    |
    +--> TAGGED_ORDERED C interpreter
    |
    +--> DYNAMIC C interpreter

After the gem PoC:

RSeq -> native-code threshold -> RegCodePlan -> RegMacroAssembler
     -> ZJIT LIR -> ZJIT register allocator
     -> ZJIT machine assembler -> native code
```

The compiler must discard temporary epsilon-NFA data after RSeq generation.

The normal runtime does not require G-IR.

The JIT compiler must be able to reconstruct its execution plan from RSeq.

This requirement permits lazy JIT compilation.

---

# 7. Three Representation Levels

Onibi defines three main representation levels.

## 7.1 Onibi AST

The AST represents Ruby regexp syntax.

The AST is not an execution format.

The AST contains constructs such as:

```text
Literal
Sequence
Alternative
Quantifier
CharacterClass
Capture
Backreference
Anchor
Lookahead
Lookbehind
Atomic
Call
Conditional
Absent
OptionScope
```

Inline options must be resolved before G-IR generation.

---

## 7.2 G-IR

G-IR is the canonical semantic representation.

G-IR represents a prioritized tagged Glushkov automaton.

G-IR is mostly epsilon-free.

A G-IR consuming state represents a position in the regexp.

Control flow is represented by graph edges.

G-IR does not contain general-purpose instructions such as:

```text
PUSH
POP
JUMP
SPLIT
BACKTRACK
```

Alternation is represented by multiple ordered edges.

Repetition is represented by graph cycles.

Greedy and lazy behavior is represented by edge order.

Capture operations are represented by edge actions.

Assertions are represented by edge predicates.

---

## 7.3 RSeq

RSeq is the compact runtime format.

The selected C interpreter executes RSeq.

The PoC contains separate C interpreters for `REGULAR_FAST`, `TAGGED_ORDERED`, and `DYNAMIC`.

The ZJIT Onibi backend also compiles RSeq.

RSeq can contain optimized operations that do not exist in canonical G-IR.

Examples are:

```text
STRING
RUN_CLASS
RUN_ANY
```

G-IR is semantic.

RSeq is operational.

---

# 8. Execution Classes

The compiler assigns one execution class to each program.

```c
enum OnibiExecKind {
    ONIBI_EXEC_REGULAR_FAST,
    ONIBI_EXEC_TAGGED_ORDERED,
    ONIBI_EXEC_DYNAMIC
};
```

Each execution class has a separate C interpreter.

The interpreters share RSeq structures, predicates, and raw match results.

The dispatcher selects exactly one interpreter for each compiled program.

---

## 8.1 REGULAR_FAST

Use `REGULAR_FAST` when matching does not require semantic capture state.

Typical patterns are:

```regex
/[a-z]+/
/foo|bar/
/\A\d{4}-\d{2}-\d{2}\z/
```

Output captures can still exist.

If captures are output-only, the engine can use tag history without capture-dependent state identity.

`Regexp#match?` can use a simpler unordered existence algorithm when the regexp is fully regular.

---

## 8.2 TAGGED_ORDERED

Use `TAGGED_ORDERED` when the engine needs:

- ordered threads;
- capture history;
- large bounded-repeat counters;
- regular lookaround state;
- other regular side effects.

This class still has no non-regular substring comparison.

---

## 8.3 DYNAMIC

Use `DYNAMIC` when future matching behavior depends on runtime semantic state.

Features that force this class include:

```text
backreference
recursion-level backreference
subexpression call
recursive subexpression call
capture-dependent condition
atomic subprogram
absence operator
\X when it uses a variable-length runtime consumer
```

The compiler MAY classify a feature into a lower class if it can prove an equivalent regular representation.

---

# 9. Input Position Model

All externally visible positions are byte offsets.

Use `OnigPosition` for subject byte offsets.

Do not use `uint32_t` for subject offsets.

A Ruby String can be larger than 4 GiB on a 64-bit system.

The execution context must distinguish these positions:

```text
subject_start
subject_end
search_origin
attempt_start
reported_start
current_position
```

`attempt_start` is the position where the current search attempt started.

`reported_start` is the beginning of group 0.

At the start of an attempt:

```text
reported_start = attempt_start
```

`\K` changes `reported_start`.

`\K` must not change `attempt_start`.

`\G` compares the current position with `search_origin`.

`\G` must not compare with `reported_start`.

---

# 10. Character Model

Onibi must use the MRI encoding infrastructure.

A G-IR character position consumes one encoded character unless its state type explicitly specifies a different rule.

A character position is not the same as one byte.

For UTF-8, one character can consume one to four bytes.

For Windows-31J, one character can consume one or two bytes.

For ASCII-8BIT, one character consumes one byte.

Onibi must use the existing encoding callbacks for:

- character decode;
- character length;
- previous character;
- character type;
- word classification;
- newline classification;
- case folding;
- encoding compatibility.

Onibi must not implement an independent Unicode case-fold database.

The existing MRI/Onigmo encoding tables remain the source of truth.

---

# 11. G-IR State Types

The canonical state types are:

```c
enum OnibiGStateOp {
    G_ACCEPT = 0,

    G_CHAR,
    G_CLASS,
    G_ANY,

    G_GRAPHEME,

    G_BACKREF,
    G_CALL,
    G_ATOMIC,
    G_ABSENT
};
```

---

## 11.1 G_CHAR

`G_CHAR` consumes one exact encoded character.

It contains a reference to an immutable literal descriptor.

Case-sensitive literal positions should normally use `G_CHAR`.

---

## 11.2 G_CLASS

`G_CLASS` consumes one character that belongs to a character class.

It is used for:

- `[abc]`;
- ranges;
- intersected classes;
- Unicode properties;
- POSIX classes;
- one-to-one case-fold sets.

---

## 11.3 G_ANY

`G_ANY` consumes one character.

Its flags specify newline behavior.

The `m` regexp option must be resolved before execution.

---

## 11.4 G_GRAPHEME

`G_GRAPHEME` implements `\X`.

It can consume more than one encoding character.

It forces an execution strategy that supports variable-width transitions unless the compiler expands it into a fixed regular graph.

---

## 11.5 G_BACKREF

`G_BACKREF` compares subject input with one or more previously captured substrings.

It can consume a variable number of bytes.

It is a dynamic state.

---

## 11.6 G_CALL

`G_CALL` invokes a regexp subprogram.

It implements `\g<name>`, numeric calls, relative calls, and recursion.

---

## 11.7 G_ATOMIC

`G_ATOMIC` executes a subprogram and commits to its first successful internal result.

It implements atomic grouping.

Possessive quantifiers lower to this semantic operation when they cannot use a simpler specialized form.

---

## 11.8 G_ABSENT

`G_ABSENT` implements the Ruby absence operator.

The absence operator must have a dedicated semantic implementation.

It must not be implemented as a simple negative lookahead.

---

# 12. G-IR Edges

A G-IR edge has this semantic form:

```c
struct OnibiGEdge {
    OnibiStateId destination;
    OnibiActionProgramId actions;
};
```

Edges are stored in priority order.

The first edge has the highest priority.

There is no separate numeric priority requirement in RSeq.

Array order defines priority.

This rule removes one field from the physical edge format.

---

# 13. Priority Rules

Onibi must implement the same preference order as MRI.

The following rules are required.

## 13.1 Alternation

For:

```regex
a|b
```

the `a` branch has higher priority.

---

## 13.2 Greedy Quantifier

For:

```regex
a*
```

the repeat edge has higher priority than the exit edge.

---

## 13.3 Lazy Quantifier

For:

```regex
a*?
```

the exit edge has higher priority than the repeat edge.

---

## 13.4 Possessive Quantifier

For:

```regex
a*+
```

the engine must not return to a previous repetition choice after the possessive region succeeds.

---

## 13.5 Search Position

For a forward search, an earlier `attempt_start` always has higher priority.

A later starting position must never replace a successful match from an earlier starting position.

For a reverse search, the search candidate order is reversed.

The internal regexp match direction remains forward.

---

# 14. Reference Priority Semantics

The semantic reference is depth-first backtracking order.

The implementation does not use a backtracking stack for regular matching.

However, its result must equal the result of this conceptual process:

1. Try the earliest permitted search start.
2. At each alternation, try the left branch first.
3. At each greedy quantifier, try repetition first.
4. At each lazy quantifier, try exit first.
5. Restore capture state when a conceptual branch fails.
6. Return the first complete match.

The optimized executor must be observationally equal to this reference.

---

# 15. Ordered Frontier Algorithm

For regular one-character states, the production executor uses an ordered frontier.

Each frontier contains state entries in priority order.

A membership bitset prevents duplicate state insertion.

When two paths reach the same state at the same input position, the first path wins if future behavior does not depend on different semantic state.

The executor must process current entries from first to last.

The executor must process outgoing edges from first to last.

This order reproduces the backtracking preference without a backtracking stack.

---

## 15.1 Accept Fallback

An accept result can occur while a higher-priority path is still alive.

A greedy quantifier is a common case.

Therefore, the engine must not always return immediately when it finds an accept edge.

The executor maintains one current fallback match.

Conceptual algorithm:

```c
fallback = NONE;

while (true) {
    next.clear();

    for (entry in current_priority_order) {
        if (entry.is_accept) {
            if (next.empty()) {
                return entry.match;
            }

            fallback = entry.match;

            /* Lower-priority entries cannot win. */
            break;
        }

        if (entry.matches(current_input)) {
            emit_successors_in_priority_order(entry, next);
        }
    }

    if (next.empty()) {
        if (fallback.exists) {
            return fallback;
        }

        if (!inject_next_search_start()) {
            return NO_MATCH;
        }
    }

    current = next;
}
```

The real implementation must also handle end-of-input actions and assertions.

---

# 16. State Deduplication

Deduplication depends on execution class.

---

## 16.1 REGULAR_FAST

The equivalence key is:

```text
state_id
```

The earlier thread wins.

---

## 16.2 TAGGED_ORDERED

If captures are output-only, the equivalence key is also:

```text
state_id
```

The earlier tag history wins.

---

## 16.3 DYNAMIC

The key contains all state that can change future matching.

The compiler must calculate the required live semantic state.

The conceptual key is:

```text
state_id
live semantic capture values
live counter values
call continuation state
other dynamic state required by the destination
```

The implementation must not include output-only captures in the dynamic key.

---

# 17. Capture Classification

The compiler classifies each capture group.

```c
enum OnibiCaptureUse {
    CAPTURE_OUTPUT_ONLY,
    CAPTURE_BACKREF_READ,
    CAPTURE_CONDITION_READ,
    CAPTURE_RECURSION_READ
};
```

A capture can have more than one flag.

A capture with only `CAPTURE_OUTPUT_ONLY` does not affect future matching.

`Regexp#match?` does not need to materialize output-only captures.

A capture that a backreference reads is semantic state.

A condition that tests a capture also makes that capture semantic state.

---

# 18. Capture Representation

Onibi uses two capture representations.

---

## 18.1 Tag History

Output capture changes use an append-only tag history.

```c
struct OnibiTagEvent {
    OnibiTagEventId parent;
    uint32_t slot;
    OnigPosition position;
};
```

Each capture has two slots:

```text
2 * capture_id     = begin
2 * capture_id + 1 = end
```

A capture update appends one tag event.

Threads share earlier history.

The engine does not copy the complete capture array at every branch.

At final match materialization, the engine walks the tag history backwards.

The first value found for each slot is the final value.

Unset slots become `ONIG_REGION_NOTPOS`.

---

## 18.2 Semantic Capture Registers

Dynamic patterns require fast capture lookup.

The compiler maps only semantic captures into a dense semantic register set.

For up to eight semantic captures, the thread stores values inline.

For more captures, use a copy-on-write register block.

Backreference lookup must be O(1) after capture-number resolution.

Capture changes must update:

1. tag history;
2. semantic registers, if the capture is semantic.

---

# 19. Group 0

Group 0 is special.

Do not store its normal beginning in tag history.

Use:

```text
reported_start
current_match_end
```

`\K` updates `reported_start`.

A successful match writes:

```text
beg[0] = reported_start
end[0] = accepted_position
```

---

# 20. Edge Action Programs

Zero-width behavior is attached to edges.

An action program runs after the source state consumes input and before the destination state becomes active.

Initial edges can run actions before the first consuming state.

Action execution is transactional.

If one predicate in an action program fails, the engine discards all modifications from that action program.

---

# 21. Semantic Action Operations

G-IR supports these semantic actions.

```text
CAPTURE_OPEN
CAPTURE_CLOSE
MATCH_RESET

ASSERT_BEGIN_BUFFER
ASSERT_END_BUFFER
ASSERT_SEMI_END_BUFFER
ASSERT_BEGIN_LINE
ASSERT_END_LINE
ASSERT_WORD_BOUNDARY
ASSERT_NOT_WORD_BOUNDARY
ASSERT_WORD_BEGIN
ASSERT_WORD_END
ASSERT_SEARCH_ORIGIN

ASSERT_LOOKAHEAD_POSITIVE
ASSERT_LOOKAHEAD_NEGATIVE
ASSERT_LOOKBEHIND_POSITIVE
ASSERT_LOOKBEHIND_NEGATIVE

TEST_CAPTURE_SET
TEST_CAPTURE_UNSET

COUNTER_INIT
COUNTER_INCREMENT
TEST_COUNTER_LT
TEST_COUNTER_GE

PROGRESS_SAVE
TEST_PROGRESS
```

Inline regexp options are not runtime actions.

The compiler resolves them before G-IR generation.

---

# 22. Physical RSeq Action ISA

RSeq uses a compact action instruction.

```c
struct OnibiRAction {
    uint8_t op;
    uint8_t flags;
    uint16_t arg16;
    uint32_t arg32;
};
```

Size:

```text
8 bytes
```

The RSeq action operations are:

```c
enum OnibiRActionOp {
    RA_END = 0,

    RA_CAPTURE,
    RA_MATCH_RESET,

    RA_ASSERT_POSITION,
    RA_ASSERT_SUBPROGRAM,

    RA_TEST_CAPTURE,

    RA_COUNTER_SET,
    RA_COUNTER_ADD,
    RA_COUNTER_TEST,

    RA_PROGRESS
};
```

`RA_CAPTURE.flags` selects open or close.

`RA_ASSERT_POSITION.arg16` selects the position predicate.

`RA_ASSERT_SUBPROGRAM.flags` selects:

```text
positive
negative
forward
backward
```

`RA_TEST_CAPTURE.flags` selects set or unset.

This compression reduces RSeq size without changing G-IR semantics.

---

# 23. Nullable Patterns

The start descriptor must support an immediate accept path.

The RSeq header contains an ordered start-edge list.

A start edge can point to:

- a consuming state;
- `ACCEPT`.

A start edge can also contain an action program.

This mechanism supports patterns such as:

```regex
/a*/
/(?:)/
/(?<x>a?)b/
```

The executor must apply start-edge actions with the same transactional rules as other edge actions.

---

# 24. Tagged Epsilon-NFA Construction

The compiler first builds a temporary tagged epsilon NFA.

This representation makes zero-width semantic ordering explicit.

Example:

```regex
(?<x>a?)b
```

Conceptual temporary representation:

```text
CAP_OPEN x
    |
optional a
    |
CAP_CLOSE x
    |
b
```

The epsilon NFA is not an execution format.

---

# 25. Epsilon Elimination

The compiler eliminates epsilon transitions before G-IR finalization.

For each consuming position, the compiler calculates an ordered epsilon closure.

The closure produces:

```text
destination consuming state
ordered action sequence
```

If two epsilon paths reach the same destination with different action sequences, both edges must remain.

If two edges have:

```text
same destination
same action program
```

the compiler keeps only the first edge.

The compiler must preserve edge priority.

The compiler must normalize nullable repetition before epsilon elimination.

The closure algorithm must detect epsilon cycles.

---

# 26. Alternation Lowering

For:

```regex
a|b
```

the start edges are:

```text
START -> a
START -> b
```

in that order.

No `SPLIT` operation exists.

---

# 27. Repetition Lowering

For:

```regex
a*
```

the graph contains:

```text
START -> ACCEPT
START -> a

a -> a
a -> ACCEPT
```

For a greedy quantifier, `a -> a` has higher priority.

For a lazy quantifier, `a -> ACCEPT` has higher priority.

---

# 28. Bounded Repetition

Large bounded repetition must not create one state for every repetition.

The compiler uses this constant:

```c
#define ONIBI_REPEAT_UNROLL_MAX 8
```

If a finite upper bound is not greater than 8, the compiler MAY fully unroll the repetition.

Otherwise, the compiler uses a counter.

A repeat descriptor contains:

```c
struct OnibiRepeatDesc {
    uint32_t counter_id;
    uint32_t min;
    uint32_t max;
    uint8_t greedy;
    uint8_t nullable;
};
```

`UINT32_MAX` represents an unbounded maximum.

A counter is thread semantic state.

A large counted repeat therefore uses the ordered thread executor unless an RSeq optimization removes the counter.

---

# 29. Nullable Repetition

Patterns such as:

```regex
(?:a?)*
```

can execute an iteration without input progress.

Onibi must prevent an infinite zero-progress cycle.

For every nullable repeated body, the compiler assigns a progress slot.

The runtime stores the input position at iteration entry.

If an iteration completes at the same input position, the engine must not begin another identical zero-progress iteration.

The exit path remains available according to normal priority.

This rule replaces Onigmo null-check bytecode.

---

# 30. Atomic Groups

For:

```regex
(?>expr)
```

the compiler creates an atomic subprogram.

The outer automaton contains:

```text
G_ATOMIC subprogram_id
```

The atomic state executes the subprogram from the current position.

The subprogram uses normal Ruby priority.

The atomic state returns only the first successful subprogram result.

It discards all other internal alternatives.

If later outer matching fails, the engine must not re-enter the atomic subprogram with another internal choice.

Successful capture changes inside the atomic subprogram propagate to the caller.

---

# 31. Possessive Quantifiers

A possessive quantifier has atomic semantics.

For example:

```regex
a*+
```

is semantically equivalent to an atomic greedy repetition.

The compiler SHOULD use a specialized RSeq run operation when the repeated body is a simple character predicate.

Otherwise, the compiler lowers the construct to `G_ATOMIC`.

---

# 32. Lookahead

Positive lookahead:

```regex
(?=expr)
```

runs a subprogram at the current position.

It does not change the outer input position.

If it succeeds, successful capture effects propagate according to current Ruby behavior.

Negative lookahead:

```regex
(?!expr)
```

succeeds only if the subprogram fails.

It never propagates subprogram capture changes.

---

# 33. Lookbehind

Positive and negative lookbehind use a subprogram plus a compile-time width set.

The compiler must validate Ruby lookbehind width rules.

The width set is measured in encoding characters, not bytes.

At runtime:

1. find the required previous character boundary;
2. execute the subprogram;
3. require its end position to equal the original current position.

A lookbehind with multiple valid top-level alternative widths stores all permitted widths in priority order.

The engine must use the existing encoding previous-character operation.

It must not decrement the byte pointer by an assumed character size.

---

# 34. Backreferences

A backreference state contains a resolved backreference descriptor.

```c
struct OnibiBackrefDesc {
    uint32_t capture_list_off;
    uint16_t capture_count;
    int16_t recursion_level;
    uint16_t flags;
};
```

Flags include:

```text
IGNORE_CASE
NAMED
RELATIVE
WITH_LEVEL
```

The parser must resolve names to capture-number lists.

The compiler must preserve the current MRI resolution order for duplicate names.

The runtime must not perform a name-table lookup on each match.

A backreference compares the captured subject bytes with the current subject.

Case-insensitive backreferences must use MRI encoding case-fold behavior.

A backreference can consume zero bytes when the captured substring is empty.

The Dynamic executor must apply zero-progress protection when this creates a cycle.

---

# 35. Subexpression Calls

A subexpression call uses an explicit Onibi call stack.

It must not use a YARV frame.

It must not use the C recursion stack as its semantic call stack.

A frame has this conceptual form:

```c
struct OnibiCallFrame {
    uint32_t subprogram_id;
    OnibiStateId continuation;
    OnibiTagEventId tag_history;
    uint32_t recursion_depth;
    OnibiCallFrameId parent;
};
```

A call state pushes a frame and enters the target subprogram.

A subprogram accept returns to the continuation in the top frame.

`\g<0>` can call the complete regexp.

Recursive calls therefore work without native C recursion.

The compiler must preserve lexical regexp options of the called group.

Caller option state must not replace callee option state.

---

# 36. Capture-Dependent Conditions

A conditional such as:

```regex
(?(1)yes|no)
```

becomes two ordered guarded edges.

```text
source
  |
  +-- [capture 1 is set]   --> yes
  |
  +-- [capture 1 is unset] --> no
```

There is no `COND_JUMP` G-IR instruction.

The tested capture becomes semantic capture state.

---

# 37. Absence Operator

The absence operator has a dedicated dynamic subprogram state.

Example:

```regex
(?~expr)
```

The implementation must reproduce current MRI behavior for:

- an empty forbidden expression;
- a forbidden expression at the current position;
- a forbidden expression after one or more consumed characters;
- captures inside the forbidden expression;
- nested absence operators;
- lookaround inside the forbidden expression;
- alternation inside the forbidden expression;
- empty matches inside the forbidden expression.

The implementation must not approximate the operator as:

```regex
(?:(?!expr).)*
```

unless the compiler proves semantic equivalence.

During development, all absence-operator tests must compare directly with the current Onigmo executor.

---

# 38. `\K`

`\K` lowers to:

```text
MATCH_RESET
```

The action performs:

```c
thread.reported_start = current_position;
```

It must not change:

```text
attempt_start
search_origin
previous capture ranges
```

---

# 39. `\G`

`\G` lowers to:

```text
ASSERT_SEARCH_ORIGIN
```

The condition is:

```c
current_position == ctx->search_origin
```

It must not compare with the current candidate `attempt_start`.

This distinction is required for search APIs and iterative methods.

---

# 40. `\R`

`\R` SHOULD lower to a normal regular graph.

CRLF must be tested before a single CR alternative.

This requirement preserves the expected two-byte CRLF match.

No dedicated runtime state is required.

---

# 41. `\X`

`\X` uses a dedicated grapheme consumer unless the compiler has a compact regular expansion.

The grapheme implementation must use the Unicode data already used by MRI.

It must return the exact next grapheme boundary.

It must not allocate a Ruby object.

---

# 42. Character Classes

Character class parsing happens before G-IR construction.

The compiler must normalize:

- class union;
- class intersection;
- negation;
- ranges;
- POSIX classes;
- shorthand classes;
- Unicode properties.

RSeq stores immutable class descriptors.

A class descriptor uses this header:

```c
struct OnibiClassDesc {
    uint32_t data_offset;
    uint16_t data_length;
    uint8_t kind;
    uint8_t flags;
};
```

Possible kinds are:

```text
ASCII_BITMAP
CODEPOINT_RANGES
ENCODING_CTYPE
MIXED
```

The compiler must deduplicate identical class descriptors.

---

# 43. Case Folding

Case folding occurs before Glushkov construction.

The executor must not implement a generic `tolower()` comparison.

The compiler uses the MRI encoding case-fold interface.

---

## 43.1 One-to-One Fold

For:

```regex
/a/i
```

the compiler creates a character class that contains all one-character equivalents.

Conceptually:

```text
CLASS { a, A }
```

One Glushkov position is sufficient.

---

## 43.2 One-to-Many Fold

For a fold such as:

```text
one codepoint <-> two codepoints
```

the compiler creates alternative paths.

Conceptual example:

```text
        +-- CLASS one-codepoint --------+
START --+                                +--> NEXT
        +-- CLASS first -> CLASS second -+
```

There is no runtime `FOLD_1_TO_2` instruction.

---

## 43.3 Many-to-One Fold

The compiler must examine more than one pattern character.

It must not fold each literal character independently.

For a two-character pattern run that has a one-character fold candidate, the compiler creates:

```text
        +-- first -> second --+
START --+                     +--> NEXT
        +-- folded-one -------+
```

---

## 43.4 Fold DAG

Ignore-case literal compilation uses a DAG over pattern offsets.

A node represents a pattern byte offset.

An edge contains:

```text
number of pattern bytes consumed
sequence of output codepoints
priority
```

The compiler asks the existing encoding case-fold table for all candidates.

The compiler places the original spelling first.

The compiler preserves the current MRI candidate order after the original spelling.

The compiler deduplicates equal output sequences.

Suffixes are shared.

This DAG avoids Cartesian expansion of independent fold alternatives.

The compiler then converts the DAG into the temporary tagged NFA.

---

# 44. Search Semantics

Onibi separates search from anchored matching.

The anchored matcher answers:

```text
Does the pattern match at this attempt_start?
```

The search layer selects candidate starts.

For forward search:

1. start at the requested byte position;
2. adjust to an encoding character boundary;
3. test candidates in increasing byte-offset order;
4. return the first preferred successful match.

The implementation MAY inject new starts into a single ordered NFA run.

If it does this, earlier starts must always remain before later starts.

After the engine records a fallback accept for an earlier start, it must not inject a lower-priority later start.

---

# 45. Reverse Search

MRI internal APIs support reverse search.

Onibi must support it.

The baseline implementation uses this algorithm:

1. enumerate candidate start positions in reverse character-boundary order;
2. run the normal forward matcher at each candidate;
3. return the first successful candidate.

A reverse prefilter MAY optimize candidate enumeration.

The regexp itself is not interpreted backwards.

---

# 46. Search Prefilters

RSeq contains optional search metadata.

The initial implementation must support:

```text
BEGIN_BUFFER anchored
BEGIN_POSITION anchored
first-character bitmap
required exact literal
exact prefix
```

A prefilter can reject candidate positions.

A prefilter must never select a different match.

A prefilter must never alter captures.

A prefilter must use byte operations only when the encoding permits them.

For ASCII-compatible strings with seven-bit content, byte search is permitted.

For other strings, candidate positions must remain valid character boundaries.

---

# 47. RSeq Header

RSeq is one relocatable memory blob.

All internal references use offsets or integer IDs.

RSeq must not contain a Ruby heap pointer.

RSeq must not contain a raw subject pointer.

Example header:

```c
struct OnibiRSeqHeader {
    uint32_t magic;
    uint16_t version;
    uint8_t exec_kind;
    uint8_t flags;

    uint32_t features;

    uint32_t state_count;
    uint32_t edge_count;
    uint32_t action_count;
    uint32_t class_count;
    uint32_t subprogram_count;
    uint32_t capture_count;
    uint32_t semantic_capture_count;
    uint32_t counter_count;

    uint32_t start_edge_base;
    uint32_t start_edge_count;

    uint32_t states_offset;
    uint32_t edges_offset;
    uint32_t actions_offset;
    uint32_t classes_offset;
    uint32_t literals_offset;
    uint32_t descriptors_offset;
    uint32_t subprograms_offset;

    uint32_t blob_size;
};
```

The initial RSeq version is:

```text
1
```

All sections must have four-byte alignment.

The blob must be smaller than 4 GiB.

The compiler must raise `RegexpError` if representation limits are exceeded.

---

# 48. RSeq State Format

```c
struct OnibiRState {
    uint32_t edge_base;
    uint32_t payload;
    uint16_t edge_count;
    uint8_t op;
    uint8_t flags;
};
```

Size:

```text
12 bytes
```

---

# 49. RSeq Edge Format

```c
struct OnibiREdge {
    uint32_t destination;
    uint32_t action_offset;
};
```

Size:

```text
8 bytes
```

Edges are stored in priority order.

`action_offset == 0` means no action program.

A reserved destination value represents ACCEPT:

```c
#define ONIBI_ACCEPT_STATE UINT32_MAX
```

---

# 50. RSeq State ISA

RSeq v1 defines these state operations.

```c
enum OnibiRStateOp {
    RS_CHAR = 1,
    RS_CLASS,
    RS_ANY,

    RS_GRAPHEME,

    RS_BACKREF,
    RS_CALL,
    RS_ATOMIC,
    RS_ABSENT,

    RS_STRING,
    RS_RUN_CLASS,
    RS_RUN_ANY
};
```

`RS_STRING`, `RS_RUN_CLASS`, and `RS_RUN_ANY` are lowering optimizations.

They are not canonical G-IR operations.

---

# 51. Safe RSeq Fusion

The compiler may fuse states only when fusion cannot change priority.

For `RS_STRING`, all fused states must satisfy these conditions:

```text
single semantic predecessor
single semantic successor
no branch boundary inside the run
no capture action inside the run
no assertion inside the run
no counter action inside the run
no accept alternative inside the run
```

If one condition is false, the compiler must keep separate states.

---

# 52. RSeq Size

For a simple unfused state:

```text
state: 12 bytes
edge:   8 bytes
```

A linear position therefore usually costs about 20 bytes before pool sharing.

Class descriptors, literals, and action programs are shared.

This format is smaller than an equivalent YARV lowering in which opcode and operands use machine-word-sized ISeq entries.

Long literal runs should use search literals or safe fusion to prevent unnecessary state growth.

---

# 53. Onibi Program Ownership

`RRegexp` currently contains a `re_pattern_buffer` immediately after the Ruby object header.

Onibi must preserve this outer object model.

During the migration period, use the existing `re_pattern_buffer` as the compatibility container.

The RSeq blob can be stored as the compiled pattern body after all internal callers use Onibi.

During dual-engine development, the Onigmo bytecode can remain in `p`, and `reserved1` can reference the Onibi sidecar.

The final implementation must define:

```c
#define ONIBI_AUX(reg) ((struct OnibiAux *)((reg)->reserved1))
```

The current MRI source does not otherwise use `reserved1`.

---

# 54. Onibi Sidecar

The mutable runtime sidecar is separate from RSeq.

```c
struct OnibiAux {
    _Atomic(uintptr_t) native_ascii_entry;
    _Atomic(uintptr_t) native_generic_entry;

    _Atomic(uint64_t) call_count;
    _Atomic(uint64_t) work_count;

    _Atomic(uint32_t) jit_state;
    uint32_t jit_generation;

    struct OnibiAux *jit_list_prev;
    struct OnibiAux *jit_list_next;
};
```

RSeq is immutable.

The sidecar contains only runtime caches and counters.

The sidecar must not change regexp semantics.

---

# 55. Execution Context

Each match operation has an execution context.

```c
struct OnibiExecCtx {
    rb_execution_context_t *ec;

    VALUE regexp;
    VALUE subject;

    const OnibiRSeqHeader *program;

    OnigPosition search_origin;
    OnigPosition attempt_start;
    OnigPosition reported_start;
    OnigPosition current_position;
    OnigPosition search_limit;

    uint32_t mode;
    uint32_t direction;

    struct OnibiFrontier current;
    struct OnibiFrontier next;

    struct OnibiTagArena tags;
    struct OnibiSemanticCaptureFile semantic_captures;
    struct OnibiCounterFile counters;
    struct OnibiCallStack calls;

    struct OnibiRawMatch best_match;

    uint64_t work_before_poll;

    rb_hrtime_t timeout_deadline;
};
```

The execution context is not shared between threads or Ractors.

---

# 56. Raw Match Result

Onibi must not allocate `MatchData` in the inner matching loop.

Use:

```c
struct OnibiRawMatch {
    OnigPosition begin;
    OnigPosition end;

    uint32_t num_regs;

    OnigPosition *beg;
    OnigPosition *end;
};
```

The arrays contain byte offsets.

The engine materializes these arrays only when the caller requires them.

---

# 57. `Regexp#match?`

`Regexp#match?` does not update `$~`.

When the pattern has no semantic capture reads, Onibi must not materialize output captures.

For a pure regular pattern, `match?` may use an unordered bitset existence executor.

Greedy and lazy preference do not affect boolean existence.

Alternation preference does not affect boolean existence.

Search-start preference does not affect the boolean result.

---

# 58. `Regexp#match` and `=~`

Methods that expose captures or update backreference state must use ordered semantics.

Before returning, Onibi materializes the capture region.

MRI then creates or updates `MatchData` through the existing `RMatch` path.

Onibi must preserve:

```text
$~
$&
$`
$'
$+
$1
$2
...
```

---

# 59. MatchData Integration

`RMatch` stores byte-offset register data.

Onibi must produce data that is compatible with the current `re_registers` model.

The final transfer is:

```text
OnibiRawMatch
    |
    v
re_registers-compatible offsets
    |
    v
RMatch
```

Character offsets remain lazy.

Existing `MatchData` character-offset conversion remains outside the matching engine.

---

# 60. MRI Internal API

The central Onibi API is:

```c
OnigPosition
rb_onibi_search(
    VALUE regexp,
    VALUE subject,
    OnigPosition start,
    OnigPosition range,
    OnigPosition gpos,
    int direction,
    uint32_t flags,
    struct re_registers *region
);
```

An anchored form is:

```c
OnigPosition
rb_onibi_match_at(
    VALUE regexp,
    VALUE subject,
    OnigPosition at,
    OnigPosition gpos,
    uint32_t flags,
    struct re_registers *region
);
```

The existing MRI regexp API should route to these functions.

Public behavior of these existing functions must remain stable:

```text
rb_reg_search
rb_reg_search0
rb_reg_match_p
rb_reg_prepare_re
onig_search
onig_search_gpos
onig_match
```

Compatibility wrappers may keep their current names.

---

# 61. Encoding Preparation

`rb_reg_prepare_re()` remains the compatibility boundary for target-string preparation.

Onibi must reuse the same encoding compatibility checks.

The matching engine receives an already validated encoding combination.

The executor selects one of these modes:

```c
enum OnibiEncodingMode {
    ONIBI_ENC_ASCII_7BIT,
    ONIBI_ENC_SINGLE_BYTE,
    ONIBI_ENC_UTF8,
    ONIBI_ENC_GENERIC_MB
};
```

The selected mode remains constant during one match operation.

---

# 62. ASCII Fast Path

For an ASCII-compatible encoding and a seven-bit subject:

```text
character decode = one byte
previous character = one byte backward
ASCII class lookup = bitmap
```

The JIT may remove generic encoding branches from the hot loop.

The entry dispatcher must make the encoding-mode check before entering specialized code.

---

# 63. Memory Management

RSeq uses one immutable allocation.

Execution arenas use match-local allocations.

The inner loop must not create Ruby objects.

The tag history should use block allocation.

Suggested tag block size:

```c
#define ONIBI_TAG_BLOCK_EVENTS 256
```

Thread arrays should grow geometrically.

All size calculations must use checked arithmetic.

Memory allocation failure must raise the normal MRI memory exception.

---

# 64. GC Rules

Generated Onibi code must not embed movable Ruby object addresses.

Generated code may embed:

- RSeq addresses;
- Onibi helper function addresses;
- immutable native constants.

The C wrapper must keep these Ruby values live during execution:

```text
regexp
subject
```

Generated code must not keep a raw `RSTRING_PTR` across a safepoint or helper call that can invoke GC.

Before such a call:

1. store the current byte offset in `OnibiExecCtx`;
2. do not rely on a live raw subject pointer.

After the call:

1. reload the subject `VALUE`;
2. reload `RSTRING_PTR`;
3. reload the end pointer;
4. reconstruct the raw current pointer from the byte offset.

---

# 65. Ractor Rules

RSeq is immutable.

RSeq can be shared.

Native code is immutable after publication.

The execution context is never shared.

The mutable JIT sidecar uses atomics and VM-level synchronization.

No match operation modifies RSeq.

---

# 66. Interrupts and Timeouts

Onibi must poll for interrupts.

Onibi must honor regexp timeout behavior.

Use:

```c
#define ONIBI_POLL_WORK 128
```

One work unit is one of:

- one state predicate evaluation;
- one dynamic-state evaluation;
- one lookaround subprogram step;
- one backreference comparison step unit;
- one subexpression-call execution step.

When the counter reaches 128:

1. store restartable execution state;
2. test the regexp timeout deadline;
3. call the MRI interrupt checker;
4. reset the work counter.

The JIT must implement the same rule.

---

# 67. Safepoints in Native Code

A native Onibi poll is a safepoint.

Before a poll, generated code must write all required restart state to `OnibiExecCtx`.

Generated code must not depend on Ruby `VALUE` objects in ZJIT virtual registers across the poll.

This rule permits `CCall` with no Ruby-value stack map for normal Onibi helpers.

---

# 68. Why Onibi Does Not Lower to YARV

YARV and Onibi use different execution models.

YARV uses:

```text
one program counter
one selected control path
VALUE operand stack
```

Onibi uses:

```text
multiple active states
ordered frontier
raw byte offsets
bitsets
capture-tag state
```

Direct YARV lowering would require Onibi to implement its frontier as data on top of YARV.

This adds YARV dispatch and VALUE-width storage without removing the automaton executor.

Therefore, Onibi native code generation starts below the YARV ISA.

---

# 69. ZJIT Integration Principle

Onibi uses ZJIT as the machine-code backend.

Onibi does not use ZJIT HIR for Ruby methods.

Onibi does not create an ISeq.

Onibi does not create YARV side exits.

Onibi does not use Ruby-local or Ruby-stack state in its generated function.

Onibi uses the low-level ZJIT facilities:

```text
BasicBlock
VReg
Mem
Imm
UImm
Load
Store
Add
Sub
And
Or
Xor
Not
LShift
URShift
Cmp
Test
conditional jumps
Jmp
CCall
FrameSetup
FrameTeardown
CRet
register allocation
CodeBlock
machine assembler
VirtualMem
```

---

# 70. Required ZJIT Refactoring

The current ZJIT LIR contains ISeq-specific structures.

Onibi must use a standalone subset.

The ZJIT backend must provide:

```rust
pub enum LirUnitKind {
    Iseq,
    Onibi,
}
```

or an equivalent separation.

The Onibi compiler must be able to create a LIR assembler without:

```text
IseqVersionRef
Ruby side exits
PatchPoint invalidation
Ruby stack maps
YARV PC state
```

The standalone compiler must still use the same register allocator and architecture backend.

---

# 71. Prohibited ZJIT Operations for Onibi

Onibi generated LIR must not use:

```text
Target::SideExit
PatchPoint
Ruby ISeq payload
YARV stack reconstruction
Ruby local reconstruction
Opnd::Value for long-lived Ruby values
```

A helper call can use `CCall`.

Its `stack_map` must normally be `None`.

---

# 72. Native Function ABI

Each compiled regexp entry uses the C ABI.

```c
typedef int (*onibi_native_entry_t)(
    struct OnibiExecCtx *ctx
);
```

Return codes are:

```c
enum OnibiNativeStatus {
    ONIBI_NATIVE_MATCH = 0,
    ONIBI_NATIVE_NO_MATCH = 1,
    ONIBI_NATIVE_RETRY_GENERIC = 2,
    ONIBI_NATIVE_FALLBACK = 3
};
```

Exceptions are raised through normal MRI mechanisms.

The native function writes match data to `ctx`.

---

# 73. Native Frame

The native function has a normal ZJIT-generated native frame.

It does not use a YARV control frame.

It does not require `CFP` or YARV `SP`.

It receives only `OnibiExecCtx *`.

Use ZJIT:

```text
FrameSetup
...
FrameTeardown
CRet
```

The ZJIT backend handles the platform calling convention.

---

# 74. RegMacroAssembler

Onibi code generation uses a target-independent macro layer.

Required conceptual operations are:

```rust
trait RegMacroAssembler {
    fn load_u8(...);
    fn load_u32(...);
    fn load_word(...);

    fn store_u32(...);
    fn store_word(...);

    fn add(...);
    fn sub(...);

    fn and(...);
    fn or(...);
    fn xor(...);

    fn shift_left(...);
    fn shift_right(...);

    fn compare(...);
    fn test_bits(...);

    fn jump(...);
    fn jump_eq(...);
    fn jump_ne(...);
    fn jump_zero(...);
    fn jump_nonzero(...);

    fn call_helper(...);

    fn frame_setup(...);
    fn frame_teardown(...);
    fn return_status(...);
}
```

This layer expresses regexp execution operations.

It does not express x86-64 or AArch64 instructions.

---

# 75. RegMacroAssembler to ZJIT LIR Mapping

The baseline mapping is:

| RegMacroAssembler operation | ZJIT LIR |
|---|---|
| load | `Load` |
| store | `Store` |
| add | `Add` |
| subtract | `Sub` |
| bitwise and | `And` |
| bitwise or | `Or` |
| bitwise xor | `Xor` |
| bitwise not | `Not` |
| left shift | `LShift` |
| unsigned right shift | `URShift` |
| compare | `Cmp` |
| bit test | `Test` |
| equal branch | `Je` |
| not-equal branch | `Jne` |
| zero branch | `Jz` |
| nonzero branch | `Jnz` |
| unconditional branch | `Jmp` |
| helper call | `CCall` |
| function entry | `FrameSetup` |
| function exit | `FrameTeardown`, `CRet` |

Onibi v1 must not require a new architecture-specific ZJIT instruction.

---

# 76. JIT Input

The JIT compiles RSeq.

It does not require the original AST.

It does not require G-IR.

Compilation path:

```text
RSeq
  |
  v
RSeq analysis
  |
  v
RegCodePlan
  |
  v
RegMacroAssembler
  |
  v
ZJIT LIR
```

This permits lazy JIT after many interpreted matches.

---

# 77. RegCodePlan

`RegCodePlan` is temporary.

It contains native-code planning information.

Example:

```rust
struct RegCodePlan {
    kind: RegCodePlanKind,
    encoding_mode: EncodingMode,

    state_count: usize,
    predicate_groups: Vec<PredicateGroup>,
    follow_sets: Vec<FollowSet>,

    needs_tags: bool,
    needs_counters: bool,
    has_dynamic_ops: bool,

    estimated_code_size: usize,
}
```

`RegCodePlan` is discarded after native code generation.

---

# 78. JIT Strategy Classes

The JIT uses three code-generation strategies.

```c
#define ONIBI_JIT_SMALL_STATES 64
#define ONIBI_JIT_MEDIUM_STATES 256
#define ONIBI_JIT_MAX_CODE_BYTES 16384
```

---

## 78.1 Small Program

For at most 64 states, the JIT may fully specialize state transitions.

The active-membership mask fits in one `uint64_t`.

Generated code may keep:

```text
active mask
next mask
subject pointer
end pointer
```

in registers.

The JIT must still preserve ordered state processing when the result depends on match priority.

---

## 78.2 Medium Program

For 65 to 256 states, the JIT should specialize predicate groups but keep transition data in RSeq tables.

The active-membership set uses multiple words.

The JIT should not create one large native block for every state if the estimated code size exceeds the limit.

---

## 78.3 Large Program

For more than 256 states, generate a specialized native executor loop.

The loop reads RSeq state and edge data.

The program can still specialize:

- encoding mode;
- capture mode;
- state-count word count;
- feature flags;
- helper addresses;
- common class predicates.

Native code size should remain almost independent of regexp size.

---

# 79. Ordered Native Executor

The native ordered executor uses both:

```text
ordered state vector
membership bitset
```

The vector preserves priority.

The bitset performs O(1) duplicate detection.

Conceptual insertion:

```c
if (!(next_bits[word] & mask)) {
    next_bits[word] |= mask;
    next_states[next_len++] = state_id;
}
```

The first insertion wins.

---

# 80. Boolean Bitset Executor

For `Regexp#match?`, a pure regular regexp can use only bitsets.

This executor does not preserve capture or match-end preference.

It only answers existence.

Conceptual step:

```c
next = 0;

for each active matching state:
    next |= follow[state];

active = next;
```

The compiler must not use this mode when runtime capture state affects the language.

---

# 81. Predicate Grouping

The JIT should group states that use the same input predicate.

Example:

```text
S1 CLASS [a-z]
S2 CLASS [a-z]
S3 CLASS [0-9]
```

The native plan should evaluate `[a-z]` once.

Conceptually:

```c
is_letter = class_letter(c);

if (is_letter) {
    process_if_active(S1);
    process_if_active(S2);
}

if (class_digit(c)) {
    process_if_active(S3);
}
```

This optimization is architecture independent.

It belongs in `RegCodePlan`.

---

# 82. Dynamic-State JIT

Dynamic states do not need complete native implementations in v1.

The JIT may call helpers for:

```text
backreference
subexpression call
atomic subprogram
absence operator
grapheme
complex lookaround
generic multibyte class
```

Example:

```text
generated native loop
    |
    v
CCall onibi_match_backref
    |
    v
continue native loop
```

The helper reads and writes `OnibiExecCtx`.

Before the call, generated code must save restart state.

---

# 83. Helper ABI

Helpers use simple C ABI functions.

Example:

```c
OnigPosition
onibi_helper_backref(
    struct OnibiExecCtx *ctx,
    uint32_t descriptor_id
);
```

Return value:

```text
negative = failure
zero or positive = number of bytes consumed
```

Helpers must not return Ruby objects to generated code.

---

# 84. ZJIT Native Entry Publication

Compilation occurs while MRI holds the required VM synchronization.

The compiler writes all code before publication.

Then it publishes the entry with a release atomic store.

Readers use an acquire atomic load.

Conceptual code:

```c
atomic_store_explicit(
    &aux->native_generic_entry,
    (uintptr_t)entry,
    memory_order_release
);
```

Execution uses:

```c
entry = atomic_load_explicit(
    &aux->native_generic_entry,
    memory_order_acquire
);
```

---

# 85. JIT Activation

Onibi native compilation is active only when ZJIT is enabled.

When ZJIT is not enabled:

```text
Onibi compiler -> RSeq
Onibi execution -> selected C interpreter
```

The existence of Onibi must not silently enable native JIT compilation.

---

# 86. JIT Hotness

Each program records:

```text
call_count
work_count
```

Initial thresholds are:

```c
#define ONIBI_JIT_CALL_THRESHOLD 32
#define ONIBI_JIT_WORK_THRESHOLD 262144
```

The engine requests JIT compilation after a match operation when either threshold is reached.

Compilation does not interrupt a match already in progress.

The program must not compile twice concurrently.

`jit_state` uses:

```c
enum OnibiJitState {
    ONIBI_JIT_COLD,
    ONIBI_JIT_COMPILING,
    ONIBI_JIT_READY,
    ONIBI_JIT_DISABLED
};
```

---

# 87. Native Code Size Limit

Each pattern-specific compiled unit has a 16 KiB initial code-size limit.

If a fully specialized plan exceeds this estimate, the compiler must select a less specialized plan.

The compiler must not fail regexp matching because a JIT plan is too large.

It must use an interpreter or generic native plan.

---

# 88. Onibi ZJIT Code Cache

Onibi uses a ZJIT-backed code region.

The code region is separate from ISeq ownership.

The initial Onibi native-code capacity is:

```text
16 MiB
```

This value is an implementation default and can later become a ZJIT configuration option.

The code region uses the same ZJIT:

```text
VirtualMem
CodeBlock
architecture emitters
```

Onibi does not implement independent executable-memory support.

---

# 89. Onibi Code Cache Reset

The initial code-GC algorithm is whole-cache reset.

When the Onibi code region is full:

1. stop publication of new Onibi code;
2. increment the Onibi JIT generation;
3. clear all published Onibi native entry pointers;
4. reset the Onibi `CodeBlock`;
5. retry the current compilation once.

Programs become hot again and can recompile.

This simple policy avoids invalid native pointers.

A later implementation may add page-level collection.

The semantic behavior must not depend on code-cache state.

---

# 90. No ZJIT Side Exits

Onibi native code does not side-exit to a YARV instruction.

A native Onibi function either:

```text
matches
does not match
requests generic retry
requests C interpreter fallback
raises through MRI
```

No Onibi native state includes a YARV PC.

---

# 91. Native Error and Fallback Rules

Native compilation failure is not a regexp error.

The engine must continue with the selected C interpreter when:

```text
ZJIT code memory is unavailable
ZJIT compilation returns an internal non-fatal failure
a state has no native lowering
a native specialization guard fails
```

A syntax error remains a `RegexpError`.

An encoding error remains the normal MRI encoding error.

A timeout remains the normal regexp timeout error.

---

# 92. YARV Integration

YARV remains the host VM.

Existing instructions such as:

```text
opt_regexpmatch2
```

continue to call the regexp subsystem.

The regexp subsystem decides:

```text
native Onibi entry
or
selected C interpreter
```

YARV does not see individual Onibi states.

---

# 93. ZJIT Caller Integration

ZJIT method compilation may later optimize a call to a constant `Regexp`.

The preferred form is a direct call to the shared Onibi native function.

Do not inline the complete regexp native body at each Ruby call site.

Conceptually:

```text
ZJIT Ruby code
    |
    v
load regexp native entry
    |
    +-- null --> rb_onibi_search
    |
    v
direct native call
```

This preserves one native regexp copy for many Ruby call sites.

Method-redefinition guards must remain consistent with normal MRI optimized-send rules.

---

# 94. Search API Users

The same Onibi engine must serve:

```text
Regexp#match
Regexp#match?
Regexp#=~
String#match
String#match?
String#scan
String#split
String#sub
String#gsub
String#index regexp paths
StringScanner regexp paths
other rb_reg_search callers
```

Onibi must not depend on being called from YARV.

---

# 95. Compilation Feature Flags

RSeq stores feature flags.

Example:

```c
enum OnibiFeature {
    OF_CAPTURE          = 1u << 0,
    OF_LOOKAROUND       = 1u << 1,
    OF_COUNTER          = 1u << 2,
    OF_GRAPHEME         = 1u << 3,

    OF_BACKREF          = 1u << 8,
    OF_CALL             = 1u << 9,
    OF_CAPTURE_COND     = 1u << 10,
    OF_ATOMIC           = 1u << 11,
    OF_ABSENT           = 1u << 12,
    OF_RECURSION        = 1u << 13
};
```

The executor kind is derived from these flags and semantic-liveness analysis.

---

# 96. Compiler Pass Order

The compiler must use this pass order.

```text
1. Parse
2. Resolve names and numbering
3. Resolve lexical options
4. Resolve encoding mode
5. Normalize character classes
6. Normalize simple escape constructs
7. Build ignore-case fold DAGs
8. Analyze capture use
9. Analyze nullable nodes
10. Analyze min/max character width
11. Analyze lookbehind width
12. Lower possessive forms
13. Select large-repeat representation
14. Build tagged epsilon NFA
15. Eliminate epsilon transitions
16. Build G-IR
17. Verify G-IR
18. Classify executor
19. Optimize G-IR
20. Lower to RSeq
21. Verify RSeq
22. Build search metadata
23. Publish immutable program
```

Do not change this order without updating semantic dependencies.

---

# 97. Compiler Verification

Before publication, the compiler must verify:

```text
all state IDs are valid
all edge ranges are inside the edge array
all action offsets are valid
all action programs terminate
all class IDs are valid
all subprogram IDs are valid
all capture IDs are valid
all counter IDs are valid
all call continuations are valid
all start edges are valid
all RSeq offsets are aligned
blob_size covers every section
no integer arithmetic overflow occurred
```

Debug builds must abort on an internal invariant failure.

Release builds must return a normal internal compilation error.

---

# 98. RSeq Debug Dump

MRI debug builds should provide an internal RSeq disassembler.

Example format:

```text
ONIBI RSEQ v1
exec=TAGGED_ORDERED
states=4 edges=7 captures=2

START:
  -> S0 action=3
  -> ACCEPT action=7

S0 CHAR "a"
  -> S0
  -> S1 action=CAPTURE_CLOSE(1)

S1 CLASS C2
  -> ACCEPT action=ASSERT_END_BUFFER
```

The dump must use state IDs.

It must not print raw machine pointers by default.

---

# 99. Native-Code Debugging

The ZJIT Onibi compiler should emit symbols such as:

```text
onibi:<regexp-object-id>:ascii
onibi:<regexp-object-id>:generic
```

when ZJIT performance-map support is active.

The symbol must identify Onibi code separately from Ruby ISeq code.

---

# 100. Differential Testing

During implementation, every supported pattern must be testable with two engines:

```text
Onigmo reference
Onibi
```

The test harness must compare:

```text
match/no-match
match begin
match end
all capture begins
all capture ends
named capture lookup
$~
$&
$`
$'
$+
search starting position
reverse search result
exceptions
encoding errors
timeout behavior class
```

---

# 101. Random Differential Testing

A regexp grammar fuzzer should generate patterns from the supported syntax.

Generate subjects in:

```text
ASCII-8BIT
UTF-8
EUC-JP
Windows-31J
other MRI encodings
```

The fuzzer must compare Onibi and Onigmo.

When results differ, the test harness must minimize:

```text
regexp
subject
options
start position
search direction
```

---

# 102. Required Feature Test Groups

The test suite must contain dedicated groups for:

```text
alternation priority
greedy quantifiers
lazy quantifiers
possessive quantifiers
nullable repetition
nested repetition
captures in repetition
duplicate named captures
numeric backreferences
named backreferences
case-insensitive backreferences
recursion-level backreferences
subexpression calls
recursive calls
lookahead captures
negative lookahead
lookbehind alternatives
negative lookbehind
atomic groups
conditional groups
absence operator
\K
\G
^
$
\A
\Z
\z
word boundaries
character class intersection
Unicode properties
POSIX classes
1:1 case fold
1:N case fold
N:1 case fold
1:3 case fold
3:1 case fold
\R
\X
empty subject
empty regexp
invalid encoding combinations
forward search
reverse search
Regexp#match?
Regexp#match
Regexp#=~
String#scan
String#gsub
String#split
timeout
interrupt
Ractor use
```

---

# 103. JIT Equivalence Tests

For each JIT-supported pattern, run these modes:

```text
applicable C interpreter
Onibi ZJIT native ASCII entry
Onibi ZJIT native generic entry
```

All modes must produce identical `OnibiRawMatch` data.

The test must compare raw byte offsets before `MatchData` creation.

---

# 104. JIT Register-Pressure Tests

ZJIT tests must compile Onibi functions with an artificially small register set.

This verifies spill correctness.

Required tests include:

```text
one allocatable register
two allocatable registers
normal architecture register set
```

The ZJIT backend already supports limited-register testing.

Onibi should use the same mechanism.

---

# 105. Performance Benchmarks

The benchmark suite must contain these groups.

## Literal

```regex
/foo/
/long-literal-string/
```

## Character classes

```regex
/[a-z]+/
/[\p{L}\p{N}_]+/
```

## Alternation

```regex
/foo|bar|baz/
```

## Common parsing

```regex
/\A[a-zA-Z_][a-zA-Z0-9_]*\z/
```

## Pathological regular patterns

```regex
/(a|aa)*b/
/(a*)*b/
```

## Captures

```regex
/([a-z]+)-([0-9]+)/
```

## Backreferences

```regex
/(a+)\1/
```

## Recursive call

Use a balanced-delimiter pattern.

## Case folding

Include one-to-many folds.

## Search

Use subjects from:

```text
32 bytes
1 KiB
1 MiB
100 MiB
```

---

# 106. Performance Counters

Debug or statistics builds should collect:

```text
compile_count
rseq_state_count
rseq_edge_count
rseq_bytes
search_candidates
state_evaluations
thread_insertions
thread_deduplications
tag_events
dynamic_threads
backref_bytes_compared
lookaround_calls
subexpression_calls
interrupt_polls
jit_compile_count
jit_compile_failures
jit_code_bytes
native_match_calls
interpreter_match_calls
```

These counters must not affect semantics.

---

# 107. Expected Complexity

For pure regular matching without runtime counters:

```text
time = O(subject_characters * active_state_work)
```

With state deduplication, one state is processed at most once per input position in one regular frontier.

The implementation must not create exponential backtracking paths for a regular pattern.

Backreferences and recursive calls can create non-polynomial behavior.

`Regexp.timeout` remains required for these cases.

---

# 108. Code-Size Policy

Onibi has three code-size controls.

1. RSeq uses compact state and edge data.
2. Long simple sequences can use safe fusion or search metadata.
3. Native compilation has a per-program code-size limit.

Do not increase native code size only to eliminate a small RSeq-table load.

The JIT should favor instruction-cache locality for large expressions.

---

# 109. No Independent Machine Assembler

The following files must not exist in Onibi:

```text
onibi/x86_64_assembler.*
onibi/aarch64_assembler.*
onibi/register_allocator.*
onibi/executable_memory.*
```

Architecture-specific generation belongs to ZJIT.

If Onibi needs a low-level operation that ZJIT does not have, first implement it as:

```text
existing LIR sequence
or
C helper
```

A new ZJIT LIR operation is permitted only when it has general value and has implementations for all ZJIT target architectures.

---

# 110. SIMD Policy

Onibi v1 does not require SIMD LIR operations.

Use existing C helpers for optimized memory search when appropriate.

Examples include MRI memory-search helpers or platform libc functions.

A future ZJIT SIMD extension may optimize:

```text
literal search
byte class scan
newline scan
ASCII classification
```

RSeq semantics must not depend on SIMD support.

---

# 111. Thread Safety

The compiled program is immutable.

Concurrent threads can execute the same RSeq.

Each thread has a separate `OnibiExecCtx`.

The native entry pointer is atomic.

JIT compilation uses one compile-state transition.

Only one thread may compile one regexp variant.

Other threads continue to use C interpreters while compilation occurs or waits for VM serialization.

---

# 112. Regexp Copy

Copying a Regexp must copy regexp semantics but does not need to copy native code.

The new Regexp can share immutable RSeq only if ownership has an explicit reference count.

The initial implementation should copy the RSeq blob and create a cold JIT sidecar.

This rule is simpler and avoids native-code ownership coupling.

---

# 113. Marshal

Marshal must store the normal Regexp source and options.

Marshal must not store:

```text
G-IR
RSeq
native code
JIT counters
```

Load recompiles the regexp.

---

# 114. Source Layout

The gem PoC uses this top-level layout:

```text
ext/onibi/
    extconf.rb
    onibi.c
    onibi_common.c
    token.c
    ast.c
    parser.c
    nfa.c
    gir.c
    compiler.c
    rseq.c
    rseq_verify.c
    exec_regular.c
    exec_tagged.c
    exec_dynamic.c
    match.c
    onibi_init.c

lib/
    onibi.rb
    onibi/version.rb

test/
    unit/
    compatibility/
```

`onibi.c` is the small amalgamated translation unit. It includes the modules
in pipeline order. Each module has one primary responsibility and can move to
an independent translation unit when its private interfaces are stable.

The later MRI integration can use these C files:

```text
onibi/
    onibi.h
    ast.h
    ast.c

    compile.h
    compile.c

    nfa.h
    nfa.c

    gir.h
    gir.c

    rseq.h
    rseq.c
    rseq_verify.c

    class.h
    class.c

    casefold.h
    casefold.c

    capture.h
    capture.c

    search.h
    search.c

    exec.h
    exec_regular.c
    exec_tagged.c
    exec_dynamic.c

    helpers.h
    helpers.c

    match.h
    match.c

    debug.c
```

The gem PoC does not contain a Rust execution component.

The later ZJIT integration can use these Rust files:

```text
zjit/src/onibi/
    mod.rs
    plan.rs
    macro_assembler.rs
    compile.rs
    abi.rs
    stats.rs
```

Common ZJIT changes should remain under:

```text
zjit/src/backend/
zjit/src/asm/
zjit/src/virtualmem.rs
```

---

# 115. PoC C Boundary and Later C and Rust Boundary

The gem PoC keeps the complete execution path in C.

C owns:

```text
parser integration
AST adaptation
G-IR compilation
RSeq
three execution interpreters
MRI Regexp API
encoding integration
MatchData integration
runtime helpers
```

After the PoC, Rust owns:

```text
RSeq JIT analysis
RegCodePlan
RegMacroAssembler
ZJIT LIR generation
native-code publication
Onibi code-cache integration
```

Rust must treat RSeq as immutable input.

C must expose a stable internal C representation for the RSeq header and tables.

Use bindgen for shared layout constants where practical.

---

# 116. JIT Compile Interface

C calls:

```c
int
rb_onibi_zjit_compile(
    regex_t *reg,
    enum OnibiEncodingMode mode
);
```

Rust returns:

```text
0 = native entry published
1 = no compilation needed
2 = temporary code-cache failure
3 = pattern uses unsupported native feature
negative = internal compiler failure
```

A JIT failure must not invalidate the regexp.

---

# 117. Execution Dispatcher

Conceptual dispatcher:

```c
static int
onibi_execute(struct OnibiExecCtx *ctx)
{
    struct OnibiAux *aux = ONIBI_AUX(RREGEXP_PTR(ctx->regexp));

    onibi_native_entry_t entry = NULL;

    if (zjit_enabled) {
        if (ctx->encoding_mode == ONIBI_ENC_ASCII_7BIT) {
            entry = atomic_load(&aux->native_ascii_entry);
        }
        else {
            entry = atomic_load(&aux->native_generic_entry);
        }
    }

    if (entry != NULL) {
        return entry(ctx);
    }

    int status = onibi_interpret(ctx);

    onibi_record_hotness(ctx);

    return status;
}
```

The real implementation must use the required atomic memory orders.

---

# 118. JIT Poll Lowering

Generated native code must implement a work counter.

Conceptual LIR:

```text
Sub work, 1 -> work
Cmp work, 0
Jg continue

Store ctx.current_position, position
CCall onibi_poll(ctx)

Load refreshed subject pointer
Load refreshed subject end

Load ONIBI_POLL_WORK -> work
```

No Ruby `VALUE` remains in a temporary virtual register across the `CCall`.

---

# 119. Example: Simple Case-Sensitive Pattern

Pattern:

```regex
/ab/
```

G-IR:

```text
S0 CHAR 'a'
S1 CHAR 'b'

START -> S0
S0 -> S1
S1 -> ACCEPT
```

RSeq:

```text
state 0:
    RS_CHAR 'a'
    edge -> state 1

state 1:
    RS_CHAR 'b'
    edge -> ACCEPT
```

A safe optimizer can use an exact search prefix.

For anchored matching, it can also fuse the run if no priority boundary exists.

---

# 120. Example: Alternation

Pattern:

```regex
/a|ab/
```

G-IR positions:

```text
S0 'a' from first alternative
S1 'a' from second alternative
S2 'b'
```

Start order:

```text
S0
S1
```

`S0 -> ACCEPT`.

`S1 -> S2`.

The first alternative wins when both can match.

The engine must not merge `S0` and `S1` only because both compare the same character.

They have different continuation semantics.

---

# 121. Example: Greedy Repetition

Pattern:

```regex
/a*/
```

Start edges:

```text
a
ACCEPT
```

After `a`:

```text
a
ACCEPT
```

The consuming state is before ACCEPT.

Therefore the engine keeps trying repetition.

The fallback accept is used only when the higher-priority repeated path cannot continue.

---

# 122. Example: Lazy Repetition

Pattern:

```regex
/a*?/
```

Start edges:

```text
ACCEPT
a
```

The engine returns the empty match immediately.

No backtracking stack is required.

---

# 123. Example: Capture

Pattern:

```regex
/(?<x>a)b/
```

Initial edge:

```text
START -> 'a'
action:
    CAPTURE_OPEN(x)
```

Edge from `a` to `b`:

```text
CAPTURE_CLOSE(x)
```

Successful match produces:

```text
x.begin = position before a
x.end   = position after a
```

---

# 124. Example: One-to-Many Case Fold

Conceptual fold:

```text
X <-> yz
```

Pattern:

```regex
/X/i
```

Normalized graph:

```text
        +-- CLASS X --------+
START --+                   +--> ACCEPT
        +-- CLASS y -> z ---+
```

No special runtime fold instruction is required.

---

# 125. Example: Many-to-One Case Fold

Pattern:

```regex
/yz/i
```

with the same fold relation.

Normalized graph:

```text
        +-- CLASS y -> z ---+
START --+                   +--> ACCEPT
        +-- CLASS X --------+
```

The compiler must find this alternative by looking at multiple pattern characters.

---

# 126. Example: Backreference

Pattern:

```regex
/(a+)\1/
```

The repeated `a` region uses ordinary prioritized states.

Capture close updates:

```text
tag history
semantic capture register
```

Then:

```text
G_BACKREF capture=1
```

compares the captured subject slice with the current subject position.

The backreference state can consume more than one byte.

This pattern uses the Dynamic executor.

---

# 127. Example: Recursive Subexpression

Pattern form:

```regex
(?<p> ... \g<p> ... )
```

`G_CALL` pushes an explicit Onibi call frame.

The called subprogram executes with its own subprogram entry.

When it accepts, the engine returns to the saved continuation.

The C stack depth does not depend on regexp recursion depth.

---

# 128. Example: ZJIT Lowering of a Bit Test

Onibi operation:

```text
if state 5 is active
```

For a 64-state mask:

```text
mask = 1 << 5
```

ZJIT LIR conceptually becomes:

```text
Test active, 0x20
Jz not_active
```

Onibi does not emit an architecture-specific `test` instruction.

The ZJIT backend selects the machine instruction.

---

# 129. Example: ZJIT Lowering of State Activation

Onibi operation:

```text
next |= follow_mask
```

ZJIT LIR:

```text
Or next, follow_mask -> next2
```

The register allocator decides whether `next` remains in a register.

---

# 130. Example: ZJIT Helper Call

Dynamic backreference:

```text
Store ctx.current_position
Store ctx.current_thread_state
CCall onibi_helper_backref(ctx, desc_id)
Cmp result, 0
Jl fail
Add position, result -> position
```

After a helper that can reach a safepoint, reload the subject raw pointer.

---

# 131. Migration Plan

Implementation should use these phases.

## Phase 1

Create the MRI-only gem C extension.

Define `Onibi::Regexp` and the minimum compatible constructor API.

Add focused unit tests for extension loading, allocation, initialization, and errors.

---

## Phase 2

Build the minimum parser, AST, tagged epsilon NFA, G-IR, and RSeq.

Implement the `REGULAR_FAST` C interpreter.

Start with literals and small regular operators.

Compare supported public results with MRI.

---

## Phase 3

Implement tag history, ordered threads, captures, and the `TAGGED_ORDERED` C interpreter.

Compare complete match and capture byte offsets with MRI.

---

## Phase 4

Implement runtime semantic state and the `DYNAMIC` C interpreter.

Add backreferences, calls, recursion, conditions, atomic groups, and absence in small groups.

---

## Phase 5

Complete the gem PoC for its declared feature set.

Expand the `Onibi::Regexp` API and differential tests.

Verify ownership, error cleanup, interrupts, timeouts, and supported encodings.

Record features that remain unsupported.

---

## Phase 6

Start MRI source-tree integration after the gem PoC is complete.

Connect the ZJIT standalone LIR backend.

Compile REGULAR_FAST patterns first.

---

## Phase 7

Compile TAGGED_ORDERED patterns.

Use helpers for complex operations.

---

## Phase 8

Compile DYNAMIC patterns with helper calls.

---

## Phase 9

Run full Ruby test suites and fuzzing with Onibi as default.

Keep a diagnostic Onigmo comparison mode.

---

## Phase 10

Remove production Onigmo matching fallback after compatibility reaches the required level.

The parser and encoding tables can remain until separate replacement work is complete.

---

# 132. Compatibility Mode

During development, MRI should support:

```text
ONIBI=off
ONIBI=on
ONIBI=compare
```

`compare` executes both engines where practical.

It reports any mismatch.

This mode is for development only.

It must not become a public compatibility guarantee.

---

# 133. Acceptance Criteria

## 133.1 Gem PoC acceptance

The gem PoC is complete when all of these conditions are true.

1. The gem builds and loads on its supported MRI version.
2. `Onibi::Regexp` provides the declared compatible API subset.
3. All three execution interpreters are implemented in C.
4. The compiler selects the correct execution class for supported patterns.
5. Focused tests cover each supported compiler and interpreter behavior.
6. Differential tests show no known mismatch in the supported API subset.
7. Unsupported features are explicit and do not cause unexpected process failures.
8. The PoC does not depend on ZJIT or MRI source-tree changes.

The complete legacy, MRI, and Ruby Spec suites are not PoC acceptance gates.

## 133.2 MRI replacement acceptance

Onibi is ready to replace the current MRI matcher when all of these conditions are true.

1. The complete MRI test suite passes.
2. Ruby Spec regexp tests pass.
3. Onibi and Onigmo differential fuzzing has no known semantic mismatch.
4. All supported MRI encodings pass targeted tests.
5. All advanced Ruby regexp constructs have dedicated tests.
6. `Regexp.timeout` passes stress tests.
7. Interrupt tests pass.
8. Ractor tests pass.
9. ASAN and UBSAN tests pass.
10. RSeq verification finds no invalid generated program.
11. C interpreter and ZJIT native results are identical.
12. Pathological regular patterns do not show exponential backtracking.
13. Typical regexp performance is not materially worse than the current engine.
14. Common regular patterns show a measurable performance improvement.
15. Native code memory remains inside the configured ZJIT Onibi code budget.
16. MRI works correctly when ZJIT is disabled.
17. MRI works correctly after Onibi code-cache reset.
18. No Onibi architecture-specific assembler exists.

---

# 134. Core Invariants

Every implementation must preserve these invariants.

### Program invariant

RSeq is immutable after publication.

### Priority invariant

Edge array order is semantic priority order.

### Position invariant

Externally visible offsets are subject byte offsets.

### Capture invariant

A discarded path cannot modify another path's capture state.

### Merge invariant

The executor merges threads only when their future observable behavior is equal.

### Encoding invariant

All input pointer movement follows the active MRI encoding.

### JIT invariant

Interpreter and native code execute the same RSeq semantics.

### GC invariant

Native code holds no untracked movable Ruby object pointer across a safepoint.

### ZJIT invariant

Onibi contains no machine-specific code generator.

### YARV invariant

Onibi state execution is not represented as a sequence of YARV regexp microinstructions.

---

# 135. Final Architecture

The final MRI architecture is:

```text
                         Ruby source
                              |
                              v
                          Regexp object
                              |
                              v
                        Onibi compiler
                              |
                              v
                     immutable RSeq program
                              |
              +---------------+---------------+
              |                               |
              v                               v
       three C interpreters               hot program
                                              |
                                              v
                                       RegCodePlan
                                              |
                                              v
                                    RegMacroAssembler
                                              |
                                              v
                                         ZJIT LIR
                                              |
                                              v
                                ZJIT register allocation
                                              |
                                              v
                              x86-64 / AArch64 backend
                                              |
                                              v
                                    Onibi native entry
                                              |
             +--------------------------------+-------------------+
             |                                |                   |
             v                                v                   v
            YARV                             ZJIT             MRI C APIs
                                                               |
                                                        scan/gsub/split/etc.
```

The boundary between Onibi and ZJIT is low-level LIR.

The boundary between Ruby and Onibi is the existing Regexp subsystem.

The regular core is a prioritized Glushkov automaton.

Ruby-specific non-regular features extend this machine with explicit dynamic states.

This structure keeps Ruby semantics in one regexp compiler.

It keeps architecture-specific native generation in one MRI JIT backend.

It permits an interpreter when ZJIT is not active.

It permits native specialization when ZJIT is active.

It does not require a second machine-code backend for regular expressions.
