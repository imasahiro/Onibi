# frozen_string_literal: true

module Onibi
  # Selects the smallest matcher capable of evaluating a compiled pattern.
  module MatchingResult
    module_function

    def call(ast, bytecode, pattern, options, input, start_position = 0)
      literal_result = literal_casefold_result(pattern, options, input, start_position)
      return literal_result unless literal_result.nil?

      specialized_result = specialized_result(ast, pattern, options, input, start_position)
      return specialized_result unless specialized_result.nil?

      default_result(bytecode, ast, pattern, options, input, start_position)
    end

    def specialized_result(ast, pattern, options, input, start_position)
      return !CaptureMatcher.new(ast, options).match_details(input, start_position).nil? if capture_matcher_required?(pattern)
      return AstMatcher.new(ast, options).match?(input, start_position) if ast_matcher_required?(pattern)

      nil
    end

    def default_result(bytecode, ast, pattern, options, input, start_position)
      result = VirtualMachine.new(bytecode, options).match?(input, start_position)
      result ||= (pattern.include?("|") || pattern.include?("(")) && AstMatcher.new(ast, options).match?(input, start_position)
      result
    end

    def literal_casefold_result(pattern, options, input, start_position)
      return nil unless literal_casefold_matchable?(pattern, options)

      characters = input.chars
      maximum_length = [pattern.length * 3, 1].max
      (start_position..characters.length).any? do |start|
        (1..maximum_length).any? do |length|
          candidate = characters[start, length]&.join
          candidate && pattern.casecmp?(candidate)
        end
      end
    end

    def literal_casefold_matchable?(pattern, options)
      return false if options.include?("extended")

      options.include?("ignorecase") && pattern.each_char.all? do |character|
        !"\\()|*+?{}[].^$".include?(character)
      end
    end

    def capture_matcher_required?(pattern)
      ["\\k", "\\g", "\\K", "\\1", "\\2", "\\3", "\\4", "\\5", "\\6", "\\7", "\\8", "\\9", "?(", "(?~"].any? do |escape|
        pattern.include?(escape)
      end
    end

    def ast_matcher_required?(pattern)
      return true if pattern.include?("(?")
      return true if pattern.include?("{") && pattern.include?("}+")

      ["\\R", "\\b", "\\B", "\\G", "\\p", "\\P", "(?=", "(?!", "(?<=", "(?<!", "(?>",
       "*+", "++", "?+", "*?", "+?", "??", "?(", "(?i:", "(?-i:"].any? do |escape|
        pattern.include?(escape)
      end
    end
  end
end
