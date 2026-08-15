# Hyperscan hybrid automata analysis and Onibi PoC

> **Historical research report — non-normative.** Its decomposition and event
> coordination findings inform the current design, but its generated-Ruby
> semantic verifier and rejection of an HFA backend are superseded by
> [`../hfa-design.md`](../hfa-design.md).

## Conclusion

Onibi should adopt Hyperscan's decomposition and event-coordination ideas, but
not its native DFA/NFA engine portfolio. The compatible architecture is:

```text
AST analysis
  -> conservative literal/regular components
  -> ordered component-event coordinator
  -> existing generated Ruby matcher as the semantic verifier
```

This keeps one generated matcher, MRI leftmost-first semantics, captures, and
the pure-Ruby constraint. The PoC for `literal + bounded gap + literal` reduces
warm matching time by 20.8x on a sparse miss and 73.1x on a late hit. A
deliberately low-selectivity case regresses by 15%, so a wider rollout needs a
profitability policy rather than unconditional decomposition.

## What "hybrid automata" means in Hyperscan

The central idea is not a single automaton that is half DFA and half NFA.
Hyperscan compiles a pattern set into a coordinated collection of engines:

1. It constructs a Glushkov NFA graph and uses dominant-path,
   dominant-region, and min-cut/network-flow analyses to extract necessary
   strings. The paper reports that 87-94% of real IDS regexes contain an
   extractable string, and 97.2-99.2% of decomposable rules benefit from its
   dominant-path analysis.
2. It splits a linear expression into string and FA components. A string hit
   is an event. An adjacent FA is executed only when predecessor components
   have enabled it, with offsets defining the input range it may inspect.
3. FDR/Teddy performs SIMD-oriented multi-literal filtering and exact
   confirmation. Smaller FA components are more likely to fit a DFA; larger
   or state-explosive components use bit-parallel Glushkov NFA execution.
4. The production source represents this coordination in Rose. Its builder
   accepts literals, Rose graphs, outfixes, and chain tails, then emits one
   `RoseEngine`. The runtime maintains role state and queues for leftfix,
   suffix, and outfix engines. LimEx represents common transitions with word
   shifts and handles irregular transitions, reports, and squash behavior as
   exceptions.

Primary sources:

- [Hyperscan NSDI 2019 paper](https://www.usenix.org/system/files/nsdi19-wang-xiang.pdf)
- [Hyperscan source: Rose build interface](https://github.com/intel/hyperscan/blob/master/src/rose/rose_build.h)
- [Hyperscan source: LimEx compiler](https://github.com/intel/hyperscan/blob/master/src/nfa/limex_compile.cpp)
- [Hyperscan developer guide: performance considerations](https://intel.github.io/hyperscan/dev-reference/performance.html)

The reported gains do not transfer directly to Onibi. Hyperscan targets
multi-pattern DPI, reports matches as end-offset events by default, and does
not implement MRI's full capture/backreference semantics. Its native SIMD and
cache-layout gains also cannot be reproduced by ordinary Ruby integer loops.

## Mapping to current Onibi

Onibi already contains three pieces of the decomposition architecture:

| Hyperscan concept | Existing Onibi mechanism | Gap before this PoC |
| --- | --- | --- |
| literal scanning | `CandidateSource::Literal`, union sources, `String#index` | only one useful event stream for variable-width sequences |
| vector-like prefilter | SWAR class/byte-set sources | no coordination across separated components |
| small regular engine | `RegularRun` and generated straight-line code | limited to a few proven sequence shapes |
| semantic verification | sole generated Ruby matcher | restarted at every admitted start |

Adding a separate DFA/NFA backend would violate the accepted HFA lowering design
and duplicate capture and priority semantics. Extending immutable search-plan
metadata and candidate sources does not: rejected candidates are proven
impossible, while every admitted candidate still runs the same generated
program.

## PoC

### Supported shape

The compiler recognizes a captureless, option-free ASCII sequence with exactly
one bounded one-character regular gap:

```text
literal (Any | CharacterClass){minimum,maximum} literal
```

Examples are `foo.{0,64}bar` and `foo[a-z]{2,8}bar`. Non-ASCII inputs and
patterns with options use the existing search path.

`BoundedLiteralChain` scans the left and right literals as monotonic event
streams. For a left event at `L`, a right event is relevant only within:

```text
[L + left.bytesize + minimum_gap,
 L + left.bytesize + maximum_gap]
```

The right cursor never moves backward. Complexity is linear in the two event
streams rather than rescanning the suffix for every left hit. The coordinator
does not decide whether dot matches a newline, whether a class accepts the
gap, or which greedy endpoint wins; the generated matcher remains responsible
for those semantics.

### Correctness coverage

- ordered candidate generation and non-zero origins;
- MRI differential `match?` and capture-producing `match`;
- greedy and lazy gaps;
- dot/newline false positives;
- character-class gaps;
- UTF-8 fallback;
- deterministic baseline/PoC/MRI benchmark fixture equivalence.

The complete suite and the cross-runtime contract pass.

## Measurements

Environment:

- base commit: `8a6cf7d44c7be592f689a024b7e2aff27a6781c6`;
- Ruby: `ruby 4.0.6 (2026-07-14 revision 03b6d3f889) +PRISM`;
- platform: `arm64-darwin25`;
- pattern: `foo.{0,64}bar`;
- input: 2,048-byte sparse miss or 2,086-byte late hit;
- monotonic wall clock, warmed instances, GC total-allocation deltas;
- fixed iterations shown below; no JIT-specific API or native extension.

The baseline uses the same generated source and the previous literal-only
search plan. Only `candidate_source` differs.

| case | path | time (us/op) | allocations/op | iterations | speedup |
| --- | --- | ---: | ---: | ---: | ---: |
| sparse miss | previous literal-only plan | 9,541.8 | 132,022.3 | 20 | 1.0x |
| sparse miss | bounded event chain | 458.7 | 262.0 | 200 | 20.8x |
| late hit | previous literal-only plan | 9,606.1 | 132,184.0 | 20 | 1.0x |
| late hit | bounded event chain | 131.4 | 398.0 | 200 | 73.1x |

Candidate counts fall from roughly one generated-matcher attempt per `foo`
to zero on the sparse miss and nine on the late-hit fixture.

Lifecycle measurements for the PoC path are kept separate:

| lifecycle, sparse miss | Onibi (us/op) | MRI (us/op) |
| --- | ---: | ---: |
| compile | 78.4 | 0.9 |
| construct + first `match?` | 631.2 | 451.6 |
| warm `match?` | 458.5 | 448.6 |
| `match` | 456.6 | 445.8 |
| `scan` | 454.6 | 448.3 |
| `gsub` | 457.1 | 449.3 |

For the late hit, Onibi warm `match?` is 133.4 us/op versus MRI's 450.0
us/op. `scan` and `gsub` are about 129-134 us/op because the right-literal
event rules out almost all starts before the generated matcher runs.

### Negative result

For `foo[a-z]{0,64}bar` over 4,096 bytes of repeated `foo1bar-`, every one of
512 left events has a nearby right event, but the class rejects every gap. The
coordinator cannot filter any candidate:

| path | time (us/op) | allocations/op | change |
| --- | ---: | ---: | ---: |
| previous literal-only plan | 400.2 | 3,072.4 | baseline |
| bounded event chain | 458.5 | 3,072.0 | 14.6% slower |

This is the expected failure mode of decomposition: if component events are
dense but do not prove the full regular constraint, coordination adds work
without avoiding verifier calls.

## Recommended next steps

1. Keep the implementation limited to search-plan metadata; do not introduce
   a public backend switch, NFA objects, DFA caches, or a second matcher.
2. Add a cheap runtime profitability sample based on left/right event density.
   Fall back to the existing literal source when the predicted candidate
   reduction is small.
3. Generalize from a pair to an immutable component DAG only after adding
   width intervals, nullable-path proofs, and ordered-event tests. Dominator or
   cut-set extraction is useful only when it proves every match crosses the
   selected component set.
4. Treat bit-parallel NFA as a later generated-code lowering for small regular
   regions, not as a runtime backend. Benchmark Ruby bitset arithmetic first;
   Hyperscan's SIMD result is not evidence that Ruby big-integer operations
   will win.
5. Measure a real Onibi corpus by pattern shape and event selectivity. The PoC
   establishes a 20-73x opportunity for sparse bounded chains, not a global
   engine-wide speedup estimate.

## Reproduction

Run correctness checks:

```sh
bundle exec ruby -Itest test/features/engine/search_plan_test.rb -n /bounded_literal_chain/
bundle exec ruby -Itest test/features/matching/hybrid_literal_chain_test.rb
bundle exec ruby -Itest test/features/matching/hybrid_literal_chain_benchmark_test.rb
bundle exec rake test
bundle exec ruby script/cross_runtime_contract.rb
```

Run one lifecycle benchmark at a time:

```sh
bundle exec ruby benchmark/hybrid_literal_chain.rb --operation match_question
bundle exec ruby benchmark/hybrid_literal_chain.rb --operation match
bundle exec ruby benchmark/hybrid_literal_chain.rb --operation scan
bundle exec ruby benchmark/hybrid_literal_chain.rb --operation gsub
```
