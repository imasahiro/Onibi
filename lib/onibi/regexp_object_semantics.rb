# frozen_string_literal: true

module Onibi
  # Defines value semantics for compiled regular expressions.
  module RegexpObjectSemantics
    def ==(other)
      other.is_a?(Regexp) && source == other.source && options == other.options
    end

    def eql?(other)
      self == other
    end

    def hash
      [source, options].hash
    end

    def to_s
      enabled = regexp_mode_flags.select { |name, _flag| @options.include?(name) }.map(&:last).join
      disabled = regexp_mode_flags.reject { |name, _flag| @options.include?(name) }.map(&:last).join
      suffix = disabled.empty? ? enabled : "#{enabled}-#{disabled}"
      "(?#{suffix}:#{source})"
    end

    def inspect
      escaped_source = source.gsub("/", "\\/")
      flags = regexp_mode_flags.select { |name, _flag| @options.include?(name) }.map(&:last).join
      "/#{escaped_source}/#{flags}"
    end

    private

    def regexp_mode_flags
      [["ignorecase", "i"], ["multiline", "m"], ["extended", "x"]]
    end
  end
end
