# TASK-42C1 evidence

## Scope

This unit routes supported native `Onibi::Regexp#match` results to
`Onibi::MatchData`.

The native VM selects the match. The constructor copies the exact raw byte
ranges before the search frame ends. The supported branch does not call the
source MRI regexp and does not call `rb_backref_set` with the custom object.

Explicit fallback keeps the source MRI regexp adapter. `match?`, `scan`,
`gsub`, `===`, `~`, String callers, and Ractor behavior remain outside this
unit.

## Handoff identity

- Relay: `task-42c1-20260920-01`
- Handoff path: `/Users/masa/.codex/relay/01a0b97a-e726-75a3-9fe0-45df485eb958/task-42c1-20260920-01/handoff.md`
- Handoff SHA-256: `fa1a47c2a13a7f5c503b5f365bcb5df1357d6861621bbdcb29719218ab2c404f`
- Origin task: `01a0b97a-e726-75a3-9fe0-45df485eb958`
- Source revision: `b08a67c6b891e41dce90bc06b5b495c3cc912c91`
- Worktree: `/Users/masa/.codex/worktrees/6b26/Onibi`
- Branch: `codex/task-42c1-native-match-routing`

## MRI and native reproduction

Ruby is MRI `4.0.6`.

The pre-change native path selected raw ranges, then called the source
regexp. A supported literal returned MRI `MatchData` and changed `$~`.

The post-change probes showed:

| Pattern and input | Native result | Raw ranges | Backreference result |
| --- | --- | --- | --- |
| `(?<letter>a)(?<tail>b)?`, `a` | `Onibi::MatchData` | `[[0, 1], [0, 1], [-1, -1]]` | Previous MRI `$~` stayed unchanged |
| `é`, `xéy` | `Onibi::MatchData` | Group zero `[1, 3]` bytes | Previous MRI `$~` stayed unchanged |
| `a`, `ba`, position `-2` | `Onibi::MatchData` at character offset `1` | Group zero `[1, 2]` bytes | Previous MRI `$~` stayed unchanged |
| `\X`, `a` | MRI `MatchData` | Explicit `:grapheme` fallback | MRI fallback behavior stayed active |

The focused guard replaces `::Regexp#match` with an exception. Supported
native calls pass the guard. The fallback test returns MRI `MatchData`.

## Checks

The build uses the Command Line Tools path because the default Xcode wrapper
requires an unaccepted local license.

| Command | Result |
| --- | --- |
| `ruby -v` | 0; MRI 4.0.6 |
| `(cd ext/onibi && DEVELOPER_DIR=/Library/Developer/CommandLineTools ruby extconf.rb && DEVELOPER_DIR=/Library/Developer/CommandLineTools make)` | 0; two known warnings: `onibi_c_ast_has_capture` and `onibi_rseq_mark_unsupported` |
| `ruby -Ilib -Itest test/features/api/match_api_test.rb` | 0; 37 runs, 110 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Ilib -Itest test/features/api/native_match_routing_test.rb` | 0; 3 runs, 10 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Ilib -Itest -e 'ARGV.each { \|f\| require_relative f }' test/features/captures/match_data_copy_deconstruct_test.rb test/features/captures/match_data_value_semantics_test.rb test/features/captures/match_data_character_offsets_test.rb test/features/captures/match_data_byte_offsets_test.rb test/features/captures/match_data_named_test.rb test/features/captures/match_data_numeric_test.rb test/features/captures/match_data_payload_test.rb test/features/captures/match_data_contract_test.rb test/features/api/regexp_metadata_isolation_test.rb test/features/quality/module_interface_contract_test.rb` | 0; 54 runs, 690 assertions, 0 failures, 0 errors, 0 skips |
| `bundle exec rubocop test/features/api/match_api_test.rb test/features/api/native_match_routing_test.rb test/features/quality/module_interface_contract_test.rb` | 0; no offenses |
| `clang-format --dry-run --Werror ext/onibi/rseq.c` | 0 |
| `git diff --check` | 0 |
| `(cd ext/onibi && DEVELOPER_DIR=/Library/Developer/CommandLineTools make distclean)` | 0 |

## Limits

`Onibi::MatchData` is not an MRI `MatchData`. It does not update MRI VM-local
backreferences. The separate C2 audit covers other backreference callers.

The custom object does not implement the later `match` and `values_at`
accessors. Those APIs remain outside this routing unit.
