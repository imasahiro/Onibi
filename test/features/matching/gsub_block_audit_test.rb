# frozen_string_literal: true

require "English"
require "test_helper"
require "json"
require "open3"
require "rbconfig"

# This file records the current gsub block boundary.  It keeps MRI results
# beside Onibi results.  A mismatch is current debt, not accepted behaviour.
class GsubBlockAuditTest < Minitest::Test
  MUTATION_PROBE = <<~'RUBY'
    require "json"
    require "onibi"

    engine, pattern, mutation = ARGV
    input = "aa".dup
    regexp = engine == "onibi" ? Onibi::Regexp.new(pattern) : Regexp.new(pattern)
    begin
      operation = proc do
        case mutation
        when "append"
          input << "x"
        when "clear"
          input.clear
        when "same_byte"
          input.setbyte(0, "z".ord)
        when "encoding"
          input.force_encoding(Encoding::BINARY)
        end
      end
      block = proc { |_value| operation.call; "X" }
      result = if engine == "onibi"
                 regexp.gsub(input, &block)
               else
                 input.gsub(regexp, &block)
               end
      puts JSON.generate(status: "ok", result: result,
                         source: input, source_encoding: input.encoding.name,
                         result_encoding: result.encoding.name)
    rescue Exception => error
      puts JSON.generate(status: "error", error_class: error.class.name,
                         message: error.message, source: input,
                         source_encoding: input.encoding.name)
    end
  RUBY

  LIFECYCLE_PROBE = <<~'RUBY'
    mode = ARGV.fetch(0)
    warn "probe=#{mode}"
    case mode
    when "exit_nonzero"
      exit 7
    when "signal"
      Process.kill("TERM", Process.pid)
    when "close_stdout_stall"
      STDOUT.close
      sleep 3
    end
  RUBY

  def test_yields_full_matches_with_mri_values_and_encodings
    pattern = "[éあ]"
    source = "xéあy"
    expected_values = []
    expected_input = source.dup
    expected_result = expected_input.gsub(Regexp.new(pattern)) do |value|
      expected_values << [value.dup, value.encoding.name]
      "<#{value}>"
    end

    actual_values = []
    actual_input = source.dup
    actual_result = Onibi::Regexp.new(pattern).gsub(actual_input) do |value|
      actual_values << [value.dup, value.encoding.name, value.object_id]
      "<#{value}>"
    end

    assert_equal expected_result, actual_result
    assert_equal expected_result.encoding, actual_result.encoding
    assert_equal(expected_values, actual_values.map { |value, encoding, _| [value, encoding] })
    assert_equal actual_values.length, actual_values.map(&:last).uniq.length
    refute_same actual_input, actual_result
  end

  def test_native_empty_matches_and_misses_match_mri
    [["", "aba"], ["(?=a)", "ba"], ["z", "aba"]].each do |pattern, source|
      expected_values = []
      expected_input = source.dup
      expected_result = expected_input.gsub(Regexp.new(pattern)) do |value|
        expected_values << value.dup
        "X"
      end
      actual_values = []
      actual_input = source.dup
      actual_result = Onibi::Regexp.new(pattern).gsub(actual_input) do |value|
        actual_values << value.dup
        "X"
      end

      assert_equal expected_result, actual_result, pattern
      assert_equal expected_values, actual_values, pattern
      refute_same actual_input, actual_result
    end
  end

  def test_diagnostics_identify_native_class_and_fallback_reason
    [["[éあ]", "xéあy"], ["", "aba"], ["(?=a)", "ba"],
     ["z", "aba"], ["a", "aa"]].each do |pattern, source|
      native = Onibi::Regexp.new(pattern).send(:__onibi_diagnostics__, source)
      assert native.fetch(:rseq), pattern
      assert_equal 0, native.fetch(:fallback), pattern
      assert_equal :none, native.fetch(:fallback_reason), pattern
      assert_kind_of Integer, native.fetch(:counter_count), pattern
      assert_kind_of Integer, native.fetch(:backref_count), pattern
    end

    lookahead = Onibi::Regexp.new("(?=a)").send(:__onibi_diagnostics__, "ba")
    assert_equal 1, lookahead.fetch(:exec_kind)

    fallback = Onibi::Regexp.new("\\X").send(:__onibi_diagnostics__, "éあ")
    refute fallback.fetch(:rseq)
    assert_nil fallback.fetch(:exec_kind)
    assert_equal 1, fallback.fetch(:fallback)
    assert_equal :grapheme, fallback.fetch(:fallback_reason)
  end

  def test_fallback_yields_mri_values_and_publishes_mri_backreferences
    source = "éあ"
    expected_values = []
    expected_input = source.dup
    expected_result = expected_input.gsub(/(\X)/) do |value|
      expected_values << [value.dup, value.encoding.name]
      "X"
    end

    actual_values = []
    actual_input = source.dup
    actual_result = Onibi::Regexp.new("(\\X)").gsub(actual_input) do |value|
      actual_values << [value.dup, value.encoding.name]
      assert_instance_of MatchData, $LAST_MATCH_INFO
      assert_equal value, ::Regexp.last_match(1)
      "X"
    end

    assert_equal expected_result, actual_result
    assert_equal expected_result.encoding, actual_result.encoding
    assert_equal expected_values, actual_values
    assert_instance_of MatchData, $LAST_MATCH_INFO
    assert_equal %w[あ あ], $LAST_MATCH_INFO.to_a
    assert_same $LAST_MATCH_INFO, Onibi::Regexp.last_match
  end

  def test_block_return_coercion_matches_mri_to_s
    object_class = Class.new do
      def to_s
        "to_s"
      end

      def to_str
        "to_str"
      end
    end

    [nil, 1, object_class.new].each do |returned|
      mri = observe_return(:mri, returned)
      native = observe_return(:onibi, returned)
      assert_equal "ok", mri[:status], returned.class.name
      assert_equal mri, native, returned.class.name
    end
  end

  def test_exceptions_break_and_nonlocal_exit_match_mri_control_flow
    ["a", "\\X"].each do |pattern|
      [[:mri, Regexp.new(pattern)], [:onibi, Onibi::Regexp.new(pattern)]].each do |engine, regexp|
        input = "aba"
        error = assert_raises(RuntimeError) do
          if engine == :mri
            input.gsub(regexp) { raise "block failed" }
          else
            regexp.gsub(input) { raise "block failed" }
          end
        end
        assert_equal "block failed", error.message

        stopped = if engine == :mri
                    input.gsub(regexp) { break :stopped }
                  else
                    regexp.gsub(input) { break :stopped }
                  end
        assert_equal :stopped, stopped

        thrown = catch(:gsub_audit_stop) do
          if engine == :mri
            input.gsub(regexp) { throw :gsub_audit_stop, :thrown }
          else
            regexp.gsub(input) { throw :gsub_audit_stop, :thrown }
          end
        end
        assert_equal :thrown, thrown
      end
    end
  end

  def test_nested_native_calls_keep_the_documented_backreference_boundary
    /(prior)/.match("prior")
    before = $LAST_MATCH_INFO
    inner = Onibi::Regexp.new("b")
    values = []
    result = Onibi::Regexp.new("a").gsub("aba") do |value|
      assert_same before, $LAST_MATCH_INFO
      inner.match("b")
      values << [$LAST_MATCH_INFO.to_a, value]
      "X"
    end

    assert_equal "XbX", result
    assert_equal [[%w[prior prior], "a"],
                  [%w[prior prior], "a"]], values
    assert_same before, $LAST_MATCH_INFO
  end

  def test_replacement_argument_precedes_block_on_mri_and_native
    [[Onibi::Regexp.new("a"), :onibi], [/a/, :mri]].each do |regexp, engine|
      input = "aba"
      yielded = []
      result = if engine == :onibi
                 regexp.gsub(input, "ignored") do |value|
                   yielded << value
                   "<#{value}>"
                 end
               else
                 input.gsub(regexp, "ignored") do |value|
                   yielded << value
                   "<#{value}>"
                 end
               end
      assert_equal "ignoredbignored", result, engine
      assert_empty yielded, engine
    end
  end

  def test_mutation_probes_keep_mri_expectations_visible
    append_mri = mutation_probe("mri", "a", "append")
    append_native = mutation_probe("onibi", "a", "append")
    assert_equal append_mri, append_native

    clear_mri = mutation_probe("mri", "a", "clear")
    clear_native = mutation_probe("onibi", "a", "clear")
    assert_equal clear_mri, clear_native

    %w[same_byte encoding].each do |mutation|
      mri = mutation_probe("mri", "a", mutation)
      native = mutation_probe("onibi", "a", mutation)
      assert_equal mri, native, mutation
    end
  end

  def test_empty_match_length_mutation_is_bounded_and_reports_the_signal
    mri = mutation_probe("mri", "", "append")
    assert_equal "error", mri[:status]
    assert_equal "RuntimeError", mri[:error_class]
    assert_equal "string modified", mri[:message]

    native = mutation_probe("onibi", "", "append")
    assert_equal mri, native
  end

  def test_child_harness_bounds_and_classifies_exit_signal_and_stall
    exited = lifecycle_probe("exit_nonzero")
    assert_equal "exit", exited[:status]
    assert_equal 7, exited[:exit_status]
    assert_includes exited[:stderr], "probe=exit_nonzero"

    signaled = lifecycle_probe("signal")
    assert_equal "signal", signaled[:status]
    assert_equal Signal.list.fetch("TERM"), signaled[:signal]
    assert_includes signaled[:stderr], "probe=signal"

    stalled = lifecycle_probe("close_stdout_stall", timeout_seconds: 0.25)
    assert_equal "timeout", stalled[:status]
    assert_equal Signal.list.fetch("KILL"), stalled[:signal]
    assert_includes stalled[:stderr], "probe=close_stdout_stall"
  end

  private

  def observe_return(engine, returned)
    input = "a"
    regexp = engine == :onibi ? Onibi::Regexp.new("a") : Regexp.new("a")
    result = if engine == :onibi
               regexp.gsub(input) { returned }
             else
               input.gsub(regexp) { returned }
             end
    { status: "ok", result: result }
  # This child probe records every exception class for MRI differential checks.
  rescue Exception => e # rubocop:disable Lint/RescueException
    { status: "error", error_class: e.class.name, message: e.message }
  end

  def mutation_probe(engine, pattern, mutation, timeout_seconds: 2)
    command = [RbConfig.ruby, "-I#{PROJECT_ROOT}/lib", "-e", MUTATION_PROBE,
               engine, pattern, mutation]
    run_child(command, timeout_seconds: timeout_seconds)
  end

  def lifecycle_probe(mode, timeout_seconds: 2)
    command = [RbConfig.ruby, "-e", LIFECYCLE_PROBE, mode]
    run_child(command, timeout_seconds: timeout_seconds)
  end

  # The child lifecycle harness keeps timeout, stream, and cleanup state together.
  # rubocop:disable Metrics/BlockLength
  def run_child(command, timeout_seconds:)
    Open3.popen3(*command) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      streams = [stdout, stderr]
      buffers = { stdout => +"", stderr => +"" }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
      process_status = nil
      timed_out = false

      until process_status && streams.empty?
        streams.dup.each do |stream|
          loop do
            chunk = stream.read_nonblock(4096, exception: false)
            case chunk
            when :wait_readable
              break
            when nil
              streams.delete(stream)
              break
            else
              buffers.fetch(stream) << chunk
              buffer = buffers.fetch(stream)
              buffers[stream] = if buffer.bytesize > 4096
                                  buffer.byteslice(-4096, 4096)
                                else
                                  buffer
                                end
            end
          end
        end

        process_status = wait_thread.value unless wait_thread.alive?
        break if process_status && streams.empty?

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          timed_out = true
          break
        end
        if streams.empty?
          sleep [remaining, 0.01].min
        else
          IO.select(streams, nil, nil, [remaining, 0.05].min)
        end
      end

      if timed_out
        Process.kill("KILL", wait_thread.pid) if wait_thread.alive?
        wait_thread.join
        process_status = wait_thread.value
        return { status: "timeout", signal: process_status.termsig,
                 stderr: buffers.fetch(stderr) }
      end

      wait_thread.join unless process_status
      process_status ||= wait_thread.value
      if process_status.signaled?
        return { status: "signal", signal: process_status.termsig,
                 stderr: buffers.fetch(stderr) }
      end
      unless process_status.success?
        return { status: "exit", exit_status: process_status.exitstatus,
                 stderr: buffers.fetch(stderr) }
      end

      JSON.parse(buffers.fetch(stdout), symbolize_names: true).merge(
        stderr: buffers.fetch(stderr)
      )
    ensure
      stdout.close unless stdout.closed?
      stderr.close unless stderr.closed?
    end
  end
  # rubocop:enable Metrics/BlockLength
end
