# TASK-42B2 evidence

The change adds a private native `Onibi::MatchData` typed payload. It copies
raw byte registers, a frozen subject snapshot, and ordered capture-name data.
The public match route remains unchanged.

## Checks

All commands used `PATH=/opt/homebrew/opt/ruby/bin:$PATH` and
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

The build used MRI 4.0.6 from `/opt/homebrew/opt/ruby/bin/ruby` and the
Command Line Tools compiler.

| Command | Result |
| --- | --- |
| `cd ext/onibi && make distclean` | 0 |
| `cd ext/onibi && ruby extconf.rb && make` | 0; two existing warnings: `onibi_c_ast_has_capture` and `onibi_rseq_mark_unsupported` |
| `ruby -Ilib -Itest test/features/captures/match_data_payload_test.rb` | 10 runs, 44 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Ilib -Itest -e 'ARGV.each { \|f\| require_relative f }' test/features/captures/match_data_contract_test.rb test/features/api/regexp_metadata_isolation_test.rb test/features/quality/module_interface_contract_test.rb` | 13 runs, 198 assertions, 0 failures, 0 errors, 0 skips |
| `bundle exec rubocop test/features/captures/match_data_payload_test.rb` | 0; no offenses |
| `git diff --check` | 0 |
| `cd ext/onibi && make distclean` | 0 |

The payload test covers copied ranges, subject mutation, garbage collection,
duplicate names, empty and unmatched captures, captures outside group zero,
multibyte byte ranges, validation errors with exact classes and messages,
direct allocation rejection, four injected constructor failure stages,
coercion failure cleanup, and GC compaction. Payload failures leave the payload register allocation counter unchanged.
Diagnostic range buffers have separate `rb_ensure` cleanup; that counter does
not measure diagnostic buffer allocation. Root reviewed that cleanup path.

## Limits

This unit does not add public MatchData accessors or change `Regexp#match`.
It does not update MRI backreference storage. Character offset conversion
remains for later MatchData units.
