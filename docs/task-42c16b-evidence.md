# TASK-42C16B: scan and gsub capture-array lifetime

Status: `READY_FOR_REVIEW`. The worktree changes are uncommitted.

## Change

`OnibiScanCall` and `OnibiGsubCall` now hold a private TypedData owner.
The owner stores the checked capture-range pointer and byte count.
Its `dfree` callback and both `rb_ensure` handlers use one release helper.
The helper clears its fields before it frees the range array.
The owner reports its struct and payload sizes through `dsize`.
The type has no Ruby references and has no GC flags.
Both call sites keep the owner live with `RB_GC_GUARD` after `rb_ensure`.

The tests compare scan and gsub output with MRI.
They cover blocks, Hash callbacks, errors, throws, suspension, resume, and abandonment.
They also cover external Enumerators, capture widths, nested calls, and fallback boundaries.
The tests check the private owner after GC without holding a strong owner reference.

## Acceptance evidence

MRI 4.0.6 and clang 21.0.0 ran these checks on 2026-09-24.
The command records include exact arguments, environment, working directory, exit status, and logs.

| Check | Result |
| --- | --- |
| `ruby extconf.rb` from `ext/onibi` | Passed |
| `make -C ext/onibi warnflags=-Wall -Wextra` | Passed; 34 inherited warnings; none in `match.c` |
| Focused matching and API group, including the new test | 144 runs; 2,072 assertions; no failures, errors, or skips |
| `bundle check` | Passed |
| RuboCop on `capture_range_lifetime_test.rb` | Passed; no offenses |
| `clang-format --dry-run --Werror ext/onibi/match.c` | Passed |
| `ruby -c test/features/matching/capture_range_lifetime_test.rb` | Passed |
| `git diff --check` | Passed with the new test included |
| `make -C ext/onibi distclean` | Passed for both build trees |

The focused group used these test files:

```text
test/features/matching/gsub_precedence_test.rb
test/features/matching/gsub_block_conversion_test.rb
test/features/matching/gsub_block_audit_test.rb
test/features/matching/gsub_mutation_test.rb
test/features/matching/gsub_encoding_test.rb
test/features/matching/gsub_replacement_encoding_test.rb
test/features/matching/scan_gsub_test.rb
test/features/matching/scan_block_test.rb
test/features/matching/gsub_hash_test.rb
test/features/matching/capture_range_lifetime_test.rb
test/features/api/string_caller_boundary_audit_test.rb
test/features/api/backreference_boundary_audit_test.rb
test/features/api/native_match_routing_test.rb
test/features/api/match_api_test.rb
```

## Raw allocation evidence

The copied instrumented build used the final `match.c` hash in `identity.json`.
It logged range arrays and TypedData owner blocks as separate allocations.
Each free event follows the matching `ruby_xfree` call.

All 34 scenarios passed.
The build made 39 range arrays and freed all 39 by matching address and size.
It made 39 owner blocks and freed all 39 by matching address and size.
All six abandoned Fibers or Enumerators freed both allocations through `dfree`.
Twelve suspended calls had no free event while they remained live.
The matrix checked native routing, sizes, addresses, and release paths.
It covered zero, one, two, and three captures, repeated matches, and nested owners.

## Limits and records

The raw-free check used a copied build on MRI 4.0.6 and Apple arm64.
It does not measure RSS or general allocator state.
The private `ObjectSpace` test checks owner reachability and `dsize` byte accounting.
The separate copied-build log proves raw allocation release.

See `/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c16b-e405850442cf/worker/commands.jsonl` for exact commands and logs.
See `/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c16b-e405850442cf/worker/instrumented-owner-final/matrix-results.json` for all probe rows.
See `/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c16b-e405850442cf/worker/instrumented-owner-final/instrumentation.diff` for copied-build instrumentation.
See `/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c16b-e405850442cf/worker/instrumented-owner-final/identity.json` for source and library hashes.
