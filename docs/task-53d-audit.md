# TASK-53D C-08 audit

This note checks the three C-08 claims against the accepted source at
`7949237cf3dea01487bae0cfd0334ced5b4a421f`.

## Claim 1: diagnostic Ruby hashes are non-canonical

Original review claim: diagnostic Ruby hashes were described as non-canonical,
although similar hashes appeared in the production compiler.

Current evidence:

- `ext/onibi/diagnostics.c` creates hashes and arrays in diagnostic entry
  points, including `onibi_diagnostics_for` and verifier hooks.
- `ext/onibi/exec_dynamic.c` creates hashes only in semantic-state diagnostic
  hooks.
- The compiler and runtime records use C vectors and records. The published
  program is the immutable RSeq blob built by `ext/onibi/rseq.c`.

Result: already resolved by the accepted module and semantic changes. The
comment at the end of `diagnostics.c` correctly limits Ruby hashes to
diagnostic and compatibility payloads. No change was needed for this claim.

## Claim 2: execution context ownership does not match storage

Original review claim: execution-context fields were described as owned runtime
state even though interpreters used local stack storage.

Current evidence:

- `ext/onibi/match.c:onibi_vm_search_body` declares `OnibiExecCtx exec_ctx`
  on the C stack and releases its heap buffers with
  `onibi_exec_ctx_release`.
- `ext/onibi/exec_dynamic.c:onibi_assertion_event_diagnostic` declares a
  stack-local context for diagnostic probes.
- `OnibiExecCtx` contains borrowed Ruby `VALUE`s and a pointer to the cached
  `OnibiRSeqView`; its frontier, tag, semantic, and class buffers are
  match-local allocations.

Correction: the private-header comment now states stack-local context use,
match-local buffer ownership, and borrowed Ruby/RSeq references. Behavior is
unchanged.

## Claim 3: tagged epsilon-NFA boundary

Original review claim: a comment called a tagged epsilon-NFA boundary even
though transferred edges did not retain NFA epsilon edges.

Current evidence:

- `ext/onibi/nfa.c:onibi_nfa_add_connection` creates epsilon edges to an
  epsilon boundary and a consuming edge to the destination.
- `ext/onibi/nfa.c:onibi_nfa_validate_edge` checks both epsilon and consuming
  transition kinds.
- `ext/onibi/nfa.c:onibi_nfa_emit_closure` follows epsilon edges and emits
  GIR edges after the closure; `onibi_epsilon_eliminate` maps only non-epsilon
  states into GIR.
- `ext/onibi/compiler.c:onibi_compiler_pass_lower` calls epsilon elimination
  before GIR verification and RSeq publication.

Result: the NFA is a real tagged epsilon-NFA intermediate. Its epsilon edges
are eliminated before publication, so GIR does not retain them. The compiler
comments now state both facts. Behavior is unchanged.

## Related current-state comments

`ext/onibi/compiler.c:onibi_compile_backref_descriptor` previously attributed
duplicate-name resolution to Ruby. The resolver in the same file records name
definitions in AST order, and the descriptor reverses that list for the native
executor. The comment now states this C behavior.

`docs/development.md` now distinguishes native raw match selection, direct
native `scan` materialization, and the remaining MRI `MatchData` adapter in
`match`. It also marks the native support checks and explicit MRI fallback in
the current pipeline description.

## Structural review

The C and private-header edits change comments only. The development document
changes prose only. No executable token, test, public API, fallback rule, or
ownership implementation changed.

## Verification

The exact commands and results are:

- `export PATH=/opt/homebrew/opt/ruby/bin:$PATH; export DEVELOPER_DIR=/Library/Developer/CommandLineTools; ruby -v`: exit 0; MRI 4.0.6.
- `if test -f ext/onibi/Makefile; then (cd ext/onibi && make distclean); fi`: exit 0; no Makefile existed before the build.
- `(cd ext/onibi && ruby extconf.rb && make)`: exit 0; two known warnings only: `onibi_c_ast_has_capture` and `onibi_rseq_mark_unsupported`.
- `ruby -Ilib -Itest test/features/quality/module_interface_contract_test.rb`: exit 0; 4 runs, 122 assertions, 0 failures, 0 errors, 0 skips.
- `git diff --check`: exit 0.
- `(cd ext/onibi && make distclean)`: exit 0 after verification.
