# Onibi Development Guide

Onibi is a pure Ruby regular expression engine. All changes must follow the design in [`docs/onibi-design.md`](docs/onibi-design.md).

## Non-negotiable development rule: TDD

Every change must be developed using test-driven development:

1. Add a focused test that describes one new behavior or regression.
2. Run the test and confirm that it fails for the expected reason.
3. Implement the smallest change that makes the test pass.
4. Run the focused test, then the complete test suite.
5. Run formatting and lint checks before opening a pull request.

Do not add production code without a corresponding test. Every bug fix must include a regression test. Fuzz and property-test failures must be reduced to deterministic regression tests when practical.

Changes to public behavior must include an acceptance test. Differential behavior
against MRI must be covered when the feature has an MRI equivalent; unit tests
may support the acceptance test but do not replace it. A task is not complete
until its focused tests, the complete suite, and the applicable differential
tests pass.

### Test scope: library behavior only

Tests under `test/` must protect behavior of the Onibi regular expression
library. Prefer tests that construct `Onibi::Regexp` or `Onibi::MatchData` and
assert matching results, captures, errors, encodings, options, or MRI
compatibility. A public API contract should be tested by calling the API and
checking its behavior, not by maintaining a list of methods or constants that
merely exist.

Do not add tests whose subject is repository or development-tooling
configuration rather than library behavior. This includes tests that only
read or assert the contents or existence of:

- `.github/workflows/`, `.githooks/`, `Rakefile`, `Gemfile`, or `.rubocop.yml`;
- coverage, release-gate, runtime-matrix, or other process configuration;
- gemspec/package file lists, clean-install packaging mechanics, or RBS/API
  inventory files;
- benchmark runners, benchmark thresholds, profiling scripts, fuzz runners,
  or differential-test harness internals.

Keep a benchmark, fuzz, or differential test only when it directly verifies
that Onibi produces the correct result (for example, a deterministic MRI
differential case). Remove workflow/configuration assertions from mixed tests
instead of preserving them for tooling coverage. File-presence checks,
`respond_to?`/method-inventory checks, and tests of test infrastructure belong
in the relevant tooling or CI validation, not in the regular expression
library test suite.

## Repository structure

The project should use this high-level layout:

```text
.
├── AGENTS.md
├── Gemfile
├── LICENSE
├── README.md
├── Rakefile
├── onibi.gemspec
├── bin/
│   └── onibi
├── docs/
│   ├── onibi-design.md
│   ├── hfa-design.md
│   ├── hfa-task-list.md
│   └── history/
├── lib/
│   ├── onibi.rb
│   └── onibi/
│       ├── regexp.rb
│       ├── parser.rb
│       ├── ast.rb
│       ├── hybrid_automata.rb
│       ├── hybrid_automata/
│       ├── match_data*.rb
│       ├── lexer*.rb
│       └── errors.rb
├── test/
│   ├── test_helper.rb
│   ├── features/
│   │   ├── api/
│   │   ├── captures/
│   │   ├── compatibility/
│   │   ├── encoding/
│   │   ├── engine/
│   │   ├── matching/
│   │   ├── quality/
│   │   └── syntax/
│   └── support/
├── fixtures/
│   ├── api/
│   ├── encoding/
│   └── syntax/
├── benchmark/
├── fuzz/
├── script/
│   ├── cross_runtime_contract.rb
│   └── profile_*.rb
└── .githooks/
    └── pre-commit
```

Keep the public API small and explicit. The sole production matcher
architecture is the hybrid finite automaton defined in
[`docs/hfa-design.md`](docs/hfa-design.md): optimized CFG, regexp
decomposition, bounded head DFA, tail NFA, typed semantic components, and one
ordered result iterator. Parser, AST, CFG, automata, predicates, timeout, and
MatchData helpers are internal unless a design document explicitly promotes an
interface. Generated-Ruby, earlier VM, adaptive-cache, and direct-specializer
references under `docs/history/` are records, not current requirements.

## Dependencies

- Runtime dependencies: none.
- C extensions: prohibited.
- FFI: prohibited.
- Development dependencies may include Minitest, Rake, RuboCop, and benchmark/fuzz libraries.

## Build and package commands

Install development dependencies:

```sh
bundle install
```

Run Ruby, Bundler, RuboCop, Rake, and `gem` from the same Ruby installation.
Before running the gates, verify `ruby -v`, `command -v ruby`, and
`bundle -v`; do not allow `/usr/bin/bundle` or another system Ruby to resolve
the project's dependencies. On machines with multiple Ruby installations,
select the intended Ruby first, for example:

```sh
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
```

Bundler's local `.bundle/` directory can contain native extensions compiled
against a different Ruby installation. It is ignored by Git and must not be
shared between Ruby installations or worktrees. After changing Ruby
installations, rebuild the local dependencies with:

```sh
bundle pristine
bundle install
```

If a native-extension load error remains, remove only the affected local
`.bundle/` directory and run `bundle install` again under the selected Ruby.

Build the gem:

```sh
bundle exec rake build
```

If the Rake task is unavailable, use the gem tool directly:

```sh
gem build onibi.gemspec
```

Install the locally built gem in a clean test environment:

```sh
gem install ./onibi-*.gem --local
```

The gem must load with:

```sh
ruby -Ilib -e 'require "onibi"; puts Onibi::Regexp.new("a+").match?("aaa")'
```

## Test commands

Run the complete test suite:

```sh
bundle exec rake test
```

Run a single feature test file:

```sh
bundle exec ruby -Itest test/features/api/match_api_test.rb
```

Run one test by name:

```sh
bundle exec ruby -Itest test/features/api/match_api_test.rb -n '/matches literal/'
```

Run the complete suite, including the MRI differential acceptance tests:

```sh
bundle exec rake test
```

The current Rakefile does not define a separate `test:differential` task;
differential coverage lives in the acceptance tests and runs as part of the
complete suite. Run an individual differential file directly when narrowing a
failure, for example:

```sh
bundle exec ruby -Itest test/features/syntax/syntax_differential_corpus_test.rb
```

Run property and fuzz tests when available:

```sh
bundle exec rake test:property
bundle exec rake test:fuzz
```

Fuzz tests are continuous `main` checks rather than required MVP/v1 pull-request checks. Keep seeds reproducible and record failures as deterministic regression tests.

## Lint and formatting

RuboCop is the required linter and formatter:

```sh
bundle exec rubocop
bundle exec rubocop -A
```

Use `rubocop -A` only on the intended changed files. Review all automatic changes before staging them.

Formatting and linting are separate gates: first apply autocorrection to the
intended changed files, then run the non-mutating lint command. Do not use
autocorrection across the whole repository as part of an unrelated change.
Production code must not hide offenses with `rubocop:disable`; fix the code or
update the shared configuration with a narrowly justified rule. Existing
repository offenses must be tracked as baseline work, but changed files and
new code must not introduce additional offenses. Acceptance-test metric
exceptions, when necessary for a readable scenario, must remain narrow and
must not weaken library-code linting.

Install the repository pre-commit hook configuration:

```sh
git config core.hooksPath .githooks
```

The pre-commit hook must:

1. Identify staged Ruby files.
2. Apply RuboCop formatting to those files.
3. Run RuboCop lint checks.
4. Stop the commit if formatting changed a file, so the developer can review and re-stage it.

Run the hook and all quality gates with the same selected Ruby/Bundler
environment. A hook failure caused by a Ruby-path mismatch is an environment
failure to fix, not a reason to bypass the hook.

## Architecture and performance guardrails

The HFA pipeline is the sole production matcher architecture:

```text
Regexp source -> AST -> optimized CFG -> component graph
              -> head DFA + tail NFA + semantic components -> ordered result
```

Do not add a second production backend, user-facing engine toggle, pattern-text
router, generated-Ruby matcher, whole-pattern semantic verifier, or silent
fallback. An HFA is specifically a bounded head DFA whose border states
activate tail NFAs; string/component decomposition is a separate upper layer.
New matcher optimizations must be derived from semantic, CFG, region, or
automaton facts, preserve ordered control semantics, and include MRI
differential coverage for the affected syntax and public API. Literal values
from Regex Redux, macro benchmarks, or applications must never select an
optimization implementation.

Performance work must report the commit SHA, Ruby/runtime configuration, input
corpus, iteration counts, and allocation results. Separate cold construction,
first match, warm `match?`, `match`, `scan`, and `gsub` measurements; do not
present a lifecycle-mismatched comparison as a regression or improvement.
Correctness, differential tests, and package gates take priority over a faster
benchmark result.

## Feature branches and worktrees

Every change must be delivered as an atomic Git change: one coherent feature, bug fix, scaffold change, or documentation change per commit. Do not combine unrelated changes in one commit.

Develop every change in its own worktree and branch. Begin each feature worktree with the failing acceptance test. Do not mix unrelated features in one worktree.

The required lifecycle is:

1. Create a dedicated worktree and branch from the current `main`.
2. Add the failing acceptance test first.
3. Implement the change and keep the commit scoped to that atomic unit.
4. Run the relevant tests, the complete test suite, lint, format, and package checks.
5. Commit the atomic change locally with a concise message.
6. Push the branch to GitHub and open a pull request.
7. Wait until every CI and status check has completed successfully; pending,
   queued, skipped unexpectedly, cancelled, or failing checks are not green.
8. Only after all checks are green, enable GitHub auto-merge and merge the pull
   request with squash merge. Do not enable auto-merge while any check is still
   running, because a repository may merge before a non-required check reports
   its result.
9. Remove the feature worktree after the pull request has merged.

Do not commit directly on `main`, push directly to `main`, enable auto-merge
before all CI is green, or merge a pull request while any CI or status check is
incomplete or unsuccessful. Treat every configured PR check as a merge gate,
even when GitHub branch protection does not mark it as required. A pull request
may contain multiple commits only when they are all part of the same atomic
change; the final merge must be a squash merge.

Before opening a GitHub pull request, run:

```sh
bundle exec rake test
bundle exec rubocop
bundle exec rake build
```

When the changed files affect runtime loading or packaging, also run the
installed-gem smoke test in an isolated `GEM_HOME`. When they affect HFA
compilation, matching, or runtime compatibility, run the cross-runtime contract
directly:

```sh
bundle exec ruby script/cross_runtime_contract.rb
```

The pull request must include the result of every configured workflow,
including cross-runtime and coverage artifacts. A scheduled fuzz workflow is a
continuous safety net, not a substitute for turning a reproducible failure
into a deterministic regression test.

For benchmark work, keep executable benchmarks under `benchmark/`, profiling
tools under `script/`, and benchmark tests under
`test/features/matching/`. Use the checked-in `benchmark-ips` dependency for
feature microbenchmarks and provide an explicit engine selection when
comparing MRI with Onibi. Benchmark refactors must retain a deterministic test
that verifies the engines produce equivalent fixture output; performance
numbers alone are not a correctness result. Separate cold HFA compilation
cost, first match, warm matching, `match`, `scan`, and `gsub` measurements so
the benchmark does not compare different lifecycle phases accidentally.

All changes enter `main` through a GitHub pull request. Direct pushes to `main` are not part of the workflow. Enable GitHub auto-merge with squash merge after the required checks pass.

## Required pull-request checks for MVP and v1

- MRI latest baseline Minitest suite.
- MRI differential tests against the selected Ruby baseline.
- RuboCop.
- `gem build`.
- Local `gem install`.
- Smoke test from a clean environment.

Other Ruby implementations, long-running benchmarks, and fuzz tests run as continuous `main` checks. They are not MVP/v1 pull-request blockers unless a later milestone changes this policy.

## Current compatibility baseline

The current baseline is MRI Ruby 4.0.6. When a newer stable Ruby is selected at the beginning of a new milestone, update the API inventory, differential-test oracle, encoding matrix, and CI configuration together. Record the selected version and source revision in the design documentation.
