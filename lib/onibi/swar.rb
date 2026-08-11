# frozen_string_literal: true

module Onibi
  module Experimental
    # SWAR helpers use explicitly bounded integers so Ruby's arbitrary precision
    # Integer cannot leak bits between logical machine words.
    module Swar
      WORD_BITS = 1.size * 8
      WORD_MASK = (1 << WORD_BITS) - 1

      Bucket = Struct.new(:width, :masks, :start_bits, :accepts, keyword_init: true) do
        def initialize(**arguments)
          super
          masks.freeze
          accepts.freeze
          freeze
        end
      end

      # Packs literal positions into native-word Shift-And buckets. A zero guard bit
      # separates adjacent patterns, preventing state from crossing lanes.
      class MultiLiteralPrefilter
        attr_reader :buckets

        def initialize(patterns)
          @buckets = build_buckets(patterns).freeze
          freeze
        end

        def bucket_count
          buckets.length
        end

        def candidate_positions(input, position)
          return unless eligible_input?(input, position)

          candidates = []
          states = Array.new(buckets.length, 0)
          input.bytes.drop(position).each_with_index do |byte, relative_index|
            scan_byte(byte, position + relative_index, states, candidates)
          end
          candidates.uniq.sort
        end

        private

        def build_buckets(patterns)
          validate_patterns!(patterns)
          builders = []
          patterns.uniq.each do |pattern|
            builder = builders.last
            builder = nil unless builder&.fits?(pattern.bytesize)
            builders << (builder = BucketBuilder.new) unless builder
            builder.add(pattern)
          end
          builders.map(&:build)
        end

        def validate_patterns!(patterns)
          valid = patterns.is_a?(Array) && patterns.length >= 2 && patterns.all? do |pattern|
            pattern.is_a?(String) && !pattern.empty? && pattern.ascii_only? && pattern.bytesize <= WORD_BITS
          end
          raise ArgumentError, "SWAR patterns must be two or more non-empty ASCII literals" unless valid
        end

        def eligible_input?(input, position)
          input.is_a?(String) && input.ascii_only? && position.is_a?(Integer) && position >= 0
        end

        def scan_byte(byte, index, states, candidates)
          buckets.each_with_index do |bucket, bucket_index|
            states[bucket_index] = next_state(states[bucket_index], bucket, byte)
            record_accepts(states[bucket_index], bucket, index, candidates)
          end
        end

        def next_state(state, bucket, byte)
          shifted = ((state << 1) | bucket.start_bits) & WORD_MASK
          shifted & bucket.masks.fetch(byte, 0)
        end

        def record_accepts(state, bucket, index, candidates)
          bucket.accepts.each do |accept_bit, length|
            candidates << index - length + 1 unless (state & accept_bit).zero?
          end
        end

        # Mutable only while one immutable bucket is being assembled.
        class BucketBuilder
          attr_reader :width

          def initialize
            @width = 0
            @masks = Hash.new(0)
            @start_bits = 0
            @accepts = {}
          end

          def fits?(length)
            width + 1 + length <= WORD_BITS
          end

          def add(pattern)
            offset = width.zero? ? 0 : width + 1
            write_masks(pattern, offset)
            @start_bits |= 1 << offset
            @accepts[1 << (offset + pattern.bytesize - 1)] = pattern.bytesize
            @width = offset + pattern.bytesize
          end

          def build
            Bucket.new(width: width, masks: @masks, start_bits: @start_bits, accepts: @accepts)
          end

          private

          def write_masks(pattern, offset)
            pattern.bytes.each_with_index do |byte, index|
              @masks[byte] |= 1 << (offset + index)
            end
          end
        end
      end

      # Extracts a safe prefilter only for a whole-regexp literal alternation.
      module LiteralAlternation
        module_function

        def build(ast, options)
          return if options.include?("ignorecase")
          return unless ast.is_a?(AST::Alternation)

          patterns = ast.branches.map { |branch| literal_value(branch) }
          return if patterns.any?(&:nil?) || patterns.uniq.length < 2

          MultiLiteralPrefilter.new(patterns)
        rescue ArgumentError
          nil
        end

        def literal_value(branch)
          return unless branch.is_a?(AST::Sequence)
          return unless branch.parts.all? { |part| part.is_a?(AST::Literal) }

          value = branch.parts.map(&:value).join
          value unless value.empty?
        end
      end
    end
  end
end
