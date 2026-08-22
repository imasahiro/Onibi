# frozen_string_literal: true

module Onibi
  module V2
    module Compiler
      OptimizedCFG = Struct.new(:ast, :graph, :options, :encoding, :applied_passes, :source_ast,
                                keyword_init: true) do
        def initialize(ast:, graph:, options:, encoding:, applied_passes:, source_ast: ast)
          super(ast: ast, graph: graph, options: options.freeze, encoding: encoding,
                applied_passes: applied_passes.freeze)
          self.source_ast = source_ast
          freeze
        end

        def runtime_program(dfa: true, string_matching: true, dfa_state_limit: 4096)
          Onibi::HybridAutomata::RuntimeCompiler.new(
            dfa: dfa, string_matching: string_matching,
            dfa_state_limit: dfa_state_limit, options: options
          ).compile(source_ast)
        end
      end

      module_function

      def compile(input, options: [], encoding: nil, passes: nil)
        parsed = input.respond_to?(:ast) ? input : nil
        ast = parsed ? parsed.ast : input
        normalized_options = Onibi::V2::Parser.send(:normalize_options, parsed ? parsed.options : options)
        raise TypeError, "expected an AST or parser result" unless ast

        pipeline = if passes.nil?
                     Onibi::V2::Compiler::Optimization::Pipeline.default
                   else
                     Onibi::V2::Compiler::Optimization::Pipeline.for(Array(passes))
                   end
        unit = pipeline.call(ast, options: normalized_options, encoding: encoding || infer_encoding(parsed, ast))
        OptimizedCFG.new(ast: unit.ast, graph: unit.cfg, options: unit.options,
                         encoding: unit.encoding, applied_passes: unit.applied_passes, source_ast: ast)
      end

      def infer_encoding(parsed, ast)
        return parsed.source.encoding if parsed

        literals = ast_values(ast).select { |node| node.is_a?(Onibi::AST::Literal) }
        literals.first&.value&.encoding || Encoding::UTF_8
      end
      private_class_method :infer_encoding

      def ast_values(node)
        children = node.each_pair.flat_map { |_field, value| ast_children(value) }
        [node] + children.flat_map { |child| ast_values(child) }
      end

      def ast_children(value)
        return value.flat_map { |child| ast_children(child) } if value.is_a?(Array)
        return [value] if Onibi::AST.constants.any? { |name| value.is_a?(Onibi::AST.const_get(name)) }

        []
      end
      private_class_method :ast_values
      private_class_method :ast_children
    end
  end
end
