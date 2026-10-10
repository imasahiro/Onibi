# TASK-42C11 native gsub block-result conversion

Date: 2026-09-21. MRI: Homebrew Ruby 4.0.6, arm64-darwin25.

Source revision: `3a2aa006cb3ec06aa4c400a34e0ea836ab84a6b2`.
Branch: `codex/task-42c11-gsub-conversion`.
Workspace: `/Users/masa/.codex/worktrees/97a6/Onibi`.

## Result

Native `gsub` now converts a block result with `rb_obj_as_string`. This uses
the MRI `to_s` rules. It does not use `to_str`.

The conversion now has these measured results:

| Block result | Native result |
| --- | --- |
| `nil` | Empty text |
| Integer or `false` | `to_s` text |
| Object with only `to_s` | `to_s` text |
| Object with `to_s` and `to_str` | `to_s` text; `to_str` is not called |
| String subclass | Original string bytes |
| `to_s` result that is not a String | MRI object text fallback |
| Raised `to_s` exception | Same exception |

The native path calls the conversion before the subject-length check. This
matches MRI when the block or `to_s` callback changes the subject. A conversion
exception wins over `string modified`. A successful conversion still raises
`RuntimeError: string modified` before native raw ranges are reused.

The accepted length guard remains in place. Same-length byte and encoding
changes remain allowed. The fallback gate, replacement routing, cleanup, and
raw-range ownership are unchanged.

## Verification

Full command output is in `.task-42c11-logs/`.

| Command | Result |
| --- | --- |
| `/opt/homebrew/opt/ruby/bin/ruby -v` | exit 0; Ruby 4.0.6 recorded |
| `(cd ext/onibi && /opt/homebrew/opt/ruby/bin/ruby extconf.rb)` | exit 0 |
| `DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi warnflags='-Wall -Wextra'` | exit 0; 34 existing warnings; no warning from changed `match.c` |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/matching/gsub_block_conversion_test.rb` | exit 0; 5 runs, 23 assertions, zero failures/errors/skips |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/matching/gsub_block_audit_test.rb` | exit 0; 11 runs, 103 assertions, zero failures/errors/skips |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/matching/gsub_mutation_test.rb` | exit 0; 8 runs, 34 assertions, zero failures/errors/skips |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/matching/scan_gsub_test.rb test/features/matching/scan_block_test.rb test/features/api/string_caller_boundary_audit_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb` | exit 0; 76 runs, 1,046 assertions, zero failures/errors/skips |
| Ruby syntax checks for the three changed test files | exit 0; `Syntax OK` for each file |
| Ruby Layout checks for the three changed test files | exit 0; no offenses |
| `clang-format --dry-run --Werror ext/onibi/match.c` | exit 0 |
| `git diff --check` | exit 0 |
| `DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi distclean` | exit 0 |

The warning build emits the same 34 warnings as the inherited source. They are
in Ruby headers, `gir.c`, `compiler.c`, `rseq.c`, `diagnostics.c`,
`rseq_runtime.c`, `exec_dynamic.c`, and `match_data.c`.

Direct MRI probes cover conversion method selection, callback ordering, native
execution, fallback execution, raw bytes, and encodings. Diagnostics report
native `rseq: true` and fallback `:grapheme` for the tested patterns.

## Encoding limitation

In the worker probe with different subject and returned String encodings, MRI
adopted the returned String encoding. Native `gsub` kept the subject encoding.
The returned bytes match in the probe. This is a separate encoding task and is
not changed here.

Replacement-plus-block precedence remains a known separate defect. No ledger
or accepted evidence file was changed.
