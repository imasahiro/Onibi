# frozen_string_literal: true

module Onibi
  # Produces a match span and numbered capture spans without using MRI Regexp.
  class CaptureMatcher
    include CaptureMatcherDispatch
    include CaptureMatcherOptionGroups
    include CaptureMatcherAtoms
    include CaptureMatcherSubexpressions
    include CaptureMatcherAbsence
    include CaptureMatcherLinebreaks

    LAZY_MATCHERS = {
      AST::Quantifier => :lazy_quantifier_node?,
      AST::Sequence => :lazy_sequence?,
      AST::Alternation => :lazy_alternation?,
      AST::Group => :lazy_group?
    }.freeze

    def initialize(ast, options = [])
      @ast = ast
      @ignorecase = options.include?("ignorecase")
      @multiline = options.include?("multiline")
      @capture_count = capture_count(ast)
    end

    def match_details(input, start_position = 0)
      characters = input.chars

      (start_position..characters.length).each do |start|
        @match_reset_position = nil
        captures = Array.new(@capture_count)
        results = match_results(@ast, characters, start, captures)
        result = lazy_pattern? ? results.min_by(&:first) : results.first
        return [@match_reset_position || start, result[0], result[1]] if result
      end

      nil
    end

    private

    def quantifier_results(node, characters, position, captures)
      all = [[position, captures]]
      current = all

      quantifier_limit(node, characters).times do
        next_results = quantifier_step(node, characters, current)
        break if next_results.empty?

        all.concat(next_results)
        break if next_results == current

        current = next_results
      end

      quantifier_results_for(node, position, all)
    end

    def quantifier_limit(node, characters)
      node.maximum || characters.length + 1
    end

    def quantifier_step(node, characters, current)
      results = current.flat_map do |current_position, state|
        match_results(node.expression, characters, current_position, state)
      end
      results.uniq { |finish, state| [finish, state] }
    end

    def capture_count(node)
      matcher = CAPTURE_COUNTS[node.class]
      matcher ? send(matcher, node) : 0
    end

    def group_capture_count(node)
      (node.capture ? 1 : 0) + capture_count(node.body)
    end

    def sequence_capture_count(node)
      parts_capture_count(node.parts)
    end

    def alternation_capture_count(node)
      parts_capture_count(node.branches)
    end

    def parts_capture_count(parts)
      parts.sum { |part| capture_count(part) }
    end

    def quantifier_results_for(node, position, all)
      results = all.select { |finish, _state| finish >= position + node.minimum }
      return [] if node.mode == :possessive && results.empty?
      return [results.max_by(&:first)] if node.mode == :possessive
      return results.reverse if node.mode == :greedy

      results
    end

    def lazy_pattern?
      lazy_quantifier?(@ast)
    end

    def lazy_quantifier?(node)
      matcher = LAZY_MATCHERS[node.class]
      matcher ? send(matcher, node) : false
    end

    def lazy_quantifier_node?(node)
      node.mode == :lazy || lazy_quantifier?(node.expression)
    end

    def lazy_sequence?(node)
      node.parts.any? { |part| lazy_quantifier?(part) }
    end

    def lazy_alternation?(node)
      node.branches.any? { |branch| lazy_quantifier?(branch) }
    end

    def lazy_group?(node)
      lazy_quantifier?(node.body)
    end
  end
end
