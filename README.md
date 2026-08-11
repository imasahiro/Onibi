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

### v1 API examples

The v1 constructor, matching, and API are opt-in: use `Onibi::Regexp` explicitly and keep MRI's `Regexp`
available in the same process.

```ruby
require "onibi"

regexp = Onibi::Regexp.new("(?<word>a+)", Onibi::Regexp::IGNORECASE)
match = regexp.match("xxAAA")
match["word"]
match.captures
match.offset("word")
match.pre_match
match.post_match
```

The utility and integration APIs are available on the same class:

```ruby
regexp.scan("a1 a2") { |match| match }
regexp.gsub("a1 a2", "b")
regexp.encoding
Onibi::Regexp.escape("a+b")
Onibi::Regexp.union("cat", "dog")
```

Timeouts may be set per instance or through the class default:

```ruby
Onibi::Regexp.timeout = 0.25
regexp = Onibi::Regexp.new("a+", timeout: 0.1)
regexp.match?("aaa")
```

Encoding behavior is explicit for string patterns and includes ASCII-compatible
cross-encoding matches plus UTF-8 Unicode case folding. See the
[encoding matrix](fixtures/encoding/matrix.yml) and the
[v1 compatibility report](docs/v1-compatibility-report.yml).

Known MRI differences: Onibi does not replace MRI's global match variables,
String/Symbol implicit regexp integration, regex-literal encoding modes, JSON
extensions, or comprehensive ReDoS controls. These are outside the v1 opt-in
contract; see the [design document](docs/onibi-design.md) for the full scope.

## Benchmarks

Run pairwise `benchmark-ips` microbenchmarks for Ruby `Regexp` and Onibi. The
checked-in corpus covers ASCII and UTF-8 patterns across literals, character
classes, anchors, quantifiers, captures, references, lookarounds, advanced
groups, options, and Unicode properties:

```sh
bundle exec ruby benchmark/regexp_features.rb --list
bundle exec ruby benchmark/regexp_features.rb --feature character_classes
bundle exec ruby benchmark/regexp_features.rb --encoding utf8 --operation all
```

The default operation is warm `match?`. Use `--operation compile` to isolate
compilation, `--operation first_match` to compile and immediately match, or
`--operation all` to run all three. Measurement defaults to 1 second with a
0.5 second warmup per Ruby/Onibi pair; `--time` and `--warmup` override those
values. Each fixture is also an acceptance test that checks Ruby and Onibi
produce the same boolean result before it is used as regression data.

### Regex Redux

Run the benchmark workload with either regular expression implementation:

```sh
ruby benchmark/regex_redux.rb --engine=ruby  < benchmark/fasta-500.txt
ruby benchmark/regex_redux.rb --engine=onibi < benchmark/fasta-500.txt
```

To compare elapsed time for both implementations, run the Minitest benchmark
methods. They use the checked-in `fasta-500.txt` fixture and a small range so
the regular test suite remains practical:

```sh
ruby -Itest test/features/matching/regex_redux_benchmark_test.rb -n /bench_/
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
