# frozen_string_literal: true

begin
  require File.expand_path("../../ext/onibi/onibi", __dir__)
rescue LoadError
  require "onibi/onibi"
end
