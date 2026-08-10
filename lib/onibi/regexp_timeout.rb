# frozen_string_literal: true

require "timeout"

module Onibi
  # Applies class and instance timeout limits to regexp matching.
  module RegexpTimeout
    def self.included(base)
      base.extend(ClassMethods)
    end

    attr_reader :timeout

    # Defines process-level timeout accessors for the regexp class.
    module ClassMethods
      def timeout
        @timeout
      end

      def timeout=(value)
        @timeout = RegexpTimeout.normalize_timeout(value)
      end
    end

    def normalize_timeout(value)
      return if value.nil?
      raise TypeError, "timeout must be a Numeric or nil" unless value.is_a?(Numeric)
      raise ArgumentError, "timeout must be finite and non-negative" unless value.finite? && value >= 0

      value.to_f
    end
    module_function :normalize_timeout

    def with_timeout(&block)
      limit = @timeout.nil? ? self.class.timeout : @timeout
      return block.call if limit.nil?

      Timeout.timeout(limit, &block)
    end
  end
end
