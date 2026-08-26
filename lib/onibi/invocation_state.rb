# frozen_string_literal: true

require_relative "execution_state"

module Onibi
  # Compatibility name for the pre-bytecode invocation state.
  #
  # InvocationState and interpreter frames now share one implementation.
  InvocationState = ExecutionState unless const_defined?(:InvocationState, false)
end
