# frozen_string_literal: true

require "onibi/onibi"

module Onibi
  class Regexp
    class << self
      def compile(pattern, options = nil, timeout: nil)
        return new(pattern, options) if timeout.nil?

        new(pattern, { options: options, timeout: timeout })
      end
    end
  end
end
