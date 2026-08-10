# frozen_string_literal: true

module Onibi
  # Compiles AST nodes into Thompson-NFA instructions.
  class Compiler
    include CompilerReferences
    include CompilerQuantifiers
    NODE_COMPILERS = {
      AST::Sequence => :compile_sequence,
      AST::Alternation => :compile_alternation,
      AST::Group => :compile_group,
      AST::Quantifier => :compile_quantifier,
      AST::Literal => :compile_literal,
      AST::CharacterClass => :compile_character_class,
      AST::Escape => :compile_escape,
      AST::Property => :compile_property,
      AST::Backreference => :compile_backreference,
      AST::Assertion => :compile_assertion,
      AST::Any => :compile_any,
      AST::Anchor => :compile_anchor
    }.freeze

    def initialize(ast)
      @ast = ast
      @instructions = []
    end

    def compile
      compile_node(@ast)
      emit(:match)
      Bytecode::Program.new(@instructions)
    end

    private

    def compile_node(node)
      compiler = NODE_COMPILERS[node.class]
      raise ArgumentError, "unsupported AST node #{node.class}" unless compiler

      send(compiler, node)
    end

    def compile_alternation(node)
      AlternationCompiler.new(@instructions, method(:compile_node)).compile(node)
    end

    def compile_sequence(node)
      node.parts.each { |part| compile_node(part) }
    end

    def compile_literal(node)
      emit(:char, node.value)
    end

    def compile_character_class(node)
      emit(:class, node.value)
    end

    def compile_escape(node)
      emit(:escape, node.kind)
    end

    def compile_property(node)
      emit(:property, [node.name, node.negated])
    end

    def compile_any(_node)
      emit(:any)
    end

    def compile_anchor(node)
      emit(:anchor, node.kind)
    end

    def compile_group(node)
      return compile_node(node.body) unless node.capture

      emit(:save_start, node.number)
      compile_node(node.body)
      emit(:save_end, node.number)
    end

    def emit(opcode, operand = nil)
      instruction = Bytecode::Instruction.new(opcode, operand, nil)
      @instructions << instruction
      instruction
    end
  end
end
