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
│   └── onibi-design.md
├── lib/
│   ├── onibi.rb
│   └── onibi/
│       ├── regexp.rb
│       ├── match_data.rb
│       ├── lexer.rb
│       ├── parser.rb
│       ├── ast.rb
│       ├── bytecode.rb
│       ├── virtual_machine.rb
│       ├── nfa.rb
│       ├── dfa.rb
│       └── errors.rb
├── test/
│   ├── test_helper.rb
│   ├── unit/
│   ├── integration/
│   ├── differential/
│   ├── regression/
│   └── support/
├── benchmark/
├── fuzz/
├── script/
│   └── ...
└── .githooks/
    └── pre-commit
```

Keep the public API small and explicit. Internal parser, AST, bytecode, VM, NFA, and DFA classes are implementation details unless the design document explicitly promotes an interface.

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

Run a single test file:

```sh
bundle exec ruby -Itest test/unit/regexp_test.rb
```

Run one test by name:

```sh
bundle exec ruby -Itest test/unit/regexp_test.rb -n '/matches literal/'
```

Run differential tests against the current MRI baseline:

```sh
bundle exec rake test:differential
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

Install the repository pre-commit hook configuration:

```sh
git config core.hooksPath .githooks
```

The pre-commit hook must:

1. Identify staged Ruby files.
2. Apply RuboCop formatting to those files.
3. Run RuboCop lint checks.
4. Stop the commit if formatting changed a file, so the developer can review and re-stage it.

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
7. Wait for CI and required status checks to pass.
8. Merge the pull request with GitHub auto-merge using squash merge.
9. Remove the feature worktree after the pull request has merged.

Do not commit directly on `main`, push directly to `main`, or merge a pull request while required CI checks are failing. A pull request may contain multiple commits only when they are all part of the same atomic change; the final merge must be a squash merge.

Before opening a GitHub pull request, run:

```sh
bundle exec rake test
bundle exec rake test:differential
bundle exec rubocop
bundle exec rake build
```

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
