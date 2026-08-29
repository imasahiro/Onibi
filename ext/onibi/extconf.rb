# frozen_string_literal: true

require "mkmf"
# The implementation modules are an intentional amalgamation. Compile only
# onibi.c; it includes the modules in dependency order.
# rubocop:disable Style/GlobalVars
$srcs = ["onibi.c"]
# rubocop:enable Style/GlobalVars
create_makefile("onibi/onibi")
