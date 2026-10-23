# Onibi

Use ASD-STE100 Simplified Technical English for prose documentation where practical.
Keep sentences short and active.
Do not rewrite code identifiers or established MRI and Onibi terminology to satisfy style rules.

Architectural sources of truth:

- docs/gir.md
- docs/review-result.md

Execution state:

- docs/execution-ledger.md

Development and verification:

- docs/development.md
- Rakefile

Read only the sections that apply to the task.

Project invariants:

- The current PoC targets MRI only.
- Keep the production compiler, semantic IR, interpreters, and native match results in C.
- Use Ruby only for loading, public wrappers, diagnostics, and documented compatibility adapters.
- Do not add FFI, an external regular-expression engine, ZJIT, or MRI source-tree dependencies during the gem PoC.
- Do not use MRI fallback as the implementation of behavior that the native engine claims to support.
- Preserve MRI observable semantics and report unsupported behavior explicitly.

Verification:

- Before review, run focused checks for the changed behavior.
- Use the current commands in `docs/development.md` and `Rakefile`; do not copy stale commands into task instructions.
- For public regexp behavior, use MRI differential tests for the relevant semantics.
- For C changes, build with compiler warnings enabled.
- Do not weaken a correct test to hide unsupported behavior or a regression.
- Record the exact commands and results used as acceptance evidence.

Change control:

- Make each commit atomic. Do not mix unrelated changes.
- Use a feature branch and a pull request.
- Do not merge or auto-merge a draft pull request.
- Merge only after all required CI checks pass.
- Update the documents when architecture or execution state changes.