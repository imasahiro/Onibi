# frozen_string_literal: true

module Onibi
  # Selects the smallest matcher capable of evaluating a compiled pattern.
  module MatchingResult
    module_function

    Context = Struct.new(:ast, :bytecode, :pattern, :options, :input, :start_position)

    def call(context)
      literal_result = literal_casefold_result(context.pattern, context.options, context.input, context.start_position)
      return literal_result unless literal_result.nil?

      specialized_result = specialized_result(context)
      return specialized_result unless specialized_result.nil?

      default_result(context)
    end

    def specialized_result(context)
      return capture_result(context) if capture_matcher_required?(context.pattern)
      return ast_result(context) if ast_matcher_required?(context.pattern)

      nil
    end

    def capture_result(context)
      !CaptureMatcher.new(context.ast, context.options).match_details(
        context.input, context.start_position
      ).nil?
    end

    def ast_result(context)
      AstMatcher.new(context.ast, context.options).match?(context.input, context.start_position)
    end

    def default_result(context)
      result = VirtualMachine.new(context.bytecode, context.options).match?(
        context.input, context.start_position
      )
      result ||= complex_pattern?(context.pattern) && AstMatcher.new(context.ast, context.options).match?(
        context.input, context.start_position
      )
      result
    end

    def complex_pattern?(pattern)
      pattern.include?("|") || pattern.include?("(")
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
