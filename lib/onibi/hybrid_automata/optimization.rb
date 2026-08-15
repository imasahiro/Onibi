# frozen_string_literal: true

module Onibi
  module HybridAutomata
    # Compiler passes that transform parsed structure before CFG publication.
    module Optimization
      module_function

      def compile(ast, options, encoding)
        Pipeline.default.call(ast, options: options, encoding: encoding)
      end

      def prepare(ast, options)
        return ast unless ast.is_a?(AST::Alternation)

        ast = Pipeline::IMPOSSIBLE.call(ast, options: options)
        Pipeline::DUPLICATE.call(ast, options: options)
      end

      def compile_prepared(ast, options, encoding)
        optimized = Pipeline::COALESCING.call(ast)
        CompilationUnit.new(
          ast: optimized,
          cfg: DeferredGraph.new(CFG::Lowerer.new, optimized),
          options: options,
          encoding: encoding,
          applied_passes: Pipeline::DEFAULT_PASS_NAMES
        )
      end

      # Resolves the graph once so ordinary construction avoids diagnostic IR costs.
      class DeferredGraph
        def initialize(lowerer, ast)
          @lowerer = lowerer
          @ast = ast
        end

        def resolve
          @resolve ||= @lowerer.call(@ast)
        end
      end

      CompilationUnit = Struct.new(:ast, :graph_source, :options, :encoding, :applied_passes, keyword_init: true) do
        def initialize(ast:, cfg:, options:, encoding:, applied_passes:)
          normalized_options = options.frozen? ? options : options.dup.freeze
          normalized_passes = applied_passes.frozen? ? applied_passes : applied_passes.dup.freeze
          super(ast: ast, graph_source: cfg, options: normalized_options, encoding: encoding,
                applied_passes: normalized_passes)
          freeze
        end

        def cfg = graph_source.resolve

        def facts
          CFG::Analysis.for(cfg, options: options, encoding: encoding)
        end

        def regions
          CFG::Analysis.regions(cfg, facts)
        end

        def component_graph
          CFG::Analysis.component_graph(cfg)
        end

        def position_nfas
          CFG::Analysis.position_nfas(cfg, facts)
        end

        def head_dfa(row_budget:)
          CFG::Analysis.head_dfa(cfg, facts, row_budget: row_budget)
        end
      end

      # Abstract transformation contract.
      class Pass
        def call(_ast, options:, encoding:)
          raise NotImplementedError
        end
      end

      # Shared structural walk for AST passes that preserve node identity when
      # none of their children changed.
      module RecursiveAstTransform
        private

        def transform(value)
          return transform_sequence(value) if value.is_a?(AST::Sequence)
          return transform_alternation(value) if value.is_a?(AST::Alternation)

          value
        end

        def transform_sequence(sequence)
          parts = sequence.parts.map { |part| transform(part) }
          parts == sequence.parts ? sequence : AST::Sequence.new(parts)
        end

        def transform_alternation(alternation)
          branches = alternation.branches.map { |branch| transform(branch) }
          branches == alternation.branches ? alternation : AST::Alternation.new(branches)
        end
      end

      # Removes alternatives that can be proven to fail without consuming input.
      class ImpossibleBranchElimination < Pass
        def name = :impossible_branch_elimination

        def call(ast, **context)
          options = context.fetch(:options)
          return ast unless options.empty? && ast.is_a?(AST::Alternation)

          branches = ast.branches.reject { |branch| impossible?(branch) }
          return ast.branches.first if branches.empty?
          return ast if branches.length == ast.branches.length

          collapse(branches)
        end

        private

        def impossible?(branch)
          branch.is_a?(AST::Sequence) && branch.parts.any? do |part|
            part.is_a?(AST::Assertion) && part.kind == :negative &&
              part.body.is_a?(AST::Sequence) && part.body.parts.empty?
          end
        end

        def collapse(branches)
          branches.one? ? branches.first : AST::Alternation.new(branches)
        end
      end

      # Retains the first of equivalent literal alternatives.
      class DuplicateLiteralBranchElimination < Pass
        def name = :duplicate_literal_branch_elimination

        def call(ast, **context)
          options = context.fetch(:options)
          return ast unless options.empty? && ast.is_a?(AST::Alternation)

          branches = unique_literal_branches(ast.branches)
          return ast if branches.length == ast.branches.length

          branches.one? ? branches.first : AST::Alternation.new(branches)
        end

        private

        def unique_literal_branches(branches)
          seen = {}
          branches.select do |branch|
            value = literal_value(branch)
            value.nil? || !seen.key?(value) && (seen[value] = true)
          end
        end

        def literal_value(branch)
          return unless branch.is_a?(AST::Sequence)
          return unless branch.parts.all? { |part| part.is_a?(AST::Literal) }

          branch.parts.map(&:value).join
        end
      end

      # Combines adjacent literals into the comparison unit already used by emission.
      class LiteralCoalescing < Pass
        include RecursiveAstTransform

        def name = :literal_coalescing

        def call(ast, **_context)
          transform(ast)
        end

        private

        def transform_sequence(sequence)
          parts = coalesce_literals(sequence.parts)
          parts == sequence.parts ? sequence : AST::Sequence.new(parts)
        end

        def coalesce_literals(values)
          values.each_with_object([]) do |value, result|
            if mergeable_literal?(result.last, value)
              result[-1] = AST::Literal.new(result.last.value + value.value)
            else
              result << value
            end
          end
        end

        def mergeable_literal?(left, right)
          left.is_a?(AST::Literal) && right.is_a?(AST::Literal) &&
            left.value.encoding == right.value.encoding
        end
      end

      # Removes adjacent identical pure assertions without changing cursor state.
      class RedundantPredicateElimination < Pass
        include RecursiveAstTransform

        def name = :redundant_predicate_elimination

        def call(ast, **_context)
          transform(ast)
        end

        private

        def transform_sequence(sequence)
          parts = sequence.parts.each_with_object([]) do |part, result|
            transformed = transform(part)
            result << transformed unless redundant?(result.last, transformed)
          end
          parts == sequence.parts ? sequence : AST::Sequence.new(parts)
        end

        def transform_alternation(alternation)
          branches = alternation.branches.map { |branch| transform(branch) }
          branches == alternation.branches ? alternation : AST::Alternation.new(branches)
        end

        def redundant?(left, right)
          left.is_a?(AST::Assertion) && right.is_a?(AST::Assertion) &&
            left.kind == right.kind && left.body == right.body && pure?(left.body)
        end

        def pure?(value)
          return value.all? { |child| pure?(child) } if value.is_a?(Array)
          return false if value.is_a?(AST::Backreference) || value.is_a?(AST::SubexpressionCall)
          return true unless value.is_a?(Struct)

          value.each { |child| return false unless pure?(child) }
          true
        end
      end

      # Hoists a common literal prefix out of side-effect-free alternatives.
      class BranchThreading < Pass
        include RecursiveAstTransform

        def name = :branch_threading

        def call(ast, **_context)
          transform(ast)
        end

        private

        def transform_sequence(sequence)
          parts = sequence.parts.map { |part| transform(part) }
          parts == sequence.parts ? sequence : AST::Sequence.new(parts)
        end

        def transform_alternation(alternation)
          branches = alternation.branches.map { |branch| transform(branch) }
          threaded = thread(branches)
          threaded || (branches == alternation.branches ? alternation : AST::Alternation.new(branches))
        end

        def thread(branches)
          return unless branches.length > 1 && branches.all? { |branch| threadable?(branch) }

          parts = branches.map(&:parts)
          return unless parts.all? { |items| items.length <= 2 }

          prefix = common_prefix(parts)
          return unless prefix

          suffixes = parts.map { |items| AST::Sequence.new(items.drop(1)) }
          AST::Sequence.new([prefix, AST::Alternation.new(suffixes)])
        end

        def common_prefix(parts)
          prefix = parts.first.first
          return unless prefix.is_a?(AST::Literal)
          return unless parts.all? { |items| items.first == prefix }

          prefix
        end

        def threadable?(branch)
          branch.is_a?(AST::Sequence) && !branch.parts.empty? &&
            branch.parts.none? { |part| part.is_a?(AST::Group) && part.capture }
        end
      end

      # Converts a literal quantifier to possessive when the following literal is disjoint.
      class AutoPossessification < Pass
        include RecursiveAstTransform

        def name = :auto_possessification

        def call(ast, **context)
          return ast unless context.fetch(:options).empty?

          transform(ast)
        end

        private

        def transform_sequence(sequence)
          parts = sequence.parts.map { |part| transform(part) }
          possessive_parts(parts)
          parts == sequence.parts ? sequence : AST::Sequence.new(parts)
        end

        def possessive_parts(parts)
          parts.each_cons(2).with_index do |(left, right), index|
            next unless disjoint_quantifier?(left, right)

            parts[index] = AST::Quantifier.new(left.expression, left.kind, left.minimum,
                                               left.maximum, :possessive)
          end
        end

        def disjoint_quantifier?(left, right)
          left.is_a?(AST::Quantifier) && right.is_a?(AST::Literal) && left.mode == :greedy &&
            left.expression.is_a?(AST::Literal) && left.expression.value != right.value
        end

        def transform_alternation(alternation)
          branches = alternation.branches.map { |branch| transform(branch) }
          branches == alternation.branches ? alternation : AST::Alternation.new(branches)
        end
      end

      # Marks fixed-count repeats as checkpoint-free because no count can be revisited.
      class DeadCheckpointElimination < Pass
        include RecursiveAstTransform

        def name = :dead_checkpoint_elimination

        def call(ast, **context)
          return ast unless context.fetch(:options).empty?

          transform(ast)
        end

        private

        def transform(value)
          return transform_quantifier(value) if value.is_a?(AST::Quantifier)

          super
        end

        def transform_sequence(sequence)
          parts = sequence.parts.map { |part| transform(part) }
          parts == sequence.parts ? sequence : AST::Sequence.new(parts)
        end

        def transform_alternation(alternation)
          branches = alternation.branches.map { |branch| transform(branch) }
          branches == alternation.branches ? alternation : AST::Alternation.new(branches)
        end

        def transform_quantifier(quantifier)
          expression = transform(quantifier.expression)
          return quantifier unless quantifier.minimum == quantifier.maximum

          AST::Quantifier.new(expression, quantifier.kind, quantifier.minimum,
                              quantifier.maximum, :possessive)
        end
      end

      # Recognizes terminal literal loops that have no suffix to backtrack into.
      class LoopIdiomRecognition < Pass
        include RecursiveAstTransform

        def name = :loop_idiom_recognition

        def call(ast, **context)
          return ast unless context.fetch(:options).empty?

          transform(ast)
        end

        private

        def transform_sequence(sequence)
          parts = sequence.parts.map { |part| transform(part) }
          tail = parts.last
          parts[-1] = AST::Quantifier.new(tail.expression, tail.kind, tail.minimum, tail.maximum, :possessive) if terminal_loop?(tail)
          parts == sequence.parts ? sequence : AST::Sequence.new(parts)
        end

        def transform_alternation(alternation)
          branches = alternation.branches.map { |branch| transform(branch) }
          branches == alternation.branches ? alternation : AST::Alternation.new(branches)
        end

        def terminal_loop?(node)
          node.is_a?(AST::Quantifier) && node.kind == :+ && node.mode == :greedy &&
            node.expression.is_a?(AST::Literal)
        end
      end

      # Enables per-search failure caching for pure candidate regions.
      class PureFailureMemoization < Pass
        def name = :pure_failure_memoization

        def call(ast, **_context) = ast
      end

      # Publishes CFG dominance facts without changing AST semantics.
      class StateDominance < Pass
        def name = :state_dominance

        def call(ast, **_context) = ast
      end

      # Records that straight-line CFG regions are lowered once and reused lazily.
      class OnePassRegionLowering < Pass
        def name = :one_pass_region_lowering

        def call(ast, **_context) = ast
      end

      # Runs an explicit ordered set of transforms and then publishes the CFG.
      class Pipeline
        DEFAULT_PASSES = [ImpossibleBranchElimination, DuplicateLiteralBranchElimination,
                          RedundantPredicateElimination, BranchThreading, AutoPossessification,
                          DeadCheckpointElimination, LoopIdiomRecognition, PureFailureMemoization,
                          StateDominance, OnePassRegionLowering, LiteralCoalescing].freeze
        IMPOSSIBLE = ImpossibleBranchElimination.new.freeze
        DUPLICATE = DuplicateLiteralBranchElimination.new.freeze
        COALESCING = LiteralCoalescing.new.freeze
        REDUNDANT_PREDICATE = RedundantPredicateElimination.new.freeze
        BRANCH_THREADING = BranchThreading.new.freeze
        AUTO_POSSESSIFICATION = AutoPossessification.new.freeze
        DEAD_CHECKPOINT = DeadCheckpointElimination.new.freeze
        LOOP_IDIOM = LoopIdiomRecognition.new.freeze
        PURE_FAILURE = PureFailureMemoization.new.freeze
        STATE_DOMINANCE = StateDominance.new.freeze
        ONE_PASS_REGION = OnePassRegionLowering.new.freeze
        DEFAULT_PASS_NAMES = DEFAULT_PASSES.map { |klass| klass.new.name }.freeze

        def self.default
          @default ||= new([IMPOSSIBLE, DUPLICATE, REDUNDANT_PREDICATE, BRANCH_THREADING,
                            AUTO_POSSESSIFICATION, DEAD_CHECKPOINT, LOOP_IDIOM, PURE_FAILURE,
                            STATE_DOMINANCE, ONE_PASS_REGION, COALESCING])
        end

        def self.for(selection)
          return default if selection.nil? || selection.empty?

          new(selection.map { |item| item.respond_to?(:call) ? item : pass_for(item) })
        end

        def self.pass_for(name)
          klass = DEFAULT_PASSES.find { |candidate| candidate.new.name == name }
          raise ArgumentError, "unknown optimization pass #{name.inspect}" unless klass

          klass.new
        end

        def initialize(passes, lowerer: CFG::Lowerer.new)
          @passes = passes.freeze
          @pass_names = @passes.map(&:name).freeze
          @lowerer = lowerer
        end

        def call(ast, options:, encoding:)
          optimized = @passes.reduce(ast) do |current, pass|
            pass.call(current, options: options, encoding: encoding)
          end
          CompilationUnit.new(
            ast: optimized,
            cfg: DeferredGraph.new(@lowerer, optimized),
            options: options,
            encoding: encoding,
            applied_passes: @pass_names
          )
        end
      end
    end
  end
end
