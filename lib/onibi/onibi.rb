# frozen_string_literal: true

require "rbconfig"

extension_name = "onibi.#{RbConfig::CONFIG.fetch("DLEXT")}"
checkout_extension = File.expand_path("../../ext/onibi/#{extension_name}", __dir__)

if File.file?(checkout_extension)
  require checkout_extension
else
  require "onibi/#{extension_name}"
end
