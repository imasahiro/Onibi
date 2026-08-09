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
```

## Development

```sh
bin/setup
bundle exec rake test
bundle exec rubocop
bundle exec rake build
```

The project is licensed under Apache License 2.0.

## Contributing

All changes must follow the TDD workflow documented in [`AGENTS.md`](AGENTS.md).
