# TASK-42B1: Onibi-owned MatchData design

Status: design accepted by root on 2026-09-20. Implementation is pending.

## Decision

Use a separate native `Onibi::MatchData` typed object for the gem PoC. Build it
directly from `OnibiRawMatch` after a supported native search. Do not construct
`RMatch`, cast a typed object to `RUBY_T_MATCH`, or run MRI again to materialize
the supported result.

The object will provide the compatible public MatchData method subset. It will
not claim `is_a?(::MatchData)`. It will not claim compatibility with MRI C APIs
that require `RMatch` or `re_registers`. The later MRI replacement can use the
same raw-result boundary after MRI adds a supported transfer API.

This decision removes the TASK-42B external register-transfer dependency only
after root accepts the gem contract below. It does not close the MRI integration
work or the TASK-55 Ractor proof.

## Evidence and current boundary

The current raw result is defined in `ext/onibi/onibi_exec_internal.h`:

```c
typedef struct OnibiRawMatch {
    OnibiBytePos begin_byte;
    OnibiBytePos end_byte;
    uint32_t num_regs;
    OnibiBytePos *beg;
    OnibiBytePos *end;
} OnibiRawMatch;
```

`num_regs` includes register zero. The arrays use subject byte offsets. A
negative pair means that a capture did not participate. `match.c` allocates
capture ranges for `scan`, passes them to all native executors, and creates
Ruby strings with byte slices. The native search owns match selection.

`rseq.c:onibi_match` currently calls native search and then calls the retained
MRI regexp with `id_match`. This is the migration debt in
`docs/development.md`: MRI currently materializes the public `MatchData`.

Homebrew MRI 4.0.6 headers provide the following facts:

* `ruby/internal/core/rmatch.h` defines `struct RMatch` with `RBasic`, `str`,
  and `regexp` fields.
* Its extension comment says that extensions have no way to manually generate
  `RMatch` except by exercising a regexp match.
* `RMATCH_REGS` requires a real `RUBY_T_MATCH` object and exposes its
  `re_registers`.
* `ruby/re.h` exports search, preparation, and register-copy helpers, but no
  constructor that accepts external `re_registers`.
* `rb_backref_set` accepts a Ruby value, but this does not make the value an
  `RMatch` or restore VM-local backreference state.

These headers block the existing `OnibiRawMatch -> re_registers -> RMatch`
step for a gem extension. They do not block a separate public typed object.

The source symbols checked for this decision were:

* `onibi_vm_search` and `onibi_raw_match_reset` in `ext/onibi/match.c` and
  `ext/onibi/onibi_common.c`;
* `onibi_match`, `onibi_match_p`, and `onibi_scan_body` in `ext/onibi/rseq.c`
  and `ext/onibi/match.c`;
* `OnibiRawMatch` and `OnibiExecCtx.raw_match` in
  `ext/onibi/onibi_exec_internal.h`; and
* `rb_backref_set` in the MRI parse header.

The read-only evidence commands were:

```text
rg -n -C 8 'OnibiRawMatch|onibi_vm_search|onibi_raw_match_reset' ext/onibi
rg -n -C 8 'onibi_match|onibi_match_p|onibi_scan_body|rb_backref_set' ext/onibi
sed -n '1,150p' /opt/homebrew/Cellar/ruby/4.0.6/include/ruby-4.0.0/ruby/internal/core/rmatch.h
sed -n '1,130p' /opt/homebrew/Cellar/ruby/4.0.6/include/ruby-4.0.0/ruby/re.h
```

The results show no exported `RMatch` constructor. `RMATCH_REGS` asserts
`RUBY_T_MATCH`. `onibi_match` still calls the retained regexp's `match`, while
`onibi_scan_body` already consumes native capture ranges. The current migration
debt is recorded in `docs/development.md` under “MatchData migration debt”.

The exact source and header checks used for this design are recorded in the
probe log directory and in the completion callback.

## Native representation and ownership

Add one typed-data payload. The proposed shape is:

```c
typedef struct {
    VALUE subject_snapshot;       /* frozen String; never the caller buffer */
    VALUE regexp;                /* Onibi::Regexp owner */
    VALUE names;                 /* frozen String array, copied at creation */
    VALUE named_index;           /* frozen name -> ordered group number arrays */
    OnibiBytePos *beg;           /* num_regs entries, -1 for no capture */
    OnibiBytePos *end;           /* num_regs entries, -1 for no capture */
    long *char_beg;              /* lazy cache; LONG_MIN means not computed */
    long *char_end;
    uint32_t num_regs;
} OnibiMatchData;
```

The constructor validates every raw range against the snapshot byte length.
It copies register zero and all capture registers into one allocation owned by
the typed object. It converts `OnibiRawMatch` to the payload before the search
cleanup runs. The raw arrays remain caller-owned and never enter the payload.

The constructor makes a `rb_str_dup` of the subject, keeps its encoding, and
freezes the copy. This is required. MRI `MatchData#string` is a frozen snapshot;
changing the original subject after a match does not change `string`, `to_s`,
`pre_match`, or `post_match`. The typed-data mark function marks the snapshot,
regexp, names, and name index. The free function releases all native arrays.
The memsize function reports the payload and arrays.

The regexp value is the owning `Onibi::Regexp`. Its source and immutable capture
metadata remain live through that reference. Copy the names and ordered
duplicate-name group lists into the payload. This prevents future regexp
metadata changes from changing an existing match. `names` returns a fresh
mutable array. `MatchData#named_captures` returns a fresh hash with capture
strings or `nil`, not the arrays used by `Regexp#named_captures`. For each name,
resolve the last participating group in its ordered list. If all groups are
unmatched, return `nil`. The retained arrays and hash remain private and
immutable.

Character positions stay lazy. `bytebegin`, `byteend`, and `byteoffset` read
the native byte registers. `begin`, `end`, and `offset` convert a byte boundary
with the snapshot encoding, then cache the result. An unmatched register keeps
both positions as `nil`; a closed empty capture has equal non-negative byte
positions and remains distinct from an unmatched capture.

`dup` and `clone` copy the native register and lazy-cache arrays while sharing
the frozen snapshot and immutable metadata values. They preserve the normal
Ruby frozen flag. No method returns the mutable internal arrays.

## Public method surface

Implement these methods first, with MRI 4.0.6 behavior as the oracle:

| Group | Methods and required behavior |
| --- | --- |
| Indexing | `[]`, `match`, `values_at`; integer-like indices use MRI coercion, negative indices count from the end, out-of-range values return `nil`, ranges return slices, and unknown names raise `IndexError`. |
| Captures | `captures`, `to_a`, `length`, `size`; preserve `nil` for an unmatched capture and `""` for an empty capture. |
| Positions | `begin`, `end`, `offset`, `bytebegin`, `byteend`, `byteoffset`, `match_length`; names and symbols resolve through the copied duplicate-name index. Character results are lazy. |
| Context | `string`, `regexp`, `pre_match`, `post_match`, `to_s`; all strings derive from the frozen snapshot. `regexp` returns the owning `Onibi::Regexp`. |
| Names | `names`, `named_captures`; retain every group index for a duplicate name, resolve the last participating group, return `nil` when all are unmatched, and return fresh containers. |
| Pattern matching | `deconstruct` returns captures. `deconstruct_keys(nil)` returns all named captures. An array selects known names; unknown names are omitted. Other key inputs raise `TypeError`. |
| Value semantics | `inspect`, `==`, `eql?`, and `hash`; compare the snapshot bytes/encoding, regexp equality, and register values. `inspect` must show unnamed numeric groups, named groups, `nil`, and empty strings like MRI. |

The MRI 4.0.6 public instance inventory is captured by the probe:
`==`, `[]`, `begin`, `bytebegin`, `byteend`, `byteoffset`, `captures`,
`deconstruct`, `deconstruct_keys`, `end`, `eql?`, `hash`, `inspect`, `length`,
`match`, `match_length`, `named_captures`, `names`, `offset`, `post_match`,
`pre_match`, `regexp`, `size`, `string`, `to_a`, `to_s`, and `values_at`.

The first implementation may leave a method unsupported only if the public gem
contract marks it explicitly and the focused differential test records it.
There must be no silent call to MRI for a supported native result.

## MRI behavior probe

`.task-42b1-logs/mri_matchdata_contract.rb` records deterministic JSON lines for:

* the MRI 4.0.6 method inventory;
* multibyte byte versus character offsets;
* duplicate names with an earlier participating group and a later unmatched
  group, plus duplicate names where all groups are unmatched;
* empty and unmatched captures;
* integer, float, negative, name, symbol, length, and range indexing;
* unknown names, `nil`, out-of-range indices, and invalid `deconstruct_keys`
  errors;
* `deconstruct`, `deconstruct_keys`, `values_at`, and `match`;
* equality, `eql?`, hash equality, duplication, and freeze behavior;
* frozen subject snapshots after original-subject mutation; and
* non-finite index, invalid UTF-8, and incompatible encoding errors.

The output marks expected MRI errors as `expected_error`. Any unexpected value,
missing error, or harness exception exits non-zero.

## Routing and backreferences

For `Onibi::Regexp#match` on a supported native result:

1. Normalize arguments with the existing wrapper rules.
2. Run `onibi_vm_search` with capture registers enabled.
3. Construct `Onibi::MatchData` from the raw result.
4. Return it or yield it to the block.

`match?` keeps its current boolean path and must not allocate an
`Onibi::MatchData` object or set `$~`. Its native traversal may still allocate
executor buffers. `scan` can keep its direct native string/capture-array
materializer, or later use the same payload for block forms. Unsupported syntax
keeps the documented MRI fallback. Preserve the existing `NOENCODING` and
input-ineligible fallback reasons as well. Do not narrow fallback to syntax
classification. MRI must not run on the supported path to repair a native
result.

The custom gem path must not call `rb_backref_set` with `Onibi::MatchData`.
That API bypasses type checks, while MRI backreference readers and C consumers
expect a real `rb_cMatch`/`RMatch`. Therefore a supported custom match does not
claim to update MRI `$~`, `$&`, `$1`, numbered backreferences, `$+`, `$`` or
`$'`, or `Regexp.last_match`. Test and document this unchanged-backreference
behavior. Do not override methods or pretend that `Onibi::MatchData` is an MRI
`MatchData`.

`String#match`, `String#scan`, `String#sub`, `String#gsub`, StringScanner, and
other `rb_reg_search` callers remain outside this gem-only routing change. They
must continue to use the documented adapter or explicit fallback until MRI
integration provides a transfer API.

## Compatibility limits

The design preserves public method results for the supported subset, but these
gaps are unavoidable in an MRI extension without VM changes:

* `Onibi::MatchData.class` is not `MatchData`, and `is_a?(MatchData)` is false.
* C extensions that require `RUBY_T_MATCH`, `RMATCH_REGS`, or `re_registers`
  cannot consume the object.
* The custom gem path does not update MRI VM-local backreference state. This
  includes caller-local `$~`, `$1`, `$&`, `$+`, `$`` and `$'`, and
  `Regexp.last_match`.
* APIs that require an MRI `Regexp` may see `Onibi::Regexp` from `regexp`.
  This is a visible contract choice, not an identity emulation.
* Subclassing or monkey-patching `MatchData` cannot fix these gaps. MRI exposes
  no public allocator for `MatchData` subclasses, and manual `RMatch` creation
  is prohibited by the header contract.

Ractor safety remains open. The payload can be immutable after construction,
but the Ruby object graph, typed-data flags, backreference storage, and use in a
child Ractor require the TASK-55 acceptance probes. Do not mark the class
shareable before that proof.

## Gem contract changes

After root approval, make these narrow changes:

1. In `docs/gir.md` section 58, replace the statement that MRI creates
   `MatchData` with the gem-PoC rule: supported `Onibi::Regexp#match` returns
   `Onibi::MatchData`; exact MRI `MatchData` identity and VM backreferences are
   MRI-integration requirements.
2. In section 59, define `OnibiRawMatch -> Onibi::MatchData` for the gem stage.
   Keep the `re_registers -> RMatch` path as the later MRI stage only.
3. In `docs/development.md`, replace the current MatchData migration debt with
   the explicit custom-object contract. Preserve all existing explicit fallback
   reasons, including unsupported syntax and input ineligibility.
4. Update the RBS and focused API tests to use the accepted method subset and
   to assert the documented identity/backreference limitations.
5. Update TASK-42B and TASK-55 dependency notes only after root accepts the
   contract and the implementation gates below pass.

These are proposals. This task intentionally does not edit the authoritative
architecture or execution ledger.

## Implementation units and acceptance gates

### B1. Payload and lifetime

Implement typed-data allocation, mark/free/memsize, subject snapshot, copied
registers, and private ordered name groups.

Gate: C warning build, GC stress, allocation-failure cleanup, range validation,
and proof that raw arrays are copied before search cleanup.

### B2. Numeric capture and string access

Implement integer and range indexing, captures, `to_a`, `length`, `size`,
`match`, `values_at`, `to_s`, `string`, `pre_match`, and `post_match`.

Gate: focused tests for coercion, negative indices, ranges, empty captures,
unmatched captures, and frozen subject snapshots.

### B3. Name lookup and metadata

Implement `names`, `named_captures`, and duplicate-name lookup from ordered group
lists. Resolve the last participating group, or `nil` when none participate.

Gate: earlier-participating/later-unmatched and all-unmatched duplicate cases
match MRI for `[]`, `match`, positions, `named_captures`, and
`deconstruct_keys`.

### B4. Character and byte offsets

Implement lazy character conversion and `begin`, `end`, `offset`, `bytebegin`,
`byteend`, `byteoffset`, and `match_length`.

Gate: multibyte, invalid, empty, and unmatched ranges match MRI. Cache values
only after conversion from the immutable byte registers.

### B5. Value, copy, and deconstruction behavior

Implement `inspect`, `==`, `eql?`, `hash`, `dup`, `clone`, `deconstruct`, and
`deconstruct_keys`.

Gate: equality and hash invariants, fresh public containers, freeze behavior,
and exact deconstruction errors pass focused MRI differential tests.

### C. Public routing

Change only supported `Onibi::Regexp#match` and its block form to construct the
payload. Keep `match?` free of `Onibi::MatchData` allocation, while allowing its
native executor buffers. Keep explicit fallback for unsupported syntax and all
existing input eligibility reasons. Add a private constructor so Ruby cannot
invent inconsistent ranges.

Gate: the existing native capture guard proves `Regexp#match` is not called on
the supported path; fallback tests prove unsupported syntax still uses MRI;
block return and no-match behavior match the current wrapper contract.

### D. Integration and backreference audit

Test that the custom path leaves `Regexp.last_match`, `$~`, `$&`, `$1`, `$2`,
`$+`, `$`` and `$'` outside its claimed contract. Test `String#match`,
`String#scan`, replacement, StringScanner, and `rb_reg_search` consumers for
explicit compatibility or documented limits. Test C consumers that call
`RMATCH_REGS` and `rb_reg_region_copy` to confirm they reject or avoid the
custom object. Do not inject the custom object into MRI backreference storage.

Gate: no identity claim remains untested. Ractor tests remain a separate
TASK-55 gate and may not be replaced by object freezing alone.

## Verification record

Run from the worktree root:

```text
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ruby -v
ruby .task-42b1-logs/mri_matchdata_contract.rb > .task-42b1-logs/mri_matchdata_contract.jsonl
ruby -c .task-42b1-logs/mri_matchdata_contract.rb
git diff --check
```

The probe output is saved beside the script. No extension build is required for
this design-only task.
