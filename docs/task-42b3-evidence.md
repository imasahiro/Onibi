# TASK-42B3 evidence

This change adds numeric capture access and snapshot string access to the
private `Onibi::MatchData` object. The object reads copied byte registers and a
frozen subject snapshot. It does not call MRI regexp matching.

## Implemented behavior

- `[]` accepts integer, negative integer, integer-like, and numeric Range
  selectors. It supports beginless and endless ranges. Single selectors use
  MRI's `int` conversion. Pair selectors and range endpoints use MRI's `long`
  conversion. An explicit `nil` length uses the complete one-selector path,
  including Range selectors.
- `captures`, `to_a`, `size`, and `length` return capture values from copied
  registers. Unmatched captures return `nil`. Empty captures return `""`.
- `to_s`, `pre_match`, and `post_match` return new strings from snapshot bytes.
- `string` returns the frozen subject snapshot. `regexp` returns the owning
  `Onibi::Regexp`.
- String and symbol selectors raise `IndexError`. Named dispatch remains
  deferred.

## Checks

All commands used MRI 4.0.6 from `/opt/homebrew/opt/ruby/bin/ruby` with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

| Command | Result |
| --- | --- |
| `ruby -v` | 0; Ruby 4.0.6 |
| `cd ext/onibi && make distclean` | 0 |
| `cd ext/onibi && ruby extconf.rb && make` | 0; two existing warnings: `onibi_c_ast_has_capture` and `onibi_rseq_mark_unsupported` |
| `ruby -Ilib -Itest test/features/captures/match_data_numeric_test.rb` | 0; 5 runs, 81 assertions, 0 failures, 0 errors, 0 skips; runtime MRI differential matrix |
| `ruby -Ilib -Itest -e 'ARGV.each { \|f\| require_relative f }' test/features/captures/match_data_payload_test.rb test/features/captures/match_data_contract_test.rb test/features/api/regexp_metadata_isolation_test.rb test/features/quality/module_interface_contract_test.rb` | 0; 23 runs, 242 assertions, 0 failures, 0 errors, 0 skips |
| `bundle exec rubocop test/features/captures/match_data_numeric_test.rb` | 0; no offenses |
| `clang-format --dry-run --Werror ext/onibi/match_data.c ext/onibi/onibi_matchdata_internal.h ext/onibi/onibi_init.c` | 0 |
| `git diff --check` | 0 |
| `cd ext/onibi && make distclean` | 0 |

Full command output is in `.task-42b3-logs/`.

## Limits

Named selectors, `match`, `values_at`, character positions, metadata methods,
equality, hashing, duplication, inspection, and deconstruction remain for
later tasks. `Regexp#match` routing remains unchanged.
