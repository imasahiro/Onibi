# TASK-42C12S stabilization evidence

Date: 2026-09-21

## Scope

This task repaired the worker-local MRI and Bundler environment. It recorded the
accepted TASK-42C9 through TASK-42C12 snapshots as four local atomic commits.
The follow-up correction keeps the C source unchanged and removes two
unnecessary lint exceptions. No production behavior was added in this task.

The handoff digest is `ea7e443831899314b074ecfe8e8d9eb24521ae8577381eb1126ff2252fa04783`.
The source revision is `3a2aa006cb3ec06aa4c400a34e0ea836ab84a6b2`.

## Environment

- Ruby: `/opt/homebrew/opt/ruby/bin/ruby`, version `4.0.6`.
- PATH prefix: `/opt/homebrew/opt/ruby/bin`.
- `LOCAL="$PWD/.bundle-local"`.
- `GEM_HOME="$LOCAL"`.
- `GEM_PATH="$LOCAL:/opt/homebrew/lib/ruby/gems/4.0.0:/opt/homebrew/Cellar/ruby/4.0.6/lib/ruby/gems/4.0.0"`.
- DEVELOPER_DIR: `/Library/Developer/CommandLineTools`.
- `bundle check`: exit 0.
- The lockfile was restored after local Bundler installation. It has no tracked change.

The exact process setup was:

```sh
LOCAL="$PWD/.bundle-local"
BASE=/opt/homebrew/lib/ruby/gems/4.0.0:/opt/homebrew/Cellar/ruby/4.0.6/lib/ruby/gems/4.0.0
PATH=/opt/homebrew/opt/ruby/bin:$PATH \
GEM_HOME="$LOCAL" GEM_PATH="$LOCAL:$BASE" \
DEVELOPER_DIR=/Library/Developer/CommandLineTools
```

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
| TASK-42C12 precedence | `d24d6016` | `docs/task-42c12-evidence.md`, `ext/onibi/match.c`, `test/features/matching/gsub_block_audit_test.rb`, `test/features/matching/gsub_precedence_test.rb` |

The final `match.c` content matches the frozen accepted source before hook
formatting. The frozen source hash is
`a45f5f8584fe08b3c2eeb96bb94b731f242815ba66c895c54fb84497e3a9800a`.

The exact commit commands used the setup above and returned exit 0. The
following is the full command form; each message was used once, in order:

```sh
LOCAL="$PWD/.bundle-local"; BASE=/opt/homebrew/lib/ruby/gems/4.0.0:/opt/homebrew/Cellar/ruby/4.0.6/lib/ruby/gems/4.0.0
PATH=/opt/homebrew/opt/ruby/bin:$PATH GEM_HOME="$LOCAL" GEM_PATH="$LOCAL:$BASE" DEVELOPER_DIR=/Library/Developer/CommandLineTools git commit -m 'test: audit native gsub block boundaries'
PATH=/opt/homebrew/opt/ruby/bin:$PATH GEM_HOME="$LOCAL" GEM_PATH="$LOCAL:$BASE" DEVELOPER_DIR=/Library/Developer/CommandLineTools git commit -m 'test: enforce native gsub mutation safety'
PATH=/opt/homebrew/opt/ruby/bin:$PATH GEM_HOME="$LOCAL" GEM_PATH="$LOCAL:$BASE" DEVELOPER_DIR=/Library/Developer/CommandLineTools git commit -m 'test: verify native gsub block conversion'
PATH=/opt/homebrew/opt/ruby/bin:$PATH GEM_HOME="$LOCAL" GEM_PATH="$LOCAL:$BASE" DEVELOPER_DIR=/Library/Developer/CommandLineTools git commit -m 'test: enforce native gsub replacement precedence'
PATH=/opt/homebrew/opt/ruby/bin:$PATH GEM_HOME="$LOCAL" GEM_PATH="$LOCAL:$BASE" DEVELOPER_DIR=/Library/Developer/CommandLineTools git commit -m 'docs: record accepted gsub commit stabilization'
```

The original per-commit hook output was not retained. The four accepted commits
were rechecked in isolated temporary worktrees. Each worktree started at the
commit parent, checked out only that commit's changed files, staged them, and
ran `.githooks/pre-commit` with the exact scoped environment. Each hook returned
exit 0. Logs and file lists are in `.task-42c12s-logs/history/`.

The C12 commit includes `gsub_block_audit_test.rb` because its replacement
precedence case belongs to the audit file created in C9. Its diff only adds
yield tracking and the native/MRI precedence assertion. It does not change the
C10 mutation assertions or the C11 conversion assertions. C10 and C11 test
files are not changed by C12.

## Lint exceptions

The remaining exceptions are narrow and test-specific:

- `Lint/RescueException` applies only to probe methods that serialize every
  exception class for MRI differential checks. This includes non-StandardError
  exceptions raised by the child probes.
- `Metrics/BlockLength` applies only to the audit child lifecycle harness. The
  timeout, stream, and cleanup state must stay in one bounded method.

The frozen-input test now uses `input = +"aa"` followed by `input.freeze`, so it
needs no `Style/RedundantFreeze` exception. The false label uses a string key,
and the conversion probe uses safe navigation. No `BooleanSymbol` or
`SafeNavigation` exception remains.

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

After the follow-up test-only correction, the same focused group passed again:
`107 runs, 1253 assertions, 0 failures, 0 errors, 0 skips`. Scoped RuboCop for
all four gsub tests passed with no offenses. The unchanged `match.c` passed
`clang-format --dry-run --Werror` again. The prior warning build and `extconf`
result remain valid because the C source hash did not change; a clean rebuild
was also run before the repeated focused group.

No hook bypass, global configuration change, lockfile change, push, pull
request, merge, or semantic implementation change was made.
