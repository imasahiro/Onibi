# TASK-42C7 scan block support

Date: 2026-09-21. MRI: Homebrew Ruby 4.0.6, arm64-darwin25.
Source: `b84fde63626b3798a8f53ef37749d809496d95c8`.
Task: `01a0bf68-94a0-7633-b230-d02c78c8ce9d`. Host: `local`.
Workspace: `/Users/masa/.codex/worktrees/f415/Onibi` (managed, detached HEAD).
Relay: `task-42c7-20260921-01`.
Handoff SHA-256: `45f3943c0400adc4740bcb3831a56f9ea8ade0435cb203b6adbf95d6659d2f87`.
Handoff: `/Users/masa/.codex/relay/01a0b97a-e726-75a3-9fe0-45df485eb958/task-42c7-20260921-01/handoff.md`.

The hash and source revision matched before edits. The worktree was clean.
The source branch `codex/task-53-module-interfaces` pointed to this revision.
The contract uses `gir.md` sections 56–58 and the saved handoff.

## Result

Native scan yields a whole-match String when the pattern has no captures.
It yields one capture Array when the pattern has captures. Unmatched captures remain nil.
A normal block scan returns the original subject String, including empty subjects and misses.
The `to_str` path returns the converted String object.
Empty matches retain the encoded-character advance.
The existing input fallback still handles the empty pattern on multibyte input.

Explicit fallback calls String scan on the original subject and forwards each value through a C callback.
Both paths use the same subject check after each normal block return.
The no-block path retains its array result and existing fallback behavior.
Native scan preserves the existing MRI backreference boundary.
Fallback blocks see MRI MatchData. No native MatchData enters MRI backreference storage.
The existing boundary tests now require block values and original-object return.
Their no-block and backreference checks remain in place.

## Mutation and cleanup

Block scan holds a frozen subject snapshot in its stack call record.
After each yield, it compares length and encoding with the snapshot.
MRI permits same-length byte changes, and Onibi keeps that behavior.
Length or encoding changes raise RuntimeError with `string modified` before any further range use or character advance.
This check also runs after the final match and inside fallback callbacks.

The native and fallback paths match MRI for tested same-length `replace("zz")` and `setbyte` edits.
They reject length and encoding changes because those changes can invalidate raw ranges or character stepping.
A write that restores the original length and encoding before return is not detected.
The check does not track every write operation.

The existing `rb_ensure` owns the scan range allocation.
Snapshot creation and all yields run inside that protected body.
The cleanup function frees the allocation on success, mutation errors, block exceptions, break, and throw.
Each VM search releases its execution context before returning a match or fallback.
The tests repeat block exceptions, break, and throw, then run scan again.
They also check nested scans, GC, heap subjects, and GC compaction.
These checks and source inspection support cleanup; they do not measure allocator balances directly.

## Exact verification

Commands ran from the workspace unless a directory is stated.

```sh
pwd
git rev-parse HEAD
git status --short
shasum -a 256 /Users/masa/.codex/relay/01a0b97a-e726-75a3-9fe0-45df485eb958/task-42c7-20260921-01/handoff.md
printenv CODEX_THREAD_ID
git worktree list
git rev-parse codex/task-53-module-interfaces
/opt/homebrew/opt/ruby/bin/ruby -v
```

From `ext/onibi`:

```sh
/opt/homebrew/opt/ruby/bin/ruby extconf.rb
```

From the workspace:

```sh
clang-format -i ext/onibi/match.c
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi clean
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi warnflags='-Wall -Wextra' > /tmp/task-42c7-build.log 2>&1
rg 'warning:' /tmp/task-42c7-build.log | wc -l
rg -n 'match.c|error:' /tmp/task-42c7-build.log
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/matching/scan_block_test.rb test/features/matching/scan_gsub_test.rb test/features/api/string_caller_boundary_audit_test.rb test/features/api/backreference_boundary_audit_test.rb
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/matching/scan_block_test.rb test/features/matching/scan_gsub_test.rb test/features/api/string_caller_boundary_audit_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_operator_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb
clang-format --dry-run --Werror ext/onibi/match.c
/opt/homebrew/opt/ruby/bin/ruby -e 'load Gem.bin_path("rubocop", "rubocop")' -- --only Layout --force-exclusion test/features/matching/scan_block_test.rb test/features/api/string_caller_boundary_audit_test.rb test/features/api/backreference_boundary_audit_test.rb > /tmp/task-42c7-rubocop.log 2>&1
/opt/homebrew/opt/ruby/bin/ruby -c test/features/matching/scan_block_test.rb
/opt/homebrew/opt/ruby/bin/ruby -c test/features/api/string_caller_boundary_audit_test.rb
/opt/homebrew/opt/ruby/bin/ruby -c test/features/api/backreference_boundary_audit_test.rb
git diff --check
git diff --no-index --check /dev/null docs/task-42c7-evidence.md
git diff --no-index --check /dev/null test/features/matching/scan_block_test.rb
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi distclean
git status --short
```

The warning-enabled build passed. It reported 34 warnings in unchanged code and Ruby headers.
No warning or error referenced `match.c`.
The four-file run passed: 34 runs, 929 assertions, no failures, errors, or skips. Seed: 46895.
Three further tests added heap, coercion, and compaction coverage before the combined run.
The combined run passed: 79 runs, 1129 assertions, no failures, errors, or skips. Seed: 21655.
C formatting, Ruby syntax, and Ruby Layout checks passed.
RuboCop also reported unconfigured new cops.
Whitespace checks and build cleanup passed.
The no-index checks emitted no whitespace errors. Their status is 1 because each file differs from `/dev/null`.

The first test run found a missing block flag in the call initializer.
The next run exposed the difference in MRI same-length mutation behavior.
The repair narrowed the check to length and encoding, and the differential tests then passed.
An initial `ruby extconf.rb` command ran from the repository root and failed with LoadError.
The same command then passed from `ext/onibi`.
A clean rebuild was required after edits because the generated build did not detect changes to the included C file.

## Limits

No complete suite, sanitizer run, or allocator-balance instrumentation ran.
The existing 34 build warnings remain.
Length and encoding changes raise `string modified`; same-length byte changes match MRI in the tested cases.
No gsub implementation, String adapter, Unicode cleanup, Ractor behavior, or MatchData implementation changed.
No ledger edit, commit, push, pull request, or merge occurred.
The parent task must review and integrate these uncommitted worktree changes.
