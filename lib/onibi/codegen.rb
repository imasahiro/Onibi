# frozen_string_literal: true

module Onibi
  # Raised when generated Ruby cannot be compiled or violates the codegen boundary.
  class CodegenError < StandardError
  end

  module Codegen
    # Computes Ruby-compatible simple and full-fold literal candidates.
    module Casefold
      module_function

      def literal_candidates(input, position, value)
        maximum = [value.length * 2, value.length].max
        (value.length..maximum).filter_map do |length|
          candidate = input[position, length]
          next unless candidate
          next unless candidate.downcase == value.downcase || candidate.upcase == value.upcase

          position + length
        end
      end
    end

    Width = Struct.new(:minimum, :maximum, :finite, :nullable, keyword_init: true) do
      def initialize(**kwargs)
        super
        freeze
      end
    end

    Analysis = Struct.new(
      :captures, :named_captures, :subexpression_calls, :widths, :labels, :options, :encoding,
      keyword_init: true
    )

    # Recursively freezes compiler metadata before publication.
    module DeepFreezer
      private

      def deep_freeze(value)
        case value
        when Struct then value.each { |item| deep_freeze(item) }
        when Hash
          value.each do |key, item|
            deep_freeze(key)
            deep_freeze(item)
          end
        when Array then value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end

    # Computes immutable facts consumed by source emitters.
    class Analyzer
      include DeepFreezer
      NODE_TYPES = [
        AST::Literal, AST::CharacterClass, AST::Escape, AST::Property, AST::Backreference,
        AST::Assertion, AST::Any, AST::Anchor, AST::Sequence, AST::Alternation, AST::Group,
        AST::OptionGroup, AST::AtomicGroup, AST::Conditional, AST::SubexpressionCall,
        AST::Absence, AST::Quantifier
      ].freeze

      def initialize(options = [], encoding = Encoding::UTF_8)
        @options = options.dup.freeze
        @encoding = encoding
        @captures = []
        @named_captures = {}
        @calls = []
        @widths = {}.compare_by_identity
        @labels = {}.compare_by_identity
        @next_label = 0
      end

      def analyze(ast)
        visit(ast)
        result = Analysis.new(
          captures: @captures,
          named_captures: @named_captures,
          subexpression_calls: @calls,
          widths: @widths,
          labels: @labels,
          options: @options,
          encoding: @encoding
        )
        deep_freeze(result)
      end

      private

      def visit(node)
        handler = "visit_#{node_type_name(node).downcase}"
        raise CodegenError, "unsupported AST node #{node.class}" unless NODE_TYPES.include?(node.class)

        assign_label(node)
        width = send(handler, node)
        @widths[node] = width
        width
      end

      def node_type_name(node)
        node.class.name.to_s.split("::").last.to_s
      end

      def assign_label(node)
        @labels[node] = @next_label
        @next_label += 1
      end

      def visit_literal(node)
        scalar_width(node.value.length)
      end

      def visit_characterclass(_node) = scalar_width(1)

      def visit_escape(node)
        return zero_width if %i[word_boundary not_word_boundary start_match match_reset].include?(node.kind)

        scalar_width(1)
      end

      def visit_property(_node) = scalar_width(1)
      def visit_backreference(_node) = variable_width
      def visit_any(_node) = scalar_width(1)
      def visit_anchor(_node) = zero_width

      def visit_subexpressioncall(node)
        @calls << node
        variable_width
      end

      def visit_assertion(node)
        visit(node.body)
        zero_width
      end

      def visit_group(node)
        @captures << node.number if node.capture
        @named_captures[node.name] = node.number if node.name
        visit(node.body)
      end

      def visit_atomicgroup(node) = visit(node.body)
      def visit_absence(node) = visit(node.body) && zero_width

      def visit_optiongroup(node)
        visit(node.body)
      end

      def visit_conditional(node)
        yes = visit(node.yes_branch)
        no = visit(node.no_branch)
        merge(yes, no)
      end

      def visit_sequence(node)
        widths = node.parts.map { |part| visit(part) }
        sequence_width(widths)
      end

      def sequence_width(widths)
        finite = finite_sequence_width(widths)
        maximum = unbounded_width?(widths) ? nil : widths.sum(&:maximum)
        Width.new(minimum: widths.sum(&:minimum), maximum: maximum, finite: finite, nullable: widths.all?(&:nullable))
      end

      def finite_sequence_width(widths)
        return nil unless widths.all?(&:finite)

        widths.flat_map { |width| width.finite || [width.minimum] }.uniq
      end

      def unbounded_width?(widths)
        widths.any? { |width| width.maximum.nil? }
      end

      def visit_alternation(node)
        widths = node.branches.map { |branch| visit(branch) }
        merge(*widths)
      end

      def visit_quantifier(node)
        body = visit(node.expression)
        minimum = body.minimum * node.minimum
        maximum = node.maximum.nil? || body.maximum.nil? ? nil : body.maximum * node.maximum
        Width.new(minimum: minimum, maximum: maximum, finite: nil, nullable: node.minimum.zero? || body.nullable)
      end

      def scalar_width(value)
        Width.new(minimum: value, maximum: value, finite: [value], nullable: value.zero?)
      end

      def zero_width
        scalar_width(0)
      end

      def variable_width
        Width.new(minimum: 0, maximum: nil, finite: nil, nullable: true)
      end

      def merge(*widths)
        Width.new(
          minimum: widths.map(&:minimum).min,
          maximum: widths.any? { |width| width.maximum.nil? } ? nil : widths.map(&:maximum).max,
          finite: widths.all?(&:finite) ? widths.flat_map(&:finite).uniq.sort : nil,
          nullable: widths.any?(&:nullable)
        )
      end
    end

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

        Security.validate_source!(source)

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

      def self.ast(ast, options: [])
        AstEmitter.new(options).emit(ast)
      end
    end

    # Emits capture group begin/end operations.
    module GroupEmitter
      private

      def emit_group(node, cursor)
        return emit_node(node.body, cursor) unless node.capture

        result = fresh_cursor
        <<~EXPRESSION.strip
          (begin captures[#{node.number - 1}] = [#{cursor}, nil]; #{result} = #{emit_node(node.body, cursor)}; #{result}.nil? ? (captures[#{node.number - 1}] = nil) : (captures[#{node.number - 1}][1] = #{result}; #{result}); end)
        EXPRESSION
      end
    end

    # Emits lookahead and fixed-width lookbehind assertions.
    module AssertionEmitter
      private

      def emit_assertion(node, cursor)
        if %i[positive negative].include?(node.kind)
          body = emit_node(node.body, cursor)
          matched = node.kind == :positive ? "!#{body}.nil?" : "#{body}.nil?"
          return "(#{matched} ? #{cursor} : nil)"
        end

        width = fixed_width(node.body)
        start = "#{cursor} - #{width}"
        body = emit_node(node.body, start)
        matched = "#{start} >= 0 && #{body} == #{cursor}"
        matched = "!(#{matched})" if node.kind == :negative_lookbehind
        "(#{matched} ? #{cursor} : nil)"
      end

      def fixed_width(node)
        case node
        when AST::Literal then node.value.length
        when AST::Sequence then node.parts.sum { |part| fixed_width(part) }
        else raise CodegenError, "lookbehind requires fixed-width generated body"
        end
      end
    end

    # Emits counter-driven quantifier loops.
    module QuantifierEmitter
      private

      def emit_quantifier(node, cursor)
        counter = fresh_cursor
        result = fresh_cursor
        previous = fresh_cursor
        maximum = node.maximum || "input.length + 1"
        body = emit_node(node.expression, result)
        greedy_exit = node.mode == :lazy ? "break if #{counter} >= #{node.minimum}" : ""
        <<~EXPRESSION.strip
          (begin #{result} = #{cursor}; #{counter} = 0; while #{counter} < #{maximum}; #{previous} = #{result}; #{result} = #{body}; if #{result}.nil?; #{result} = #{previous}; break; end; #{counter} += 1; break if #{result} == #{previous}; #{greedy_exit}; end; #{counter} >= #{node.minimum} ? #{result} : nil; end)
        EXPRESSION
      end
    end

    # Emits backreferences, conditionals, calls, and absence regions.
    module NonRegularEmitter
      private

      def emit_backreference(node, cursor)
        index = node.identifier.to_i - 1
        length = "captures[#{index}][1] - captures[#{index}][0]"
        source = "input[captures[#{index}][0], #{length}]"
        target = "input[#{cursor}, #{length}]"
        "(captures[#{index}] ? (#{target} == #{source} ? #{cursor} + #{length} : nil) : nil)"
      end

      def emit_conditional(node, cursor)
        condition = Array(node.condition).first.to_i - 1
        yes_branch = emit_node(node.yes_branch, cursor)
        no_branch = emit_node(node.no_branch, cursor)
        "(captures[#{condition}] ? #{yes_branch} : #{no_branch})"
      end

      def emit_subexpression_call(node, cursor)
        group = @groups[node.identifier]
        raise CodegenError, "unresolved subexpression call #{node.identifier}" unless group

        emit_node(group.body, cursor)
      end

      def emit_absence(node, cursor)
        body = emit_node(node.body, cursor)
        "(#{body}.nil? ? #{cursor} : nil)"
      end
    end

    # Emits anchors and line-boundary predicates.
    module AnchorEmitter
      private

      def emit_anchor(node, cursor)
        predicate = case node.kind
                    when :anchor_absolute_start then "#{cursor} == 0"
                    when :anchor_absolute_end then "#{cursor} == input.length"
                    when :anchor_start then line_start_predicate(cursor)
                    when :anchor_end then line_end_predicate(cursor)
                    when :anchor_before_final_newline
                      "#{cursor} == input.length || (#{cursor} == input.length - 1 && " \
                        "input[#{cursor}] == \"\\n\")"
                    else "false"
                    end
        "(#{predicate} ? #{cursor} : nil)"
      end

      def line_start_predicate(cursor)
        return "#{cursor} == 0" unless @options.include?("multiline")

        "#{cursor} == 0 || input[#{cursor} - 1] == \"\\n\""
      end

      def line_end_predicate(cursor)
        return "#{cursor} == input.length" unless @options.include?("multiline")

        "#{cursor} == input.length || input[#{cursor}] == \"\\n\""
      end
    end

    # Emits character class and Unicode property predicates.
    module PredicateEmitter
      private

      def emit_class(node, cursor)
        ignorecase = @options.include?("ignorecase")
        predicate = "Onibi::ClassPredicates.matches?(#{node.value.dump}, input[#{cursor}], ignorecase: #{ignorecase})"
        "(#{cursor} < input.length && #{predicate} ? #{cursor} + 1 : nil)"
      end

      def emit_property(node, cursor)
        predicate = "Onibi::UnicodeProperties.matches?(#{node.name.dump}, input[#{cursor}])"
        predicate = "!(#{predicate})" if node.negated
        "(#{cursor} < input.length && #{predicate} ? #{cursor} + 1 : nil)"
      end
    end

    # Emits direct Ruby control flow for regular consuming AST nodes.
    class AstEmitter
      include GroupEmitter
      include AssertionEmitter
      include QuantifierEmitter
      include NonRegularEmitter
      include AnchorEmitter
      include PredicateEmitter
      NODE_EMITTERS = {
        AST::Literal => :emit_literal,
        AST::Sequence => :emit_sequence,
        AST::Alternation => :emit_alternation,
        AST::Any => :emit_any,
        AST::CharacterClass => :emit_class,
        AST::Property => :emit_property,
        AST::Escape => :emit_escape,
        AST::Anchor => :emit_anchor,
        AST::OptionGroup => :emit_option_group,
        AST::Quantifier => :emit_quantifier,
        AST::Group => :emit_group,
        AST::AtomicGroup => :emit_atomic_group,
        AST::Assertion => :emit_assertion,
        AST::Backreference => :emit_backreference,
        AST::Conditional => :emit_conditional,
        AST::SubexpressionCall => :emit_subexpression_call,
        AST::Absence => :emit_absence
      }.freeze

      def initialize(options)
        @options = options
        @counter = 0
        @groups = {}
      end

      def emit(ast)
        collect_groups(ast)
        body = emit_node(ast, "position")
        <<~RUBY
          def self.__onibi_search(input, position, capture)
            return false unless input.is_a?(String)
            captures = []
            result = #{body}
            result.nil? ? false : (capture ? [position, result, captures] : true)
          end
        RUBY
      end

      private

      def collect_groups(value)
        return value.each { |item| collect_groups(item) } if value.is_a?(Array)
        return unless value.is_a?(Struct)

        @groups[value.number] = value if value.is_a?(AST::Group) && value.number
        @groups[value.name] = value if value.is_a?(AST::Group) && value.name
        value.each { |child| collect_groups(child) }
      end

      def emit_node(node, cursor)
        handler = NODE_EMITTERS[node.class]
        raise CodegenError, "unsupported regular AST node #{node.class}" unless handler

        send(handler, node, cursor)
      end

      def emit_literal(node, cursor)
        value = node.value.dump
        value = "#{value}.b" if node.value.encoding == Encoding::ASCII_8BIT
        comparison = if @options.include?("ignorecase")
                       "Onibi::Codegen::Casefold.literal_candidates(input, #{cursor}, #{value}).first"
                     else
                       "input[#{cursor}, #{node.value.length}] == #{value}"
                     end
        if @options.include?("ignorecase")
          "(#{comparison} || nil)"
        else
          "(#{comparison} ? #{cursor} + #{node.value.length} : nil)"
        end
      end

      def emit_sequence(node, cursor)
        emit_sequence_parts(node.parts, cursor)
      end

      def emit_sequence_parts(parts, cursor)
        return cursor if parts.empty?

        next_cursor = fresh_cursor
        expression = emit_node(parts.first, cursor)
        remainder = emit_sequence_parts(parts.drop(1), next_cursor)
        "(#{next_cursor} = #{expression}; #{next_cursor}.nil? ? nil : #{remainder})"
      end

      def emit_alternation(node, cursor)
        branches = node.branches.map do |branch|
          expression = emit_node(branch, cursor)
          "(branch = #{expression}; branch.nil? ? nil : branch)"
        end
        "(#{branches.join(" || ")})"
      end

      def emit_any(node, cursor)
        condition = node.value == "." && !@options.include?("multiline") ? "input[#{cursor}] != \"\\n\"" : "true"
        "(#{cursor} < input.length && #{condition} ? #{cursor} + 1 : nil)"
      end

      def emit_escape(node, cursor)
        if %i[word_boundary not_word_boundary].include?(node.kind)
          predicate = "Onibi::CharacterPredicates.word_boundary?(input.chars, #{cursor})"
          predicate = "!(#{predicate})" if node.kind == :not_word_boundary
          return "(#{predicate} ? #{cursor} : nil)"
        end
        return cursor.to_s if %i[start_match match_reset].include?(node.kind)

        if %i[digit not_digit space not_space word not_word horizontal_space not_horizontal_space].include?(node.kind)
          predicate = "Onibi::CharacterPredicates.escape_matches?(#{node.kind.inspect}, input[#{cursor}])"
          return "(#{cursor} < input.length && #{predicate} ? #{cursor} + 1 : nil)"
        end

        if node.kind == :linebreak
          predicate = "Onibi::CharacterPredicates.linebreak?(input[#{cursor}])"
          return "(#{cursor} < input.length && #{predicate} ? #{cursor} + 1 : nil)"
        end

        "(#{cursor} < input.length ? #{cursor} + 1 : nil)"
      end

      def emit_option_group(node, cursor)
        scoped_options = @options.dup
        scoped_options = toggle_option(scoped_options, "ignorecase", node.ignorecase)
        scoped_options = toggle_option(scoped_options, "multiline", node.multiline)
        scoped_options = toggle_option(scoped_options, "extended", node.extended)
        AstEmitter.new(scoped_options).send(:emit_node, node.body, cursor)
      end

      def toggle_option(options, name, value)
        return options unless value == true || value == false

        value ? (options | [name]) : (options - [name])
      end

      def emit_atomic_group(node, cursor)
        emit_node(node.body, cursor)
      end

      def fresh_cursor
        @counter += 1
        "cursor_#{@counter}"
      end
    end

    # Owns one immutable generated module for one regexp compilation.
    class GeneratedProgram
      attr_reader :compiled_module, :entrypoint, :source

      def self.literal(value)
        new(RubyEmitter.literal(value))
      end

      def self.ast(ast, options: [])
        new(RubyGenerator.ast(ast, options: options))
      end

      def initialize(source, compiler: SourceCompiler.new, filename: "(onibi-generated)")
        @source = source.dup.freeze
        @compiled_module = compiler.compile(@source, filename: filename)
        @entrypoint = SourceCompiler::ENTRYPOINT
        freeze
      end

      def search(input, position, capture:)
        candidate = position
        while candidate <= input.length
          result = compiled_module.__send__(entrypoint, input, candidate, capture)
          return result if result

          candidate += 1
        end
        false
      end
    end

    # Converts generated offsets into the existing public MatchData shape.
    class MatchAdapter
      def self.build(result, input, regexp, names = {})
        return nil unless result

        start, finish, capture_offsets = result
        characters = input.chars
        full_match = characters[start...finish].join
        captures = capture_offsets.map { |offset| offset && characters[offset[0]...offset[1]].join }
        offsets = [[start, finish]] + capture_offsets
        normalized_names = names.transform_values { |value| Array(value).last }
        MatchData.new(full_match, captures, offsets, normalized_names, MatchData::Context.new(input, regexp))
      end
    end

    # Experimental boolean surface backed by the same generated program.
    class BooleanMatcher
      def initialize(ast, options: [])
        @program = GeneratedProgram.ast(ast, options: options)
      end

      def match?(input, position = 0)
        @program.search(input, position, capture: false) == true
      end
    end

    class ExecutionBudget
      attr_reader :steps

      def initialize(limit: 1_000_000, deadline: nil)
        @limit = limit
        @deadline = deadline
        @steps = 0
      end

      def consume!(amount = 1)
        @steps += amount
        return true if @steps <= @limit && (!@deadline || Process.clock_gettime(Process::CLOCK_MONOTONIC) < @deadline)

        raise Regexp::TimeoutError, "regexp match timeout"
      end
    end

    module Security
      FORBIDDEN_SOURCE = /RubyVM|InstructionSequence|`|\beval\b|\bsystem\b/.freeze

      def self.validate_source!(source, max_bytes: 1_000_000)
        raise CodegenError, "generated source exceeds source_bytes limit" if source.bytesize > max_bytes
        raise CodegenError, "generated source contains forbidden operation" if source.match?(FORBIDDEN_SOURCE)

        source
      end
    end
  end
end
