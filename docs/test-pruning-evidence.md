# Test pruning evidence

Review date: 2026-09-27.
Base commit: `89157b806ad3e57299088adf18dbc44505439097`.

The review removed 398 tests. It added no tests and changed no production code.
The full suite decreased from 1477 tests to 1079 tests.
The review kept public behavior checks, including failing MRI comparisons.

## Removal rules

Remove tests for deleted Ruby compiler APIs.
These tests stop at missing constants or methods before they reach the C engine.
Remove source spelling and graph layout checks when retained tests exercise their behavior.
Keep isolated checks that reach failure states absent from E2E coverage.

The review covered all feature directories.
Most API, matching, capture, encoding, and compatibility tests run complete behavior paths.
Their location or small size does not make them redundant unit tests.

## Retained coverage

Paths below start at `test/features/`.

| Removed checks | Retained coverage |
| --- | --- |
| `v2/` Ruby parser, AST, automata, compiler, IRGen, and interpreter tests | `syntax/syntax_differential_corpus_test.rb`, `syntax/advanced_syntax_differential_test.rb`, `compatibility/dynamic_differential_test.rb`, `compatibility/tagged_ordered_differential_test.rb` |
| Ruby lexer, parser, and class snapshots in `syntax/` | `syntax/character_class_differential_test.rb`, `syntax/lexer_parser_error_boundary_test.rb`, `syntax/syntax_differential_corpus_test.rb` |
| `syntax/syntax_corpus_test.rb` fixture shape checks | `syntax/syntax_differential_corpus_test.rb` consumes the fixture data and compares results |
| Ruby capture analysis and class predicate metadata in `engine/` | `captures/regular_fast_capture_test.rb`, `compatibility/dynamic_differential_test.rb`, `syntax/character_class_differential_test.rb`, `encoding/encoding_class_descriptor_test.rb` |
| Ruby `InputView` and invocation state tests | `captures/match_data_byte_offsets_test.rb`, `captures/match_data_character_offsets_test.rb`, `compatibility/gir_semantic_regression_test.rb`, `engine/semantic_state_test.rb` |
| Ruby `EncodingSupport` profile tests | `encoding/encoding_test.rb`, `encoding/encoding_contract_test.rb`, `encoding/encoding_matrix_test.rb` |
| Obsolete pipeline, VM, lexer, parser, and RSeq adapters in `benchmark/benchmark_api_test.rb` | Public feature corpus comparison remains in that file; native results remain in compatibility, encoding, syntax, and capture suites |
| Duplicate regex-redux comparison | `matching/regex_redux_contract_test.rb` runs the full pipeline with the correct fixture path |
| Ruby `MatchData` factory tests | `captures/match_data_payload_test.rb`, offset suites, and `api/native_match_routing_test.rb` check native construction and results |
| Class descriptor kinds and flag snapshots | The same encoding class file retains MRI comparisons and native fallback checks |
| Source check for scan byte slicing | `captures/match_data_contract_test.rb` retains capture comparisons and an MRI rematch guard |
| Header placement and runtime type spelling | The extension build checks declarations and static width assertions; byte and character offset suites check results |
| Compiler pass and resolved AST source layout | Scope, duplicate name, call, and capture tests remain; `quality/resolved_semantic_ast_test.rb` retains compile probes |
| GIR and RSeq verifier source layout | `quality/gir_verifier_test.rb` and `quality/rseq_physical_verifier_test.rb` retain malformed-program injection |
| Compiler ownership implementation spelling | `quality/compiler_exception_safety_test.rb` injects failures through 15 phases and checks allocation counts |
| Parser delimiter index spelling | `quality/parser_delimiter_index_test.rb` retains nested, adjacent, and malformed input checks |
| NFA graph snapshots | `quality/tagged_nfa_lowering_test.rb` retains MRI nullable-cycle comparisons and action-order/deduplication probes; capture and priority suites remain |
| Internal dispatch, option, search, and vector source layout | Execution-class tests, native diagnostics, search-candidate tests, and compiler/encoding/scale tests remain |
| Inline modifier prototype token assertions | `syntax/inline_modifier_test.rb` retains the public matching assertions |

## Isolated tests kept

- Vector self-append and slice-append tests force reallocation and invalid indexes.
- GIR and RSeq tests inject malformed records that valid patterns cannot produce.
- State-ID checks cover reserved values and narrowing near unallocatable graph sizes.
- Semantic-state probes check collisions, rollback, sibling state, and accepted capture lineage.
- Allocation probes check cleanup after injected compiler and MatchData failures.
- Resource tests measure work, growth, retained events, and compact repeat programs.
- Timeout and interrupt tests stop execution during long matches.
- A few source guards remain for cleanup and GC ownership without equivalent failure injection.
- Harness tests keep mismatch detection and error reporting from becoming vacuous.

## Verification

Toolchain: Homebrew MRI 4.0.6 and Apple Command Line Tools.
The default Xcode build stopped at its license gate.
The default rbenv Ruby could not load the Homebrew-linked JSON gem.
The commands below select the installed compatible toolchain.

The build completed with two existing warnings:
`onibi_c_ast_has_capture` and `onibi_rseq_mark_unsupported`.

| Check | Result |
| --- | --- |
| Original tests, fixed seed | 1477 runs, 36192 assertions, 52 failures, 322 errors |
| Pruned tests, fixed seed | 1079 runs, 34926 assertions, 42 failures, 18 errors |
| Focused native, MRI, allocation, vector, and verifier checks | 55 runs, 1363 assertions, no failures or errors |
| RuboCop on changed Ruby test files | Pass |
| `git diff --check` | Pass |

All 60 remaining failing test names and failure kinds occur in the original run.
The full suite remains red. This cleanup does not claim to repair its behavior gaps.
[Machine-readable results](test-pruning-results.json) record these tests and log hashes.

Run from the repository root:

```sh
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
bundle exec rake test TESTOPTS='--seed 20260927' > /tmp/onibi-tests-final.log 2>&1
```

The baseline used `git show` to load original test definitions at their original paths.
It used the same extension and support files. Neither changed in this review.
The original command used `HEAD`, which then named the base commit above.
This equivalent command remains repeatable after the cleanup commit:

```sh
bundle exec ruby -Ilib -Itest -e '
  base = "89157b806ad3e57299088adf18dbc44505439097"
  paths = IO.popen(["git", "ls-tree", "-r", "--name-only", base, "test"], &:read)
    .lines.map(&:chomp).grep(/_test\.rb$/)
  paths.each do |path|
    source = IO.popen(["git", "show", "#{base}:#{path}"], &:read)
    eval(source, TOPLEVEL_BINDING, File.expand_path(path))
  end
' -- --seed 20260927 > /tmp/onibi-tests-original.log 2>&1
```

Focused command:

```sh
bundle exec ruby -Ilib -Itest -e '
  ARGV.replace(["--seed", "20260927"])
  %w[
    test/features/syntax/brace_grammar_test.rb
    test/features/syntax/escape_cursor_test.rb
    test/features/syntax/one_digit_hex_test.rb
    test/features/api/native_match_routing_test.rb
    test/features/api/native_match_operator_test.rb
    test/features/api/native_case_equality_test.rb
    test/features/api/native_tilde_test.rb
    test/features/captures/match_data_payload_test.rb
    test/features/quality/compiler_exception_safety_test.rb
    test/features/quality/vector_invariant_test.rb
    test/features/quality/rseq_physical_verifier_test.rb
    test/features/matching/regex_redux_contract_test.rb
  ].each { |path| require_relative path }
' > /tmp/onibi-prune-focused.log 2>&1
```

Lint and cleanup commands:

```sh
bundle exec rubocop $(git diff --name-only --diff-filter=M -- 'test/**/*.rb')
git diff --check
(cd ext/onibi && make distclean)
```

## Removed test methods by file

Counts include explicit test methods. The original diff retains each removed assertion.

| File under `test/features/` | Methods removed |
| --- | ---: |
| `benchmark/benchmark_api_test.rb` | 172 |
| `captures/match_data_contract_test.rb` | 1 |
| `captures/match_data_test.rb` | 3 |
| `encoding/encoding_class_descriptor_test.rb` | 2 |
| `encoding/encoding_profile_test.rb` | 6 |
| `engine/capture_use_analysis_test.rb` | 5 |
| `engine/composite_predicate_metadata_test.rb` | 4 |
| `engine/input_view_test.rb` | 5 |
| `engine/invocation_state_test.rb` | 6 |
| `engine/predicate_bitmap_test.rb` | 2 |
| `quality/compiler_exception_safety_test.rb` | 1 |
| `quality/execution_class_authority_test.rb` | 2 |
| `quality/gir_verifier_test.rb` | 4 |
| `quality/internal_regexp_dependency_test.rb` | 25 |
| `quality/module_interface_contract_test.rb` | 4 |
| `quality/parser_delimiter_index_test.rb` | 2 |
| `quality/resolved_semantic_ast_test.rb` | 8 |
| `quality/rseq_physical_verifier_test.rb` | 1 |
| `quality/runtime_position_type_test.rb` | 7 |
| `quality/tagged_nfa_lowering_test.rb` | 10 |
| `quality/tagged_order_resource_scale_test.rb` | 1 |
| `syntax/character_class_test.rb` | 2 |
| `syntax/inline_modifier_test.rb` | 1 |
| `syntax/lexer_test.rb` | 3 |
| `syntax/parser_test.rb` | 2 |
| `syntax/syntax_corpus_test.rb` | 2 |
| `v2/automata_ast_cfg_test.rb` | 2 |
| `v2/automata_test.rb` | 16 |
| `v2/compiler_ast_cfg_test.rb` | 9 |
| `v2/compiler_corpus_test.rb` | 1 |
| `v2/compiler_test.rb` | 4 |
| `v2/interpreter_test.rb` | 22 |
| `v2/irgen_test.rb` | 35 |
| `v2/parser_advanced_groups_test.rb` | 3 |
| `v2/parser_anchors_assertions_test.rb` | 2 |
| `v2/parser_any_extended_test.rb` | 3 |
| `v2/parser_backrefs_conditionals_test.rb` | 3 |
| `v2/parser_classes_escapes_test.rb` | 4 |
| `v2/parser_comments_test.rb` | 1 |
| `v2/parser_corpus_test.rb` | 3 |
| `v2/parser_groups_test.rb` | 2 |
| `v2/parser_quantifiers_test.rb` | 2 |
| `v2/parser_test.rb` | 5 |
