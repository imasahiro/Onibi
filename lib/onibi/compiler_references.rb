# frozen_string_literal: true

module Onibi
  # Compiles backreference nodes into bytecode placeholders.
  module CompilerReferences
    private

    def compile_backreference(node)
      emit(:backreference, [node.identifier, node.named])
    end

    def compile_assertion(node)
      compile_node(node.body)
    end
  end
end
