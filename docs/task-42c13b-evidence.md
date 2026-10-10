# Native gsub result encoding

Native `gsub` now appends each string part with its source encoding. MRI selects the result encoding or raises an encoding error.

Subject and capture ranges stay as signed byte offsets. The code checks each range before append. It checks byte lengths before conversion to `long`. The `rb_ensure` cleanup still frees capture ranges.

Block results convert before Onibi appends the unmatched subject range. Explicit replacement expansion is built in a temporary native String first. These steps preserve the callback and expansion error order in the checked cases.

## MRI evidence

The adapted differential audit has 36 cases. It reports zero harness failures and zero observable mismatches.

The audit path counts are 33 native, two explicit MRI fallback, and one diagnostic error without path proof. The fallback and unclassified cases do not prove native behavior.

The saved block-order probe agrees with MRI for normal, raise, mutation, and `throw` cases. Each engine runs both yields and both string conversions before the encoding error. The saved replacement-order probe agrees for named and unnamed captures. Both raise `IndexError` with `undefined group name reference: bad`.

## Verification

Source revision: `16ed396635598c17696b9aecd245784d51c58b25`.

Build environment: Homebrew MRI 4.0.6, Bundler 4.0.16, and Apple clang 21.0.0 on arm64-darwin25. Build commands used `DEVELOPER_DIR=/Library/Developer/CommandLineTools`. Bundler commands also used `BUNDLE_IGNORE_CONFIG=true`, `BUNDLE_PATH=/tmp/onibi-bench-gem`, and `BUNDLE_FROZEN=true`.

| Check | Result |
| --- | --- |
| `/opt/homebrew/opt/ruby/bin/ruby extconf.rb` from `ext/onibi` | Exit 0 |
| `DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi warnflags='-Wall -Wextra'` | Exit 0; 34 inherited warnings; none in `match.c` |
| Focused MRI group below | Exit 0; 117 runs, 1,484 assertions, no failures, errors, or skips |
| Adapted MRI audit | Exit 0; 36 cases, zero mismatches, zero harness failures |
| Root block-order probe | Exit 0; all four MRI and Onibi rows agree |
| Root replacement-order probe | Exit 0; both MRI and Onibi rows agree |
| Bundler check and focused RuboCop | Exit 0; no offenses |
| `clang-format --dry-run --Werror ext/onibi/match.c` | Exit 0 |
| Ruby syntax check for the new test | Exit 0 |
| `git diff --check` and owned-file whitespace check | Exit 0 |
| `DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi distclean` | Exit 0 |

The focused MRI group command was:

```sh
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' \
  test/features/matching/gsub_precedence_test.rb \
  test/features/matching/gsub_block_conversion_test.rb \
  test/features/matching/gsub_block_audit_test.rb \
  test/features/matching/gsub_mutation_test.rb \
  test/features/matching/gsub_encoding_test.rb \
  test/features/matching/scan_gsub_test.rb \
  test/features/matching/scan_block_test.rb \
  test/features/api/string_caller_boundary_audit_test.rb \
  test/features/api/backreference_boundary_audit_test.rb \
  test/features/api/native_match_routing_test.rb \
  test/features/api/match_api_test.rb
```

The audit command was:

```sh
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Iext/onibi /Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c13b-15c5f10f5492/worker/probe.rb
```

The root order probes used:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools /opt/homebrew/opt/ruby/bin/ruby -Ilib -Iext/onibi /Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c13b-15c5f10f5492/root-review/order-probe.rb
DEVELOPER_DIR=/Library/Developer/CommandLineTools /opt/homebrew/opt/ruby/bin/ruby -Ilib -Iext/onibi /Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c13b-15c5f10f5492/root-review/replacement-order-probe.rb
```

Bundler commands used:

```sh
PATH=/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:$PATH BUNDLE_IGNORE_CONFIG=true BUNDLE_PATH=/tmp/onibi-bench-gem BUNDLE_FROZEN=true /opt/homebrew/opt/ruby/bin/bundle check
PATH=/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:$PATH BUNDLE_IGNORE_CONFIG=true BUNDLE_PATH=/tmp/onibi-bench-gem BUNDLE_FROZEN=true /opt/homebrew/opt/ruby/bin/bundle exec rubocop --force-exclusion test/features/matching/gsub_encoding_test.rb
```

Full logs are in `/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c13b-15c5f10f5492/worker/logs/`. Final build logs are `final3-extconf.log` and `final3-warning-build.log`. Final test and probe logs start with `final4-`. Final style logs start with `final4-`.

The clean warning build created an arm64 Mach-O bundle. Its SHA-256 was `0deb3e1e5aba2f8cb6bc222122837566feac359a461ba0c250c796dff1fa3299`.

Changed source hashes:

- `ext/onibi/match.c`: `6071b14a4f43481405a66c3f93a4513990d36edb74641147ee680d95cc217d36`
- `test/features/matching/gsub_encoding_test.rb`: `9543232a2194045b659cf23c9da70891ea4aed6e3147122e541841c5f170b4c8`

Related review symbols: E-03, E-05, API-01, API-02.

## Known limit

Replacement escape parsing still reads bytes. MRI expands a UTF-16LE `\1` replacement to captured UTF-8 `a`.

Native gsub returns bytes `[92, 0, 49, 0]` with UTF-16LE encoding for that case. The pattern is `(a)`, and diagnostics prove the native path. This parser issue remains separate work.
