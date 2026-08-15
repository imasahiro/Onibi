# Ruby 4.0.6 Regexp feature coverage

This document is a compatibility snapshot comparing Onibi's explicit
`Onibi::Regexp` / `Onibi::MatchData` API with MRI Ruby 4.0.6. The status is based
on implementation and public differential tests. Revalidate this table when the
MRI baseline changes.

The normative matcher architecture is [`hfa-design.md`](hfa-design.md). The
completed API implementation sequence is preserved in
[`history/v1-task-list.md`](history/v1-task-list.md). A green feature row does
not mean that the HFA architecture migration is complete; transitional
adaptive-subset and direct-specializer paths are tracked in
[`hfa-task-list.md`](hfa-task-list.md).

## Status symbols

| Symbol | Meaning |
| --- | --- |
| ✅ | Implemented and verified for the representative public contract. |
| ◐ | Partially implemented, or not fully equivalent to MRI in meaning, return values, encodings, or errors. |
| ❌ | Not implemented. |
| Out of scope | Excluded from the current explicit Onibi API by design. |

## Ruby 4.0.6 syntax

| Category | MRI feature | Representative form | Onibi | Notes |
| --- | --- | --- | --- | --- |
| Literals | Characters and Unicode characters | `abc`, `café` | ✅ | UTF-8 and ASCII-8BIT behavior is covered for the supported cases. |
| Metacharacters | Escaped metacharacters | `a\+` | ◐ | Common control, caret-control, hex, Unicode, and meta escapes are implemented; uncommon combinations remain incomplete. |
| Any character | Dot excluding newline by default | `.` | ✅ | `multiline` provides the documented dot-all behavior. |
| Character classes | Enumeration, negation, ranges | `[abc]`, `[^a]`, `[a-z]` | ✅ | Core forms are implemented. |
| Character classes | Escapes, nesting, intersection | `[\]]`, `[a-z[0-9]]`, `[a-w&&[^c-g]z]` | ◐ | Structured class parsing and common escapes are implemented; complete MRI class-escape coverage remains incomplete. |
| Shorthand classes | Word, digit, space, hex, and complements | `\w`, `\d`, `\s`, `\h`, `\W` | ✅ | Ruby-compatible ASCII word/digit behavior and the supported complements are covered. |
| Linebreak class | Linebreak sequences | `\R` | ✅ | CR, LF, CRLF, NEL, LSEP, and PSEP cases are implemented. |
| Anchors | Line and string anchors | `^`, `$`, `\A`, `\Z`, `\z` | ✅ | `^` and `$` use Ruby line-boundary semantics. |
| Anchors | Word/current-position boundaries | `\b`, `\B`, `\G` | ✅ | Representative boundary cases are implemented. |
| Match reset | Reset the reported match span | `\K` | ✅ | Implemented as a span reset. |
| Alternation | Left-to-right choice | `a|b`, `(a|b)` | ✅ | Priority and capture interactions remain part of the HFA differential corpus. |
| Quantifiers | Greedy repetition and bounds | `*`, `+`, `?`, `{n,m}`, `{,max}` | ✅ | Bounded, unbounded, and empty-minimum forms are covered. |
| Quantifiers | Lazy repetition | `*?`, `+?`, `{1,3}?` | ✅ | Implemented and differentially tested. |
| Quantifiers | Possessive repetition | `*+`, `++`, `{1,3}+` | ✅ | Implemented; the Ruby counting-range suffix is covered. |
| Groups | Capturing, non-capturing, named | `(abc)`, `(?:abc)`, `(?<name>abc)` | ✅ | Numbered, named, nested, and unmatched captures are covered. |
| Groups | Atomic groups | `(?>abc)` | ✅ | Implemented with non-backtracking semantics. |
| Backreferences | Numbered and named references | `\1`, `\k<name>` | ✅ | Representative forms are implemented. |
| Subexpression calls | Numbered and named calls | `\g<name>`, `\g1` | ✅ | Representative forms are implemented. |
| Conditionals | Capture-dependent branches | `(?(1)yes|no)` | ✅ | Numbered and named conditions are covered. |
| Absence | Absence operator | `(?~pat)` | ✅ | Representative Ruby 4.0 cases are covered. |
| Lookaround | Lookahead and fixed-width lookbehind | `(?=pat)`, `(?<=pat)` | ✅ | Fixed-width validation is implemented for lookbehind. |
| Comments | Pattern comments | `(?#comment)` | ✅ | Comments do not create captures; unterminated comments raise `RegexpError`. |

## Unicode, POSIX, and encodings

| Category | MRI feature | Representative form | Onibi | Notes |
| --- | --- | --- | --- | --- |
| Unicode properties | Positive, negative, category, script, block | `\p{Alpha}`, `\P{Alpha}`, `\p{Hiragana}` | ✅ | Representative properties and invalid-property errors are covered. |
| POSIX classes | Standard and Ruby extensions | `[[:digit:]]`, `[[:word:]]` | ✅ | Standard classes and `ascii`/`word` extensions are implemented. |
| UTF-8 | Literal/class/property matching and folding | `é`, Unicode properties | ◐ | Core matching, invalid input handling, and representative Unicode folding are covered; the complete fold inventory is incomplete. |
| ASCII-8BIT | Binary and byte matching | binary literals/classes | ◐ | Binary matching, `NOENCODING`, invalid bytes, and compatibility errors are covered; full parity is incomplete. |
| US-ASCII | ASCII-compatible pattern/input | ASCII literals | ◐ | Basic compatibility is covered; all source/fixed-encoding details are incomplete. |
| Other encodings | EUC-JP and Windows-31J | `/pat/e`, `/pat/s` equivalents | ◐ | Representative same-encoding and cross-encoding cases are covered; constructor encoding modes are incomplete. |
| Literal encoding modes | `/u`, `/n`, `/e`, `/s` | Ruby regexp literals | Out of scope | Onibi accepts string patterns and does not parse Ruby regexp literals or interpolation. |
| Fixed/no encoding | `FIXEDENCODING`, `NOENCODING` | integer options | ◐ | Core flags, introspection, and representative compatibility behavior are implemented; full MRI parity remains incomplete. |

## Modes and `Regexp` API

| Category | MRI feature | Onibi | Notes |
| --- | --- | --- | --- |
| Construction | `Regexp.new` / `Regexp.compile` | ◐ | Explicit Onibi constructors support the documented forms, copies, options, and timeout keyword; every MRI argument combination is not yet equivalent. |
| Ignorecase | `i` / `IGNORECASE` | ◐ | Literal/class folding and scoped modifiers are implemented; full syntax-wide folding is incomplete. |
| Multiline | `m` / `MULTILINE` | ✅ | Dot-all behavior and Ruby line-anchor semantics are covered. |
| Extended mode | `x` / `EXTENDED` | ◐ | Whitespace/comments, escaped markers, and representative scoped modifiers are implemented; some mixed scopes remain incomplete. |
| Interpolation | `o` and regexp-literal interpolation | Out of scope | The explicit string-pattern API does not parse Ruby literals. |
| Matching | `match`, `match?`, position argument | ◐ | MatchData, captures, offsets, and position handling are implemented; complete MRI error and encoding parity is incomplete. |
| Operators | `=~`, `===`, unary `~` | ◐ | Basic explicit-API behavior is implemented; global match state and every offset form are not. |
| Global state | `$~`, `$&`, `$1`, `Regexp.last_match` | Out of scope | Onibi's opt-in API does not mutate MRI global match variables. |
| Introspection | `source`, `options`, `encoding`, `fixed_encoding?`, `casefold?` | ◐ | Core values and ASCII-only source normalization are implemented; full encoding/option formatting is incomplete. |
| Timeout | Class/instance timeout and timeout errors | ◐ | Positive timeout validation and the dedicated timeout exception are implemented; complete MRI copy/error semantics remain incomplete. |
| Object semantics | `==`, `eql?`, `hash`, `inspect`, `to_s` | ◐ | Basic value semantics and mode formatting are covered; every encoding detail is not. |
| Utilities | `Regexp.escape`, `quote`, `union`, `try_convert` | ◐ | String/symbol coercion, compiled-pattern alternatives, and core option propagation are implemented; full option compatibility is incomplete. |
| Linear-time query | `Regexp.linear_time?` | ◐ | Conservative unsafe-syntax classification is implemented; exhaustive MRI classification is not. |
| Serialization | JSON extension methods | ❌ | JSON integration is not implemented. |
| Explicit repeated-match APIs | `Onibi::Regexp#scan`, `#gsub` | ✅ | Capture arrays, blocks, empty-match progression, replacement tokens, and named/numeric references are covered. |
| Implicit integration | `String#match`, `scan`, `gsub`, `sub` | Out of scope | v1 keeps Onibi explicit; MRI core classes are not patched. |

## `MatchData` API

| Area | Representative methods | Onibi | Notes |
| --- | --- | --- | --- |
| Values | `[]`, `captures`, `to_a` | ◐ | Numbered/named lookup, ranges, negative indices, and common coercions are implemented; complete extraction/error parity is incomplete. |
| Count | `length`, `size` | ✅ | Implemented. |
| Character offsets | `begin`, `end`, `offset` | ◐ | Named indices, unmatched captures, and representative character offsets are implemented; the full encoding matrix remains incomplete. |
| Byte offsets | `bytebegin`, `byteend`, `byteoffset` | ◐ | Derived byte offsets and common index validation are implemented. |
| Length | `match_length` | ◐ | Common capture lengths and indices are implemented; full error parity remains incomplete. |
| Context | `string`, `regexp`, `pre_match`, `post_match` | ◐ | Match context is available for results returned by `Onibi::Regexp`; direct-construction edge cases are incomplete. |
| Named captures | `names`, `named_captures` | ◐ | Basic named capture enumeration and lookup are implemented. |
| Formatting and identity | `inspect`, `to_s`, `==`, `eql?`, `hash` | ◐ | Basic MRI-shaped values are implemented; all encoding/context formatting is incomplete. |
| Destructuring | `deconstruct`, `deconstruct_keys` | ◐ | Capture-only positional and symbol-keyed named values are implemented; all Ruby pattern-matching edge cases are not yet verified. |

## Current conclusion

Core MVP and the planned v1 explicit API and major syntax families are
implemented. Remaining compatibility gaps are concentrated in the rows marked
`◐`: constructor and option combinations, complete encoding and case-folding
matrices, MatchData edge cases, timeout/global-state semantics, and implicit
String/Symbol integration.

Architecture migration is tracked separately. The formal HFA work must finish
the component graph, bounded head-DFA/tail-NFA borders, tagged and semantic
components, common result iterator, and removal of benchmark-specific direct
paths. A compatibility `✅` does not imply that migration status.

## Historical implementation summary

The completed REGEXP-001 through REGEXP-013 work packages established the
public API, syntax, encodings, modes, timeout, MatchData, `scan`, and `gsub`
contracts represented above. Their detailed acceptance history remains in
[`history/v1-task-list.md`](history/v1-task-list.md); the active HFA migration
plan is [`hfa-task-list.md`](hfa-task-list.md).

## References

- [Ruby 4.0.6 `Regexp` documentation](https://docs.ruby-lang.org/en/4.0/Regexp.html)
- [Ruby 4.0.6 `MatchData` documentation](https://docs.ruby-lang.org/en/4.0/MatchData.html)
- [Onibi product overview](onibi-design.md)
- [Formal HFA design](hfa-design.md)
- [Historical Core MVP task list](history/core-mvp-task-list.md)
- [Historical v1 task list](history/v1-task-list.md)

Ruby's official documentation defines the syntax, modes, encodings, timeout
behavior, linear-time query, and public APIs summarized in this snapshot.
