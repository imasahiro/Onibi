# frozen_string_literal: true

require_relative "fuzzer"

seed = Integer(ENV.fetch("ONIBI_FUZZ_SEED", "20260811"))
cases = Integer(ENV.fetch("ONIBI_FUZZ_CASES", "100"))
result = Fuzzer.run(seed: seed, cases: cases)
puts Fuzzer.report(result)
exit 1 unless result.fetch(:mismatches).zero?
