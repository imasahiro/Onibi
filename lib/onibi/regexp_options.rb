# frozen_string_literal: true

module Onibi
  # Normalizes the public constructor options into VM option names.
  module RegexpOptions
    private

    def normalize_options(options)
      return normalize_integer_options(options) if options.is_a?(Integer)

      normalized_options = options || []
      valid_options = normalized_options.is_a?(Array) && normalized_options.all? do |option|
        %w[ignorecase multiline].include?(option)
      end
      raise ArgumentError, "invalid options" unless valid_options

      normalized_options
    end

    def normalize_integer_options(options)
      raise ArgumentError, "invalid options" if invalid_integer_options?(options)

      integer_option_names.each_with_object([]) do |(name, flag), normalized_options|
        normalized_options << name if (options & flag).positive?
      end
    end

    def invalid_integer_options?(options)
      supported = Regexp::IGNORECASE | Regexp::MULTILINE | Regexp::FIXEDENCODING | Regexp::NOENCODING
      options.negative? || (options & ~supported).positive? ||
        ((options & Regexp::FIXEDENCODING).positive? && (options & Regexp::NOENCODING).positive?)
    end

    def integer_option_names
      [["ignorecase", Regexp::IGNORECASE], ["multiline", Regexp::MULTILINE], ["noencoding", Regexp::NOENCODING]]
    end

    def validate_noencoding_pattern!(pattern, options)
      return unless options.include?("noencoding") && !pattern.ascii_only?

      raise RegexpError, "non-ASCII pattern with no encoding"
    end
  end
end
