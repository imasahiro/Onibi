# TASK-42C6 String caller boundary audit

Date: 2026-09-21. MRI: Homebrew Ruby 4.0.6, arm64-darwin25.
Source: `10a7567deca85aee5996c1b36f89064b19514357`.
Task: `01a0bf62-2973-7032-9a2f-6a23d9482992`. Host: `local`.
Workspace: `/Users/masa/.codex/worktrees/0afe/Onibi` (managed, detached HEAD).
Relay: `task-42c6-20260921-01`.
Handoff SHA-256: `d71a2c00ddef0e2e59455d24722b740ba37c0d467219fb8cfe23f3d8aa445428`.

The hash and source revision matched before work. The worktree was clean.
The source branch `codex/task-53-module-interfaces` pointed to this revision.
The contract is `gir.md` sections 58–59 and `task-42c5-evidence.md`.
Only this evidence file and the new boundary test changed.

## String callers

| Caller with Onibi::Regexp | Current result | MRI backreference state |
| --- | --- | --- |
| `String#=~`, native success | Character position; matches MRI for tested input | Keeps the same prior MRI MatchData object |
| `String#=~`, native miss | nil | Clears `$~` |
| `String#=~`, explicit fallback | MRI position or nil | Publishes MRI MatchData, or clears on miss |
| `String#match`, `match?`, `scan`, `split`, `[]`, `sub`, `gsub` | TypeError for native and fallback patterns | Keeps the same prior MRI MatchData object |

MRI delegates String `=~` to the custom operator. No String adapter is needed for this call.
The other tested String methods do not accept this custom regexp type.
Tests also check `Onibi::Regexp.last_match` identity and retained numbered captures after rejection.
These errors record the current boundary. They do not define future support.

## Onibi scan and gsub

| Path | Values and block behavior | MRI backreference state |
| --- | --- | --- |
| Native scan | Matches MRI arrays for tested captures, unmatched captures, empty matches, and misses | Keeps prior object on success and miss |
| Native scan with block | Ignores block; returns the array | Keeps prior object |
| Fallback scan, with or without block | Matches MRI arrays; ignores block | Publishes MRI MatchData; clears on miss |
| Native gsub with plain replacement | Matches MRI strings for tested patterns | Keeps prior object on success and miss |
| Native gsub with block | Yields full match strings; matches tested MRI output | Block sees prior object; call keeps it when block leaves it unchanged |
| Gsub with backslash replacement | Calls MRI even for otherwise native patterns | Publishes MRI MatchData; clears on miss |
| Fallback gsub with block | Forwards block; matches tested MRI output | Block sees current MRI MatchData and captures |
| Gsub without replacement or block | TypeError; MRI String gsub returns an Enumerator | Keeps prior object |

Native empty-match cases use ASCII input and include an empty capture on an empty subject.
The empty pattern on `éあ` uses input fallback. Its scan and gsub results match MRI.
Explicit pattern fallback uses `\X` and `(\X)`, including empty input.
Replacement cases cover `\1`, `\&`, `\k<letter>`, escaped backslash, and `\q`.
All these backslash cases call MRI, including replacements without a capture reference.
The native block result is a new String in the tested cases.
The native scan and plain gsub guard test rejects calls to String scan or gsub.

No tested path publishes native Onibi::MatchData to MRI backreference storage.
Fallback state contains MRI MatchData. Native paths retain the prior MRI object.
This statement covers the tested paths and source inspection; it is not a complete memory-safety proof.

## C inspection

`ext/onibi/match.c` selects unsupported-pattern and input fallback before executor entry.
`onibi_scan_body` reads raw whole-match ranges and capture arrays.
It copies slices into Ruby strings and arrays. Unmatched captures become nil.
`onibi_scan` frees its range allocation through `rb_ensure`.
The scan loop has no yield. Its fallback duplicates the subject and calls String scan with the stored MRI regexp.
It uses `rb_funcall`, so it does not forward the caller block.

`onibi_gsub` reads raw whole-match ranges without requesting capture arrays.
It copies unchanged bytes and replacement bytes into a new result buffer.
Its native block receives a copied full-match slice.
A replacement containing any backslash enters the MRI adapter before native search.
The source comment still describes this adapter as necessary until Onibi owns MatchData.
Native MatchData now exists, but native replacement expansion remains absent.
Execution fallback duplicates the subject and passes the stored MRI regexp to String gsub.
The fallback uses `rb_block_call` when a block is present.

Both native loops advance nonempty matches to the raw end position.
For empty matches, they advance one encoded character, or stop at the subject end.
Neither loop constructs native MatchData or calls `rb_backref_set`.
The setters elsewhere in this file only store nil for operator misses or nil input.
No custom MatchData enters an `RMATCH_REGS` consumer in these inspected paths.

## Smallest next unit

Implement Onibi scan block behavior in C as one focused unit.
Yield each native string or capture array. Return the original subject object when a block is given.
Forward the block on explicit fallback and preserve original-subject return identity.
Retain the accepted native backreference boundary; never store custom MatchData in MRI state.
Test captures, empty matches, misses, fallback, block exceptions, and subject mutation.
Subject mutation needs an explicit rule before block execution can safely reuse raw ranges.
Do not add String adapters in that unit.
Native replacement expansion is a separate later unit.

## Verification

Commands ran from the workspace unless a directory is stated.

```sh
pwd
shasum -a 256 /Users/masa/.codex/relay/01a0b97a-e726-75a3-9fe0-45df485eb958/task-42c6-20260921-01/handoff.md
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
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi warnflags='-Wall -Wextra' > /tmp/task-42c6-build.log 2>&1
rg -n 'warning:' /tmp/task-42c6-build.log | wc -l
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/api/string_caller_boundary_audit_test.rb
/opt/homebrew/opt/ruby/bin/ruby -e 'load Gem.bin_path("rubocop", "rubocop")' -- --only Layout --force-exclusion test/features/api/string_caller_boundary_audit_test.rb > /tmp/task-42c6-rubocop.log 2>&1
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/api/string_caller_boundary_audit_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_operator_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb
/opt/homebrew/opt/ruby/bin/ruby -c test/features/api/string_caller_boundary_audit_test.rb
git diff --check
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi distclean
git status --short
```

The build passed with 34 warnings in unchanged code and Ruby headers.
The final audit run passed: 10 runs, 314 assertions, no failures, errors, or skips. Seed: 54208.
The combined run passed: 61 runs, 552 assertions, no failures, errors, or skips. Seed: 18662.
Ruby syntax and Layout checks passed. RuboCop reported unconfigured new cops.
Whitespace checks and build cleanup passed.

The first audit run had five failures and one error across nine tests.
Three failures used `assert_same` with nil, which this Minitest version rejects.
Two failures and the guard error exposed input fallback for an empty pattern on multibyte input.
The final tests separate that fallback from native ASCII empty matches.
No existing expectations changed. The final tests retain the discovered fallback boundary.
Temporary console probes confirmed scan block suppression and gsub replacement state.
All acceptance cases are repeatable in the new test file.

## Limits

No production source, ledger, or existing test changed.
No commit, push, pull request, or merge occurred.
No complete suite, sanitizer run, mutation stress test, or full replacement grammar audit ran.
Existing compiler warnings remain. Block exceptions and subject mutation need further checks before scan block implementation.
Native gsub replacement coercion, hash replacements, and replacement-plus-block precedence remain outside this audit.

The two new files also passed explicit whitespace inspection:

```sh
git diff --no-index --check /dev/null docs/task-42c6-evidence.md
git diff --no-index --check /dev/null test/features/api/string_caller_boundary_audit_test.rb
git diff --exit-code
```

Both no-index checks emitted no whitespace errors. They returned 1 because each file differs from `/dev/null`.
The tracked-file diff returned 0. Final status contained only the two requested new files.
