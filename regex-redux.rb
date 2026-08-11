# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "onibi"

class RegexRedux
  MATCHERS = [
    "agggtaaa|tttaccct",
    "[cgt]gggtaaa|tttaccc[acg]",
    "a[act]ggtaaa|tttacc[agt]t",
    "ag[act]gtaaa|tttac[agt]ct",
    "agg[act]taaa|ttta[agt]cct",
    "aggg[acg]aaa|ttt[cgt]ccct",
    "agggt[cgt]aa|tt[acg]accct",
    "agggta[cgt]a|t[acg]taccct",
    "agggtaa[cgt]|[acg]ttaccct"
  ].freeze

  FINAL_TRANSFORM = [
    ["tHa[Nt]", "<4>"],
    ["aND|caN|Ha[DS]|WaS", "<3>"],
    ["a[NSt]|BY", "<2>"],
    ["<[^>]*>", "|"],
    ["\\|[^|][^|]*\\|", "-"]
  ].freeze

  class RubyEngine
    def compile(pattern)
      ::Regexp.new(pattern)
    end

    def count(regexp, input)
      input.scan(regexp).length
    end

    def replace(input, regexp, replacement)
      input.gsub(regexp, replacement)
    end

    def source(regexp)
      regexp.source
    end
  end

  class OnibiEngine
    def compile(pattern)
      Onibi::Regexp.new(pattern)
    end

    def count(regexp, input)
      count = 0
      position = 0

      while (match = regexp.match(input, position))
        count += 1
        finish = match.end(0)
        position = finish > position ? finish : position + 1
        break if position > input.length
      end

      count
    end

    def replace(input, regexp, replacement)
      result = +""
      cursor = 0
      position = 0

      while (match = regexp.match(input, position))
        start = match.begin(0)
        finish = match.end(0)
        result << input[cursor...start] << replacement
        cursor = finish
        position = finish > position ? finish : position + 1
        break if position > input.length
      end

      result << input[cursor..] if cursor < input.length
      result
    end

    def source(regexp)
      regexp.source
    end
  end

  def self.engine(name)
    case name.to_sym
    when :ruby
      RubyEngine.new
    when :onibi
      OnibiEngine.new
    else
      raise ArgumentError, "unknown regex engine: #{name.inspect}"
    end
  end

  def self.engine_name(arguments)
    arguments.each_with_index do |argument, index|
      case argument
      when "--ruby"
        return :ruby
      when "--onibi"
        return :onibi
      when "--engine"
        return arguments.fetch(index + 1).to_sym
      else
        return argument.delete_prefix("--engine=").to_sym if argument.start_with?("--engine=")
      end
    end

    :ruby
  end

  def initialize(io, engine: :ruby)
    @engine = self.class.engine(engine)
    @seq = io.readlines.join
    @original_size = @seq.size
    @clean_size = remove_breaks!
    @match_results = match_results
    @final_size = final_transform!
  end

  def to_s
    "%s\n\n%d\n%d\n%d" % [
      @match_results.join("\n"),
      @original_size,
      @clean_size,
      @final_size
    ]
  end

  private

  def pattern_count(pattern)
    regexp = @engine.compile(pattern)
    "#{@engine.source(regexp)} #{@engine.count(regexp, @seq)}"
  end

  def remove_breaks!
    @seq = @engine.replace(@seq, @engine.compile(">.*\n|\n"), "")
    @seq.size
  end

  def match_results
    MATCHERS.map { |pattern| pattern_count(pattern) }
  end

  def final_transform!
    FINAL_TRANSFORM.each do |pattern, replacement|
      @seq = @engine.replace(@seq, @engine.compile(pattern), replacement)
    end
    @seq.size
  end
end

if $PROGRAM_NAME == __FILE__
  engine = RegexRedux.engine_name(ARGV)
  puts RegexRedux.new(STDIN, engine: engine)
end
