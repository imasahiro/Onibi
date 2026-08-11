# frozen_string_literal: true

module Onibi
  # Invocation-local mutable state shared by generated matcher labels.
  class InvocationState
    Checkpoint = Struct.new(:cursor, :capture_top, :call_top, :repeat_top, :cut_top, keyword_init: true)

    attr_accessor :cursor
    attr_reader :search_origin, :captures, :backtracks, :calls, :repeats, :cuts

    def initialize(cursor: 0, search_origin: cursor, capture_count: 0)
      @cursor = cursor
      @search_origin = search_origin
      @captures = Array.new(capture_count)
      @capture_trail = []
      @backtracks = []
      @calls = []
      @repeats = []
      @cuts = []
    end

    def checkpoint
      Checkpoint.new(
        cursor: @cursor,
        capture_top: @capture_trail.length,
        call_top: @calls.length,
        repeat_top: @repeats.length,
        cut_top: @cuts.length
      )
    end

    def restore(checkpoint)
      @cursor = checkpoint.cursor
      rollback_captures(checkpoint.capture_top)
      @calls.slice!(checkpoint.call_top..)
      @repeats.slice!(checkpoint.repeat_top..)
      @cuts.slice!(checkpoint.cut_top..)
      self
    end

    def write_capture(index, value)
      @capture_trail << [index, @captures[index]]
      @captures[index] = value
    end

    def push_backtrack(label)
      @backtracks << [label, checkpoint]
    end

    private

    def rollback_captures(top)
      while @capture_trail.length > top
        index, value = @capture_trail.pop
        @captures[index] = value
      end
    end
  end
end
