# frozen_string_literal: true

require "timeout"

module Onibi
  # Applies class and instance timeout limits to regexp matching.
  module RegexpTimeout
    module_function

    def normalize_timeout(value)
      return if value.nil?
      raise TypeError, "timeout must be a Numeric or nil" unless value.is_a?(Numeric)
      raise ArgumentError, "timeout must be finite and non-negative" unless value.finite? && value >= 0

      value.to_f
    end

    def with_timeout(instance_timeout, class_timeout)
      limit = instance_timeout.nil? ? class_timeout : instance_timeout
      return yield if limit.nil?

      Timeout.timeout(limit) { yield }
    end
  end
end
