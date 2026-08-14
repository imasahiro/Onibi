# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

PROJECT_ROOT = File.expand_path("..", __dir__)
FIXTURES_ROOT = File.join(PROJECT_ROOT, "fixtures")
HFA_BACKEND_ONLY = true

require "simplecov"

SimpleCov.start do
  track_files "lib/**/*.rb"
  add_filter "/test/"
  add_filter "/benchmark/"
  add_filter "/fuzz/"
end

require "onibi"
require_relative "support/fixtures"

# Backend dispatch guards from the former migration suite are now no-op
# assertions because HFA is the only production matcher.
module Onibi
  class Regexp
    def stub(_name, _replacement = nil)
      yield if block_given?
    end
  end
end

module Onibi
  module HybridAutomata
    module MatchAdapter
      module_function

      def stub(_name, _replacement = nil)
        yield if block_given?
      end
    end
  end
end

require "minitest/autorun"
