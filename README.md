# Onibi

Onibi is a pure Ruby regular expression engine intended to provide a Ruby-compatible `Regexp` and `MatchData` API.

The project is currently in the Core MVP stage and is being developed using TDD. See [`docs/onibi-design.md`](docs/onibi-design.md) for the design and [`docs/core-mvp-task-list.md`](docs/core-mvp-task-list.md) for the implementation plan.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "onibi"
```

Then run:

```sh
bundle install
```

## Usage

```ruby
require "onibi"

regexp = Onibi::Regexp.new("a+")
regexp.match?("aaa")
regexp.match("aaa")[0]

compiled = Onibi::Regexp.compile("cat", ["ignorecase"])
compiled.match?("A CAT")
```

## Regex Redux benchmark

Run the benchmark workload with either regular expression implementation:

```sh
ruby benchmark/regex-redux.rb --engine=ruby  < benchmark/fasta-500.txt
ruby benchmark/regex-redux.rb --engine=onibi < benchmark/fasta-500.txt
```

To compare elapsed time for both implementations, run the Minitest benchmark
methods. They use the checked-in `fasta-500.txt` fixture and a small range so
the regular test suite remains practical:

```sh
ruby -Itest test/benchmark/regex_redux_test.rb -n /bench_/
```

The output prints separate `bench_ruby` and `bench_onibi` timings for direct
comparison. The same benchmark methods also run as part of the full Minitest
suite.

## Development

```sh
bin/setup
git config core.hooksPath .githooks
bundle exec rake test
bundle exec rubocop
bundle exec rake build
```

The project is licensed under Apache License 2.0.

## Contributing

All changes must follow the TDD workflow documented in [`AGENTS.md`](AGENTS.md).
