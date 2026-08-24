# frozen_string_literal: true

module Onibi
  module ClassPredicates
    module_function

    # Validates semantic names inside a character-class source.
    def validate!(source)
      body = source.start_with?("^") ? source[1..] : source
      validate_atoms!(body)
      true
    end

    def validate_atoms!(source)
      index = 0
      while index < source.length
        current, after = atom(source, index)
        kind, value = current
        case kind
        when :property
          UnicodeProperties.validate!(value[0])
        when :nested
          if value.start_with?("[:")
            raise RegexpError, "invalid POSIX bracket type" unless POSIX_PROPERTIES.key?(value)
          elsif value.start_with?("[") && value.end_with?("]")
            validate!(value[1...-1])
          end
        end
        if kind != :literal && source[after] == "-" && after + 1 < source.length
          nested, = atom(source, after + 1)
          raise RegexpError, "invalid character class range" if nested && nested[0] == :nested
        end
        index = range_end(source, after, current)
        index = after if index <= after
      end
    end
  end
end
