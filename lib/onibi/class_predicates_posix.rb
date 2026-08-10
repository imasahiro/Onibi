# frozen_string_literal: true

module Onibi
  module ClassPredicates
    POSIX_PROPERTIES = {
      "[:digit:]" => "Digit", "[:alpha:]" => "Alpha", "[:alnum:]" => "Alnum",
      "[:space:]" => "Space", "[:word:]" => "Word", "[:xdigit:]" => "XDigit",
      "[:upper:]" => "Upper", "[:lower:]" => "Lower", "[:blank:]" => "Blank",
      "[:cntrl:]" => "Cntrl", "[:graph:]" => "Graph", "[:print:]" => "Print",
      "[:punct:]" => "Punct", "[:ascii:]" => "ASCII"
    }.freeze
  end
end
