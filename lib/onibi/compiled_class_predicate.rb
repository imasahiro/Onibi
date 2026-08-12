# frozen_string_literal: true

module Onibi
  # Character-class compilation helpers.
  module ClassPredicates
    module_function

    Normalized = Struct.new(
      :kind, :negative, :literals, :ranges, :ascii_applicable, :ascii_bitmap,
      :ascii_bitmap_bits, :encoding,
      keyword_init: true
    )
    ScanAtom = Struct.new(:index, :value, :range_end)
    ScanState = Struct.new(:literals, :ranges, :index, :ascii) do
      def add(atom)
        self.index = atom.index
        return add_range(atom) if atom.range_end

        literals << atom.value
        self.ascii &&= atom.value.ord < 128
      end

      private

      def add_range(atom)
        ranges << [atom.value, atom.range_end].freeze
        self.ascii &&= atom.value.ord < 128 && atom.range_end.ord < 128
      end
    end

    # Produces conservative immutable metadata for reusable class predicates.
    module Normalizer
      module_function

      def normalize(source)
        negative = source.start_with?("^")
        body = negative ? source[1..] : source
        return unknown(source, negative) if composite_source?(body)

        literals, ranges, ascii = scan(body, source.encoding.ascii_compatible?)

        build_metadata(source, negative, literals, ranges, ascii)
      rescue StandardError
        unknown(source, negative)
      end

      def build_metadata(source, negative, literals, ranges, ascii)
        Normalized.new(
          kind: :ascii,
          negative: negative,
          literals: literals.uniq.freeze,
          ranges: ranges.freeze,
          ascii_applicable: ascii,
          ascii_bitmap: ascii ? bitmap_for(literals, ranges, negative) : nil,
          ascii_bitmap_bits: ascii ? 256 : nil,
          encoding: source.encoding
        ).freeze
      end

      def scan(body, ascii)
        state = ScanState.new([], [], 0, ascii)
        while state.index < body.length
          atom = parse_atom(body, state.index)
          return [[], [], false] unless atom

          state.add(atom)
        end
        [state.literals, state.ranges, state.ascii]
      end

      def composite_source?(body)
        ClassPredicates.split_intersection(body) || body.include?("\\p{") || body.include?("[")
      end

      def parse_atom(body, index)
        first, after_first = ClassPredicates.atom(body, index)
        return unless literal_atom?(first)
        return ScanAtom.new(after_first, first[1], nil) unless body[after_first] == "-"
        return unless after_first + 1 < body.length

        last, after_last = ClassPredicates.atom(body, after_first + 1)
        return unless literal_atom?(last)

        ScanAtom.new(after_last, first[1], last[1])
      end

      def literal_atom?(atom)
        atom.is_a?(Array) && atom[0] == :literal && atom[1].is_a?(String)
      end

      def unknown(source, negative)
        Normalized.new(
          kind: :composite,
          negative: negative,
          literals: [].freeze,
          ranges: [].freeze,
          ascii_applicable: false,
          ascii_bitmap: nil,
          ascii_bitmap_bits: nil,
          encoding: source.encoding
        ).freeze
      end

      def bitmap_for(literals, ranges, negative)
        bitmap = literals.reduce(0) { |mask, literal| mask | (1 << literal.ord) }
        ranges.each do |first, last|
          first.ord.upto(last.ord) { |codepoint| bitmap |= 1 << codepoint }
        end
        negative ? (((1 << 256) - 1) ^ bitmap) : bitmap
      end
    end

    def compiled(source, ignorecase: false)
      cache = (@compiled_cache ||= {})
      key = [source, ignorecase == true].freeze
      cache[key] ||= Compiled.new(source, ignorecase == true)
    end

    # Immutable ASCII lookup table with source-backed fallback for other input.
    class Compiled
      attr_reader :source, :metadata

      def initialize(source, ignorecase)
        @source = source.dup.freeze
        @ignorecase = ignorecase
        @metadata = Normalizer.normalize(@source)
        @ascii = Array.new(256) do |codepoint|
          ClassPredicates.match_source(@source, codepoint.chr(Encoding::ASCII_8BIT), @ignorecase)
        end.freeze
        freeze
      end

      def ascii_table_length
        @ascii.length
      end

      def matches_byte?(byte)
        byte.is_a?(Integer) && byte.between?(0, 255) && @ascii[byte]
      end

      def matches?(character)
        character = character.chr(@source.encoding) if character.is_a?(Integer)
        return false unless character
        if character.length == 1 && character.ord < 256 &&
           (character.encoding == Encoding::ASCII_8BIT || character.ord < 128)
          return @ascii[character.ord]
        end

        ClassPredicates.match_source(@source, character, @ignorecase)
      rescue RangeError
        false
      end
    end
  end
end
