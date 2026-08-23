# Historical HFA design

This file records a previous HybridAutomata architecture. It is retained for
provenance only and is not an active design requirement.

The current design is in [`onibi-design.md`](onibi-design.md). The current
pipeline lowers optimized CFG to Glushkov TNFA, DFA or partial DFA, and
dedicated Onibi bytecode.
