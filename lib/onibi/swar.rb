# frozen_string_literal: true

module Onibi
  module Experimental
    # SWAR helpers use explicitly bounded integers so Ruby's arbitrary precision
    # Integer cannot leak bits between logical machine words.
    module Swar
      WORD_BITS = 1.size * 8
      WORD_MASK = (1 << WORD_BITS) - 1
      MINIMUM_INPUT_BYTES = WORD_BITS

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
        include Codegen::CandidateSource

        attr_reader :buckets, :patterns

        DEFAULT_LOOKAHEAD_BYTES = 64

        def initialize(patterns, default_policy: true)
          validate_patterns!(patterns)
          @patterns = patterns.map(&:dup).freeze
          @default_policy = default_policy
          @first_byte_table = build_first_byte_table(patterns)
          @buckets = build_buckets(patterns).freeze
          freeze
        end

        def bucket_count
          buckets.length
        end

        def candidate_positions(input, position)
          return unless eligible_input?(input, position)
          return indexed_candidates(input, position) unless @default_policy

          scan_candidates(input, position)
        end

        def scan_candidates(input, position)
          candidates = []
          states = Array.new(buckets.length, 0)
          active = false
          index = position
          while index < input.bytesize
            byte = input.getbyte(index)
            if active || @first_byte_table[byte]
              scan_byte(byte, index, states, candidates)
              active = states.any? { |state| !state.zero? }
            end
            index += 1
          end
          candidates.uniq.sort
        end

        def indexed_candidates(input, position)
          patterns.filter_map do |pattern|
            cursor = position
            starts = []
            while (found = input.index(pattern, cursor))
              starts << found
              cursor = found + 1
            end
            starts
          end.flatten.uniq.sort
        end

        def eligible?(input, position)
          profitable?(input, position)
        end

        def preserves_order?
          true
        end

        def profitable?(input, position)
          return false unless eligible_input?(input, position)
          return false if input.bytesize - position < MINIMUM_INPUT_BYTES
          return true unless @default_policy

          window_length = DEFAULT_LOOKAHEAD_BYTES + patterns.map(&:bytesize).max
          window = input.byteslice(position, window_length)
          earliest = patterns.filter_map { |pattern| window.index(pattern) }.min
          earliest && earliest <= DEFAULT_LOOKAHEAD_BYTES
        end

        private

        def build_buckets(patterns)
          builders = []
          filter_patterns(patterns).each do |pattern|
            builder = builders.last
            builder = nil unless builder&.fits?(pattern.bytesize)
            builders << (builder = BucketBuilder.new) unless builder
            builder.add(pattern)
          end
          builders.map(&:build)
        end

        def build_first_byte_table(patterns)
          table = Array.new(256, false)
          filter_patterns(patterns).each { |pattern| table[pattern.getbyte(0)] = true }
          table.freeze
        end

        def validate_patterns!(patterns)
          valid = patterns.is_a?(Array) && patterns.length >= 2 && patterns.all? do |pattern|
            pattern.is_a?(String) && !pattern.empty? && pattern.ascii_only?
          end
          raise ArgumentError, "SWAR patterns must be two or more non-empty ASCII literals" unless valid
        end

        def filter_patterns(patterns)
          patterns.map { |pattern| pattern.byteslice(0, WORD_BITS) }.uniq
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

      # Scans ASCII input in native-word chunks and emits matching positions
      # from one immutable character-class bitmap.
      class ClassPrefilter
        include Codegen::CandidateSource

        attr_reader :predicate, :table

        def initialize(source, ignorecase: false)
          @predicate = ClassPredicates.compiled(source, ignorecase: ignorecase)
          @table = @predicate.ascii_table
          matches = @table.each_index.select { |byte| @table[byte] }
          @single_byte = matches.one? ? matches.first.chr(Encoding::ASCII_8BIT).freeze : nil
          freeze
        end

        def eligible?(input, position)
          input.is_a?(String) && input.ascii_only? && position.is_a?(Integer) && position >= 0
        end

        def preserves_order?
          true
        end

        def candidate_positions(input, position)
          return [] unless eligible?(input, position)
          return singleton_candidate_positions(input, position) if @single_byte

          candidates = []
          cursor = position
          while cursor < input.bytesize
            limit = [cursor + WORD_BITS / 8, input.bytesize].min
            mask = match_mask(input, cursor, limit)
            while mask != 0
              bit = mask & -mask
              candidates << cursor + bit.bit_length - 1
              mask ^= bit
            end
            cursor = limit
          end
          candidates
        end

        def each_candidate(input, position, &block)
          return enum_for(__method__, input, position) unless block
          return unless eligible?(input, position)
          return each_singleton_candidate(input, position, &block) if @single_byte

          cursor = position
          while cursor < input.bytesize
            limit = [cursor + WORD_BITS / 8, input.bytesize].min
            emit_mask_matches(input, cursor, limit, &block)
            cursor = limit
          end
        end

        private

        def emit_mask_matches(input, cursor, limit, &block)
          mask = match_mask(input, cursor, limit)
          while mask != 0
            bit = mask & -mask
            block.call(cursor + bit.bit_length - 1)
            mask ^= bit
          end
        end

        def match_mask(input, cursor, limit)
          mask = 0
          index = cursor
          while index < limit
            mask |= 1 << (index - cursor) if @table[input.getbyte(index)]
            index += 1
          end
          mask
        end

        def each_singleton_candidate(input, position)
          cursor = position
          while (found = input.index(@single_byte, cursor))
            yield found
            cursor = found + 1
          end
        end

        def singleton_candidate_positions(input, position)
          candidates = []
          each_singleton_candidate(input, position) { |candidate| candidates << candidate }
          candidates
        end
      end

      # Ordered candidate source for a conservative union of ASCII first-set bytes.
      class ByteSetPrefilter
        include Codegen::CandidateSource

        attr_reader :table

        def initialize(bytes)
          bytes = bytes.uniq.freeze
          @table = Array.new(256, false)
          bytes.each { |byte| @table[byte] = true }
          @table.freeze
          @single_byte = bytes.one? ? bytes.first.chr(Encoding::ASCII_8BIT).freeze : nil
          freeze
        end

        def eligible?(input, position)
          input.is_a?(String) && (input.ascii_only? || input.encoding == Encoding::ASCII_8BIT) &&
            position.is_a?(Integer) && position >= 0
        end

        def preserves_order?
          true
        end

        def candidate_positions(input, position)
          candidates = []
          each_candidate(input, position) { |candidate| candidates << candidate }
          candidates
        end

        def each_candidate(input, position, &block)
          return enum_for(__method__, input, position) unless block
          return unless eligible?(input, position)

          return each_singleton_candidate(input, position, &block) if @single_byte

          position.upto(input.bytesize - 1) do |index|
            block.call(index) if table[input.getbyte(index)]
          end
        end

        def each_singleton_candidate(input, position)
          cursor = position
          while (found = input.index(@single_byte, cursor))
            yield found
            cursor = found + 1
          end
        end
      end

      # Native-word bitmap run scanner for a single ASCII class quantifier.
      class ClassRun
        attr_reader :predicate, :table

        WORD_BYTES = WORD_BITS / 8
        MIN_SCAN_BYTES = WORD_BYTES * 2

        def initialize(source)
          @predicate = ClassPredicates.compiled(source)
          @table = @predicate.ascii_table
          @match_count = @table.count(true)
          stop_bytes = @table.each_index.reject { |byte| @table[byte] }
          @stop_byte = stop_bytes.one? ? stop_bytes.first : nil
          @stop_byte_ascii = @stop_byte&.chr(Encoding::ASCII_8BIT)&.freeze
          freeze
        end

        def profitable?(input, position)
          return false unless byte_scan_input?(input)
          return false unless position.is_a?(Integer) && position >= 0 && position <= input.bytesize

          remaining = input.bytesize - position
          remaining >= MIN_SCAN_BYTES && @match_count.between?(8, 255)
        end

        def search(input, position, capture:)
          return character_search(input, position, capture: capture) unless byte_scan_input?(input)

          cursor = profitable?(input, position) ? scan_words(input, position) : position
          cursor = scan_tail(input, cursor)
          return false if cursor == position

          capture ? [position, cursor, []] : true
        end

        def matches_byte?(byte)
          byte.is_a?(Integer) && @table[byte]
        end

        def scan_end(input, position)
          return position unless byte_scan_input?(input)
          return position unless position.is_a?(Integer) && position >= 0 && position <= input.bytesize

          return delimiter_scan_end(input, position) if @stop_byte

          cursor = word_scan_profitable?(input, position) ? scan_words(input, position) : position
          scan_tail(input, cursor)
        end

        private

        def byte_scan_input?(input)
          input.is_a?(String) && (input.ascii_only? || input.encoding == Encoding::ASCII_8BIT)
        end

        def word_scan_profitable?(input, position)
          profitable?(input, position) && @match_count >= 64
        end

        def scan_words(input, cursor)
          full_mask = (1 << WORD_BYTES) - 1
          while cursor + WORD_BYTES <= input.bytesize
            mask = 0
            cursor.upto(cursor + WORD_BYTES - 1) do |index|
              mask |= 1 << (index - cursor) if @table[input.getbyte(index)]
            end
            break unless mask == full_mask

            cursor += WORD_BYTES
          end
          cursor
        end

        def character_search(input, position, capture:)
          return unless input.is_a?(String) && position.is_a?(Integer) && position >= 0

          cursor = position
          suffix = input[position..]
          return false unless suffix

          suffix.each_char.with_index do |character, index|
            break unless @predicate.matches?(character)

            cursor = position + index + 1
          end
          return false if cursor == position

          capture ? [position, cursor, []] : true
        end

        def scan_tail(input, cursor)
          return delimiter_scan_end(input, cursor) if @stop_byte

          cursor += 1 while cursor < input.bytesize && @table[input.getbyte(cursor)]
          cursor
        end

        def delimiter_scan_end(input, cursor)
          delimiter = input.encoding == Encoding::ASCII_8BIT ? @stop_byte_ascii : @stop_byte.chr(input.encoding)
          input.index(delimiter, cursor) || input.bytesize
        end
      end

      # Extracts a safe prefilter only for a whole-regexp literal alternation.
      module LiteralAlternation
        module_function

        # Default SWAR policy is deliberately conservative. Single-byte and
        # native-word-or-longer literals remain explicit internal opt-ins until
        # their early/late/no-match behavior is measured independently.
        def policy_for(patterns)
          return :unsupported unless valid_policy_patterns?(patterns)

          lengths = patterns.map(&:bytesize)
          if lengths.all? { |length| length >= 2 && length < WORD_BITS }
            :default
          else
            :opt_in
          end
        end

        def valid_policy_patterns?(patterns)
          patterns.is_a?(Array) && patterns.length >= 2 && patterns.all? do |pattern|
            pattern.is_a?(String) && !pattern.empty? && pattern.ascii_only?
          end
        end

        def build(ast, options, allow_long_literals: false, allow_single_character: false)
          patterns = eligible_patterns(ast, options)
          return unless patterns
          return unless eligible_lengths?(patterns, allow_long_literals, allow_single_character)

          MultiLiteralPrefilter.new(
            patterns, default_policy: !allow_long_literals && !allow_single_character
          )
        rescue ArgumentError
          nil
        end

        def eligible_patterns(ast, options)
          return if options.include?("ignorecase") || !ast.is_a?(AST::Alternation)

          patterns = ast.branches.map { |branch| literal_value(branch) }
          patterns if patterns.none?(&:nil?) && patterns.uniq.length >= 2
        end

        def eligible_lengths?(patterns, allow_long_literals, allow_single_character)
          minimum = allow_single_character ? 1 : 2
          maximum = allow_long_literals ? Float::INFINITY : WORD_BITS - 1
          patterns.all? { |pattern| pattern.bytesize.between?(minimum, maximum) }
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
