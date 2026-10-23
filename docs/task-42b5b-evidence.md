# TASK-42B5B evidence

This unit adds lazy character offsets to the native `Onibi::MatchData` payload.
The payload keeps byte registers as the source of truth. The first call to
`begin`, `end`, `offset`, or `match_length` for a participating register scans
the needed subject prefix once with MRI public encoding APIs. It publishes one
per-payload cache only after conversion succeeds. Unmatched registers return
`nil` or `[nil, nil]` and do not require conversion.

Character positions count encoding characters. They do not count bytes or
graphemes. Binary, UTF-8, combining-sequence, and Windows-31J subjects are
covered by the focused test. Invalid UTF-8 raises `ArgumentError` and leaves
the cache unpublished. The cache uses one allocation for both position arrays,
and the free path releases that allocation once.

The source workspace is `/Users/masa/.codex/worktrees/ef8b/Onibi` at source
revision `d9aa9cc17d93b4b6b23301ba1e481441cc362f11`.

## Checks

Exact commands and results are in `.task-42b5b-logs/checks.txt`.

| Command | Status | Result |
| --- | ---: | --- |
| `ruby -v` | 0 | MRI 4.0.6 |
| `(cd ext/onibi && make distclean)` before build | 0 | clean |
| `(cd ext/onibi && ruby extconf.rb && make)` | 0 | build passed; two existing warnings only |
| focused character offset test | 0 | 7 runs, 83 assertions, 0 failures, 0 errors, 0 skips |
| required capture and contract tests | 0 | 40 runs, 568 assertions, 0 failures, 0 errors, 0 skips |
| `bundle exec rubocop test/features/captures/match_data_character_offsets_test.rb` | 0 | no offenses |
| `git diff --check` | 0 | clean |
| `(cd ext/onibi && make distclean)` after checks | 0 | clean |

## Limits

Public `Onibi::Regexp#match` routing remains outside this unit. The cache is
owned by each payload. `lazy_character_cache` remains a capability diagnostic;
`character_cache_present` reports publication state.
