# Design: AST-to-Ruby Regexp Matcher for Onibi

## Metadata

- **Status:** Accepted for implementation
- **Owner:** Onibi maintainers
- **Created:** 2026-08-11
- **Compatibility baseline:** MRI Ruby 4.0.6
- **Supersedes:** Thompson bytecode VM, AST fallback matcher, capture matcher, and DFA specialization as production execution paths

## Decision summary

Onibi will replace its matcher pipeline with:

```text
Regexp source -> Token stream -> AST -> generated Ruby matcher
```

The generated Ruby matcher is the only production execution engine. It performs prioritized backtracking with explicit Ruby data structures, rather than using the Ruby call stack, and returns character-offset capture spans to the existing `Onibi::MatchData` builder. `Onibi::Regexp#match?` and `#match` enter the same generated control program with different result requirements.

The implementation will not build Thompson NFA bytecode, determinize an NFA, retain a DFA cache, or dispatch between VM, AST, capture, NFA, and DFA matchers after migration. During migration only, the current implementation remains available as a test oracle behind an internal flag. It is deleted after the code-generated path passes the exit gates in this document.

This is a single generated-matcher architecture. Shared character, encoding, timeout, and `MatchData` helpers are runtime services, not alternative matching engines.

## Context

The current repository does not have one effective matcher. `Compiler` emits Thompson-like bytecode, `VirtualMachine` executes part of the regular syntax, `AstMatcher` handles features the VM does not complete, and `CaptureMatcher` independently implements capture-producing matching. `MatchingResult` chooses among those paths using pattern-text heuristics. `DfaSpecialization` currently stores metadata but creates another architectural seam and corresponding tests.

This arrangement has three costs:

- a syntax feature can require equivalent changes in several executors;
- routing by pattern spelling can diverge from the parsed semantics;
- capture priority, backtracking, options, and encoding behavior are duplicated.

The attached draft proposed generating Ruby from NFA and DFA forms. That would improve dispatch cost but preserve NFA, DFA, capture-aware variants, backend selection, and fallback behavior. It therefore does not solve the maintenance problem motivating this change. This design instead makes the parsed AST the last regexp-specific representation before Ruby source.

## Goals

- Maintain exactly one production matching algorithm.
- Compile every supported AST node to executable Ruby source on a capability-tested runtime profile.
- Preserve MRI-compatible leftmost-first matching, branch priority, greediness, captures, offsets, errors, and timeout behavior.
- Avoid recursive Ruby matching calls so pattern or input depth cannot overflow the Ruby stack.
- Make generated source deterministic, inspectable in development, safe for untrusted regexp text, and bounded linearly by AST size.
- Keep `match?` free of public result allocation while retaining captures required by backreferences, conditionals, or subexpression semantics.
- Keep the public `Onibi::Regexp` and `Onibi::MatchData` APIs unchanged.
- Remain pure Ruby with zero runtime dependencies and no C extension, FFI, or CRuby-only requirement.
- Delete the legacy bytecode, VM, AST matcher, capture matcher, and DFA paths after a bounded migration.

## Non-goals

- Generating native code or manipulating CRuby instruction sequences.
- Preserving NFA or DFA as an optimization backend.
- Guaranteeing linear-time execution for all patterns. Backreferences, subexpression calls, and several other Ruby regexp features are inherently outside a finite-automaton-only design.
- Making generated source part of the public API or a stable serialization format.
- Persisting compiled Ruby across processes.
- Using Ruby's built-in `Regexp` at runtime.
- Solving every performance problem in the first cutover. Correctness and removal of duplicate engines come first.

## Constraints and invariants

1. The lexer and parser remain the syntax authority. A token-stream nesting guard runs before recursive descent; code generation never reparses pattern text.
2. The compiler handles AST node classes exhaustively. An unknown node fails at `Onibi::Regexp` construction with an internal compilation error; it never silently selects a legacy matcher.
3. Generated source contains only templates and literals serialized from typed compiler values. Raw regexp source is never inserted as Ruby syntax.
4. A successfully constructed regexp has one immutable generated program. Matching does not mutate it.
5. All mutable execution state belongs to one invocation, so concurrent calls on the same regexp do not share cursors, captures, stacks, or counters.
6. Matcher success is represented internally as offsets, not substrings or `MatchData` objects.
7. Generated source size is `O(AST nodes + normalized character-class data)`. Quantifier counts do not cause source unrolling.
8. Production code has no semantic fallback after cutover. Unsupported syntax is rejected by the parser/compiler instead of being routed elsewhere.

## Architecture

```text
pattern + options
        |
      Lexer
        |
   Token stream
        |
 syntactic nesting guard
        |
      Parser
        |
       AST
        |
  Semantic analysis
        |  capture table, group targets, width sets,
        |  nullability, option scopes, first-set hints
        v
 Ruby code generator
        |
 deterministic Ruby source + frozen constants
        |
 capability-gated source compilation
        |
 immutable GeneratedProgram
        |
        +-------------------+
        |                   |
     `match?`             `match`
        |                   |
        +------ same generated control program
                            |
                      offset result
                            |
                     MatchData builder
```

Semantic analysis is a compiler pass over the AST, not a separately executable IR or matcher. Its results are immutable metadata used while emitting Ruby and, where needed, frozen predicate tables passed to the generated program.

## Components

### `Onibi::ParserNestingGuard`

Before recursive descent begins, an iterative pass over the lexer token stream tracks group, assertion, and nested character-class delimiters using lexer-classified tokens, so escaped delimiters and comment contents do not count. Syntactic nesting is limited to 256. Crossing the limit raises `Onibi::RegexpError`, `"regexp compilation limit exceeded: pattern_nesting"`, during construction. Unbalanced syntax remains the parser's responsibility.

The parser accepts the already validated token stream rather than lexing the source again. Tests at 255, 256, and 257 levels run on every supported host and explicitly reject `SystemStackError`. If a supported host cannot recursively parse 256 levels safely, the common limit is lowered before release; it is never raised above the lowest verified host capacity without making the parser iterative.

### `Onibi::Codegen::Analyzer`

The analyzer performs checks and computes facts that are currently scattered across matchers:

- exhaustive AST-node validation;
- numbered and named capture tables;
- subexpression-call targets and recursion detection;
- option/encoding-aware minimum, maximum, and finite width sets;
- nullability and zero-width repetition risk;
- lexical option scopes;
- capture liveness for boolean matching;
- first-character sets and anchoring hints;
- a stable numeric label assignment.

The analyzer must not decide matches. Every fact it computes has unit tests and an MRI differential acceptance case where it affects public behavior.

### `Onibi::Codegen::RubyGenerator`

The generator lowers the analyzed AST into a closed set of Ruby templates. Each AST node compiler emits labels, cursor operations, state updates, and branches into one method body. The initial emitter uses a label loop because it represents arbitrary cycles without recursive Ruby calls:

```ruby
label = 0

loop do
  steps += 1
  case label
  when 0
    # generated operation for a concrete AST location
  when 1
    # generated transition for another location
  end
end
```

This loop is not a bytecode VM: there are no instruction objects, generic opcode decoder, NFA state sets, DFA states, or runtime AST traversal. All cases and operands are emitted for one regexp. Straight-line sequences may later be coalesced into a case arm, but the label-loop form remains the semantic baseline.

### `Onibi::Codegen::GeneratedProgram`

`GeneratedProgram` owns:

- the anonymous module containing fixed-name generated methods;
- frozen constants/predicate tables needed by those methods;
- compiler version and optional diagnostic metadata;
- `search(input, position, capture:)`, the internal entry point.

The public regexp instance owns one frozen `GeneratedProgram`. It does not retain bytecode, NFA, DFA, or mutable specialization data.

### Runtime helpers

Small shared helpers are permitted for operations whose semantics should not be duplicated in generated source, such as Unicode properties, character classes, case folding, timeout checks, and input cursor conversion. A helper must be a leaf operation: it may answer a predicate or update a supplied execution state, but it may not interpret AST nodes, labels, opcodes, or alternative matchers.

## Semantic contract

MRI Ruby 4.0.6 is the behavioral oracle. For every supported pattern, options, input, and start position, Onibi must agree on:

- match versus no match;
- the leftmost start position;
- the first successful path at that start position;
- overall match and capture contents;
- character and byte offsets;
- unmatched and empty captures;
- named-capture lookup and repeated-capture results;
- exception class and observable timing;
- timeout behavior within the precision allowed by the existing compatibility harness.

Internal label order, stack shape, allocation count, generated source, and optimization choices are not observable contracts.

### Search and path priority

`search` stores the normalized public start position once as immutable `search_origin`, then tries candidate start positions in increasing character-offset order. `match_at` explores choices in MRI priority order. The first accepted path at the first accepted start wins. `\G` compares the current cursor with `search_origin`, not with the current candidate's `match_start`; for example, `Regexp.new("\\Ga").match("ba", 0)` must fail while the same match from position 1 succeeds at `[1, 2]`.

The compiler assigns a deterministic order to alternatives:

- alternation evaluates branches left to right;
- a greedy quantifier prefers another repetition before its exit;
- a lazy quantifier prefers its exit before another repetition;
- a possessive quantifier discards its internal alternatives once it has consumed as much as its semantics allow;
- an atomic group discards alternatives created inside the group after the group succeeds.

Search optimizations may skip candidate positions only when analysis proves that the skipped positions cannot match. Each optimization is differentially tested against the unoptimized generated search loop.

### Backtracking and capture state

Every invocation owns an explicit execution state:

```text
cursor             current character offset
search_origin      immutable public start-position origin for `\G`
match_start        group 0 start, mutable for `\K`
captures           begin/end slots for groups
capture_trail      old slot values for rollback
backtrack_stack    alternative label + cursor + saved state tops
call_arena/top     persistent subexpression return frames
repeat_arena/top   activation-scoped count/progress frames
cut_arena/top      persistent atomic/possessive boundaries
steps/deadline     resource accounting
```

A backtrack frame records the capture-trail depth and the current call/repeat/cut top pointers needed to restore a checkpoint. Capture writes append their old values to the trail. Call, repeat, and cut frames are immutable append-only arena entries linked by integer parent indexes, so a checkpoint can restore a logically returned activation without copying a Ruby array. Each repeat frame contains its AST label, call activation ID, count, entry cursor, last-progress cursor/state, and parent repeat top; recursive calls therefore never overwrite another activation's quantifier state.

Capture slots use `nil` for unmatched boundaries and character offsets for matched boundaries. Group 0 is stored explicitly because `\K` can change its begin position without changing the current cursor.

Captures that are not observable may be removed in `capture: false` mode only if analysis proves they are not read by a backreference, conditional, subexpression call, assertion, or another semantic operation. The default implementation keeps all semantic captures until this liveness optimization is proven.

### AST lowering rules

- **Sequence:** emit the children in order and pass success to the next child.
- **Alternation:** push later branches as checkpoints, then enter the first branch.
- **Literal / character class:** ask the option/encoding-aware atom helper for an ordered set of candidate end cursors, push later candidates, and enter the preferred one. Full case folding may consume a different number of input characters than the pattern contains.
- **Escape / property / dot:** call a frozen predicate or leaf helper and use its candidate end cursor or cursors. Dot and most properties consume one logical character; `\R` and case-fold-sensitive forms are explicitly variable-width.
- **Capture group:** trail and write its begin slot on entry and end slot on successful exit.
- **Quantifier:** use a runtime counter and generated entry/body/exit labels. Never unroll `{m,n}` proportional to `n`.
- **Anchor / boundary:** test the current cursor without consuming input.
- **Lookahead:** enter an assertion boundary with the original cursor and state tops. Positive lookahead commits captures from its first successful internal path, restores the cursor, and discards all internal choice/call/repeat/cut frames so later outer failure cannot re-enter it. Negative lookahead explores all internal choices; it succeeds only when none accepts and restores cursor, captures, and every state top.
- **Lookbehind:** use the analyzer's option/encoding-aware finite width set to choose candidate start positions, execute the assertion region, and require it to end at the original cursor. It uses the same positive/negative commit rules as lookahead.
- **Atomic group / possessive quantifier:** record stack depth and remove checkpoints created inside the cut region when it commits.
- **Backreference:** read the selected capture and compare the referenced input slice using the active option and encoding semantics.
- **Conditional:** branch from capture participation or the parsed assertion condition.
- **Subexpression call:** allocate a new call activation and jump to the generated target with an explicit return continuation. Internal choice points remain on the global backtrack stack after a logical return; if the caller's suffix fails, restoration re-enters the saved call activation and can try its next path. Captures written by the selected call path commit normally. Recursion depth is budgeted; Ruby method recursion is not used.
- **Absence operator:** implement the absent-stopper rule described below; it is not delegated to a generic assertion helper.
- **Match reset (`\K`):** trail and update `match_start` at the current cursor.

Each rule has one code generator implementation. There is no capture-specific reimplementation of the node.

### Variable-width full case folding

Ruby ignore-case matching is not a one-pattern-character-to-one-input-character operation. On MRI 4.0.6, `/[ß]/i` matches `"ss"` with offset `[0, 2]`, `/ß/i` matches `"SS"` with `[0, 2]`, and `/(?<=[ß])x/i` matches `"ssx"` at `[2, 3]`.

Consequently, a consuming atom returns zero or more candidate end cursors rather than a boolean. Candidate order is part of the MRI differential contract. Width analysis is scoped by options and encoding and returns a finite set or `variable`, never an unconditional scalar based only on AST character count. Lookbehind compilation uses that set; if MRI accepts a lookbehind whose fold expansion has widths `{1, 2}`, the generated matcher probes both starts in MRI priority order. Literal-run optimization must preserve the baseline atom candidates.

### Assertion and subexpression choice boundaries

Assertions and calls deliberately differ. A successful positive assertion is atomic with respect to its internal choice points, while its MRI-visible captures commit. A negative assertion commits no speculative state. A subexpression call is non-atomic unless enclosed by an atomic/possessive cut: internal alternatives survive logical return and can be restored after a caller suffix fails. Checkpoints therefore save persistent call/repeat/cut top pointers, not only stack lengths.

Required contract probes include `(?=(a|aa))\\1b` on `"aab"` (the start-zero assertion choice is not revisited) and `(?<x>a|ab)c\\g<x>d` on `"acabd"` (the returned call is revisited and captures `"ab"`).

### Absence operator semantics

For `(?~body)` entered at cursor `s`, the generated region searches `body` from `s` using normal leftmost-first semantics. If the selected stopper match ends at `e`, the absence region offers end cursors from `e - 1` down to `s`; if no stopper exists, it offers input end down to `s`. The stopper's MRI-visible captures are trailed and retained for the selected absence path even though its final character is excluded from the overall span. A failing suffix backtracks through the offered ends and then through the outer search. An empty stopper has a dedicated terminal rule: it yields the MRI-compatible empty match only at input end and never creates a zero-progress loop.

This contract is pinned before lowering with `(?~real)` and `(?~real)ist` on `"surrealist"`, `(?~a)` on `"ba"`, `(?~(a))` on `"ba"`, and `(?~)` on non-empty and empty inputs. Nested alternatives, captures, lookarounds, and cuts inside `body` extend that corpus; any observation that contradicts the rule blocks implementation and requires a design revision.

### Empty matches and termination

Nullable quantified bodies can otherwise loop forever. Every quantifier records the cursor at entry to an iteration. If the body succeeds without progress, the generated code follows the MRI-compatible exit/backtrack rule and does not enqueue the same `(quantifier, cursor, relevant state)` indefinitely.

Subexpression recursion, nested assertions, and backtracking use explicit stacks and counters. A malformed internal control graph raises an internal invariant error; it must not hang.

The matcher returns one result. Repeated-match APIs such as `scan` and `gsub` remain responsible for advancing after an empty match according to their existing public contract.

## Encoding and cursor model

Correct offsets take precedence over byte-only code generation. The baseline execution cursor is a logical character index, matching the public `MatchData#begin`, `#end`, and `#offset` contract.

An invocation creates an `InputView` with:

- the original frozen-or-borrowed input string;
- its encoding and validity mode;
- logical characters or codepoints used by predicates;
- a boundary table mapping character offsets to byte offsets when byte offsets are requested.

UTF-8 and other valid text use encoded characters. ASCII-8BIT and the existing invalid-byte behavior use bytes according to the compatibility matrix. Encoding compatibility is validated before entering generated code. Code generation never assumes UTF-8 and never calls `getbyte` as though one byte were one public character.

The cutover gate covers every encoding in Onibi's recorded migration baseline, initially UTF-8, US-ASCII, ASCII-8BIT, EUC-JP, and Windows-31J, including same-encoding, ASCII-compatible cross-encoding, incompatible non-ASCII input, invalid sequences, case folding, and both offset units. Adding every remaining Onigumo encoding is still a v1 release goal in the canonical design; it uses the same `InputView`/atom interfaces and does not add a matcher. The task list contains a pre-cutover encoding task rather than deferring this to a cross-runtime smoke test.

An ASCII-compatible fast path may access bytes directly when both pattern analysis and input prove that byte and character offsets are identical over the inspected region. It must return the same internal offset result as the baseline `InputView` path.

## Generated result protocol

The generated program returns:

- `nil` for no match;
- `true` for `capture: false` success; or
- a fixed-shape array `[match_begin, match_end, capture_offsets]` for `capture: true` success.

`capture_offsets` contains `[begin, end]` or `nil` per numbered group. The existing regexp facade converts this protocol into `Onibi::MatchData`. Generated code does not construct public objects and does not update global Ruby match variables.

## Compilation strategy

`Onibi::Codegen::SourceCompiler` is a small host adapter that compiles the same generated Ruby source without changing matching semantics. MRI, JRuby, and TruffleRuby use string `Module#module_eval` with a synthetic filename such as `(onibi-regexp:<digest>)` and line 1. The source defines fixed `module_function` entry names in a fresh anonymous module; `GeneratedProgram` invokes that module and passes the input view, frozen table, and invocation state explicitly. Fixed names avoid creating one permanent Symbol per regexp, and no global constants are registered.

mruby is supported only through a selected build profile that includes a runtime source parser/evaluator (normally the `mruby-eval` mrbgem) and passes the source-compiler capability suite. A minimal mruby build without runtime eval is not a supported Onibi v1 runtime. If the capability spike cannot compile and invoke the generated source with equivalent scoping and errors, implementation is blocked until the canonical platform promise is changed; no bytecode/AST matcher is added as a fallback.

`RubyVM::InstructionSequence` may be used only by optional benchmark or diagnostic tooling. Production behavior and tests must not depend on it because it is CRuby-specific. The source-compiler adapter may select an equivalent string-eval entry point on a supported host, but it may not introduce another matcher representation.

Compilation occurs eagerly in `Onibi::Regexp#initialize`. Eager compilation preserves constructor-time error behavior and makes a constructed regexp immutable. Lazy JIT compilation by the host Ruby remains outside Onibi's contract.

If Ruby compilation rejects generated source, Onibi raises an internal `CodegenError` containing the pattern digest, compiler version, and generated location. The raw pattern and generated source are included only in an explicitly enabled diagnostic dump.

## Compilation safety

Regexp patterns are untrusted input. The code generator follows these rules:

- never interpolate pattern text, capture names, property names, encodings, or user strings as Ruby source fragments;
- generate identifiers only from fixed prefixes and compiler-assigned integers;
- serialize necessary scalar literals through one audited emitter;
- place complex character sets and strings in a separately built, recursively frozen constant table passed to generated methods;
- validate every label target and table index before calling `module_eval`;
- scan generated source in tests to reject dangerous constructs such as constant assignment, command execution, arbitrary method sends, global variables, and additional `eval` calls;
- fuzz patterns containing quotes, interpolation markers, newlines, encoding directives, NUL bytes, and comment markers;
- never write generated source to disk unless diagnostic mode names an explicit destination.

`$SAFE` and taint are not security boundaries and are not used.

## Cache, lifetime, and invalidation

The initial cache is exactly one generated program per `Onibi::Regexp` instance. There is no process-global cache, eviction policy, or weak-reference complexity during migration.

The program identity includes the normalized AST semantics, options, encoding mode, and `CODEGEN_VERSION`. If a future shared cache is introduced, it must use a bounded entry and byte budget, collision-safe equality after hashing, and concurrency tests. Marshal persistence is out of scope.

The generated module becomes collectible with the regexp instance. Diagnostic source retention is disabled by default so ordinary use does not retain a second large string.

## Concurrency and Ractor

Concurrent `Thread` calls are supported because all execution state is invocation-local and the generated program is immutable. Construction is eager, so matching does not race to publish generated code.

Ractor support is an explicit compatibility gate, not an assumption. Ruby 4.0 permits methods defined from a string with `module_eval` to be called across Ractors, but an `Onibi::Regexp` is shareable only if its entire reachable object graph is shareable. The implementation must either:

1. recursively freeze and make the regexp, generated module references, and constant table shareable; or
2. document that each Ractor must construct its own `Onibi::Regexp` until shareability is implemented.

The task list requires a probe and acceptance test before choosing. No mutable global compiler cache may be introduced to solve Ractor sharing.

## Resource limits

Code generation changes execution shape but does not eliminate ReDoS. Onibi retains public timeout behavior and adds deterministic internal accounting.

### Compile-time limits

- AST nodes: 100,000;
- syntactic nesting before recursive parsing: 256;
- generated labels: 1,000,000;
- generated source: 16 MiB, checked before and after emission;
- normalized predicate/character-class tables: 64 MiB;
- no quantifier unrolling by its numeric maximum.

These initial ceilings are internal constants, not user configuration. The nesting ceiling is checked iteratively on tokens before the recursive parser; the remaining compile ceilings are enforced during/after AST analysis and emission. A ceiling hit during construction raises `Onibi::RegexpError` with `"regexp compilation limit exceeded: <limit>"`; a generator invariant raises `Onibi::CodegenError` instead. Tests inject smaller internal limits and cover `N-1`, `N`, and `N+1` without allocating production-sized fixtures. Valid patterns within the limits compile through the one backend. The final implementation never falls back to the old engine when a limit is reached.

### Match-time limits

- step counter incremented at generated backward edges, choice restoration, subexpression calls, and periodically in straight-line regions;
- monotonic deadline checks derived from the regexp instance/class timeout;
- backtrack frames: 1,048,576;
- call activations: 65,536;
- repeat arena entries: 1,048,576;
- capture-trail entries: 4,194,304;
- consistent `Onibi::Regexp::TimeoutError` for elapsed public timeout;
- no independent default step ceiling when timeout is `nil`.

A non-time match ceiling raises `Onibi::RegexpError` at the attempted over-budget push with `"regexp match limit exceeded: <limit>"`. These safety exceptions are documented deviations for adversarial resource exhaustion; they are distinct from syntax errors by message and timing. Tests inject reduced internal limits and cover `N-1`, `N`, `N+1`, cleanup, and the next match. A future configurable/public limit surface requires a separate design change.

The initial cutover may retain the existing outer `Timeout.timeout` wrapper as a safety net. Cooperative deadline checks become the primary mechanism only after differential timeout and interrupt tests pass.

## Diagnostics and observability

Development-only diagnostics expose a pattern digest, compiler version, source byte count, label count, predicate-table size, compile duration, match steps, maximum stack depths, and timeout reason. They do not expose untrusted pattern/input contents by default.

`generated_source` is not a public API. Tests may request it through an internal compiler object. When source dumping is enabled, filenames use a digest and permissions prevent unintended disclosure.

## Optimization policy

The label-loop generator is the correctness baseline. Optimizations are compiler transformations on the same generated control graph, not additional engines. Each optimization must be independently disableable in tests and must differentially agree with unoptimized code generation and MRI.

Allowed early optimizations include:

- coalescing straight-line labels;
- literal-run comparison;
- anchored search elimination;
- first-character and required-literal skipping;
- experimental multi-literal candidate skipping with fixed-width SWAR bitmaps;
- ASCII byte fast path;
- capture liveness for `match?`;
- reducing redundant checkpoints and capture-trail writes.

An optimization is accepted only when it reduces a measured workload without an unacceptable compile-time, source-size, or memory regression. YJIT/ZJIT improvements are a benefit, not a correctness dependency.

The experimental SWAR prefilter applies by default only to whole-regexp
alternations of two or more ASCII literals whose lengths are between two bytes
and one native word. It packs literal positions into native-word
Shift-And buckets separated by zero guard bits and masks every state transition
back to the native word width. Search probes the initial position directly and
uses the bitmap prefilter only when at least one native word of input remains.
The prefilter supplies ordered candidate start positions to the same generated
matcher; longer literals, unsupported AST shapes, ignorecase, non-ASCII input,
and short remaining input retain the baseline candidate loop. Tests and
benchmarks can disable SWAR or opt into single-character or long-literal prefix
filtering internally, but none is a user-facing backend selection. The default
policy is benchmark-driven: one-character literals improve long late matches
but regress the common early-match path even after the guards, while
long-literal prefix filtering regresses the measured late workload.

## Testing strategy

### Acceptance and differential tests

Public acceptance tests compare Onibi with MRI for every supported syntax category, both `match?` and capture-producing APIs, positive and negative start positions, options, encodings, empty matches, and errors. Warm-up does not change results.

High-risk deterministic corpora include:

- `(a|aa)`, `(a*)(a*)`, `(.*)(.*)` for priority and captures;
- nested greedy/lazy/possessive quantifiers;
- empty quantified bodies and empty alternatives;
- captures inside positive and negative assertions;
- option/encoding-aware lookbehind width sets and full-fold expansions;
- atomic groups followed by failing suffixes;
- numbered/named backreferences and unmatched references;
- recursive and nested quantified subexpression-call activations;
- conditionals, absence, `\G`, `\K`, and `\R`;
- `/[ß]/i` on `"ss"`, `/ß/i` on `"SS"`, and `/(?<=[ß])x/i` on `"ssx"`;
- `\G` with a later viable candidate from positions zero and one;
- UTF-8, US-ASCII, ASCII-8BIT, EUC-JP, Windows-31J, invalid bytes, and cross-encoding cases;
- adversarial source-injection strings.

### Compiler tests

- every AST class has exactly one lowering handler;
- every generated label has a valid target;
- source is deterministic for equivalent analyzed input;
- source size grows linearly for large bounds and large ASTs;
- generated code parses under every supported Ruby implementation;
- the selected mruby build profile provides a working runtime source compiler;
- no generated method recursively invokes the matcher;
- all mutable state is invocation-local.

### Property and fuzz tests

Generate bounded ASTs and inputs, compare MRI with generated Onibi, and record the seed. Any failure that can be reduced becomes a deterministic regression test before the fix. During migration, a `verify` mode may also compare the legacy result; this mode is test-only and is removed with the legacy code.

### Performance tests

Measure construction, first match, warm match, allocations, generated source size, stack/trail peaks, and timeout overhead. Compare:

- current Onibi at the migration baseline;
- unoptimized generated matcher;
- optimized generated matcher;
- MRI `Regexp`;
- interpreter, YJIT, and ZJIT configurations where available.

Performance data guides optimization but does not excuse semantic differences.

## Migration and deletion criteria

Migration is deliberately one-way and bounded:

1. Freeze the current MRI differential corpus and record the legacy baseline.
2. Add the generator and run it only in tests for a literal subset.
3. Extend the same generated control program feature by feature.
4. Add internal `legacy`, `codegen`, and `verify` modes for test and benchmark comparison. User-facing backend selection is prohibited.
5. While codegen is still explicitly selected, run `match?`, `match`, `scan`, `gsub`, the full encoding matrix, property/fuzz and injection corpora, concurrency/Ractor contract, package gates, cross-runtime source-compilation/execution tests, and benchmark guardrails.
6. Switch all public matching defaults only after every pre-cutover gate passes.
7. Remove the internal mode, routing heuristics, and every legacy execution file in one final atomic change.

Deletion is allowed only when:

- all supported syntax and API differential tests pass through codegen;
- no test inspects `@bytecode`, NFA/DFA state, or matcher selection;
- long non-matches and recursive syntax do not overflow the Ruby stack;
- timeout, concurrent-call, source-safety, encoding, and package tests pass;
- no production require references the legacy files;
- a repository search finds no production `Compiler`, `Bytecode`, `VirtualMachine`, `AstMatcher`, `CaptureMatcher`, `MatchingResult`, or `DfaSpecialization` constant.

The files expected to be removed include `bytecode.rb`, the Thompson compiler files, `virtual_machine*.rb`, `ast_matcher*.rb`, `capture_matcher*.rb`, `matching_result.rb`, and `dfa.rb`. Predicate, parser, capture-name, timeout, and `MatchData` helpers remain if they satisfy the leaf-helper rule.

## Rollout and rollback

Each task ships through its own branch and pull request. Before final deletion, a bad codegen change can be reverted or the internal test-only default can be switched back in a follow-up PR. After deletion, rollback is a Git revert of the cutover/deletion commit; the production gem does not carry a permanent alternate engine.

No generated-source format compatibility is promised between gem versions. A release containing the final cutover must call out the architectural change and the timeout/performance characteristics observed by the benchmark suite.

## Rejected alternatives

### Generate Ruby from NFA and DFA

Rejected because it retains multiple automata, capture-aware variants, backend selection, state-explosion policy, and fallback logic. It optimizes execution but does not achieve the maintenance objective.

### Keep a reference VM in production

Rejected after migration because every new semantic feature would still need two implementations. The historical commit and MRI differential suite are the references. A legacy oracle is permitted only during the bounded migration.

### Recursive AST-to-Ruby methods or nested lambdas

Rejected as the baseline because nested patterns, repetitions, and subexpression calls could consume the Ruby call stack. Explicit stacks make limits observable and testable.

### Generate one Ruby method per regexp state in a global module

Rejected because unbounded regexp construction would create permanent method names/symbols and complicate cleanup. Anonymous modules with fixed method names have instance lifetime.

### Direct `RubyVM::InstructionSequence` generation

Rejected as a production dependency because it is CRuby-specific and unstable across Ruby releases. It remains diagnostic-only.

### Continue routing by pattern text

Rejected because spelling is not a semantic capability check and has already produced multiple matcher paths. The AST and analyzer are the only routing authority.

### Compile through Ruby's built-in `Regexp`

Rejected because Onibi must remain an independent pure Ruby regexp implementation and future MRI replacement candidate.

## Risks and mitigations

- **Backtracking can be slower or exponential.** Preserve timeout behavior, add explicit accounting, and benchmark pathological patterns.
- **The label loop may not outperform the current VM.** The primary objective is one correct engine; straight-line coalescing and other transformations can optimize the same control graph later.
- **Generated source can be a code-injection boundary.** Use typed templates, separate frozen constants, source scanning, and hostile-pattern fuzzing.
- **Capture rollback is subtle.** Centralize it in trail operations and maintain a focused ambiguity corpus.
- **Encoding shortcuts can corrupt offsets.** Start with `InputView`; add byte fast paths only behind equivalence tests.
- **Migration can prolong duplicate maintenance.** Use the ordered task list, forbid public backend selection, and make deletion a release gate.
- **Ractor may conflict with generated object graphs.** Probe it explicitly and document per-Ractor construction if full sharing is not yet supportable.

## Success criteria

The redesign is complete when the public and differential suites pass with this sole pipeline:

```text
Regexp source -> Token stream -> AST -> generated Ruby matcher -> offset result
```

At that point the gem contains no executable NFA, DFA, bytecode VM, AST-walking matcher, capture-specific matcher, or runtime matcher-selection heuristic. One AST-node lowering implementation defines matching behavior, and every future syntax change begins with an MRI differential acceptance test for that implementation.

## Adversarial review disposition

An independent senior-engineer subagent reviewed the design against the current Onibi implementation in three rounds on 2026-08-11. The first round rejected the draft for two P0 and several P1 gaps. Corrections added:

- variable-width full case folding and option/encoding-aware lookbehind width sets;
- capability-gated source compilation and the source-eval-capable mruby profile;
- activation-scoped persistent call/repeat/cut state and complete checkpoint restoration;
- normative assertion, subexpression-call, `\G`, and absence behavior;
- exact compile/match resource contracts and a pre-parser nesting guard;
- a five-encoding migration matrix and pre-cutover security/concurrency/product gates;
- corrected TDD ordering and the 25-task dependency graph.

The second round found only the pre-parser nesting issue. After the iterative token-stream guard and cross-host boundary tests were added, the third round returned **APPROVE** with no remaining P0 or P1 findings. Lower-priority discoveries during implementation still require normal design amendments and TDD; approval does not waive any exit gate.

## References

- [Ruby 4.0 Regexp documentation](https://docs.ruby-lang.org/en/4.0/Regexp.html)
- [Ruby 4.0 Ractor documentation](https://docs.ruby-lang.org/en/4.0/language/ractor_md.html)
- [Ruby source repository](https://github.com/ruby/ruby/)
- [`docs/onibi-design.md`](onibi-design.md)
- [`docs/regexp-feature-coverage.md`](regexp-feature-coverage.md)
