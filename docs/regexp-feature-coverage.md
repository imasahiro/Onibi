# Regexp syntax coverage for the compiler pipeline

This document records syntax cases covered by parser, compiler, automata, and
IR-generation tests. The current milestone covers compiler representations.

## Covered pipeline features

| Feature | Parser | CFG | TNFA/DFA | Bytecode |
| --- | --- | --- | --- | --- |
| Literal | yes | yes | yes | yes |
| Character class | yes | yes | yes | yes |
| Choice | yes | yes | yes | yes |
| Capture | yes | yes | tagged states | capture instructions |
| Greedy and lazy repeat | yes | yes | yes | yes |
| Possessive repeat | yes | yes | yes | yes |
| Atomic group | yes | yes | tagged control | yes |
| Anchors and assertions | yes | yes | semantic regions | assertion opcodes |
| Named groups and calls | yes | yes | semantic effects | semantic opcodes |

Each feature has focused tests under `test/features/v2/`. Tests compare full
intermediate objects and full generated instruction order. The comparator
ignores only unstable byte offsets.

## Scope

The current milestone verifies compiler representation and dedicated-bytecode
generation. MRI integration and public API compatibility are later milestones.
