# Onibi performance profiling

This document records the profiling environment and the current root-cause
analysis for the generated-Ruby matcher. It is intentionally a diagnosis
document, not a performance claim or a pull request proposal.

## Environment

- Ruby 4.0.6 (`/opt/homebrew/opt/ruby/bin/ruby`)
- Architecture: arm64 macOS
- YJIT: available in the selected Ruby
- YARV `RubyVM::InstructionSequence`: available
- External sampling profilers: not required by the harness
- Benchmark workload: `benchmark/fasta-500.txt` through `benchmark/regex_redux.rb`

The repository-local `.bundle` directory must be built by the same Ruby as the
one used for measurements. If it was built by rbenv or another Ruby, native
extensions such as `json` can fail to load or produce incomparable results.

```sh
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
bundle pristine
bundle install
```

## Profiling harness

The dependency-free harness is [`script/profile_regex_redux.rb`](../script/profile_regex_redux.rb).
It reports:

- wall, user, and system time;
- `GC.stat` deltas and total allocated objects;
- YARV generated source size, instruction count, local count, and stack max;
- YJIT runtime counters when YJIT is enabled;
- optional TracePoint call counts;
- optional per-operation time and allocation breakdown for the warm workload.

The two phases deliberately answer different questions:

```sh
# Includes Onibi's lazy generated-program construction.
RUBYLIB=lib bundle exec ruby script/profile_regex_redux.rb \
  --engine onibi --phase end_to_end --iterations 5 --warmup 1 --profile none

# Reuses compiled patterns and measures matching/replacement work.
RUBYLIB=lib bundle exec ruby script/profile_regex_redux.rb \
  --engine onibi --phase warm_match --iterations 5 --warmup 1 --profile none

# Call-shape profile. TracePoint changes absolute timings and is not a timing run.
RUBYLIB=lib bundle exec ruby script/profile_regex_redux.rb \
  --engine onibi --phase warm_match --iterations 1 --warmup 0 --profile trace

# Per-pattern/per-replacement breakdown.
RUBYLIB=lib bundle exec ruby script/profile_regex_redux.rb \
  --engine onibi --phase warm_match --iterations 2 --warmup 1 \
  --profile none --breakdown

# YJIT counters and timing.
RUBYLIB=lib bundle exec ruby --yjit script/profile_regex_redux.rb \
  --engine onibi --phase warm_match --iterations 5 --warmup 1 \
  --profile none --yjit
```

The `--yjit` script option is useful when the process was not started with
`ruby --yjit`; for stable runs, prefer `ruby --yjit` and retain the option so
the report records the request explicitly.

## Important measurement boundary

`Onibi::Regexp#initialize` currently lexes, parses, and analyzes the pattern.
The generated Ruby source and `Module#module_eval` are lazy and happen on the
first match. Therefore:

- `compile` in `benchmark/regexp_features.rb` does not include code generation;
- `first_match` includes lazy code generation and source compilation;
- the `match` operation in that benchmark is actually `match?`, not `match` and
  does not include `MatchData` construction.

The profiling harness keeps cold (`end_to_end`) and warm (`warm_match`) phases
separate to avoid attributing lifecycle costs to the wrong component.

## Measurements on current `main`

The following values were collected with Ruby 4.0.6 and the harness above.
TracePoint was disabled for timing/allocation runs.

### Warm workload, no YJIT

| engine | iterations | wall/iteration | allocated objects/iteration | GC/iteration |
|---|---:|---:|---:|---:|
| Ruby | 100 | 0.001227 s | ~64 | 0 |
| Onibi | 5 | 0.259979 s | ~5,858,279 | 122 |

Onibi is approximately 212x slower per reused workload iteration in this
steady-state harness. The earlier command-level ratio was much smaller because
the single `fasta-500` process is dominated by startup and has only one
workload execution.

### Cold/end-to-end Onibi

For three measured iterations without YJIT:

- 0.260463 s/iteration;
- 17,590,758 allocated objects total;
- 323 GC cycles, including 5 major collections.

The cold and warm figures are close for this workload, so lazy code generation
is not the dominant cost after the generated program has been established.

### YJIT

For five warm Onibi iterations, the measured wall time changed from about
0.260 s/iteration without YJIT to about 0.238 s/iteration with YJIT in the
instrumented run. This is a modest improvement, not a root-cause fix.

YJIT also spent about 67 ms compiling code during that five-iteration run.
The generated program produced 1,109 bytes of Ruby source, 149 counted YARV
instructions, 14 locals, and a maximum YARV stack depth of 3 for the sample
`a.*z` program. The small generated method size but high runtime cost indicates
that helper calls and allocations, rather than a large YARV instruction body,
are the primary issue.

## Operation breakdown

Two warm Onibi iterations produced this breakdown:

| operation | seconds | allocations |
|---|---:|---:|
| `replace:<[^>]*>` | 0.139704 | 3,922,372 |
| `replace:a[NSt]|BY` | 0.138196 | 3,696,399 |
| `replace:\|[^|][^|]*\|` | 0.064746 | 1,657,725 |
| `count:[cgt]gggtaaa|tttaccc[acg]` | 0.037959 | 344,211 |
| `count:agggtaa[cgt]|[acg]ttaccct` | 0.037140 | 351,783 |
| `remove_breaks` | 0.037094 | 954,861 |

The three replacement operations account for approximately 66% of measured
time and 79% of allocated objects in this run. The two largest replacement
operations alone account for more than half of measured time.

The corresponding Ruby engine completes the same prepared workload in about
0.0013 s/iteration and allocates only about 100 objects per iteration. The
large difference is therefore not explained by regex syntax complexity alone;
it is concentrated in Onibi's replacement/match integration.

## TracePoint evidence

TracePoint changes timing, so these are call-shape observations only. In a
five-iteration cold Onibi profile, the most frequent calls included:

```text
String#==                         2,612,605
String#[]                         1,857,740
NilClass#nil?                     1,710,690
Integer#+                           785,965
Array.new / Array#initialize       359,020
ClassPredicates#intersection_state 242,590
ClassPredicates#intersection_marker? 242,590
ClassPredicates#atom                192,115
ClassPredicates#range_matches?      192,115
Codegen::Casefold#class_candidates  85,760
ClassPredicates#matches?             85,750
```

This confirms that the hot path is executing many small Ruby operations and
re-parsing character-class source, rather than spending time in one large
generated YARV method.

## Root-cause classification

### Design-level problems

1. **Bulk replacement is expressed as repeated public matching.**
   `RegexRedux::OnibiEngine#replace` repeatedly calls `Regexp#match`. Each
   match performs candidate search and constructs `MatchData`, even though
   replacement only needs offsets and the replacement text. The public
   `scan`/`gsub` layer has the same shape. This is an API/control-flow design
   mismatch for bulk operations.

2. **Search invokes the generated method once per candidate start position.**
   `GeneratedProgram#search` loops over candidate positions and calls the
   generated entrypoint for each one. A failed unanchored search therefore
   pays a method-entry and state-initialization cost at every character.

3. **The boolean path still creates capture state.**
   The generated entrypoint allocates `captures = Array.new(capture_count)` even
   when `capture: false`. This prevents `match?` from being a genuinely cheap
   result path.

4. **Generated code does not yet provide a bulk offset iterator.**
   The architecture exposes one-match `search`; `scan` and `gsub` must rebuild
   higher-level behavior through repeated public calls. A matcher-level
   offset iterator would avoid repeated adapter and `MatchData` work.

### Code-level inefficiencies

1. **Character-class source is interpreted repeatedly.**
   `ClassPredicates.matches?` scans class source, detects intersections, and
   parses atoms for every tested character. The TracePoint counts and the
   `count` rows show this is expensive for the regex-redux classes.

2. **Quantifier backtracking snapshots copy captures.**
   Generated quantifier expressions use `captures.map { |item| item&.dup }` for
   candidates. This creates large transient object volumes when a suffix
   causes backtracking.

3. **`MatchAdapter` materializes character arrays and strings.**
   `match` converts the entire input with `chars` and reconstructs full/capture
   strings with slices and joins. This is unnecessary for boolean matching and
   expensive when called repeatedly by replacement.

4. **Generated code repeatedly dispatches through accessor/helper calls.**
   The hot call list contains `GeneratedProgram#compiled_module`,
   `#entrypoint`, `String#[]`, `String#==`, and small predicate methods at very
   high frequency. These are implementation costs after the architecture has
   selected the generated matcher.

## Current conclusion

The implementation work is split into independently executable design packages:

- [search-plan design](design-search-plan.md)
- [one-pass execution design](design-one-pass-execution.md)
- [offset iterator design](design-offset-iterator.md)
- [compiled character predicates design](design-compiled-class-predicates.md)
- [boolean match path design](design-boolean-match-path.md)

The dominant issue is a **design problem amplified by inefficient code**:

- The design routes `gsub`/replacement through repeated full `match` calls and
  lacks a bulk offset-producing execution surface.
- The implementation then makes each of those calls expensive through
  per-candidate entrypoints, unconditional capture arrays, repeated class
  parsing, capture snapshots, and `MatchData` materialization.

YJIT is not the root cause. It provides a modest warm improvement, but it
cannot remove the allocation volume or the repeated public-API control flow.
The first fixes to evaluate should therefore be measured in this order:

1. Add an internal offset-only repeated-match path and measure replacement
   without `MatchData`.
2. Reuse or precompile character-class predicates/tables and measure the class
   microbenchmarks again.
3. Avoid capture allocation in proven boolean paths.
4. Replace capture-array snapshots with a rollback representation that does
   not copy all captures per quantifier candidate.
5. Re-measure candidate-start search separately on anchored, first-hit,
   last-hit, and miss inputs.

Each change must preserve the existing MRI differential corpus; the profile
numbers alone are not correctness evidence.

## Feature microbenchmark analysis

The feature corpus contains 37 cases across ASCII and UTF-8 and measures
`compile`, `first_match`, and warm `match?`. The run used
`benchmark/regexp_features.rb --operation all --time 0.2 --warmup 0.1` on
Ruby 4.0.6. The pairwise IPS comparison was:

| operation | median Onibi slowdown | largest slowdown |
|---|---:|---:|
| compile | about 39x | about 78x in the short IPS run |
| first_match | about 112x | about 191x |
| warm match? | about 28x | about 831x |

The case profiler is [`script/profile_regexp_features.rb`](../script/profile_regexp_features.rb).
It primes lazy generated programs before the `match` measurement, so its warm
numbers do not accidentally include source compilation. It reports one row per
case with time, allocation, GC count, generated source bytes, and YARV
instruction count:

```sh
RUBYLIB=lib bundle exec ruby script/profile_regexp_features.rb \
  --engine onibi --operation all --iterations 20 --format tsv > onibi.tsv
RUBYLIB=lib bundle exec ruby script/profile_regexp_features.rb \
  --engine ruby --operation all --iterations 100 --format tsv > ruby.tsv
```

### Compile phase

Compile cost is broad rather than isolated to the generated matcher. The
profiler's `compile` operation constructs `Onibi::Regexp` repeatedly, so it
covers lexer, token-stream validation, parser, AST allocation, and analyzer
work, but not `RubyGenerator` or `Module#module_eval`.

Representative steady measurements (per construction) were roughly:

- 40x median slowdown across the corpus;
- 100x or more for `match_reset` and lookbehind cases;
- roughly 150-280 allocated objects per Onibi construction, versus about 2
  objects for the corresponding MRI construction in this harness.

This is primarily a **front-end design cost**: Onibi intentionally materializes
tokens, AST nodes, and immutable analysis metadata in multiple passes. The
feature results do not yet prove which pass dominates. The next required
measurement is a stage split for `Lexer`, `Parser`, `Analyzer`, source emission,
and source compilation before changing any of those passes.

### First-match phase

`first_match` includes lazy generated source emission and `module_eval`, in
addition to the first search. Its median slowdown is about 104-112x in the
case profiler. High allocation cases include:

- character-class range/intersection: about 1.5k objects per operation;
- numbered captures: about 1.5k objects per operation;
- lookaround, captures, and quantifiers: several hundred objects per operation.

Generated source size alone does not explain the result. For example, simple
literal and anchor cases still pay the generated-program construction and Ruby
compilation fixed cost. Source sizes in the corpus range from roughly 500 to
2,100 bytes; the largest source is not consistently the slowest first match.

### Warm match phase

After priming the generated program, the median slowdown is about 27x. The
outliers are highly diagnostic:

| case | slowdown | Onibi allocations/op | generated source |
|---|---:|---:|---:|
| character class intersection | about 967x | about 1,286 | 653 bytes / 98 YARV instructions |
| character class range | about 342x | about 1,289 | 1,336 bytes / 123 instructions |
| numbered captures | about 162x | about 250 | 1,549 bytes / 257 instructions |
| named captures | about 153x | about 247 | 1,549 bytes / 257 instructions |
| anchors | about 145x | about 237 | 1,102 bytes / 138 instructions |
| positive lookahead | about 139x | about 273 | 1,504 bytes / 123 instructions |

The intersection/range results point to runtime predicate work, not generated
source size. `ClassPredicates.matches?` walks and reparses the class source for
each tested character; intersection detection, atom parsing, and range checks
are all visible in the TracePoint profile.

The capture and anchor results point to fixed matcher overhead. Even a small
pattern pays for generated entrypoint invocation, candidate-start search,
capture-array creation, and Ruby-level helper dispatch. This is why a 1,100
byte anchor program can be slower than a larger but simpler program.

### YJIT comparison

The per-case inputs are intentionally tiny, so YJIT startup and compilation
noise is substantial. In a 20-iteration warm case run, Onibi's median was not
consistently improved by YJIT (about 0.81x no-YJIT throughput ratio in the
short run), while MRI improved by about 1.18x. Some Onibi cases improved and
others regressed sharply. This confirms that YJIT is not a reliable remedy for
the current architecture; allocation and helper-call volume must be reduced
first, then YJIT should be re-measured on larger inputs.

## Microbenchmark-driven priority

### P0 — make the measurement boundaries explicit

Add a compiler-stage report for each pattern:

```text
Lexer/tokenization
Parser/AST construction
Analyzer metadata
Ruby source emission
Module#module_eval
```

The current `compile` benchmark cannot distinguish these costs, and
`first_match` combines the last two with execution. This instrumentation is a
prerequisite for deciding whether the front-end needs a design change.

### P1 — remove per-match fixed overhead

Measure and then redesign the generated entrypoint around an internal
offset-only search/iteration surface:

- no `MatchData` for `match?`, scan, or replacement;
- no capture array when analysis proves captures are not read;
- fewer generated-method calls while trying candidate start positions;
- one invocation state for a bulk operation rather than one public match per
  occurrence.

This addresses the broad anchor/capture/lookaround slowdown and the
regex-redux replacement hotspot simultaneously.

### P1 — precompile character-class predicates

Normalize and freeze class/intersection/range data at compile time. Runtime
matching should evaluate a predicate/table, not rescan the class source. Use
the range and intersection cases as acceptance performance probes and retain
the Unicode/encoding differential tests.

### P2 — replace capture snapshots with rollback state

The quantifier emitter currently copies capture arrays for backtracking
candidates. Replace whole-array snapshots with a trail/checkpoint scheme and
measure capture-heavy cases separately from boolean cases.

### P2 — reduce MatchData materialization

Keep character/byte offsets as the internal result. Materialize strings only
when the public caller requests `match`, and avoid rebuilding `input.chars` for
every match in scan/gsub loops.

### P3 — optimize Unicode and helper dispatch

After the fixed overhead and class predicates are addressed, profile Unicode
properties, case folding, word boundaries, and encoding conversion on long
inputs. These are currently secondary to the ASCII class and replacement
outliers.

## Design decision checkpoints

The following results should gate future design changes:

1. If Lexer/Parser/Analyzer dominate compile time, reduce front-end passes or
   cache immutable compile artifacts; do not optimize generated matching yet.
2. If `Module#module_eval` dominates first match, add an explicit cold/warm
   policy and measure whether eager or shared code compilation is appropriate.
3. If offset-only matching removes most replacement time and allocations, make
   the bulk execution surface part of the matcher design rather than adding
   local gsub special cases.
4. If precompiled class predicates fix range/intersection but not anchors and
   captures, treat those remaining cases as independent fixed-overhead issues.
5. Re-run all three operations with inputs scaled from bytes to MiB before
   accepting any YJIT conclusion.

## Review against an Onigumo-equivalent performance goal

The analysis above is sufficient to select the first local optimizations, but
it is not sufficient to claim a route to Onigumo-equivalent performance. The
original corpus mostly uses short successful inputs. It did not test input
scaling, late matches, misses, anchoring shortcuts, dense scan/gsub workloads,
or individual compile stages.

Two additional profilers close those measurement gaps:

```sh
# Input length, match location, failure, and public API scaling.
RUBYLIB=lib bundle exec ruby script/profile_regexp_scaling.rb \
  --engine onibi --case literal_miss --operation match_question \
  --sizes 64,1024,16384,65536 --iterations 3 --format tsv

# Lexer, parser, analyzer, source emission, and module_eval.
RUBYLIB=lib bundle exec ruby script/profile_compile_stages.rb \
  --iterations 50 --format tsv
```

Every scaling case runs a Ruby-result correctness preflight before timing.

### Anchors are not used to constrain search

`\\Aneedle` on a non-matching input should test only position zero. Current
Onibi still loops over every candidate position:

| input length | Onibi time | allocated objects | Ruby slowdown |
|---:|---:|---:|---:|
| 64 | 0.000016 s | 70 | about 123x |
| 1,024 | 0.000234 s | 1,027 | about 2,127x |
| 16,384 | 0.004129 s | 16,387 | about 37,539x |
| 65,536 | 0.015017 s | 65,539 | about 136,519x |

This is a search-plan design defect. Improving the generated anchor predicate
does not help while `GeneratedProgram#search` continues invoking it at every
candidate position.

### Literal search is linear but allocation-heavy

A literal at the first position remains constant-time at roughly 1.7-2.0 µs,
although that fixed Ruby cost is still about 13x MRI for the tiny call. A
literal at the end or absent from the input scales linearly, but allocates about
three objects per candidate position:

| input length | literal miss time | allocated objects | Ruby slowdown |
|---:|---:|---:|---:|
| 64 | 0.000020 s | 198 | about 151x |
| 1,024 | 0.000296 s | 3,075 | about 539x |
| 16,384 | 0.004923 s | 49,155 | about 716x |
| 65,536 | 0.019808 s | 196,611 | about 727x |

Onigumo uses required-literal and skip/search optimizations. To approach it,
Onibi must not call the generated entrypoint and initialize state once per
character for exact-literal searches.

### A common class miss is quadratic

`[a-z]+[0-9]+` on an all-letter input exposes the most important algorithmic
problem. Doubling the input approximately quadruples time and allocations:

| input length | Onibi time | allocated objects | GC cycles |
|---:|---:|---:|---:|
| 64 | 0.012905 s | 115,088 | 3 |
| 128 | 0.043819 s | 459,527 | 12 |
| 256 | 0.174690 s | 1,836,551 | 51 |
| 512 | 0.699425 s | 7,343,111 | 205 |

The 4,096-character run exceeded one minute and was intentionally interrupted.
The captured stack was inside `ClassPredicates.range_matches?`, reached from
the generated quantifier's `reverse_each` candidate loop. MRI/Onigumo scaled
approximately linearly for the same pattern and inputs.

Precompiling character classes will reduce the constant factor but will not
fix this O(n²) behavior. The generated matcher greedily scans and backtracks at
each candidate start, then repeats the same work at the next candidate.

### Dense scan and gsub are also superlinear

For pattern `a` on an all-`a` input, each public match reconstructs match data
from the complete input. Allocation growth approaches quadratic:

| matches/input length | scan time | scan allocations | gsub time | gsub allocations |
|---:|---:|---:|---:|---:|
| 64 | 0.000316 s | 5,586 | 0.000355 s | 5,973 |
| 128 | 0.000974 s | 19,337 | 0.001031 s | 20,108 |
| 256 | 0.003057 s | 71,433 | 0.003191 s | 72,972 |
| 512 | 0.010704 s | 273,929 | 0.011240 s | 277,004 |

This confirms that an internal offset iterator is a design requirement, not a
gsub-only micro-optimization.

### Compile-stage breakdown

Median results across the 37 feature cases were:

| stage | median time | median allocations |
|---|---:|---:|
| Lexer | 9.42 µs | 70 |
| Parser | 2.98 µs | 13 |
| Analyzer | 22.54 µs | 73 |
| Ruby source emission | 8.26 µs | 36 |
| `module_eval` source compilation | 50.14 µs | 18 |
| current `Regexp.new` total, before lazy codegen | 43.34 µs | 164 |

The analyzer is the largest eager front-end stage. `module_eval` is the largest
lazy first-match stage. Parser optimization is low priority unless later
profiles change this ordering.

## Revised design conclusion

The current optimization plan is necessary but not sufficient. Reaching
Onigumo's asymptotic behavior requires a compile-time search plan and a more
specialized generated control graph.

### Required search-plan metadata

The analyzer should publish immutable, option/encoding-aware facts consumed by
the generator:

- absolute/line anchoring constraints;
- minimum remaining width and last viable start position;
- required exact literal and safe skip/search strategy;
- first-character/first-byte sets;
- nullable-prefix information;
- regular versus capture/backreference-dependent subgraphs;
- safe failure memoization points.

At present, analysis metadata is not sufficient to stop the outer candidate
loop for an absolute anchor or to skip directly to a required literal.

### Required execution changes

1. Compile anchored patterns to one `match_at` attempt rather than a generic
   search loop.
2. Use `String#index` or an equivalent generated skip loop for proven required
   literals. Calling Ruby's normal string primitive remains pure Ruby and moves
   the byte scan into optimized native code without delegating regexp semantics.
3. Compile simple character classes into frozen range/bitmap/predicate data;
   never parse class source in the hot path.
4. Prevent repeated suffix rescans. For regular capture-free subgraphs, use a
   generated one-pass/automaton-style loop or safe failure memoization. Merely
   optimizing the existing backtracking loop preserves O(n²).
5. Provide one offset-producing iterator for `match?`, `match`, `scan`, and
   `gsub`; materialize `MatchData` only at the public boundary that needs it.
6. Use capture trails/checkpoints instead of copying whole capture arrays.

This can remain a single generated-matcher architecture if automaton-like
regular subgraphs are compiled into specialized Ruby templates rather than
selected as a second runtime matcher. If the design forbids even that form of
regular-subgraph specialization, Onigumo-like scaling is not achievable with
the current prioritized-backtracking template.

## Realism of exact parity

Strict 1.0x parity for tiny warm calls is not a credible target while runtime
extensions, C, and FFI are prohibited. MRI enters an optimized C engine in
roughly hundreds of nanoseconds; Onibi necessarily crosses Ruby method and
object boundaries. The literal-first case already shows a roughly 13x fixed
floor even when input length does not matter.

A defensible pure-Ruby target should therefore separate:

- **asymptotic parity:** no worse complexity than Onigumo for the regular
  acceptance corpus;
- **allocation parity by order:** O(1) state for boolean linear searches and
  O(matches) for scan/gsub results, not O(input × matches);
- **large-input throughput:** measured on KiB/MiB inputs where loop quality,
  not call startup, dominates;
- **tiny-call overhead:** tracked separately as an unavoidable language/runtime
  boundary unless constraints change.

If "same speed" means within a small constant factor on large representative
workloads, the revised design may be viable. If it means approximately 1.0x on
all tiny MRI microbenchmarks, the zero-native-code constraint and the target
conflict.

## Revised implementation order

1. **P0: fix asymptotics.** Absolute-anchor pruning, required-literal search,
   minimum-width bounds, and the quadratic class-miss regression.
2. **P0: add the offset iterator.** Make dense scan/gsub allocation O(matches)
   plus output rather than O(input × matches).
3. **P1: precompile class predicates.** Remove runtime class parsing after the
   algorithmic class-miss fix is in place.
4. **P1: remove boolean capture state and full capture snapshots.**
5. **P2: reduce cold cost.** Optimize analyzer allocations, then evaluate
   eager/lazy source compilation and generated-program caching. Parser work is
   not currently the bottleneck.
6. **P3: tune generated YARV/YJIT layout.** Only after allocation and scaling
   gates pass.

Each P0 change needs a scaling acceptance test, not only an IPS improvement.
For a case that is linear in Onigumo, doubling input must not approximately
quadruple Onibi time or allocation after the change.
