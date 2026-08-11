# frozen_string_literal: true

require_relative "v1_fuzzer"

seed = Integer(ENV.fetch("ONIBI_FUZZ_SEED", "20260811"))
cases = Integer(ENV.fetch("ONIBI_FUZZ_CASES", "100"))
result = V1Fuzzer.run(seed: seed, cases: cases)
puts result.inspect
exit 1 unless result.fetch(:mismatches).zero?
