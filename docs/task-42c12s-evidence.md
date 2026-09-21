# TASK-42C12S stabilization evidence

Date: 2026-09-21

## Scope

This task repaired the worker-local MRI and Bundler environment. It recorded the
accepted TASK-42C9 through TASK-42C12 snapshots as four local atomic commits.
No production behavior was added in this task.

The handoff digest is `ea7e443831899314b074ecfe8e8d9eb24521ae8577381eb1126ff2252fa04783`.
The source revision is `3a2aa006cb3ec06aa4c400a34e0ea836ab84a6b2`.

## Environment

- Ruby: `/opt/homebrew/opt/ruby/bin/ruby`, version `4.0.6`.
- PATH prefix: `/opt/homebrew/opt/ruby/bin`.
- GEM_HOME: worker-local `.bundle-local`.
- GEM_PATH: worker-local `.bundle-local` plus the Homebrew Ruby 4.0.6 gem paths.
- DEVELOPER_DIR: `/Library/Developer/CommandLineTools`.
- `bundle check`: exit 0.
- The lockfile was restored after local Bundler installation. It has no tracked change.

The first scoped attempt used the rbenv gem directory and failed while Bundler
loaded two Bundler installations. The final process-local environment uses one
Homebrew MRI, one local bundle path, and the Command Line Tools compiler.

## Atomic commits

Each commit ran the unmodified `.githooks/pre-commit`. The first hook pass can
format staged Ruby files. The formatted files were inspected, restaged, and the
hook was run again. RuboCop changes were limited to formatting or explicit cop
directives. Assertions, probes, callback order, and test scenarios remain intact.

| Unit | Commit | Files |
| --- | --- | --- |
| TASK-42C9 audit | `e680a3db` | `docs/task-42c9-evidence.md`, `test/features/matching/gsub_block_audit_test.rb` |
| TASK-42C10 mutation | `c6bf48ba` | `docs/task-42c10-evidence.md`, `ext/onibi/match.c`, `test/features/matching/gsub_block_audit_test.rb`, `test/features/matching/gsub_mutation_test.rb` |
| TASK-42C11 conversion | `3994482b` | `docs/task-42c11-evidence.md`, `ext/onibi/match.c`, `test/features/matching/gsub_block_audit_test.rb`, `test/features/matching/gsub_block_conversion_test.rb`, `test/features/matching/gsub_mutation_test.rb` |
| TASK-42C12 precedence | `d24d6016` | `docs/task-42c12-evidence.md`, `ext/onibi/match.c`, `test/features/matching/gsub_block_audit_test.rb`, `test/features/matching/gsub_block_conversion_test.rb`, `test/features/matching/gsub_mutation_test.rb`, `test/features/matching/gsub_precedence_test.rb` |

The final `match.c` content matches the frozen accepted source before hook
formatting. The frozen source hash is
`a45f5f8584fe08b3c2eeb96bb94b731f242815ba66c895c54fb84497e3a9800a`.

## Required checks

All checks below passed. Full output is in `.task-42c12s-logs/`.

- Homebrew Ruby version and scoped `bundle check`: pass.
- `ruby extconf.rb`: pass.
- Command Line Tools `make -C ext/onibi warnflags='-Wall -Wextra'`: pass.
- C build warnings: 34 inherited warnings; no new failure.
- Focused MRI group: `107 runs, 1253 assertions, 0 failures, 0 errors, 0 skips`.
- Scoped RuboCop for the four gsub tests: pass, no offenses.
- `clang-format --dry-run --Werror ext/onibi/match.c`: pass.
- `make -C ext/onibi distclean`: pass.
- `git diff --check`: pass.

No hook bypass, global configuration change, lockfile change, push, pull
request, merge, or semantic implementation change was made.
