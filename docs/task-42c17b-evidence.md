# Native `gsub` Enumerator support

Status: `READY_FOR_REVIEW`.

`Onibi::Regexp#gsub(subject)` now returns a standard Enumerator without a block.
The Enumerator reports `size == nil`. It does not convert the subject during creation or size checks.

`onibi_gsub` calls `RETURN_ENUMERATOR` after arity and receiver checks.
It calls the macro before `StringValue(subject)`. Iteration calls the same C method with the original subject.
Supported patterns still use `onibi_vm_search`. The existing fallback boundary remains active.
Explicit `nil` remains an error. Calls with a block still return a String.

The C16B capture-range owner is unchanged. The new test checks owner lifetime during direct Enumerator suspension, resume, and abandonment.
The C16B evidence remains the proof for raw range-array release.

## Acceptance evidence

The clean warning build passed on MRI 4.0.6 with clang 21. It reported 34 inherited warnings and no warning in `match.c`.
The focused matching and API group passed: 158 runs and 2,208 assertions. It had no failures, errors, or skips.
The Enumerator test passed: 14 runs and 136 assertions. It had no failures, errors, or skips.
The caller-boundary audit passed: 10 runs and 285 assertions. It had no failures, errors, or skips.
The adapted audit passed 27 of 27 checks across 37 raw rows.
It confirmed native routing for supported patterns and one `String#gsub` call for the grapheme fallback.
It also confirmed restart after a failed feed conversion.

`bundle check`, Ruby syntax checks, `clang-format`, and `git diff --check` passed.
`make -C ext/onibi distclean` passed after the final checks.
RuboCop passed for both changed Ruby tests.
The audit keeps direct `$~` and `$1` checks. Two test-only directives disable only their style cops.
The bundle check exited 0 and printed the known frozen-lockfile message.

See the worker record for exact commands, environments, exits, raw results, hashes, and full logs:
`/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c17b-efcc50a41e66/worker/commands.md`.

## Limits

The caller-local backreference difference remains within the accepted contract.
The GC checks are smoke tests. They do not measure raw frees.
