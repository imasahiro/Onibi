# TASK-42C9 gsub block boundary audit

Date: 2026-09-21. MRI: Homebrew Ruby 4.0.6, arm64-darwin25.

Source revision: `3a2aa006cb3ec06aa4c400a34e0ea836ab84a6b2`.
Worker: `/Users/masa/.codex/worktrees/a561/Onibi`.

## Result

The audit has 11 tests and 120 assertions. It keeps MRI results beside Onibi
results. It does not change production code.

Native block behaviour matches MRI for yielded full matches, UTF-8 value and
result encodings, new result identity, empty matches, misses, raised
exceptions, `break`, non-local exit, nested native calls, and the tested
same-length byte and encoding mutations on ASCII input.

The audit records these current differences:

| Case | MRI | Onibi native | Classification |
| --- | --- | --- | --- |
| Block returns `nil` or an `Integer` | Converts with `to_s` | `StringValue` raises `TypeError` | native defect |
| Block returns an object with `to_s` and `to_str` | Uses `to_s` | Uses `to_str` | native defect |
| Replacement and block are both given | Replacement wins | Block wins | native defect |
| Block appends to a non-empty subject | Raises `RuntimeError: string modified` | Returns `"XXxx"` | mutation defect |
| Block clears a non-empty subject | Raises `RuntimeError: string modified` | Raises `ArgumentError` | mutation defect |
| Block appends during an empty match | Raises `RuntimeError: string modified` | Does not terminate before the bound | dangerous mutation defect |

The empty-match append probe runs in an isolated child. The parent kills the
child with `SIGKILL` after 0.75 seconds. The test records signal 9.

The child harness also tests three lifecycle classes. It drains stdout and
stderr, reports an ordinary exit with status 7, reports `SIGTERM` as signal
15, and reports a stalled child as a timeout followed by `SIGKILL` signal 9.
Each path reaps the child before it returns. Stderr is kept to 4 KiB.

Fallback behaviour remains explicit. `\\X` reports `fallback: 1` and
`fallback_reason: :grapheme`. Its block receives MRI `MatchData` state. Native
`(?=a)` reports `rseq: true`, `exec_kind: 1`, `fallback: 0`, and
`fallback_reason: :none`. Its diagnostic `counter_count` and `backref_count`
are present. Native block calls keep the prior MRI backreference. This is the
documented native boundary, not a hidden defect.

## Structural review

`onibi_gsub_body` searches with `onibi_vm_search`, appends the raw prefix, then
yields a new byte slice at `ext/onibi/match.c:707-710`. It coerces the block
value with `StringValue` and appends it. It then reuses `call->copied`,
`call->origin`, the raw range, `RSTRING_PTR`, and `RSTRING_LEN` at lines
720-733.

Unlike `scan`, this path has no subject snapshot or length/encoding check after
the block. A block can therefore invalidate the next raw range. The empty
match plus append case can keep advancing the subject and does not terminate.
The smallest repair target is subject mutation safety before raw range reuse.
The block-result coercion and replacement-argument differences are separate
later units. Do not apply repairs in this audit.

`rb_ensure` wraps the body at lines 779-780. The cleanup at lines 738-745 frees
the heap range storage. The exception, `break`, and `throw` checks passed. They
show that exits propagate. They do not prove that no leak occurs. The cleanup
function and its `ruby_xfree` call are structural evidence. Fallback calls
duplicate the subject and use `rb_block_call` at lines 696-700. The stored MRI
regexp is used only for this explicit fallback.

## Verification

Full command output is in `.task-42c9-logs/`.

| Command | Result |
| --- | --- |
| `/opt/homebrew/opt/ruby/bin/ruby -v` | exit 0; Ruby 4.0.6 recorded |
| `(cd ext/onibi && /opt/homebrew/opt/ruby/bin/ruby extconf.rb)` | exit 0 |
| `DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi warnflags='-Wall -Wextra'` | exit 0 |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/matching/gsub_block_audit_test.rb` | exit 0; 11 runs, 120 assertions, 0 failures, 0 errors, 0 skips |
| `/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/features/matching/scan_gsub_test.rb test/features/matching/scan_block_test.rb test/features/api/string_caller_boundary_audit_test.rb test/features/api/backreference_boundary_audit_test.rb test/features/api/native_match_routing_test.rb test/features/api/match_api_test.rb` | exit 0; 76 runs, 1,046 assertions, 0 failures, 0 errors, 0 skips |
| `/opt/homebrew/opt/ruby/bin/ruby -c test/features/matching/gsub_block_audit_test.rb` | exit 0; `Syntax OK` |
| `/opt/homebrew/opt/ruby/bin/ruby -e 'load Gem.bin_path("rubocop", "rubocop")' -- --only Layout --force-exclusion test/features/matching/gsub_block_audit_test.rb` | exit 0; no offenses |
| `git diff --check` | exit 0 |
| `DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi distclean` | exit 0 |

The warning-enabled build emitted 34 existing warnings. No warning came from
the new Ruby test. The warning groups are:

- Ruby headers: 2 unused-parameter warnings.
- `gir.c`: 2 missing-field warnings and 1 static-function warning.
- `compiler.c`: 6 missing-field warnings and 2 unused-parameter warnings.
- `rseq.c`: 1 missing-field warning and 1 unused-function warning.
- `diagnostics.c`: 8 missing-field warnings and 1 casefold warning.
- `rseq_runtime.c`: 2 tautological range warnings.
- `exec_dynamic.c`: 3 tautological range warnings.
- `match_data.c`: 5 tautological range warnings.

These warnings are in the unchanged source revision. They are listed in
`.task-42c9-logs/build-revised.txt`.
The handoff baseline names two warnings, but this exact warning-enabled
command emits 34. This audit adds no C source, so it adds no warning.

## Required next repair

Repair subject mutation safety in the native gsub block path. Use the measured
MRI rules before raw range reuse. Do not blanket-reject the tested same-length
encoding mutation because it matches MRI. Keep the existing fallback gate and
`rb_ensure` cleanup. Keep block-result coercion and replacement precedence as
separate later units.
