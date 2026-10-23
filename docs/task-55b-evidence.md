# TASK-55B evidence: retained capture metadata and getter isolation

## Scope

The task repairs `Onibi::Regexp#names` and
`Onibi::Regexp#named_captures` ownership. The retained C metadata is now
immutable. Each getter returns mutable values with MRI-compatible sharing.

The change does not enable Ractor use. It does not change execution class or
the MRI `MatchData` adapter.

## MRI observations

Environment: MRI 4.0.6.

The probe is [mri_metadata_probe.rb](/Users/masa/.codex/worktrees/0167/Onibi/.task-55b-logs/mri_metadata_probe.rb).
Its output is [mri_metadata_probe.out](/Users/masa/.codex/worktrees/0167/Onibi/.task-55b-logs/mri_metadata_probe.out).

MRI returns a new mutable array from `names` on every call. Its name strings
are mutable and have the source encoding. MRI returns a new mutable hash from
`named_captures` on every call. Its value arrays are mutable. Its string keys
are frozen and safely shared. Duplicate names keep all capture indices.

MRI accepts `(?<é>a)`. The current Onibi parser rejects this name as an
unsupported capture-name form. The supported UTF-8 pattern `(?<x>é)` verifies
the getter encoding boundary without expanding parser scope.

Before this change, the Onibi probe changed retained values by mutating getter
results. The first name became `"xz"`, and the first capture array became
`[1, 2, 99]`. The output is [onibi_metadata_probe.out](/Users/masa/.codex/worktrees/0167/Onibi/.task-55b-logs/onibi_metadata_probe.out).

## Ownership repair

`onibi_freeze_metadata` freezes retained name strings, named-capture keys and
value arrays, and both retained containers. `onibi_names` duplicates each
retained name string into a new array. `onibi_named_captures` creates a new
hash, shares only frozen keys, and duplicates each value array.

The focused test mutates nested strings, nested arrays, and outer containers.
It checks later getter results, another regexp, duplicate indices, encodings,
and native matching. The native path remains selected after mutation.

The representative output is [native_metadata_representatives.out](/Users/masa/.codex/worktrees/0167/Onibi/.task-55b-logs/native_metadata_representatives.out):

* three named-capture patterns matched with status `1`;
* all three used execution class `0` and the regular native executor;
* all three reported fallback count `0`;
* raw captures remained `[[0, 1]]`, `[[0, 1], [1, 2]]`, and `[[0, 2]]`.

## Checks

All checks ran in `/Users/masa/.codex/worktrees/0167/Onibi` with
`PATH=/opt/homebrew/opt/ruby/bin:$PATH` and
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

1. `ruby -v` — exit 0; MRI 4.0.6.
2. `(cd ext/onibi && make distclean)` before the build — exit 0.
3. `(cd ext/onibi && ruby extconf.rb && make)` — exit 0. The build reported
   the two known warnings: `onibi_c_ast_has_capture` and
   `onibi_rseq_mark_unsupported`.
4. `ruby -Ilib -Itest test/features/api/regexp_metadata_isolation_test.rb` —
   exit 0; 4 runs, 43 assertions, 0 failures, 0 errors, 0 skips.
5. `ruby -Ilib -Itest -e 'ARGV.each { |f| require_relative f }'
   test/features/api/regexp_constructor_test.rb
   test/features/api/regexp_constructor_contract_test.rb
   test/features/captures/match_data_contract_test.rb` — exit 0; 43 runs,
   171 assertions, 0 failures, 0 errors, 0 skips.
6. `bundle exec rubocop
   test/features/api/regexp_metadata_isolation_test.rb` — exit 0; 1 file,
   no offenses.
7. `clang-format --dry-run --Werror ext/onibi/rseq.c` — exit 0.
8. `git diff --check` — exit 0.
9. `(cd ext/onibi && make distclean)` after verification — exit 0.

The complete command output is in `.task-55b-logs/check-*.out`.

The clean-source baseline for the existing three-test command was also 43
runs, 171 assertions, with no failures, errors, or skips.
