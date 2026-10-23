# TASK-42B4 evidence

This change adds named access to the native `Onibi::MatchData` payload.
The payload keeps copied names and ordered group indexes.

## Implemented behavior

- `[]` accepts String and Symbol names.
- Duplicate names select the last participating group.
- An all-unmatched name returns `nil`.
- Empty captures return an empty String.
- Unknown names raise `IndexError` with MRI-compatible text. Quotes and
  backslashes stay literal. Control and binary bytes use MRI escapes.
- A two-argument call with a `nil` length uses named single-selector
  dispatch.
- `names` returns a fresh mutable Array with copied Strings.
- `named_captures` returns a fresh Hash with copied capture Strings or `nil`.
- `named_captures(symbolize_names: true)` returns Symbol keys.
- Unknown keywords and positional arguments keep MRI errors.
- Returned names, hashes, keys, values, and selected captures cannot mutate
  retained payload metadata or later results.

## Checks

All commands used MRI 4.0.6 from `/opt/homebrew/opt/ruby/bin/ruby`.
The build used `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

| Command | Result |
| --- | --- |
| `ruby -v` | 0; Ruby 4.0.6 |
| `cd ext/onibi && make distclean` | 0 |
| `cd ext/onibi && ruby extconf.rb && make` | 0; two existing warnings: `onibi_c_ast_has_capture` and `onibi_rseq_mark_unsupported` |
| `ruby -Ilib -Itest test/features/captures/match_data_named_test.rb` | 0; 7 runs, 106 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Ilib -Itest -e 'ARGV.each { \|f\| require_relative f }' test/features/captures/match_data_numeric_test.rb test/features/captures/match_data_payload_test.rb test/features/captures/match_data_contract_test.rb test/features/api/regexp_metadata_isolation_test.rb test/features/quality/module_interface_contract_test.rb` | 0; 28 runs, 323 assertions, 0 failures, 0 errors, 0 skips |
| `bundle exec rubocop test/features/captures/match_data_named_test.rb` | 0; no offenses |
| `clang-format --dry-run --Werror ext/onibi/match_data.c ext/onibi/onibi_matchdata_internal.h ext/onibi/onibi_init.c` | 0 |
| `git diff --check` | 0 |
| `cd ext/onibi && make distclean` | 0 |

Full command records are in `.task-42b4-logs/checks.txt`.

## Limits

Position access, values, deconstruction, copy behavior, inspection, and
public `Regexp#match` routing remain outside this task.
