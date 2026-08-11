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
      scoped = source.match(/\A\(\?([imx]+):(.+)\)\z/m)
      return scoped_to_s(scoped[1], scoped[2]) if scoped && @options.empty?

      enabled = regexp_mode_flags.select { |name, _flag| @options.include?(name.to_s) }.map(&:last).join
      disabled = regexp_mode_flags.reject { |name, _flag| @options.include?(name.to_s) }.map(&:last).join
      suffix = disabled.empty? ? enabled : "#{enabled}-#{disabled}"
      "(?#{suffix}:#{source})"
    end

    def inspect
      escaped_source = source.gsub("/", "\\/")
      flags = regexp_mode_flags.select { |name, _flag| @options.include?(name.to_s) }.map(&:last).join
      flags += "n" if @options.include?("noencoding")
      "/#{escaped_source}/#{flags}"
    end

    private

    def scoped_to_s(enabled, scoped_source)
      disabled = %w[m i x].reject { |flag| enabled.include?(flag) }.join
      "(?#{enabled}-#{disabled}:#{scoped_source})"
    end

    def regexp_mode_flags
      { multiline: "m", ignorecase: "i", extended: "x" }
    end
  end
end
