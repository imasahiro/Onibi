# frozen_string_literal: true

require "optparse"
require "stringio"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../benchmark", __dir__)
require "onibi"
require "regex_redux"

# Reproducible, dependency-free profiling harness for the regex-redux workload.
module RegexReduxProfiler
  DEFAULTS = {
    engine: "onibi",
    iterations: 10,
    warmup: 1,
    phase: "end_to_end",
    profile: "all",
    yjit: false
  }.freeze

  # Reuses compiled patterns to isolate matching and replacement costs.
  class PreparedWorkload
    def initialize(input, engine_name)
      @engine = RegexRedux.engine(engine_name)
      @input = input
      @matchers = RegexRedux::MATCHERS.map { |pattern| [@engine.compile(pattern), pattern] }
      @remove_breaks = @engine.compile(">.*\n|\n")
      @final_transform = RegexRedux::FINAL_TRANSFORM.map do |pattern, replacement|
        [@engine.compile(pattern), replacement]
      end
    end

    def run
      sequence = @engine.replace(@input.dup, @remove_breaks, "")
      counts = @matchers.map { |regexp, pattern| [pattern, @engine.count(regexp, sequence)] }
      @final_transform.each { |regexp, replacement| sequence = @engine.replace(sequence, regexp, replacement) }
      [counts, sequence.length]
    end

    def run_breakdown
      sequence = measure("remove_breaks") { @engine.replace(@input.dup, @remove_breaks, "") }
      @matchers.each do |regexp, pattern|
        measure("count:#{pattern}") { @engine.count(regexp, sequence) }
      end
      @final_transform.each do |regexp, replacement|
        sequence = measure("replace:#{regexp.source}") { @engine.replace(sequence, regexp, replacement) }
      end
      sequence.length
    end

    def measure(label)
      return yield unless @breakdown

      before = GC.stat[:total_allocated_objects]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      value = yield
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      entry = (@breakdown[label] ||= { seconds: 0.0, allocations: 0, calls: 0 })
      entry[:seconds] += elapsed
      entry[:allocations] += GC.stat[:total_allocated_objects] - before
      entry[:calls] += 1
      value
    end

    attr_writer :breakdown
  end

  # Collects runtime, allocation, GC, YARV, YJIT, and trace measurements.
  class Runner
    attr_reader :options

    def initialize(options)
      @options = options
      @input = File.read(File.expand_path("../benchmark/fasta-500.txt", __dir__))
      @breakdown = {}
    end

    def run
      enable_yjit if options[:yjit]
      warmup
      @breakdown.clear
      result = measure
      emit(result)
    end

    private

    def warmup
      return if options[:warmup].zero?

      execute(options[:warmup])
    end

    def measure
      gc_before = GC.stat
      yjit_before = yjit_stats
      trace = %w[trace all].include?(options[:profile]) ? TraceCollector.new : nil
      trace&.start
      wall_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cpu_start = Process.times
      result = execute(options[:iterations])
      cpu_finish = Process.times
      wall_finish = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      trace&.stop
      {
        result: result,
        wall_seconds: wall_finish - wall_start,
        user_seconds: cpu_finish.utime - cpu_start.utime,
        system_seconds: cpu_finish.stime - cpu_start.stime,
        gc: gc_delta(gc_before, GC.stat),
        allocations: GC.stat[:total_allocated_objects] - gc_before[:total_allocated_objects],
        yjit: yjit_delta(yjit_before, yjit_stats),
        trace: trace&.top_calls,
        yarv: yarv_report,
        breakdown: @breakdown
      }
    end

    def execute(iterations)
      case options[:phase]
      when "end_to_end"
        iterations.times { RegexRedux.new(StringIO.new(@input), engine: options[:engine]).to_s }
      when "warm_match"
        workload = PreparedWorkload.new(@input, options[:engine])
        workload.breakdown = @breakdown if options[:breakdown]
        iterations.times { options[:breakdown] ? workload.run_breakdown : workload.run }
      else
        raise ArgumentError, "unknown phase: #{options[:phase]}"
      end
    end

    def gc_delta(before, after)
      %i[count minor_gc_count major_gc_count total_allocated_objects].to_h do |key|
        [key, after.fetch(key) - before.fetch(key)]
      end
    end

    def yjit_stats
      return nil unless defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:runtime_stats)

      RubyVM::YJIT.runtime_stats
    end

    def yjit_delta(before, after)
      return nil unless before && after

      after.each_with_object({}) do |(key, value), delta|
        previous = before[key]
        delta[key] = value - previous if value.is_a?(Numeric) && previous.is_a?(Numeric)
      end
    end

    def yarv_report
      return { available: false } unless options[:engine] == "onibi" && defined?(RubyVM::InstructionSequence)

      regexp = Onibi::Regexp.new("a.*z")
      program = regexp.send(:codegen_program)
      method = program.compiled_module.method(:__onibi_search)
      iseq = RubyVM::InstructionSequence.of(method)
      return { available: false } unless iseq

      {
        available: true,
        generated_source_bytes: program.source.bytesize,
        instruction_lines: iseq.disasm.lines.length,
        instruction_count: iseq.to_a.fetch(13).count { |entry| entry.is_a?(Array) },
        local_count: iseq.to_a.fetch(4).fetch(:local_size),
        stack_max: iseq.to_a.fetch(4).fetch(:stack_max)
      }
    rescue StandardError => e
      { available: false, error: "#{e.class}: #{e.message}" }
    end

    def enable_yjit
      return unless defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)

      RubyVM::YJIT.enable
    end

    def emit(report)
      puts "# regex-redux profile"
      puts
      puts "- Ruby: `#{RUBY_DESCRIPTION}`"
      puts "- Engine: `#{options[:engine]}`"
      puts "- Phase: `#{options[:phase]}`"
      puts "- Iterations: `#{options[:iterations]}`"
      puts "- YJIT requested: `#{options[:yjit]}`"
      puts
      puts "## Timing"
      puts
      puts "- wall: `#{format("%.6f", report[:wall_seconds])}` seconds"
      puts "- user: `#{format("%.6f", report[:user_seconds])}` seconds"
      puts "- system: `#{format("%.6f", report[:system_seconds])}` seconds"
      puts "- wall/iteration: `#{format("%.6f", report[:wall_seconds] / options[:iterations])}` seconds"
      puts
      puts "## GC and allocation"
      puts
      report[:gc].each { |key, value| puts "- #{key}: `#{value}`" }
      puts "- allocated objects: `#{report[:allocations]}`"
      emit_section("YJIT", report[:yjit])
      emit_section("YARV", report[:yarv])
      emit_section("TracePoint top calls", report[:trace])
      emit_breakdown(report[:breakdown])
    end

    def emit_breakdown(values)
      return if values.empty?

      puts
      puts "## Operation breakdown"
      puts
      puts "| operation | seconds | allocations | calls |"
      puts "|---|---:|---:|---:|"
      values.sort_by { |_label, entry| -entry[:seconds] }.each do |label, entry|
        puts "| `#{label}` | #{format("%.6f", entry[:seconds])} | #{entry[:allocations]} | #{entry[:calls]} |"
      end
    end

    def emit_section(title, values)
      return if values.nil?

      puts
      puts "## #{title}"
      puts
      if values.is_a?(Hash)
        values.each { |key, value| puts "- #{key}: `#{value}`" }
      else
        values.each { |key, value| puts "- `#{key}`: `#{value}`" }
      end
    end
  end

  # Counts Ruby and C method calls; it is diagnostic, not a timing mode.
  class TraceCollector
    def initialize
      @calls = Hash.new(0)
      @trace = TracePoint.new(:call, :c_call) do |point|
        @calls[[point.defined_class, point.method_id]] += 1
      end
    end

    def start
      @trace.enable
    end

    def stop
      @trace.disable
    end

    def top_calls
      @calls.sort_by { |_key, count| -count }.first(30).to_h do |(owner, method), count|
        ["#{owner}##{method}", count]
      end
    end
  end

  # Parses the reproducible profiling command-line interface.
  class CLI
    def self.run(arguments)
      options = DEFAULTS.dup
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby script/profile_regex_redux.rb [options]"
        opts.on("--engine NAME", %w[ruby onibi]) { |value| options[:engine] = value }
        opts.on("--iterations N", Integer) { |value| options[:iterations] = value }
        opts.on("--warmup N", Integer) { |value| options[:warmup] = value }
        opts.on("--phase PHASE", %w[end_to_end warm_match]) { |value| options[:phase] = value }
        opts.on("--profile PROFILE", %w[all trace none]) { |value| options[:profile] = value }
        opts.on("--yjit", "enable YJIT before measuring") { options[:yjit] = true }
        opts.on("--breakdown", "break warm-match work into operations") { options[:breakdown] = true }
      end
      parser.parse!(arguments)
      raise ArgumentError, "iterations must be positive" unless options[:iterations].positive?

      Runner.new(options).run
    rescue OptionParser::ParseError, ArgumentError => e
      warn e.message
      warn parser
      exit 1
    end
  end
end

RegexReduxProfiler::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
