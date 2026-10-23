# TASK-42C5 native match operator

Date: 2026-09-21. MRI: Homebrew Ruby 4.0.6, arm64-darwin25.
Source: `21f501c528cf620501c403ef6a2e0a66ee84e481`.
Task: `01a0bf5d-d8f9-7323-ba64-65cbd69d9c6a`, host `local`.
Workspace: `/Users/masa/.codex/worktrees/7961/Onibi` (managed, detached HEAD).
Relay: `task-42c5-20260921-01`.
Handoff SHA-256: `0ac17f7bedcf822288eb669ecfee2cd5a928d72702716ffcd36153ec5804e895`.
The hash and source revision matched before changes. The worktree was clean.

## Result

The private C function `onibi_match_operator` implements `Onibi::Regexp#=~`.
Native success returns the character position from the raw begin range.
It preserves the prior MRI backreference. It does not construct native MatchData or rematch with MRI.
Native miss and nil input clear MRI backreference state and return nil.
Symbols convert to strings. Other inputs use `to_str` conversion or raise TypeError.
Explicit fallback calls `rb_reg_match` with the stored MRI regexp.
This preserves MRI positions, MatchData, and backreferences, including fallback `\K` positions.

The boundary audit now expects positions from `regexp =~ string` and `string =~ regexp`.
MRI automatically delegates the latter call to the new operator.
No String implementation changed. Other String boundary checks remain unchanged.
These assertions replace the previous missing-method expectations.

## Verification

Commands ran from the workspace unless stated otherwise.

```sh
pwd
shasum -a 256 /Users/masa/.codex/relay/01a0b97a-e726-75a3-9fe0-45df485eb958/task-42c5-20260921-01/handoff.md
git rev-parse HEAD
git status --short
printenv CODEX_THREAD_ID
git worktree list
/opt/homebrew/opt/ruby/bin/ruby -v
/opt/homebrew/opt/ruby/bin/ruby -e '/prior/.match("prior"); p(/a/ =~ nil); p $~'
```

The MRI nil probe returned nil and cleared `$~`.
From `ext/onibi`:

```sh
/opt/homebrew/opt/ruby/bin/ruby extconf.rb
```

From the workspace:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi warnflags='-Wall -Wextra' > /tmp/task-42c5-build.log 2>&1
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/api/native_match_operator_test.rb test/features/api/native_tilde_test.rb test/features/api/native_case_equality_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb
clang-format --dry-run --Werror ext/onibi/match.c ext/onibi/onibi_init.c ext/onibi/onibi_ruby_api_internal.h
/opt/homebrew/opt/ruby/bin/ruby -e 'load Gem.bin_path("rubocop", "rubocop")' -- --only Layout --force-exclusion test/features/api/native_match_operator_test.rb test/features/api/backreference_boundary_audit_test.rb > /tmp/task-42c5-rubocop.log 2>&1
git diff --check
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi distclean
git status --short
```

The build passed with 34 warnings in unchanged code and Ruby headers.
Tests passed: 59 runs, 314 assertions, no failures, errors, or skips. Seed: 25652.
Tests cover native positions, MRI method guards, result publication, backreference identity, coercion, and explicit fallback.
C formatting passed. Ruby Layout checks passed for both files, with no offenses.
RuboCop also reported unconfigured new cops. No configuration changed.
Whitespace checks and build cleanup passed.

## Limits

Native `\K` uses the raw begin range, as required by this unit.
The known raw-range versus MRI operator position difference remains outside this unit.
No complete suite, sanitizer run, or external C consumer test was performed.
The 34 existing build warnings remain outside this unit.
No ledger, commit, remote branch, or pull request changed.
