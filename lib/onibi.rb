# frozen_string_literal: true

require "onibi/onibi"

module Onibi
  class Regexp
    class TimeoutError < RegexpError; end unless const_defined?(:TimeoutError, false)

    class << self
      def compile(pattern, options = nil, timeout: nil)
        raise ArgumentError, "timeout is not supported" unless timeout.nil?

        new(pattern, options)
      end

      def timeout=(_value)
        raise ArgumentError, "timeout is not supported"
      end

      def timeout
        nil
      end
    end
  end
end
