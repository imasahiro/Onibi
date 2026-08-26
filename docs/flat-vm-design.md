# Flat VM design

## Goal

The matcher executes one immutable instruction stream. It does not walk AST
or SemanticBytecode trees during matching.

The current implementation is in migration. Supported programs use the flat
command dispatcher. The compatibility evaluator handles unsupported forms.

## Machine state

The VM state is:

```text
pc, cursor, captures, input, flags
```

`ExecutionState#vm_stack` stores suspended instruction frames. Each frame
contains a program counter, cursor, capture checkpoint, and frame checkpoint.
`ExecutionFrame` stores scope state. `CallFrame` stores return state.

Absence probes use `ExecutionState::AbsenceFrame`. Its state is separate from
ordinary scopes and contains the probe interval, probe cursor, resume PC, body
PC, candidate points, body checkpoints, and capture checkpoints. A future flat absence
instruction must use `push_absence_frame` and must not call the tree evaluator.

## Instruction families

```text
consume(operand)       consume one operand
assert(kind, operand)   test a zero-width condition
capture_start(number)  save the current cursor
capture_end(number)    publish a capture span
choice(targets)        push ordered alternatives
repeat(body, policy)   push repeat continuations
atomic_start           save a choice barrier
atomic_end             discard choices after the barrier
call(target)            push a CallFrame
return                  pop a CallFrame
accept                  return the current match
fail                    restore the next backtrack point
```

All instructions use integer program counters. Composite operands contain
program counters, not semantic node objects.

## Tagged automata

TNFA transitions carry ordered tags. DFA determinization preserves the tag
program for each transition. A tag program can write captures, push a choice,
enter a repeat frame, or call a subprogram. Tags are never inferred by the VM
from source syntax.

## Migration order

1. Lower literal and class operands to `consume` instructions.
2. Lower capture groups to `capture_start` and `capture_end` tags.
3. Lower ordered alternation and quantifiers to `choice` and `repeat`.
4. Lower assertions, backreferences, conditionals, and absence.
5. Isolate the compatibility tree evaluator from the flat interpreter.

Each step requires differential tests for match range, captures, ordering,
Unicode boundaries, and failure restoration before the next step.

## Current implementation

`Program#tagged_automaton` is present when the compiler enables `tagged_vm`.
The interpreter consumes tagged DFA transitions and applies capture tags.
`SemanticProgram#vm_instructions` exposes command names for every semantic
node. `FlatProgram` now contains a root instruction stream and subroutine entry
PCs. Subexpression calls use `call` and `return`, including consuming recursive
calls. Capture group quantifiers use PC loops; possessive groups use an
`atomic_start`/`atomic_end` barrier. Assertions and absence use compile-time
flat atom lists. These lists support literals, classes, properties, graphemes,
backreferences, and zero-width boundary atoms. Scoped multiline flags use
`scope_start` and `scope_end`.

Flat assertions are tree-free. `Assertion#tree_free?` rejects composite atoms,
and `FlatProgram` rejects them during construction. `FlatProgram` also owns
`instruction_at`, `valid_pc?`, and `call_target`; the interpreter does not
read flat instruction or subroutine tables directly.

Literal operands expose `source_width` and `folded_width`. The fold matcher
uses these character widths, not byte widths. Boundary-sensitive folds enter
the flat VM only for terminal or anchored forms. Other forms use compatibility
execution until source-width conversion is complete.

The compatibility evaluator remains for Unicode fold boundary rules, leading
terminal-anchor assertions, complex recursive bodies, and other constructs
that do not yet have complete PC lowering. Leading terminal-anchor assertions
need a search policy in addition to an assertion instruction. Unbounded
absence repeats also remain there when their greedy retry and zero-width retry
rules need a dedicated VM policy. It lives in
`SemanticTreeEvaluator` and is not used by the supported flat instruction
stream.

`Executor.new` selects `FlatExecutor` for a flat program. It selects
`CompatibilityExecutor` only when the program has a semantic compatibility
stream. `FlatExecutor` does not include `SemanticTreeEvaluator`.
