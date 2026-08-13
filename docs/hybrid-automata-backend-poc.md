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

| Case | Engine | Compile us | First scan us | Warm scans/s | vs codegen |
|---|---:|---:|---:|---:|---:|
| literal sparse miss | hybrid | 375 | 23 | 39,807 | 0.99x |
|  | hybrid Ruby | 579 | 24 | 40,943 | **1.01x** |
|  | no string | 364 | 4,852 | 165 | 0.00x |
|  | NFA only | 392 | 9,155 | 104 | 0.00x |
|  | Ruby codegen | 115 | 24 | 40,350 | 1.00x |
| prefix sparse late | hybrid | 777 | 38 | 35,074 | 0.94x |
|  | hybrid Ruby | 974 | 40 | 37,301 | 1.00x |
|  | no DFA | 712 | 31 | 28,331 | 0.76x |
| DFA dense hit | hybrid | 805 | 5,350 | 167 | **1.60x** |
|  | hybrid Ruby | 947 | 6,261 | 148 | **1.42x** |
|  | no DFA | 1,400 | 48,816 | 20 | 0.19x |
|  | Ruby codegen | 565 | 8,714 | 104 | 1.00x |
| low-selectivity miss | hybrid | 443 | 6,353 | 133 | 0.57x |
|  | hybrid Ruby | 598 | 6,758 | 132 | 0.57x |
|  | no string | 437 | 5,187 | 173 | 0.75x |
|  | Ruby codegen | 230 | 3,918 | 232 | 1.00x |

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
