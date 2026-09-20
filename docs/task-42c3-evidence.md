# TASK-42C3 native case equality

Date: 2026-09-21. MRI: Homebrew Ruby 4.0.6, arm64-darwin25.
Source: `6ea80fedfd75093e5d3033072b6c8b8cabc8caf6`.
Task: `01a0bf56-269d-7863-ba38-a55477e9bb45`, host `local`.
Workspace: `/Users/masa/.codex/worktrees/3c13/Onibi` (managed, detached HEAD).
Relay: `task-42c3-20260921-01`.
Handoff SHA-256: `3145748ee6c72d51a23af065b27ccaf566a312e1be34adcb4ba5cefe236abc23`.
The hash and source revision matched before changes. The worktree was clean.

## Result and contract

Native `Onibi::Regexp#===` success now returns true without calling the stored MRI regexp.
It does not construct MatchData or publish a custom object into MRI backreference storage.
Native success retains the prior MRI backreference. Native miss clears it.
Explicit fallback still calls MRI `match` and retains MRI MatchData behavior.
Non-String input still returns false and retains prior state.
These rules apply the gem boundary from `gir.md` sections 58–59 to `===`.
They do not promise MRI backreference behavior for native success.

The production change removes three lines from the native-success branch in `ext/onibi/match.c`.
The API test now checks prior-object identity under the accepted contract.
The audit guard now requires native case equality to pass while `~` still calls MRI.
These two old expectations described the removed adapter, not the accepted gem contract.
No unrelated expectation changed.

The new test compares eight Boolean results with MRI while MRI `match` raises on any call.
Cases cover literals, captures, backreferences, success, failure, empty input, and multibyte input.
Additional tests check native state, non-String state, and explicit grapheme fallback state.

## Checks

Commands ran from the workspace unless stated otherwise.

```sh
pwd
shasum -a 256 /Users/masa/.codex/relay/01a0b97a-e726-75a3-9fe0-45df485eb958/task-42c3-20260921-01/handoff.md
git rev-parse HEAD
git status --short
git worktree list
/opt/homebrew/opt/ruby/bin/ruby -v
```

From `ext/onibi`:

```sh
/opt/homebrew/opt/ruby/bin/ruby extconf.rb
```

From the workspace:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi warnflags='-Wall -Wextra'
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/api/native_case_equality_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb
clang-format --dry-run --Werror ext/onibi/match.c
/opt/homebrew/opt/ruby/bin/ruby -e 'load Gem.bin_path("rubocop", "rubocop")' -- --only Layout --force-exclusion test/features/api/native_case_equality_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/match_api_test.rb
git diff --check
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi distclean
git status --short
```

The build passed with 34 warnings in unchanged code and Ruby headers.
Warnings concern unused declarations or parameters, missing initializers, and constant range comparisons.
No warning identifies the changed branch.
Tests passed: 51 runs, 205 assertions, no failures, errors, or skips. Seed: 60734.
C formatting passed. Ruby Layout checks passed for all three files, with no offenses.
RuboCop also reported unconfigured new cops. No configuration changed.
Whitespace checks and build cleanup passed.

Two Ruby formatter discovery attempts failed before the successful command above:

```sh
/opt/homebrew/opt/ruby/bin/rubocop --version
/opt/homebrew/opt/ruby/bin/ruby -S rubocop --only Layout --force-exclusion test/features/api/native_case_equality_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/match_api_test.rb
```

The first executable was absent. The second found an rbenv shell shim, not a Ruby script.
An initial test-file write used the extension directory and failed because the relative directory was absent.
The file was then written from the workspace root. That failed write changed no file.

## Limits

No complete suite, sanitizer run, or external C consumer test was performed.
The build warnings remain outside this unit.
The known constructor and utility failures in TASK-42C2 were not tested again.
String callers, `~`, `=~`, scan/gsub state, Unicode cleanup, Ractor behavior, and MatchData accessors remain outside this unit.
No ledger, commit, remote branch, or pull request changed.
