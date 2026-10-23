# TASK-42C14B evidence

Source revision: `e038b55ee1e848b9e79837874e0e22ef498af970`

Workspace: `/Users/masa/.codex/worktrees/5cf4/Onibi`

MRI: 4.0.6

The native replacement scanner reads encoded character boundaries. It keeps literal bytes and follows MRI replacement assembly order.

## Acceptance checks

- Focused test group: 122 runs, 1,675 assertions, zero failures, errors, or skips.
- C14A audit: 40 cases, zero harness failures. All 39 in-scope cases match MRI. The remaining mismatch is the out-of-scope non-ASCII capture-name regexp compile rejection.
- C13B audit: 36 cases, zero harness failures or mismatches.
- Both saved root probes match MRI for every checked order.
- Warning build passes. It reports 34 inherited warnings and none in `match.c`.
- `bundle check`, focused RuboCop, Ruby syntax, `clang-format`, and `git diff --check` pass.

The raw C14A audit labels three UTF-16LE assembly errors as `unclassified`: `utf16le_prefix_literal_then_capture`, `utf16le_capture_then_suffix_literal`, and `utf16le_numeric_tail`. Native VM diagnostics and zero observed `String#gsub` calls show that native code raised each error. The reviewed path counts are 30 native successes, three native assembly errors, four replacement fallbacks, one no-match case, one matcher fallback, and one out-of-scope compile rejection.

Two UTF-16 named-capture lookup misses use the existing replacement fallback. They do not show native named-replacement support.

Exact command arguments, work directory, environment, output, and file hashes are in `/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c14b-a964332062f6/worker/final-summary.json` and the matching files under `worker/logs/`.
