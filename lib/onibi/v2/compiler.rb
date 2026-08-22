# frozen_string_literal: true

module Onibi
  module V2
    module Compiler
      OptimizedCFG = Struct.new(:ast, :graph, :options, :encoding, :applied_passes, keyword_init: true) do
        def initialize(ast:, graph:, options:, encoding:, applied_passes:)
          super(ast: ast, graph: graph, options: options.freeze, encoding: encoding,
                applied_passes: applied_passes.freeze)
          freeze
        end
      end

      module_function

      def compile(input, options: [], encoding: nil)
        parsed = input.respond_to?(:ast) ? input : nil
        ast = parsed ? parsed.ast : input
        normalized_options = Onibi::V2::Parser.send(:normalize_options, parsed ? parsed.options : options)
        raise TypeError, "expected an AST or parser result" unless ast

        unit = Onibi::HybridAutomata::Optimization.compile(
          ast, normalized_options, encoding || infer_encoding(parsed, ast)
        )
        OptimizedCFG.new(ast: unit.ast, graph: unit.cfg, options: unit.options,
                         encoding: unit.encoding, applied_passes: unit.applied_passes)
      end

      def infer_encoding(parsed, ast)
        return parsed.source.encoding if parsed

        literals = ast_values(ast).select { |node| node.is_a?(Onibi::AST::Literal) }
        literals.first&.value&.encoding || Encoding::UTF_8
      end
      private_class_method :infer_encoding

      def ast_values(node)
        children = case node
                   when Onibi::AST::Sequence then node.parts
                   when Onibi::AST::Alternation then node.branches
                   else []
                   end
        [node] + children.flat_map { |child| ast_values(child) }
      end
      private_class_method :ast_values
    end
  end
end
