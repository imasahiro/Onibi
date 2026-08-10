# frozen_string_literal: true

module Onibi
  # Validates input encodings against a compiled pattern.
  module RegexpEncodingValidation
    private

    def validate_encoding!(input)
      validate_input_encoding!(input)
      return if noencoding_input?(input)
      return if compatible_ascii_input?(input)
      return if @pattern.encoding == input.encoding

      raise Encoding::CompatibilityError, "incompatible encoding regexp match"
    end

    def validate_input_encoding!(input)
      return if input.valid_encoding?

      raise ArgumentError, "invalid byte sequence in #{input.encoding}"
    end

    def noencoding_input?(input)
      @options.include?("noencoding") && input.encoding == Encoding::ASCII_8BIT
    end

    def compatible_ascii_input?(input)
      return true if @pattern.ascii_only? && !@options.include?("fixedencoding")

      @pattern.ascii_only? && input.ascii_only?
    end
  end
end
