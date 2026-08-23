# Onibi historical design records

Files in this directory are preserved for provenance. They record completed
plans, rejected architectures, experiments, and benchmark measurements. They
are **not normative** and must not be used to justify new production design.

Current guidance lives in:

- [`../onibi-design.md`](../onibi-design.md) — product scope and architecture
  overview;
- [`../cfg-optimization-pipeline.md`](../cfg-optimization-pipeline.md) — active
  compiler IR and optimization rules;
- [`../regexp-feature-coverage.md`](../regexp-feature-coverage.md) — current
  compiler syntax coverage.

The former HFA design and task-list files are retained as historical records.
They do not define the current implementation.

## Records

| Record | Historical value | Superseded aspect |
| --- | --- | --- |
| [`core-mvp-task-list.md`](core-mvp-task-list.md) | completed MVP sequence | Thompson VM, lazy DFA, and fallback requirements |
| [`v1-task-list.md`](v1-task-list.md) | completed v1 API/syntax sequence | matcher architecture and active work status |
| [`design-boolean-match-path.md`](design-boolean-match-path.md) | capture-liveness analysis | generated-Ruby result-mode implementation |
| [`design-compiled-class-predicates.md`](design-compiled-class-predicates.md) | reusable predicate-table idea | generated-code ownership and source fallback framing |
| [`design-offset-iterator.md`](design-offset-iterator.md) | raw offset iteration goal | generated matcher as iterator owner |
| [`design-one-pass-execution.md`](design-one-pass-execution.md) | regular/stateful partition insight | exclusion of NFA/DFA and generated one-pass lowering |
| [`hybrid-automata-backend-poc.md`](hybrid-automata-backend-poc.md) | bit-parallel NFA and benchmark evidence | adaptive subset cache labeled as HFA; direct specializations |
| [`hyperscan-hybrid-automata-poc.md`](hyperscan-hybrid-automata-poc.md) | decomposition/event research | generated-Ruby verifier and rejection of formal HFA |

Historical claims and measurements retain the environment and assumptions of
their original record. Moving a file here does not assert that every task was
implemented exactly as described; Git history and current tests remain the
evidence for repository state.
