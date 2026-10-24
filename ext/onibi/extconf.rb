# frozen_string_literal: true

require "mkmf"
# The implementation modules are an intentional amalgamation. Compile only
# onibi.c; it includes the modules in dependency order.
# rubocop:disable Style/GlobalVars
$srcs = ["onibi.c"]
# rubocop:enable Style/GlobalVars

module_sources = Dir.glob(File.join(__dir__, "*.c"))
                    .reject { |source| File.basename(source) == "onibi.c" }
                    .sort
module_dependencies = module_sources.map do |source|
  "$(srcdir)/#{File.basename(source)}"
end

# Append after mkmf targets to keep its default target and header prerequisites.
create_makefile("onibi/onibi")
File.open("Makefile", "a") do |makefile|
  makefile.puts "\n$(OBJS): #{module_dependencies.join(" ")}"
end
