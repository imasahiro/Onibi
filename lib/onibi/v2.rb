# frozen_string_literal: true

# Version two exposes the compiler pipeline as small, testable boundaries.
module Onibi
  module V2
  end
end

require_relative "v2/parser_core"
require_relative "v2/parser"
require_relative "v2/cfg"
require_relative "v2/optimization"
require_relative "v2/compiler"
require_relative "v2/automata"
require_relative "v2/irgen"
