# frozen_string_literal: true

module Onibi
  # Evaluates zero-width anchor instructions for the virtual machine.
  module VirtualMachineAnchors
    ANCHOR_MATCHERS = {
      anchor_start: :line_start?,
      anchor_end: :line_end?,
      anchor_absolute_start: :absolute_start?,
      anchor_absolute_end: :absolute_end?,
      anchor_before_final_newline: :before_final_newline?
    }.freeze

    private

    def anchor_matches?(kind, position, input)
      matcher = ANCHOR_MATCHERS[kind]
      matcher ? send(matcher, position, input) : false
    end

    def line_start?(position, input)
      position.zero? || input[position - 1] == "\n".ord
    end

    def line_end?(position, input)
      position == input.length || input[position] == "\n".ord
    end

    def absolute_start?(position, _input)
      position.zero?
    end

    def absolute_end?(position, input)
      position == input.length
    end

    def before_final_newline?(position, input)
      position == input.length || final_newline?(position, input)
    end

    def final_newline?(position, input)
      position == input.length - 1 && input[position] == "\n".ord
    end
  end
end
