# frozen_string_literal: true

module Onibi
  # Provides private matching and capture helpers for the public regexp facade.
  module RegexpMatching
    private

    def capture_names
      @capture_names ||= CaptureNameCollector.call(@ast)
    end

    def matching_result(input, start_position = 0)
      context = MatchingResult::Context.new(@ast, @bytecode, @pattern, @options, input, start_position)
      MatchingResult.call(context)
    end

    def dfa_specialization
      return if self.class.dfa_memory_budget.zero?

      @dfa_specialization ||= DfaSpecialization.new(@ast)
    end

    def match_details(input, start_position = 0)
      CaptureMatcher.new(@ast, @options).match_details(input, start_position)
    end

    def normalize_match_position(input, position)
      position = position.to_int if position.respond_to?(:to_int)
      raise TypeError, "no implicit conversion of #{position.class} into Integer" unless position.is_a?(Integer)

      position += input.length if position.negative?
      position
    end

    def match_data_arguments(details, input)
      start, finish, capture_offsets = details
      characters = input.chars
      full_match = characters[start...finish].join
      captures = capture_offsets.map { |offset| offset && characters[offset[0]...offset[1]].join }
      [full_match, captures, [[start, finish]] + capture_offsets]
    end
  end
end
