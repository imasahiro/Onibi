# TASK-42B6B evidence

This change adds native copy and deconstruction behavior to
`Onibi::MatchData`.

## Implemented behavior

- `dup` copies native registers and keeps the result unfrozen.
- `clone` copies native registers, lazy character positions, freeze state, and
  singleton methods.
- Copy operations share only frozen subject and metadata values.
- `deconstruct` returns fresh capture values, including `nil` and empty
  captures.
- `deconstruct_keys(nil)` returns all named captures with Symbol keys.
- `deconstruct_keys` accepts Symbol arrays, omits unknown names, and raises
  `TypeError` for other key forms.

## Checks

All checks use MRI 4.0.6. The build uses the installed Command Line Tools
because the default compiler wrapper requires an unavailable Xcode license.

| Command | Result |
| --- | --- |
| `ruby -v` | 0; Ruby 4.0.6 |
| `cd ext/onibi && make distclean` | blocked by the Xcode license wrapper when the generated Makefile exists |
| `cd ext/onibi && ruby extconf.rb && make` | blocked by the Xcode license wrapper |
| `cd ext/onibi && DEVELOPER_DIR=/Library/Developer/CommandLineTools SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk make CC=/Library/Developer/CommandLineTools/usr/bin/clang` | 0; two known warnings: `onibi_c_ast_has_capture` and `onibi_rseq_mark_unsupported` |
| `ruby -Ilib -Itest test/features/captures/match_data_copy_deconstruct_test.rb` | 0; 4 runs, 19 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Ilib -Itest -e 'ARGV.each { \|f\| require_relative f }' test/features/captures/match_data_value_semantics_test.rb test/features/captures/match_data_character_offsets_test.rb test/features/captures/match_data_byte_offsets_test.rb test/features/captures/match_data_named_test.rb test/features/captures/match_data_numeric_test.rb test/features/captures/match_data_payload_test.rb test/features/captures/match_data_contract_test.rb test/features/api/regexp_metadata_isolation_test.rb test/features/quality/module_interface_contract_test.rb` | 0; 50 runs, 665 assertions, 0 failures, 0 errors, 0 skips |
| `bundle exec rubocop test/features/captures/match_data_copy_deconstruct_test.rb` | 0; no offenses |
| `clang-format --dry-run --Werror ext/onibi/match_data.c ext/onibi/onibi_matchdata_internal.h ext/onibi/onibi_init.c` | 0 |
| `git diff --check` | 0 |
| `cd ext/onibi && DEVELOPER_DIR=/Library/Developer/CommandLineTools SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk make distclean` | 0 |

## Limits

The default `make` command remains blocked by the local Xcode license state.
The Command Line Tools build completes with the same two existing warnings.
Public `Onibi::Regexp#match` routing remains outside this task.
