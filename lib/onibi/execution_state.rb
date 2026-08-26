# frozen_string_literal: true

module Onibi
  # Mutable state for one matcher invocation.
  #
  # Invocation state and bounded-scope state share one owner.  A checkpoint
  # can therefore restore every mutable stack that belongs to one execution.
  # Semantic bytecode results can remain immutable capture hashes; this class
  # owns the mutable resources around those values.
  class ExecutionState
    Checkpoint = Struct.new(
      :cursor,
      :capture_top,
      :backtrack_top,
      :call_top,
      :repeat_top,
      :cut_top,
      :frame_top,
      keyword_init: true
    )

    # One frame shape serves absence, group, and repeat scopes.  The original
    # bounded-probe names remain as fields for readable VM code.  Generic
    # aliases below allow other scope operations to use the same frame.
    Frame = Struct.new(
      :kind,
      :absent_start,
      :absent_end,
      :probe_position,
      :possible_points,
      :body_checkpoints,
      :capture_checkpoints,
      keyword_init: true
    ) do
      def scope_start
        absent_start
      end

      def scope_start=(value)
        self.absent_start = value
      end

      def scope_end
        absent_end
      end

      def scope_end=(value)
        self.absent_end = value
      end

      def position
        probe_position
      end

      def position=(value)
        self.probe_position = value
      end

      def checkpoints
        body_checkpoints
      end

      def checkpoints=(value)
        self.body_checkpoints = value
      end
    end

    attr_accessor :cursor, :search_origin, :steps
    attr_reader :captures, :backtracks, :calls, :repeats, :cuts, :frames

    def initialize(cursor: 0, search_origin: cursor, capture_count: 0)
      @frames = []
      reset!(cursor: cursor, search_origin: search_origin, capture_count: capture_count)
    end

    # Reset invocation-local resources before a new match attempt.
    def reset!(cursor: 0, search_origin: cursor, capture_count: nil)
      capture_count ||= @captures&.length || 0
      @cursor = cursor
      @search_origin = search_origin
      @captures = Array.new(capture_count)
      @capture_trail = []
      @backtracks = []
      @calls = []
      @repeats = []
      @cuts = []
      @frames.clear
      @steps = 0
      self
    end

    def checkpoint
      Checkpoint.new(
        cursor: @cursor,
        capture_top: @capture_trail.length,
        backtrack_top: @backtracks.length,
        call_top: @calls.length,
        repeat_top: @repeats.length,
        cut_top: @cuts.length,
        frame_top: @frames.length
      )
    end

    def restore(checkpoint)
      @cursor = checkpoint.cursor
      rollback_captures(checkpoint.capture_top)
      truncate(@backtracks, checkpoint.backtrack_top || @backtracks.length)
      truncate(@calls, checkpoint.call_top || @calls.length)
      truncate(@repeats, checkpoint.repeat_top || @repeats.length)
      truncate(@cuts, checkpoint.cut_top || @cuts.length)
      truncate(@frames, checkpoint.frame_top || @frames.length)
      self
    end

    def write_capture(index, value)
      @capture_trail << [index, @captures[index]]
      @captures[index] = value
    end

    def push_backtrack(label)
      @backtracks << [label, checkpoint]
    end

    # Construct a scope frame from the single frame type used by the VM.
    def new_frame(kind: :generic, **attributes)
      Frame.new(kind: kind, **attributes)
    end

    def push_frame(frame = nil, kind: :generic, **attributes)
      frame ||= new_frame(kind: kind, **attributes)
      raise TypeError, "expected an ExecutionState::Frame" unless frame.is_a?(Frame)

      @frames << frame
      frame
    end

    def pop_frame
      @frames.pop
    end

    def current_frame
      @frames.last
    end

    def with_frame(frame = nil, kind: :generic, **attributes)
      active = push_frame(frame, kind: kind, **attributes)
      yield active
    ensure
      pop_frame if active && @frames.last.equal?(active)
    end

    private

    def truncate(array, top)
      count = array.length - top
      array.slice!(top, count) if count.positive?
    end

    def rollback_captures(top)
      while @capture_trail.length > top
        index, value = @capture_trail.pop
        @captures[index] = value
      end
    end
  end
end
