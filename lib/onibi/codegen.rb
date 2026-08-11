# frozen_string_literal: true

module Onibi
  # Raised when generated Ruby cannot be compiled or violates the codegen boundary.
  class CodegenError < StandardError
  end

  module Codegen
    # Compiles generated Ruby source without depending on CRuby instruction sequences.
    class SourceCompiler
      ENTRYPOINT = :__onibi_search

      def self.available?
        module_object = Module.new
        module_object.module_eval("def self.__onibi_probe; true; end", __FILE__, __LINE__)
        module_object.__send__(:__onibi_probe) == true
      rescue StandardError, SyntaxError
        false
      end

      def self.production_requires_rubyvm?
        false
      end

      def compile(source, filename: "(onibi-generated)")
        raise TypeError, "generated source must be a String" unless source.is_a?(String)

        module_object = Module.new
        module_object.module_eval(source, filename, 1)
        return module_object if module_object.respond_to?(SourceCompiler::ENTRYPOINT)

        raise CodegenError, "generated source does not define #{SourceCompiler::ENTRYPOINT}"
      rescue CodegenError
        raise
      rescue StandardError, SyntaxError => e
        raise CodegenError, "generated Ruby compilation failed: #{e.class}: #{e.message}"
      end
    end

    # Emits the smallest typed source fragment used to validate the codegen boundary.
    class RubyEmitter
      def self.literal(value)
        raise TypeError, "literal value must be a String" unless value.is_a?(String)

        escaped_value = value.dump
        length = value.length
        <<~RUBY
          def self.__onibi_search(input, position, capture)
            return false unless input.is_a?(String)
            return false unless input[position, #{length}] == #{escaped_value}

            capture ? [position, position + #{length}, []] : true
          end
        RUBY
      end
    end

    # Coordinates typed emitters; later AST emitters will be added here.
    class RubyGenerator
      def self.literal(value)
        RubyEmitter.literal(value)
      end
    end

    # Owns one immutable generated module for one regexp compilation.
    class GeneratedProgram
      attr_reader :compiled_module, :entrypoint, :source

      def self.literal(value)
        new(RubyEmitter.literal(value))
      end

      def initialize(source, compiler: SourceCompiler.new, filename: "(onibi-generated)")
        @source = source.dup.freeze
        @compiled_module = compiler.compile(@source, filename: filename)
        @entrypoint = SourceCompiler::ENTRYPOINT
        freeze
      end

      def search(input, position, capture:)
        compiled_module.__send__(entrypoint, input, position, capture)
      end
    end
  end
end
