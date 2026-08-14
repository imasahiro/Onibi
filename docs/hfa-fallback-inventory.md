# HFA execution and codegen fallback inventory

This is the current snapshot of the runtime dispatch. The public matcher has
three API families, and each currently has a separate safety census:

| API | HFA dispatch | codegen fallback |
| --- | --- | --- |
| `match?` | direct specializations, then `hfa_match_question_safe?` | `codegen_match?` when the input is not ASCII-safe or the compiled HFA program is unavailable |
| `match` | direct result specializations, then the captureless/capturing result predicates | `codegen_match` when no result predicate can reconstruct the public `MatchData` |
| `scan`/`gsub` | direct iterators, then `hfa_each_result` and `hfa_iterator_safe?` | `codegen_each_result`/`codegen_each_match` when the iterator cannot produce equivalent offsets |

The predicates overlap today. For example, `hfa_match_question_safe?` can be
true for a pattern that is also handled by a literal, anchor, or backreference
specialization; the earlier branch wins. `hfa_match_result_safe?` is mostly a
captureless AST census, while `hfa_simple_capture_result_safe?`, nested-capture
predicates, and backreference predicates form a second, partially duplicated
census for `match`. `hfa_iterator_safe?` repeats much of both lists for
`scan`.

## Known fallback patterns

These are historical fallback fixtures. They remain acceptance tests: each API
stubs the corresponding codegen entrypoint and fails if a future change
reintroduces the fallback. The current inventory is empty for these shapes.

| Pattern | APIs affected before the capturing-backref work | Reason |
| --- | --- | --- |
| `(?<x>.*)\\k<x>` | `match?`, `match`, `scan` | arbitrary-width capture must be retained and compared at runtime |

`(a*)\\1`, `(?<x>a)(?i:\\k<x>)`, `(?<x>.*)\\k<x>`, and `(?>a|ab)c` were
fallbacks in the original snapshot. They are now covered by generalized HFA
runtime paths: variable literal backreference matching, scoped casefold
backreference matching, variable-width capture matching, and atomic-literal
branch evaluation.

`(?>a|ab)c` was a fallback in the original snapshot because the generic
atomic-literal shortcut only handled branches whose remainder repeated the
suffix. It is now covered by a generalized atomic-literal branch evaluator and
is no longer a fallback.

## Simplification target

The intended dispatch should converge to:

1. captureless HFA result/iterator;
2. tagged/capturing HFA result/iterator;
3. a small set of explicit VM/string-search specializations;
4. codegen only for patterns that cannot be represented by either HFA mode.

New syntax support should add one capability to (1) or (2), not another API-
specific safety list. The fallback fixtures above are the acceptance boundary
for that refactoring.
