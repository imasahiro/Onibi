# frozen_string_literal: true

module Onibi
  module V2
    module Parser
      Result = Struct.new(:source, :options, :ast, keyword_init: true) do
        def initialize(source:, options:, ast:)
          super(source: source, options: options.freeze, ast: ast)
          freeze
        end
      end

      module_function

      def parse(source, options: [])
        raise TypeError, "pattern must be a String" unless source.is_a?(String)

        normalized_options = Array(options).dup
        tokens = Onibi::Lexer.new(source, normalized_options).tokens
        ast = Onibi::Parser.new(tokens).parse
        Result.new(source: source, options: normalized_options, ast: ast)
      end
    end
  end
end
