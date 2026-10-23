# TASK-42C10 gsub subject mutation safety

Date: 2026-09-21. MRI: Homebrew Ruby 4.0.6, arm64-darwin25.

Source revision: `3a2aa006cb3ec06aa4c400a34e0ea836ab84a6b2`.
Branch: `codex/task-42c10-gsub-mutation`.
Workspace: `/Users/masa/.codex/worktrees/0719/Onibi`.

## Result

Native `gsub` records the subject byte length before block execution. It
checks this length after the block and after block-result `to_str` conversion.
A length change raises `RuntimeError` with `string modified` before native code
uses saved ranges or subject bytes again.

The check permits same-length byte, buffer, and encoding changes. MRI permits
these changes for `gsub`. The native and MRI results match in the focused
differential tests. Multibyte encoding changes keep MRI's later encoding error.
Empty-match append is now bounded and raises `string modified`.

The existing block-result conversion remains unchanged. Native `gsub` still
uses `StringValue` and its `to_str` behavior. Replacement precedence remains
unchanged. This unit changes subject mutation safety only.

## Measured behavior

| Case | MRI and native result |
| --- | --- |
| Append or clear the subject in the block | `RuntimeError: string modified` |
| Replace the subject with a different length | `RuntimeError: string modified` |
| Append during an empty match | `RuntimeError: string modified`; no unbounded loop |
| Same-length `setbyte` or `replace` | Same output and subject bytes |
| Same-length ASCII encoding change | Same output and result encoding |
| UTF-8 multibyte match, then force BINARY | `Encoding::CompatibilityError` with the MRI message |
| Frozen subject with no mutation | Same result; subject stays frozen |
| Frozen subject mutation | `FrozenError` from the Ruby callback |
| Length mutation during native block-result `to_str` | `RuntimeError: string modified` |
| Same-length mutation during native block-result `to_str` | Preserved native conversion behavior; no range error |

The new differential test has 8 runs and 34 assertions. The repaired block
audit has 11 runs and 109 assertions. The existing scan and API regression
group has 76 runs and 1,046 assertions. All have zero failures and zero errors.

## Verification

Full command output is in `.task-42c10-logs/`.

| Command | Result |
| --- | --- |
| `/opt/homebrew/opt/ruby/bin/ruby -v` | exit 0; Ruby 4.0.6 recorded |
| `(cd ext/onibi && /opt/homebrew/opt/ruby/bin/ruby extconf.rb)` | exit 0 |
| `DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi warnflags='-Wall -Wextra'` | exit 0; 34 existing warnings; no new warning |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/matching/gsub_block_audit_test.rb` | exit 0; 11 runs, 109 assertions |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/matching/gsub_mutation_test.rb` | exit 0; 8 runs, 34 assertions |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/matching/scan_gsub_test.rb test/features/matching/scan_block_test.rb test/features/api/string_caller_boundary_audit_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb` | exit 0; 76 runs, 1,046 assertions |
| `/opt/homebrew/opt/ruby/bin/ruby -c test/features/matching/gsub_block_audit_test.rb` | exit 0; `Syntax OK` |
| `/opt/homebrew/opt/ruby/bin/ruby -c test/features/matching/gsub_mutation_test.rb` | exit 0; `Syntax OK` |
| `/opt/homebrew/opt/ruby/bin/ruby -e 'load Gem.bin_path("rubocop", "rubocop")' -- --only Layout --force-exclusion test/features/matching/gsub_block_audit_test.rb` | exit 0; no offenses |
| `/opt/homebrew/opt/ruby/bin/ruby -e 'load Gem.bin_path("rubocop", "rubocop")' -- --only Layout --force-exclusion test/features/matching/gsub_mutation_test.rb` | exit 0; no offenses |
| `clang-format --dry-run --Werror ext/onibi/match.c` | exit 0 |
| `git diff --check` | exit 0; new files also have no trailing whitespace |
| `DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi distclean` | exit 0 |

The 34 build warnings are unchanged warnings in Ruby headers, `gir.c`,
`compiler.c`, `rseq.c`, `diagnostics.c`, `rseq_runtime.c`, `exec_dynamic.c`,
and `match_data.c`. The changed `match.c` code adds no warning.

## Scope limits

This unit changes `ext/onibi/match.c`, mutation expectations in the gsub block
audit, this evidence note, and the new mutation test. It does not change the
execution class, fallback routing, block-result conversion rules, replacement
precedence, scan behavior, String adapters, backreferences, Unicode helpers,
Ractor behavior, MatchData integration, or the execution ledger.
