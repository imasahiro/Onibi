# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

PROJECT_ROOT = File.expand_path("..", __dir__)
FIXTURES_ROOT = File.join(PROJECT_ROOT, "fixtures")

require "simplecov"

SimpleCov.start do
  track_files "lib/**/*.rb"
  add_filter "/test/"
  add_filter "/benchmark/"
  add_filter "/fuzz/"
end

require "onibi"
require "onibi/codegen"
require_relative "support/fixtures"

require "minitest/autorun"
