# frozen_string_literal: true

module Onibi
  module RegexpCapturelessScanGsub
    private

    def hfa_captureless_scan_api(input, block)
      return unless input.is_a?(String) && input.ascii_only? && hfa_capture_count.zero?

      spec = hfa_captureless_alternation_scan_spec
      return unless spec

      values = []
      hfa_captureless_alternation_each_range(input, spec) do |start_position, finish_position|
        value = input.byteslice(start_position, finish_position - start_position)
        block ? block.call(value) : values << value
      end
      block ? input : values
    end

    def hfa_captureless_replace_api(input, replacement, block)
      return if block || replacement.index("\\") || !input.ascii_only? || hfa_capture_count.positive?

      spec = hfa_captureless_alternation_scan_spec
      return unless spec

      result = String.new(capacity: input.bytesize, encoding: input.encoding)
      cursor = 0
      hfa_captureless_alternation_each_range(input, spec) do |start_position, finish_position|
        result << input.byteslice(cursor, start_position - cursor) << replacement
        cursor = finish_position
      end
      result << input.byteslice(cursor, input.bytesize - cursor) if cursor < input.bytesize
      [result, input.bytesize]
    end
  end
end
