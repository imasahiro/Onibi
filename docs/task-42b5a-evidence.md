# TASK-42B5A evidence

The unit adds native `bytebegin`, `byteend`, and `byteoffset` methods to
`Onibi::MatchData`.

The methods read the retained raw byte registers. They do not rescan the
subject or convert byte positions to character positions. Numeric selectors
use MRI integer coercion and reject negative or out-of-range indexes with the
MRI error class and message. String and Symbol selectors use the ordered named
capture metadata. An unknown name raises `IndexError`. A known name with no
participating capture returns `nil` or `[nil, nil]`.

The source workspace is `/Users/masa/.codex/worktrees/7c0c/Onibi` at source
revision `2db70f97837c0938031298d89da2c2821407b24d`.

## Checks

The checks used MRI 4.0.6 and the Command Line Tools SDK.

```text
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
```

| Command | Status | Result |
| --- | ---: | --- |
| `ruby -v` | 0 | MRI 4.0.6 |
| `(cd ext/onibi && make distclean)` before build | 0 | clean |
| `(cd ext/onibi && ruby extconf.rb && make)` | 0 | build passed; two existing warnings only |
| `ruby -Ilib -Itest test/features/captures/match_data_byte_offsets_test.rb` | 0 | 5 runs, 139 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Ilib -Itest -e 'ARGV.each { |f| require_relative f }' test/features/captures/match_data_named_test.rb test/features/captures/match_data_numeric_test.rb test/features/captures/match_data_payload_test.rb test/features/captures/match_data_contract_test.rb test/features/api/regexp_metadata_isolation_test.rb test/features/quality/module_interface_contract_test.rb` | 0 | 35 runs, 429 assertions, 0 failures, 0 errors, 0 skips |
| `bundle exec rubocop test/features/captures/match_data_byte_offsets_test.rb` | 0 | 1 file, no offenses |
| `git diff --check` | 0 | clean |
| `(cd ext/onibi && make distclean)` after checks | 0 | clean |

The build warnings are the existing `onibi_c_ast_has_capture` and
`onibi_rseq_mark_unsupported` warnings. No new warning was added.

The full command output is in `.task-42b5a-logs/checks.txt`.

## Limits

Character offsets and other `MatchData` accessors remain outside this unit.
Public `Onibi::Regexp#match` routing remains outside this unit.
