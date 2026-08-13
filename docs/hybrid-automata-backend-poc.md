# Hybrid automata backend PoC

## Conclusion

This PoC replaces generated Ruby with one `HybridAutomata::Program` for a
captureless ASCII regular subset. It does not call `GeneratedProgram` and it
does not fall back to another matcher. The same automaton can also be lowered
to `HybridAutomata::RubyProgram`; that path embeds the HFA transition kernel in
generated Ruby rather than calling the interpreter. A single runtime combines:

1. mandatory-prefix string matching, which emits candidate-start events;
2. a Glushkov position NFA represented by one Ruby `Integer` bitset;
3. LimEx-style masked shifts for cold NFA transitions; and
4. a bounded lazy-DFA cache keyed directly by the observed NFA subset.

The NFA and DFA therefore share one state representation. The DFA is not a
separate selected backend: an observed `(subset, byte, start-mode)` transition
is promoted into the same program's table, while a cache miss is evaluated by
the bit-parallel NFA transition kernel.

## Surface and scope

```ruby
program = Onibi::HybridAutomata.compile("BEGIN(?:[a-z]+|[0-9]{2,4})END")
program.match?(input)
```

`compile` first runs the current `Optimization::CompilationUnit` pipeline and
passes its CFG through the HFA regular-subset validator. Callers that already
hold a unit can use `HybridAutomata.compile_unit(unit)`; no generated-Ruby
matcher is selected as a fallback.

Supported in the PoC: ASCII literals, concatenation, alternation, character
classes, `.`, common character escapes, greedy/lazy quantifiers, bounded
quantifiers up to 64, and non-capturing groups. The compiled automaton is capped
at 512 position states and the lazy DFA at 4,096 subset rows by default.

Captures, offsets/`MatchData`, anchors, lookaround, backreferences, atomic and
possessive semantics, option groups, Unicode, streaming state, and multi-pattern
databases are deliberately rejected with `UnsupportedPattern` or
`UnsupportedInput`. The PoC remains an experimental surface and is not wired
into `Onibi::Regexp`; doing so before offsets and the remaining semantics exist
would silently narrow the public API.

## Benchmark

Reproduce with:

```sh
PATH=/opt/homebrew/opt/ruby/bin:$PATH \
  ONIBI_BENCH_SIZE=262144 \
  ONIBI_BENCH_TIME=0.5 \
  ONIBI_BENCH_SAMPLES=15 \
  ruby benchmark/hybrid_automata_backend.rb
```

Recorded run: Ruby 4.0.6 arm64, 32,768-byte target input. `compile` and first
scan are medians of 7 runs; warm throughput is sampled for 0.15 seconds. The
ablation variants still use the same program: `no_dfa` disables promotion,
`no_string` disables prefix events, and `nfa_only` disables both.

The original recorded throughput run used commit `b3ed436` (Ruby 4.0.6 arm64,
32,768 bytes, 7 lifecycle samples, 0.15 seconds warm time). The latest runtime
policy run uses commit `e7a18ae` (same Ruby/input, 3 lifecycle samples, 0.1
seconds warm time). A separate allocation
run used the same corpus shapes at 4,096 bytes and 100 warm calls per engine;
representative objects/call were: `dfa_dense_hit` hybrid 0.1, hybrid Ruby 0.4,
Ruby codegen 14,339; `prefix_sparse_late` hybrid 0.0, hybrid Ruby 1.4, Ruby
codegen 5.1. Allocation and throughput runs are intentionally separate.

| Case | Engine | Compile us | First scan us | Warm scans/s | vs codegen |
|---|---:|---:|---:|---:|---:|
| literal sparse miss | hybrid | 353 | 22 | 47,897 | **1.01x** |
|  | hybrid Ruby | 432 | 22 | 46,910 | 0.99x |
|  | no string | 395 | 4,469 | 224 | 0.00x |
|  | NFA only | 325 | 4,471 | 224 | 0.00x |
|  | Ruby codegen | 110 | 22 | 47,340 | 1.00x |
| prefix sparse late | hybrid | 773 | 40 | 43,824 | 0.98x |
|  | hybrid Ruby | 938 | 39 | 43,522 | 0.97x |
|  | no DFA | 654 | 28 | 36,769 | 0.82x |
| DFA dense hit | hybrid | 671 | 4,969 | 200 | **1.64x** |
|  | hybrid Ruby | 911 | 5,220 | 192 | **1.58x** |
|  | no DFA | 747 | 39,824 | 25 | 0.21x |
|  | Ruby codegen | 445 | 8,225 | 122 | 1.00x |
| low-selectivity miss | hybrid | 392 | 4,601 | 221 | 0.81x |
|  | hybrid Ruby | 498 | 5,084 | 197 | 0.72x |
|  | no string | 389 | 4,515 | 222 | 0.81x |
|  | Ruby codegen | 213 | 3,656 | 274 | 1.00x |

MRI is intentionally not a design baseline, but was included as a semantic and
performance reference. It ranged from 1.31x to 79.88x the current generated
Ruby matcher in these cases, showing the remaining distance to a native engine.

## Interpretation

- The fused DFA/NFA state is valuable. On the dense case, DFA promotion raises
  throughput from 20 to 167 scans/s (8.4x) and moves the PoC from 0.19x to
  1.60x the generated matcher.
- String matching is essential for sparse inputs. Removing it drops the prefix
  case from about 35,000 to 171 scans/s. The full hybrid only ties codegen here
  because the current generated matcher already has a literal candidate source.
- Event selectivity needs a compiler cost model. In the low-selectivity case,
  every `a` creates a candidate event; disabling string matching improves the
  result from 0.64x to 0.79x codegen in this low-selectivity corpus.
- Compilation is currently 2.2x-3.9x slower than codegen for non-trivial cases;
  HFA-to-Ruby adds another source-compilation cost.
  Most cost comes from constructing 256-byte reach masks in Ruby. Cacheable
  normalized predicates and direct literal construction should be addressed
  before treating this as the default engine.

## Recommended next experiment

Keep a single `HybridProgram`, but add a compile-time event cost model using
literal length, expected byte frequency, and maximum verification distance.
Then add compact DFA state IDs and flat transition storage instead of a Ruby
Hash of 256-entry rows. Only after that should the surface grow to offsets/SOM
tracking, captures, UTF-8 character classes, and finally replace
`Onibi::Regexp#codegen_program` for the supported semantic region.
