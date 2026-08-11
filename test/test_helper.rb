# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

PROJECT_ROOT = File.expand_path("..", __dir__)
FIXTURES_ROOT = File.join(PROJECT_ROOT, "fixtures")

require "simplecov"

SimpleCov.start do
  add_filter "/test/"
end

require "onibi"
require_relative "support/fixtures"

require "minitest/autorun"
