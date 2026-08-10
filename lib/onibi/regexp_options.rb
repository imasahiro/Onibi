# frozen_string_literal: true

module Onibi
  # Normalizes the public constructor options into VM option names.
  module RegexpOptions
    INLINE_MODIFIERS = [
      ["(?i)", "ignorecase", true],
      ["(?-i)", "ignorecase", false],
      ["(?m)", "multiline", true],
      ["(?-m)", "multiline", false],
      ["(?x)", "extended", true],
      ["(?-x)", "extended", false]
    ].freeze
    INLINE_OPTION_NAMES = { "i" => "ignorecase", "m" => "multiline", "x" => "extended" }.freeze

    def encoding
      return Encoding::US_ASCII if @options.include?("noencoding")
      return @pattern.encoding if fixed_encoding?

      Encoding::US_ASCII
    end

    def fixed_encoding?
      return false if @options.include?("noencoding")

      @options.include?("fixedencoding") || !@pattern.ascii_only?
    end

    private

    def normalize_options(options)
      return normalize_integer_options(options) if options.is_a?(Integer)

      normalized_options = options || []
      valid_options = normalized_options.is_a?(Array) && normalized_options.all? do |option|
        %w[ignorecase multiline extended].include?(option)
      end
      raise ArgumentError, "invalid options" unless valid_options

      normalized_options
    end

    def normalize_inline_modifier(pattern, options)
      return [pattern[4...-1], options | ["ignorecase"]] if whole_scoped_ignorecase?(pattern)

      modifier = INLINE_MODIFIERS.find { |prefix, _option, _enabled| pattern.start_with?(prefix) }
      return apply_inline_modifier(pattern, options, modifier) if modifier

      apply_combined_inline_modifier(pattern, options)
    end

    def apply_combined_inline_modifier(pattern, options)
      combined = combined_inline_modifier(pattern)
      return [pattern, options] unless combined

      prefix_length, enabled, disabled = combined
      [pattern[prefix_length..], update_combined_options(options, enabled, disabled)]
    end

    def update_combined_options(options, enabled, disabled)
      updated_options = options.dup
      enabled.each { |modifier_name| updated_options |= [INLINE_OPTION_NAMES.fetch(modifier_name)] }
      disabled.each { |modifier_name| updated_options.delete(INLINE_OPTION_NAMES.fetch(modifier_name)) }
      updated_options
    end

    def apply_inline_modifier(pattern, options, modifier)
      prefix, option, enabled = modifier
      updated_options = enabled ? options | [option] : options.reject { |item| item == option }
      [pattern[prefix.length..], updated_options]
    end

    def combined_inline_modifier(pattern)
      return unless pattern.start_with?("(?")

      closing = pattern.index(")")
      return unless closing

      enabled, disabled = pattern[2...closing].split("-", -1)
      enabled = enabled.to_s.chars
      disabled = disabled.to_s.chars
      return unless valid_inline_modifier_names?(enabled, disabled)

      [closing + 1, enabled, disabled]
    end

    def valid_inline_modifier_names?(enabled, disabled)
      names = enabled + disabled
      !names.empty? && names.all? { |name| INLINE_OPTION_NAMES.key?(name) } && (enabled & disabled).empty?
    end

    def whole_scoped_ignorecase?(pattern)
      pattern.start_with?("(?i:") && pattern.end_with?(")")
    end

    def store_pattern_options(pattern, normalized_options, options)
      @pattern = pattern
      @options = normalized_options
      @public_options = options.is_a?(Integer) ? options : normalized_options
    end

    def normalize_integer_options(options)
      raise ArgumentError, "invalid options" if invalid_integer_options?(options)

      integer_option_names.each_with_object([]) do |(name, flag), normalized_options|
        normalized_options << name if (options & flag).positive?
      end
    end

    def invalid_integer_options?(options)
      supported = Regexp::IGNORECASE | Regexp::EXTENDED | Regexp::MULTILINE |
                  Regexp::FIXEDENCODING | Regexp::NOENCODING
      options.negative? || (options & ~supported).positive? ||
        ((options & Regexp::FIXEDENCODING).positive? && (options & Regexp::NOENCODING).positive?)
    end

    def integer_option_names
      [["ignorecase", Regexp::IGNORECASE], ["extended", Regexp::EXTENDED],
       ["multiline", Regexp::MULTILINE],
       ["fixedencoding", Regexp::FIXEDENCODING], ["noencoding", Regexp::NOENCODING]]
    end

    def validate_noencoding_pattern!(pattern, options)
      return unless options.include?("noencoding") && !pattern.ascii_only?
      return if pattern.encoding == Encoding::ASCII_8BIT

      raise RegexpError, "non-ASCII pattern with no encoding"
    end
  end
end
