# frozen_string_literal: true

module Onibi
  module Interpreter
    # Runtime entry point for generated Onibi bytecode.
    #
    # The implementation remains compatible with the historical YARVIR
    # executor while callers use an interpreter-owned constant.
    Executor = Onibi::IRGen::YARVIR::Executor
  end
end
