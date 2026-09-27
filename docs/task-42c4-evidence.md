# TASK-42C4 native tilde

Date: 2026-09-21. MRI: Homebrew Ruby 4.0.6, arm64-darwin25.
Source: `87eed8334ec50df26448169397cbc51dd59d4965`.
Task: `01a0bf59-eca2-7b11-b742-111f4850e43c`, host `local`.
Workspace: `/Users/masa/.codex/worktrees/bb20/Onibi` (managed, detached HEAD).
Relay: `task-42c4-20260921-01`.
Handoff SHA-256: `17ccbfeeec441651247576dea46e98e9b4047020ac237ce5cdc6db0c53854671`.
The hash and source revision matched before changes. The worktree was clean.

## Result and contract

Native `Onibi::Regexp#~` success returns the character position from the raw match range.
It no longer calls the stored MRI regexp. It does not construct or publish MatchData.
Native success retains the prior MRI backreference. Native miss clears it.
Explicit fallback retains MRI MatchData and backreference behavior.
Non-String `$_`, including nil, returns nil and retains prior state.
These rules apply the gem boundary in `gir.md` sections 58–59 to `~`.

The production change removes three lines from the native-success branch.
The boundary audit now requires native `~` to pass while MRI `Regexp#match` raises.
Its previous exception expectation described the removed adapter.
New tests compare eight native results with MRI under that guard.
They cover literals, captures, backreferences, success, miss, empty input, and multibyte input.
Separate tests check prior-object identity, miss cleanup, non-String state, and explicit grapheme fallback.

## Checks

Commands ran from the workspace unless stated otherwise.

```sh
pwd
shasum -a 256 /Users/masa/.codex/relay/01a0b97a-e726-75a3-9fe0-45df485eb958/task-42c4-20260921-01/handoff.md
git rev-parse HEAD
git status --short
printenv CODEX_THREAD_ID
git worktree list
/opt/homebrew/opt/ruby/bin/ruby -v
```

From `ext/onibi`:

```sh
/opt/homebrew/opt/ruby/bin/ruby extconf.rb
```

From the workspace:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi warnflags='-Wall -Wextra' > /tmp/task-42c4-build.log 2>&1
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/api/native_tilde_test.rb test/features/api/native_case_equality_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb
clang-format --dry-run --Werror ext/onibi/match.c
/opt/homebrew/opt/ruby/bin/ruby -e 'load Gem.bin_path("rubocop", "rubocop")' -- --only Layout --force-exclusion test/features/api/native_tilde_test.rb test/features/api/backreference_boundary_audit_test.rb > /tmp/task-42c4-rubocop.log 2>&1
git diff --check
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi distclean
git status --short
```

The build passed with 34 warnings in unchanged code and Ruby headers.
No warning identifies the changed branch.
Final tests passed: 55 runs, 245 assertions, no failures, errors, or skips. Seed: 3834.
C formatting passed. Ruby Layout checks passed for both files, with no offenses.
RuboCop also reported unconfigured new cops. No configuration changed.
Whitespace checks and build cleanup passed.

The first test run included an exploratory ninth case: `a\Kb` against `あab`.
It failed: MRI `~` returned 1; Onibi returned 2.
That run had 55 runs, 246 assertions, one failure, no errors, and no skips. Seed: 21201.
The source revision already returned the raw begin position after the MRI adapter call.
This task explicitly preserves that return calculation.
The exploratory case was removed from the new differential test and recorded here as a limit.
No pre-existing position assertion changed.
Formatting and whitespace checks passed before and after this test adjustment.

## Limits

The existing `\K` position difference remains outside this routing unit.
No complete suite, sanitizer run, or external C consumer test was performed.
The 34 build warnings remain outside this unit.
No ledger, commit, remote branch, or pull request changed.
`=~`, String callers, scan/gsub state, Unicode cleanup, Ractor behavior, and MatchData accessors remain outside this unit.
