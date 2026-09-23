# TASK-42C15B: native Hash replacement

Onibi `gsub` now supports Hash replacements on the native path.

Onibi checks `to_hash` before it checks `to_str` or starts matching. It does this even when no match exists. A real Hash bypasses `to_hash` overrides.

For each match, Onibi creates a fresh mutable String key. The key contains the whole match bytes and the current subject encoding. Onibi calls `rb_hash_aref` and converts the value with `rb_obj_as_string` for every match.

Hash values append as literal strings. They do not enter the String replacement scanner. Onibi checks subject length after lookup and value conversion. A value conversion error therefore occurs before the length check.

Onibi measures the subject after replacement coercion. It passes an already-converted Hash to MRI only when the matcher uses its existing fallback. That path does not call the user's `to_hash` method again.

The call keeps Ruby values in its active C frame. `RB_GC_GUARD` keeps callback values live across Ruby calls. The code does not register stack addresses as global GC roots.

`rb_ensure` frees capture ranges on return, Ruby errors, and throws. A suspended Enumerator can release its subject when it is abandoned.

## MRI evidence

The Hash audit ran 42 cases. It had zero harness failures and zero mismatches after accepted-contract comparison. The raw comparison had two known differences:

- A bad `to_s` return uses normal Object text. Each process has a different address. The derived comparison checks the text and bytes against that process's object, then normalizes only that address.
- A nested callback records a different `caller_backreference` value. The accepted caller-local backreference rule allows this difference. The derived comparison removes only those event entries. Other events, including the nested backreference event, still match.

Trace and diagnostic evidence shows 33 native Hash cases with no observed MRI `String#gsub` call. The Hash and `to_hash` matcher-fallback controls each make one call. The fallback `to_hash` object converts once.

The C13B audit passed all 36 cases. Both C13B order probes match MRI. The Hash order probe confirms that value conversion errors win over subject-length errors. It also confirms that restoring the original length succeeds.

The C14A audit has one known, separate mismatch: Onibi rejects a non-ASCII capture name during regexp compilation. Three UTF-16 replacement assembly errors reach native code. Two UTF-16 name misses use the existing replacement fallback.

The collection regression passes for normal return, callback error, throw, abandoned block enumeration, and abandoned Hash enumeration. Suspended Hash and block callbacks resume after full collection and compaction.

The saved MRI and Onibi weak-reference probes both release the source after an abandoned block Enumerator. The root ran the full focused group after the correction: 137 runs and 1,806 assertions passed. The final Hash test includes 15 runs and 131 assertions.

## Verification

The final Hash test had no failures, errors, or skips. The warning build passed with 34 inherited warnings and no warning in `match.c`.

`bundle check`, focused RuboCop, Ruby syntax, `clang-format`, whitespace checks, and `make distclean` passed. `bundle check` printed the frozen-lockfile warning, then confirmed that dependencies were satisfied.

Exact commands, working directories, environments, exit codes, totals, hashes, and logs are in the task worker artifacts at `/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c15b-889331b23d57/worker/`.

Known caller-local backreference behavior remains as accepted. Non-ASCII capture-name parsing remains separate work. The tested UTF-16 assembly errors match MRI; they are expected compatibility errors.

Root final commands, exits, and full logs: `/Users/masa/.codex/relay/01a0cbee-5c89-7ab2-9709-a924eb3e96ef/task-42c15b-889331b23d57/root-review/review2-checks.json`.
