# TASK-42C8 native replacement expansion

Date: 2026-09-21. MRI: Homebrew Ruby 4.0.6, arm64-darwin25.

## Result

Native `gsub` now expands replacement forms that use raw native ranges:

- `\\1` through numbered captures, including the MRI long-number rule;
- `\\k<name>` and duplicate-name selection;
- `\\0` and `\\&` for the whole match;
- `\\+` for the last participating capture;
- prefix and suffix references;
- `\\\\` and unknown escapes as literal bytes.

The native path keeps the prior MRI backreference. An unknown named reference
uses the stored MRI regexp, so MRI raises the correct `IndexError`.
Explicit input fallback and block replacement behavior stay unchanged.

Capture registers use ensured heap storage. The cleanup path covers native
matches, MRI replacement fallback, Ruby exceptions, and non-local exits.

## Verification

The warning-enabled build passed with the two known warnings in `gir.c` and
`rseq.c`. The focused group passed 80 runs and 1,115 assertions with zero
failures, errors, or skips. It covered scan, scan blocks, native replacement,
String caller boundaries, backreference boundaries, operators, native routing,
and the public match API.

The direct differential probes covered optional captures, duplicate names,
named and unnamed capture mixes, long numeric references, empty input, empty
matches, and unknown names. They matched MRI output and exception classes.

The following checks passed:

```sh
clang-format --dry-run --Werror ext/onibi/match.c
ruby -c test/features/matching/scan_gsub_test.rb
ruby -c test/features/api/string_caller_boundary_audit_test.rb
git diff --check
```

The generated extension was removed after the build checks.
