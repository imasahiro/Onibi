# TASK-42C2 boundary audit

Date: 2026-09-20. MRI: Homebrew Ruby 4.0.6, arm64-darwin25.
Source: `a1f4b26f9f2b82704efc6dffa2172fdf5b808da6`.
Workspace: `/Users/masa/.codex/worktrees/f2bb/Onibi` (managed, detached HEAD).
Task: `01a0bf4f-9c0d-7412-9543-4c96b5b66d8f`, host `local`.
Relay: `task-42c2-20260920-01`.
Handoff SHA-256: `695c05084e0c50c9af3673f19518d9e26833cda6f712064cf76889855fe8ad47`.
The hash and source revision matched before inspection. The worktree was clean.

## Result

The inspected paths never put `Onibi::MatchData` into MRI backreference storage.
There are no `RMATCH_REGS` consumers or manual `RMatch` constructors in `ext` or `lib`.
Native `match` follows the object boundary in `docs/gir.md` sections 58–59.
This does not establish complete MRI API compatibility.

| Source and function | Observed boundary |
| --- | --- |
| `ext/onibi/rseq.c:1662`, `onibi_match_body` | Native success copies raw registers through `onibi_matchdata_new`. It returns or yields the custom object. It does not call MRI `match`. Native failure clears `$~`. Explicit fallback returns or yields MRI MatchData. |
| `ext/onibi/rseq.c:1701`, `onibi_match` | Nil input returns without clearing `$~`. An invalid negative position clears it. `rb_ensure` releases heap registers after construction, yield, or exception. |
| `ext/onibi/rseq.c:1756`, `onibi_match_p` | Native results use only raw status. Explicit fallback calls MRI `match?`. Both preserve prior backreferences in the probes. |
| `ext/onibi/match.c:396`, `onibi_case_equal` | Native success still calls source MRI `match`. Native failure clears `$~`. Non-String input returns false without clearing it. Fallback calls source MRI `match`. |
| `ext/onibi/match.c:419`, `onibi_last_match` | Reads MRI state only. Optional indexing uses `[]` on the stored MRI object. It does not retain native results. |
| `ext/onibi/match.c:430`, `onibi_tilde` | Reads `$_`. Native success still calls source MRI `match`, then returns the native character position. Failure clears `$~`. Non-String input returns nil without clearing it. Fallback consumes MRI `bytebegin`. |
| `ext/onibi/match.c:303`, `onibi_scan_body` | Native scan builds strings or capture arrays from raw registers. It leaves prior state unchanged and does not yield its supplied block. Fallback calls String#scan with the source MRI regexp. |
| `ext/onibi/match.c:458`, `onibi_gsub` | Native substitution uses raw whole-match ranges. Its block receives a String and sees prior MRI state. Replacement text with a backslash uses the explicit MRI replacement adapter. Runtime fallback calls String#gsub with the source MRI regexp. |
| `ext/onibi/match.c:116`, `onibi_vm_search_body` | Calls `rb_reg_prepare_re` for input preparation. This receives the stored MRI regexp, not a match result. Unsupported or ineligible input selects fallback before execution. |
| `ext/onibi/unicode.c:5`, `onibi_grapheme_width` | Saves MRI state, runs MRI `rb_reg_match`, reads MRI `byteend`, then restores state. Restoration has no `rb_ensure`; an exception can skip it. |
| `ext/onibi/exec_dynamic.c:3319` | The grapheme instruction calls that helper. Public compilation rejects grapheme support at `ext/onibi/compiler.c:2199`. Public `\\X` probes therefore exercise fallback, not this helper. |
| `ext/onibi/match_data.c:223`, `onibi_matchdata_build_body` | Uses private typed data, copies byte registers, and freezes a subject copy. All accessors and copy paths consume this private payload. They do not use MRI match storage. |
| `ext/onibi/diagnostics.c:60`, `onibi_matchdata_payload_body` | Diagnostic construction uses raw native results or supplied ranges. It calls the same custom constructor. It does not publish backreferences. |
| `ext/onibi/onibi_init.c:141` | Both custom classes inherit Object. Method registration supplies no `=~` method or String adapter. No Ractor-safe method was added. |
| `lib/onibi.rb`, `lib/onibi/onibi.rb` | These files only load the extension and wrap `compile`. No Ruby wrapper calls `Onibi::Regexp#match`. |

The four `rb_backref_set(Qnil)` calls are in `match.c` and `rseq.c`.
The only other setter restores the saved MRI value in `unicode.c`.
The only getters occur in `last_match` and the Unicode helper.
Other `rb_reg_options` calls consume source regexps, not MatchData.

## Focused observations

The added audit test records six boundaries with 40 assertions.
It describes current behavior. It does not require future implementations to retain known gaps.
No existing expectation was changed.

A separate MRI/native matrix used `(a)` with `ba`, `z`, and nil.
Each call started with `/prior/.match('prior')`.
It checked `match`, `match?`, `===`, `=~`, `~`, `$~`, and `Onibi::Regexp.last_match`.

- Native `match` success retained `prior`; MRI replaced it with `a`.
- Native and MRI misses cleared state. Native nil input retained `prior`; MRI cleared it.
- Both `match?` paths retained `prior` for success, failure, and nil input.
- `===` and `~` matched MRI results for String success and failure.
- Their nil-input paths retained `prior`; MRI cleared it.
- Onibi `=~` raised `NoMethodError` on all three inputs.
- The MRI-match guard allowed native `match` and `match?`, but caught `===` and `~`.

String `scan`, `gsub`, `sub`, `match`, `match?`, and `split` rejected the custom regexp with `TypeError`.
String `[]` also raised `TypeError`. String `=~` raised `NoMethodError` through the missing custom method.
These paths do not deliver custom MatchData to MRI C consumers.
External C extensions remain outside this inspection.

Native `scan('aba')` with `(a)` returned `[['a'], ['a']]` and ignored its block.
Native block `gsub` returned `xbx`; both block calls saw the prior MRI match.
Explicit `\\X` fallback returned MRI MatchData and updated `$~`.
NOENCODING fallback did the same.
Replacement `gsub('aba', '<\\1>')` returned `<a>b<a>` and left MRI captures in `$~`.
Fallback `scan('ab')` returned `['a', 'b']`; fallback `gsub('ab', 'x')` returned `xx`.
Both left `b` in MRI state.

## Checks

Commands ran from the workspace unless a directory is specified.

```sh
shasum -a 256 /Users/masa/.codex/relay/01a0b97a-e726-75a3-9fe0-45e966a14d2f/task-42c2-20260920-01/handoff.md
git rev-parse HEAD
git status --short
git worktree list
rg -n 'RMatch|RMATCH|T_MATCH|rb_backref|rb_reg_nth|rb_reg_last|rb_match_' ext lib
```

The search also returns unrelated `AST_MATCH_RESET` names. Those are not MRI match storage.

From `ext/onibi`:

```sh
/opt/homebrew/opt/ruby/bin/ruby extconf.rb
make warnflags='-Wall -Wextra'
DEVELOPER_DIR=/Library/Developer/CommandLineTools make
```

The first make stopped at the Xcode license check, before compilation.
The Command Line Tools build passed with the generated warning flags.
It reported two existing warnings: `onibi_c_ast_has_capture` and `onibi_rseq_mark_unsupported`.
No C file changed.

```sh
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/api/native_match_routing_test.rb
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/api/backreference_boundary_audit_test.rb
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'Dir["test/features/api/*_test.rb"].sort.each { |path| require_relative path }'
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/api/regexp_constructor_test.rb
/opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest test/features/api/regexp_utility_test.rb
```

- Native routing: 4 runs, 20 assertions, no failures.
- Boundary audit: 6 runs, 40 assertions, no failures.
- API set: 122 runs, 428 assertions, two failures.
- Constructor alone: 34 runs, 76 assertions, one failure.
- Utility alone: 33 runs, 78 assertions, one failure.

The constructor failure expects `['ab', 'b']` but receives `['ab', 'a', 'b']`.
It concerns named-group numbering and remains outside this audit.
The utility failure expects native `match` to publish its result through `last_match`.
That expectation conflicts with the accepted custom-object boundary. The test remains unchanged.
Both failures reproduce without loading the new audit test.

## Next unit and limits

The smallest next implementation unit is the native-success branch of `===`.
Remove its MRI rematch and prove its Boolean result with MRI differential tests and an MRI-call guard.
Define its permitted backreference behavior explicitly under the gem contract.
Keep explicit fallback intact. Do not publish custom MatchData into MRI storage.
Handle `~`, the missing `=~`, String adapters, and scan/gsub block state in separate units.
Repair Unicode exception restoration before enabling native grapheme support.

This audit did not enable MRI integration or Ractor support.
It did not exercise the dormant grapheme helper through a synthetic instruction stream.
No complete suite, sanitizer run, or external C consumer test was performed.
`docs/development.md` still describes the old MRI materialization adapter; sections 58–59 and the ledger take precedence.
No production source, ledger, commit, remote branch, or pull request changed.

Final checks:

```sh
/opt/homebrew/opt/ruby/bin/ruby -c test/features/api/backreference_boundary_audit_test.rb
git diff --check
DEVELOPER_DIR=/Library/Developer/CommandLineTools make -C ext/onibi distclean
git status --short
```

Syntax and whitespace checks passed. Build cleanup passed.
Only this note and the new audit test remain untracked.
The inline exploratory matrix is recorded in the task tool output.
The six durable tests provide the repeatable boundary gate.
