# frozen_string_literal: true

module Onibi
  # Validates input encodings against a compiled pattern.
  module RegexpEncodingValidation
    private

    def validate_encoding!(input, ascii_input: nil)
      ascii_input = input.ascii_only? if ascii_input.nil?
      return if @pattern.ascii_only? && !fixed_encoding? && ascii_input

      validate_input_encoding!(input)
      return if noencoding_input?(input)
      return if compatible_ascii_input?(input, ascii_input: ascii_input)
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

    def compatible_ascii_input?(input, ascii_input: nil)
      return true if @pattern.ascii_only? && !fixed_encoding?

      ascii_input.nil? ? input.ascii_only? : ascii_input
    end
  end
end
