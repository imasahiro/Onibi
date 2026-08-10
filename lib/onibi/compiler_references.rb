# frozen_string_literal: true

module Onibi
  # Compiles backreference nodes into bytecode placeholders.
  module CompilerReferences
    private

    def compile_backreference(node)
      emit(:backreference, [node.identifier, node.named])
    end
  end
end
