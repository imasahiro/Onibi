# frozen_string_literal: true

module Onibi
  module Experimental
    # SWAR helpers use explicitly bounded integers so Ruby's arbitrary precision
    # Integer cannot leak bits between logical machine words.
    module Swar
      WORD_BITS = 1.size * 8
      # Scans ASCII input in native-word chunks and emits matching positions
      # from one immutable character-class bitmap.
      class ClassPrefilter
        include Codegen::CandidateSource

        attr_reader :predicate, :table

        MAX_SPARSE_BYTES = 4

        def initialize(source, ignorecase: false)
          @predicate = ClassPredicates.compiled(source, ignorecase: ignorecase)
          @table = @predicate.ascii_table
          matches = @table.each_index.select { |byte| @table[byte] }
          @single_byte = matches.one? ? matches.first.chr(Encoding::ASCII_8BIT).freeze : nil
          @sparse_bytes = matches.length.between?(2, MAX_SPARSE_BYTES) ? matches.freeze : nil
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
          return sparse_candidate_positions(input, position) if sparse_profitable?(input, position)

          table_candidate_positions(input, position)
        end

        def table_candidate_positions(input, position)
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
          return each_sparse_candidate(input, position, &block) if sparse_profitable?(input, position)

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

        def each_sparse_candidate(input, position, &block)
          candidates = @sparse_bytes.flat_map do |byte|
            cursor = position
            member = byte.chr(Encoding::ASCII_8BIT)
            starts = []
            while (found = input.index(member, cursor))
              starts << found
              cursor = found + 1
            end
            starts
          end.sort.uniq
          candidates.each(&block)
        end

        def sparse_candidate_positions(input, position)
          candidates = []
          each_sparse_candidate(input, position) { |candidate| candidates << candidate }
          candidates
        end

        def sparse_profitable?(input, position)
          return false unless @sparse_bytes

          limit = [position + 64, input.bytesize].min
          matches = 0
          position.upto(limit - 1) { |index| matches += 1 if @table[input.getbyte(index)] }
          matches <= (limit - position) / 8
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
    end
  end
end
