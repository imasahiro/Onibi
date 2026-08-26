# frozen_string_literal: true

module Onibi
  module Compiler
    Pipeline = Optimization::Pipeline
    MAX_REPEAT_COUNT = 100_000

    # Build the execution program from compiler output. Runtime objects pass
    # semantic flags and subexpressions; this keeps IR generation out of the
    # public regexp facade.
    def bytecode_program(ast, options:, encoding:, flags: {})
      compiled = compile(ast, options: options, encoding: encoding)
      tnfa = Onibi::Automata::GlushkovTNFA.from_cfg(compiled.graph)
      dfa = Onibi::Automata::DFA.from_tnfa(tnfa)
      semantic_root = flags[:semantic_root] ||
                      Onibi::IRGen::YARVIR::SemanticBytecode.compile(
                        ast, casefold: flags.fetch(:casefold, false)
                      )
      Onibi::IRGen::YARVIR.generate(
        dfa,
        flags: flags.merge(semantic_root: semantic_root)
      )
    end
    module_function :bytecode_program

    OptimizedCFG = Struct.new(:ast, :graph, :options, :encoding, :applied_passes, :source_ast,
                              keyword_init: true) do
      def initialize(ast:, graph:, options:, encoding:, applied_passes:, source_ast: ast)
        super(ast: ast, graph: graph, options: options.freeze, encoding: encoding,
              applied_passes: applied_passes.freeze)
        self.source_ast = source_ast
        freeze
      end
    end

    module_function

    def validate(ast)
      validate_quantifier_bounds(ast)
      true
    end

    def compile(input, options: [], encoding: nil, passes: nil)
      parsed = input.respond_to?(:ast) ? input : nil
      ast = parsed ? parsed.ast : input
      ast = normalize_numeric_escapes(ast)
      normalized_options = Onibi::Parser.send(:normalize_options, parsed ? parsed.options : options)
      raise TypeError, "expected an AST or parser result" unless ast

      validate(ast)

      pipeline = if passes.nil?
                   Onibi::Compiler::Pipeline.default
                 else
                   Onibi::Compiler::Pipeline.for(Array(passes))
                 end
      unit = pipeline.call(ast, options: normalized_options, encoding: encoding || infer_encoding(parsed, ast))
      OptimizedCFG.new(ast: unit.ast, graph: unit.cfg, options: unit.options,
                       encoding: unit.encoding, applied_passes: unit.applied_passes, source_ast: ast)
    end

    # Resolve ambiguous numeric escapes after the parser knows the capture
    # count. MRI uses a backreference when that capture exists; otherwise it
    # uses an octal byte or literal digits.
    def normalize_numeric_escapes(ast)
      captures = ast_values(ast).count { |node| node.is_a?(Onibi::AST::Group) && node.capture }
      normalize_numeric_node(ast, captures)
    end

    def normalize_numeric_node(node, captures)
      if node.is_a?(Onibi::AST::Backreference) && !node.named && node.identifier.is_a?(String)
        digits = node.identifier
        number = digits.to_i
        return Onibi::AST::Backreference.new(number, false) if digits.length > 1 && number <= captures
        return Onibi::AST::Literal.new(digits) unless digits.each_char.all? { |digit| digit >= "0" && digit <= "7" }

        return Onibi::AST::Literal.new(digits.to_i(8).chr(digits.encoding))
      end

      values = node.each_pair.map { |_field, value| normalize_numeric_value(value, captures) }
      node.class.new(*values)
    end
    private_class_method :normalize_numeric_node

    def normalize_numeric_value(value, captures)
      return value.map { |item| normalize_numeric_value(item, captures) } if value.is_a?(Array)
      return normalize_numeric_node(value, captures) if Onibi::AST.constants.any? do |name|
        value.is_a?(Onibi::AST.const_get(name))
      end

      value
    end
    private_class_method :normalize_numeric_value

    def validate_quantifier_bounds(ast)
      ast_values(ast).each do |node|
        validate_character_class(node) if node.is_a?(Onibi::AST::CharacterClass)

        next unless node.is_a?(Onibi::AST::Quantifier)
        next if node.minimum <= MAX_REPEAT_COUNT &&
                (node.maximum.nil? || node.maximum <= MAX_REPEAT_COUNT)

        raise RegexpError, "too big number for repeat range"
      end
    end
    private_class_method :validate_quantifier_bounds

    def validate_character_class(node)
      value = node.value
      raise RegexpError, "empty character class" if ["", "^"].include?(value)

      Onibi::ClassPredicates.validate!(value)

      metadata = Onibi::ClassPredicates::Normalizer.normalize(value)
      return unless metadata.kind == :ascii
      return unless metadata.ranges.any? { |first, last| first.ord > last.ord }

      raise RegexpError, "invalid character class range"
    end
    private_class_method :validate_character_class

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
