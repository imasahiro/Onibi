# frozen_string_literal: true

module Onibi
  # Defines value semantics for compiled regular expressions.
  module RegexpObjectSemantics
    def ==(other)
      other.is_a?(Regexp) && source == other.source && options == other.options
    end

    def eql?(other)
      self == other
    end

    def hash
      [source, options].hash
    end
  end
end
