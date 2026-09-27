# TASK-42C12 explicit gsub replacement precedence

Date: 2026-09-21. MRI: Homebrew Ruby 4.0.6, arm64-darwin25.

Source revision: `3a2aa006cb3ec06aa4c400a34e0ea836ab84a6b2` plus the accepted
TASK-42C9, TASK-42C10, and TASK-42C11 working-tree files.

Branch: `codex/task-42c12-gsub-precedence`.

Workspace: `/Users/masa/.codex/worktrees/f705/Onibi`.

Relay: `task-42c12-1a2585ad9677`; handoff SHA-256:
`b0820a51acddec33afa1c868c08261b399c437960947c3b6569eeac3715c09f3`.

## Result

`Onibi::Regexp#gsub` now uses argument presence to select the replacement
path. When the caller supplies a replacement argument, `gsub` converts it with
`StringValue`, uses native replacement expansion when supported, and does not
yield the block. This matches MRI when a replacement and a block are both
present.

When the caller omits the replacement and supplies a block, the existing native
block path remains active. When the caller omits both, the existing Onibi
`TypeError` path remains active. Explicit `nil` and invalid replacement objects
therefore do not switch to block execution.

Native replacement does not rematch through `String#gsub`. Unsupported patterns
still use the explicit MRI fallback path without yielding the block.

## Measured differential behavior

The supplied baseline reproduced the defect:

```text
MRI:    "aba".gsub(/a/, "R") { "B" }      => "RbR", no yields
Onibi:  regexp.gsub("aba", "R") { "B" }   => "BbB", two yields
```

The final direct probes matched MRI for native match, native miss, native empty
match, native multibyte input, numbered capture replacement, and explicit
`\\X` fallback. All explicit replacement probes had zero block yields. Native
diagnostics reported `rseq: true`, `fallback: 0`, and `fallback_reason: :none`.
The `\\X` probe reported `fallback: 1` and `fallback_reason: :grapheme`.

The replacement coercion probe called `to_str` once and did not call `to_s` or
the block. Explicit `nil` and `Object` replacements matched MRI `TypeError`
class, message, and zero block yields.

## Verification

Full command output is in `.task-42c12-logs/`.

| Command | Result |
| --- | --- |
| `/opt/homebrew/opt/ruby/bin/ruby -v` | exit 0; Ruby 4.0.6 recorded |
| `(cd ext/onibi && /opt/homebrew/opt/ruby/bin/ruby extconf.rb)` | exit 0 |
| `DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi warnflags='-Wall -Wextra'` | exit 0; 34 existing warnings; no new warning from `match.c` |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/matching/gsub_block_audit_test.rb` | exit 0; 11 runs, 107 assertions, zero failures/errors/skips |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { \|path\| require_relative path }' test/features/matching/scan_gsub_test.rb test/features/matching/scan_block_test.rb test/features/api/string_caller_boundary_audit_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb` | exit 0; 76 runs, 1,046 assertions, zero failures/errors/skips |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/matching/gsub_mutation_test.rb` | exit 0; 8 runs, 34 assertions, zero failures/errors/skips |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/matching/gsub_block_conversion_test.rb` | exit 0; 5 runs, 23 assertions, zero failures/errors/skips |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/matching/gsub_precedence_test.rb` | exit 0; 7 runs, 43 assertions, zero failures/errors/skips |
| Ruby syntax checks for `gsub_block_audit_test.rb`, `gsub_mutation_test.rb`, `gsub_block_conversion_test.rb`, and `gsub_precedence_test.rb` | exit 0; `Syntax OK` for each file |
| Ruby Layout checks for the four changed test files | exit 0; no offenses |
| `clang-format --dry-run --Werror ext/onibi/match.c` | exit 0 |
| `git diff --check` | exit 0 |
| `DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi distclean` | exit 0 |

The warning build reports the inherited 34 warnings in Ruby headers,
`gir.c`, `compiler.c`, `rseq.c`, `diagnostics.c`, `rseq_runtime.c`,
`exec_dynamic.c`, and `match_data.c`. No warning comes from the changed
`match.c` lines.

## Scope and limitations

Only `ext/onibi/match.c`, the precedence expectation in
`gsub_block_audit_test.rb`, this focused test, and this evidence note are new
for TASK-42C12. Accepted files remain unchanged.

Hash replacement support and missing-argument `Enumerator` behavior remain
separate debt. Result encoding adoption, native backreference limits, String
adapters, Unicode cleanup, Ractor behavior, and MatchData integration remain
outside this task.
