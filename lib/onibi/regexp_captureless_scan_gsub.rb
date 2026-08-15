# frozen_string_literal: true

module Onibi
  module RegexpCapturelessScanGsub
    private

    def hfa_captureless_scan_api(input, block)
      return unless input.is_a?(String) && input.ascii_only? && hfa_capture_count.zero?

      literal_class_spec = hfa_captureless_literal_class_scan_spec
      if literal_class_spec
        values = []
        hfa_captureless_literal_class_each_range(input, literal_class_spec) do |start_position, finish_position|
          value = input.byteslice(start_position, finish_position - start_position)
          block ? block.call(value) : values << value
        end
        return block ? input : values
      end

      nil
    end

    def hfa_captureless_replace_api(input, replacement, block)
      return if block || replacement.index("\\") || !input.ascii_only? || hfa_capture_count.positive?

      literal_class_spec = hfa_captureless_literal_class_scan_spec
      if literal_class_spec
        result = String.new(capacity: input.bytesize, encoding: input.encoding)
        cursor = 0
        hfa_captureless_literal_class_each_range(input, literal_class_spec) do |start_position, finish_position|
          result << input.byteslice(cursor, start_position - cursor) << replacement
          cursor = finish_position
        end
        result << input.byteslice(cursor, input.bytesize - cursor) if cursor < input.bytesize
        return [result, input.bytesize]
      end

      nil
    end

    def hfa_captureless_literal_class_scan_spec
      return @hfa_captureless_literal_class_scan_spec if defined?(@hfa_captureless_literal_class_scan_spec)

      parts = @ast.is_a?(AST::Sequence) ? @ast.parts : []
      class_index = nil
      parts.each_with_index do |part, index|
        if part.is_a?(AST::CharacterClass)
          return @hfa_captureless_literal_class_scan_spec = false if class_index

          class_index = index
        elsif !part.is_a?(AST::Literal)
          return @hfa_captureless_literal_class_scan_spec = false
        end
      end
      return @hfa_captureless_literal_class_scan_spec = false unless class_index&.positive?

      prefix = parts.first(class_index).each_with_object(+"") { |part, result| result << part.value }
      suffix = parts.drop(class_index + 1).each_with_object(+"") { |part, result| result << part.value }
      table = class_index && hfa_capture_class_table(parts[class_index])
      valid = prefix.bytesize.positive? && table
      @hfa_captureless_literal_class_scan_spec = valid ? [prefix, table, suffix].freeze : false
    end

    def hfa_captureless_literal_class_each_range(input, spec)
      prefix, table, suffix = spec
      position = 0
      while (start_position = input.index(prefix, position))
        class_position = start_position + prefix.bytesize
        if table[input.getbyte(class_position)] && input.index(suffix, class_position + 1) == class_position + 1
          yield start_position, class_position + 1 + suffix.bytesize
          position = class_position + 1 + suffix.bytesize
        else
          position = start_position + prefix.bytesize
        end
      end
    end
  end
end
