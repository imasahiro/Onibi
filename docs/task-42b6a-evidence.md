# TASK-42B6A evidence

The change adds native value methods for `Onibi::MatchData`:

* `inspect` formats full, numeric, named, empty, and unmatched captures.
* `==` and `eql?` compare the frozen subject snapshot, regexp equality, and
  copied byte registers.
* `hash` uses the same values as equality.

The methods do not call MRI matching. They read only native payload state.
Public capture containers remain fresh, so getter changes do not affect value
methods.

## Acceptance checks

The handoff digest was verified before edits:

```text
39c9e332d30cd8216cac6ed54171f6e2ad36c78f5450e9c66d804afb5e8c7307
```

`ruby -v` reported MRI 4.0.6.

The exact build command needs the installed Command Line Tools because the
default Xcode developer directory has an unaccepted license. This equivalent
command passed with the two known compiler warnings:

```text
cd ext/onibi && DEVELOPER_DIR=/Library/Developer/CommandLineTools ruby extconf.rb && DEVELOPER_DIR=/Library/Developer/CommandLineTools make
```

Focused test:

```text
ruby -Ilib -Itest test/features/captures/match_data_value_semantics_test.rb
3 runs, 14 assertions, 0 failures, 0 errors, 0 skips
```

Regression tests:

```text
ruby -Ilib -Itest -e 'ARGV.each { |f| require_relative f }' test/features/captures/match_data_value_semantics_test.rb test/features/captures/match_data_character_offsets_test.rb test/features/captures/match_data_byte_offsets_test.rb test/features/captures/match_data_named_test.rb test/features/captures/match_data_numeric_test.rb test/features/captures/match_data_payload_test.rb test/features/captures/match_data_contract_test.rb test/features/api/regexp_metadata_isolation_test.rb test/features/quality/module_interface_contract_test.rb
50 runs, 665 assertions, 0 failures, 0 errors, 0 skips
```

```text
bundle exec rubocop test/features/captures/match_data_value_semantics_test.rb
1 file inspected, no offenses detected
```

```text
clang-format --dry-run --Werror ext/onibi/match_data.c ext/onibi/onibi_matchdata_internal.h ext/onibi/onibi_init.c
passed
git diff --check
passed
```

The exact `cd ext/onibi && make distclean` command returned status 69 because
the default Xcode directory has an unaccepted license. The equivalent command
with `DEVELOPER_DIR=/Library/Developer/CommandLineTools` returned status 0.
No commit, push, pull request, or ledger update was made for this worker task.
