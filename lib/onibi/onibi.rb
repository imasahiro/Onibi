# frozen_string_literal: true

begin
  require File.expand_path("../../ext/onibi/onibi", __dir__)
rescue LoadError
  begin
    require "onibi/onibi"
  rescue LoadError
    # The extension is built by RubyGems during installation.
  end
end
