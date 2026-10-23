# TASK-42C18B evidence

Source revision: `9accc63ce22b2d66fb04be8fc94f649384cb640e`

Workspace: `/Users/masa/.codex/worktrees/456c/Onibi`

MRI: 4.0.6

## Change

The C name-key iterator now handles `\c`, `\C-`, and `\M-` escapes.
It handles nested control and meta escapes and encoded byte composition.
It keeps source bytes in tokens and AST nodes.
The same normalized bytes drive name lookup, hashing, and equality.

Named groups, references, calls, and replacements use the native C path.
The named replacement adapter does not call `String#gsub` for these cases.

## Differential results

- The review 3 matrix has 43 cases. MRI accepts 41 and rejects two invalid escape forms.
- All 116 reference rows and 82 duplicate-name rows match MRI.
- All 14 named replacement rows match MRI and use zero `String#gsub` calls.
- The matrix reports zero harness errors and zero behavior differences.
- The new test passed: 16 runs and 537 assertions.
- The required focused group passed: 174 runs and 2,745 assertions.
- Control escapes map to MRI's canonical `\xNN` names. Meta and combined escapes retain the measured encoded bytes.
- UTF-8 and Windows-31J composition cases match MRI. They use native matching.

## Verification

- The warning build passed with `-Wall -Wextra` and 34 warnings.
- A comparison with the clean-base log found the same 34 warning signatures.
- `bundle check`, RuboCop, Ruby syntax, `clang-format`, and `git diff --check` passed.
- Related existing name/parser checks ran 26 tests and 139 assertions.
  Three errors match the clean-base logs: missing `MatchData#values_at` and two old parser errors.
- The broader parser/name batch still has 2 failures and 14 errors.
  It had the same results on the clean base. The 40-name verifier also fails the same way on both sources.
- Invalid-name message bytes match MRI. MRI marks the message as UTF-8; Onibi marks it as ASCII-8BIT.
- MRI and Onibi return capture range `[2,3]` for `(?<word>a)\g<word>` on `zaa`.

Exact commands, environments, and full logs are in
`/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c18b-17b138c148ff/worker/verification_manifest_review3_final.json`.
Raw matrices, warning comparisons, and loaded-library identity are in the same worker directory.

## Mixed-byte repair

The attempt 3 matrix covers UTF-8 characters with two, three, and four bytes.
It also covers Windows-31J characters with a backslash trail byte.
It tries hex, meta, control, and escaped-backslash forms at each byte position.
It checks both group-to-literal and literal-to-reference forms.

MRI accepts all 634 matrix rows.
Onibi matches all 634 rows, with native routing and no fallback.
The new test passes: 17 runs and 635 assertions.
The required focused group passes: 175 runs and 2,843 assertions.
The 43-row review 3 matrix still passes its 116 reference, 82 duplicate, and 14 replacement rows.
The 39-row name matrix has no result, metadata, scan, replacement, or error differences.

The C iterator now decodes continuation bytes with the same bounded hex, control, and meta rules.
It also decodes escaped backslash bytes for encoded characters.
The source name bytes remain unchanged.
The normalized byte stream still drives name lookup, hashing, and equality.

The warning build has 34 warnings.
Its warning signatures match the clean-base build.
`bundle check`, RuboCop, Ruby syntax, `clang-format`, and `git diff --check` pass.
Six targeted parser and name checks pass.
The related legacy check reports three known errors and no failures.
Clean-base evidence records the same error signatures.

The full matrix and exact commands are in
`/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c18b-17b138c148ff/root-review/`.
The final manifest and logs are in the matching `worker/` directory.
