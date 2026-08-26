# frozen_string_literal: true

module Onibi
  # Mutable state for one matcher invocation.
  #
  # Invocation state and bounded-scope state share one owner.  A checkpoint
  # can therefore restore every mutable stack that belongs to one execution.
  # Semantic bytecode results can remain immutable capture hashes; this class
  # owns the mutable resources around those values.
  class ExecutionState
    # Explicit VM stack records.  They keep control flow and scope state
    # separate from semantic operands.
    CallFrame = Struct.new(:return_pc, :cursor, :capture_top, :frame_top, keyword_init: true)
    BacktrackPoint = Struct.new(:pc, :cursor, :capture_top, :frame_top, :captures, :flags,
                                :capture_frames, :capture_starts,
                                keyword_init: true)
    RepeatFrame = Struct.new(:pc, :cursor, :lengths, :next_index, :minimum, :maximum,
                             keyword_init: true)
    CaptureFrame = Struct.new(:number, :name, :start, :finish, keyword_init: true) do
      def span
        return unless start && finish

        [start, finish]
      end
    end
    VMFrame = Struct.new(:state, :cursor, :captures, :start, :edges, :edge_index, keyword_init: true)
    SemanticFrame = Struct.new(:pc, :cursor, :captures, :flags, :return_pc, :call_stack, :capture_stack,
                               :capture_starts,
                               keyword_init: true)
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
    # Dedicated probe frame for absence execution. It keeps unbounded probe
    # state separate from ordinary scope frames before flat lowering.
    AbsenceFrame = Struct.new(
      :kind,
      :resume_pc,
      :body_pc,
      :absent_start,
      :absent_end,
      :probe_position,
      :possible_points,
      :body_checkpoints,
      :capture_checkpoints,
      :branch_checkpoints,
      :preferred_branch,
      keyword_init: true
    ) do
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

      def restorable_capture_checkpoint(require_ambiguous: false)
        capture_checkpoints.reverse.find do |checkpoint|
          !checkpoint[3] && (!require_ambiguous || checkpoint[4])
        end
      end

      def record_capture_checkpoint(position, length, state, discard_capture, ambiguous)
        capture_checkpoints << [position, length, state.dup, discard_capture, ambiguous]
      end

      def branch_checkpoints_at(position)
        branch_checkpoints.select { |checkpoint| checkpoint[0] == position }
      end

      def record_branch_checkpoint(position, branch, length)
        branch_checkpoints << [position, branch, length]
        self.preferred_branch = branch if length.positive? && preferred_branch.nil?
      end

      def preferred_branch_at(position)
        branch_checkpoints_at(position).find { |_point, _branch, length| length.positive? }&.fetch(1)
      end

      def preferred_body_result(position, results)
        branch = preferred_branch_at(position) || preferred_branch
        if branch && results.any? { |_length, state| state[:__match_alternative_index] == branch }
          return results.find { |_length, state| state[:__match_alternative_index] == branch }
        end
        return results.find { |_length, state| !state.key?(:__match_start) } if
          results.any? { |_length, state| state.key?(:__match_alternative) }

        nil
      end

      def tighten_absent_end(boundary)
        self.absent_end = [absent_end, boundary].min
      end

      def record_body_checkpoint(position, results, captures)
        possible_points << [position, captures]
        body_checkpoints << [position, results]
      end
    end

    attr_accessor :cursor, :search_origin, :steps
    attr_reader :captures, :backtracks, :calls, :repeats, :cuts, :frames, :vm_stack, :semantic_stack,
                :capture_frames

    def initialize(cursor: 0, search_origin: cursor, capture_count: 0)
      @frames = []
      @vm_stack = []
      @semantic_stack = []
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
      @capture_frames = []
      @capture_starts = {}
      @cuts = []
      @frames.clear
      @vm_stack.clear
      @semantic_stack.clear
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

    def push_call(return_pc)
      frame = CallFrame.new(return_pc: return_pc, cursor: @cursor,
                            capture_top: @capture_trail.length, frame_top: @frames.length)
      @calls << frame
      frame
    end

    def pop_call
      @calls.pop
    end

    def push_repeat_frame(pc:, cursor:, lengths:, minimum:, maximum:)
      frame = RepeatFrame.new(pc: pc, cursor: cursor, lengths: lengths,
                              next_index: 0, minimum: minimum, maximum: maximum)
      @repeats << frame
      frame
    end

    def push_capture_frame(number:, name:, start:)
      frame = CaptureFrame.new(number: number, name: name, start: start)
      @capture_frames << frame
      frame
    end

    def start_capture(number:, start:, name: nil)
      (@capture_starts[number] ||= []) << start
      push_capture_frame(number: number, name: name, start: start)
    end

    def pop_capture_start(number)
      starts = @capture_starts[number]
      return unless starts

      start = starts.pop
      @capture_starts.delete(number) if starts.empty?
      start
    end

    def pop_capture_frame(expected = nil)
      frame = @capture_frames.pop
      raise TypeError, "expected the active ExecutionState::CaptureFrame" unless frame.is_a?(CaptureFrame) && (expected.nil? || frame.equal?(expected))

      frame
    end

    def active_capture_frame(number = nil)
      return @capture_frames.last unless number

      @capture_frames.reverse_each.find { |frame| frame.number == number }
    end

    def finish_capture_frame(frame, finish:)
      raise TypeError, "expected the active ExecutionState::CaptureFrame" unless frame.is_a?(CaptureFrame) && @capture_frames.last.equal?(frame)

      frame.finish = finish
      pop_capture_frame(frame)
      frame.span
    end

    def commit_capture(captures, frame, finish:)
      span = finish_capture_frame(frame, finish: finish)
      pop_capture_start(frame.number)
      captures[frame.number] = span
      captures[frame.name] = span if frame.name
      span
    end

    def pop_repeat_frame(expected = nil)
      frame = @repeats.pop
      raise TypeError, "expected the active ExecutionState::RepeatFrame" unless frame.is_a?(RepeatFrame) && (expected.nil? || frame.equal?(expected))

      frame
    end

    def with_repeat_frame(**attributes)
      frame = push_repeat_frame(**attributes)
      yield frame
    ensure
      pop_repeat_frame(frame) if frame && @repeats.last.equal?(frame)
    end

    def push_backtrack_point(program_counter, cursor: @cursor, captures: nil, flags: nil)
      point = BacktrackPoint.new(pc: program_counter, cursor: cursor,
                                 capture_top: @capture_trail.length, frame_top: @frames.length,
                                 captures: captures, flags: flags,
                                 capture_frames: @capture_frames.map(&:dup),
                                 capture_starts: @capture_starts.transform_values(&:dup))
      @backtracks << point
      point
    end

    def pop_backtrack_point
      @backtracks.pop
    end

    def resume_backtrack
      point = pop_backtrack_point
      return unless point

      push_semantic_frame(SemanticFrame.new(
                            pc: point.pc, cursor: point.cursor,
                            captures: point.captures || {}, flags: point.flags || {},
                            capture_stack: point.capture_frames || [],
                            capture_starts: point.capture_starts || {}
                          ))
      point
    end

    def push_vm_frame(frame)
      raise TypeError, "expected an ExecutionState::VMFrame" unless frame.is_a?(VMFrame)

      @vm_stack << frame
    end

    def pop_vm_frame
      @vm_stack.pop
    end

    def push_semantic_frame(frame)
      raise TypeError, "expected an ExecutionState::SemanticFrame" unless frame.is_a?(SemanticFrame)

      frame.call_stack ||= @calls.dup
      frame.capture_stack ||= @capture_frames.dup
      frame.capture_starts ||= @capture_starts.transform_values(&:dup)
      @semantic_stack << frame
    end

    def pop_semantic_frame
      frame = @semantic_stack.pop
      @calls = frame.call_stack.dup if frame&.call_stack
      @capture_frames = frame.capture_stack.dup if frame&.capture_stack
      @capture_starts = frame.capture_starts.transform_values(&:dup) if frame&.capture_starts
      frame
    end

    # Construct a scope frame from the single frame type used by the VM.
    def new_frame(kind: :generic, **attributes)
      Frame.new(kind: kind, **attributes)
    end

    def push_frame(frame = nil, kind: :generic, **attributes)
      frame ||= new_frame(kind: kind, **attributes)
      raise TypeError, "expected an ExecutionState::Frame" unless frame.is_a?(Frame) || frame.is_a?(AbsenceFrame)

      @frames << frame
      frame
    end

    def new_absence_frame(**attributes)
      AbsenceFrame.new(kind: :absence,
                       branch_checkpoints: [], preferred_branch: nil, **attributes)
    end

    def push_absence_frame(**attributes)
      frame = new_absence_frame(**attributes)
      @frames << frame
      frame
    end

    def pop_absence_frame(expected = nil)
      frame = @frames.pop
      raise TypeError, "expected the active ExecutionState::AbsenceFrame" unless frame.is_a?(AbsenceFrame) && (expected.nil? || frame.equal?(expected))

      frame
    end

    def with_absence_frame(**attributes)
      frame = push_absence_frame(**attributes)
      yield frame
    ensure
      pop_absence_frame(frame) if frame && @frames.last.equal?(frame)
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
