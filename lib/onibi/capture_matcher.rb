# frozen_string_literal: true

module Onibi
  # Produces a match span and numbered capture spans without using MRI Regexp.
  class CaptureMatcher
    include CaptureMatcherDispatch
    include CaptureMatcherAtoms

    def initialize(ast, options = [])
      @ast = ast
      @ignorecase = options.include?("ignorecase")
      @multiline = options.include?("multiline")
      @capture_count = capture_count(ast)
    end

    def match_details(input)
      characters = input.chars

      (0..characters.length).each do |start|
        captures = Array.new(@capture_count)
        result = match_results(@ast, characters, start, captures).max_by(&:first)
        return [start, result[0], result[1]] if result
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

      all.select { |finish, _state| finish >= position + node.minimum }
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
      [node.number, capture_count(node.body)].max
    end

    def sequence_capture_count(node)
      parts_capture_count(node.parts)
    end

    def alternation_capture_count(node)
      parts_capture_count(node.branches)
    end

    def parts_capture_count(parts)
      parts.map { |part| capture_count(part) }.max || 0
    end
  end
end
