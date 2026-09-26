# rubocop:disable Style/SpecialGlobalVars

# Issue #1367 — a refinement that adds only a hatch. Ruby 4.0.5's `respond_to?(:write)` does not consult a refined
# `respond_to_missing?` or `respond_to?`, so the stream setter still raises where the `using` is in effect. A line
# marked FIRES-1367 quotes the error.
module MissingWriter
  refine(Integer) { def respond_to_missing?(name, include_private = false) = name == :write || super }
end

module RespondingWriter
  refine(Float) { def respond_to?(name, include_private = false) = name == :write || super }
end

using MissingWriter
using RespondingWriter

def integer_stdout = ($stdout = 1) # FIRES-1367 global.write-type-mismatch — $stdout must have write method, Integer given
def float_stdout = ($stdout = 1.5) # FIRES-1367 global.write-type-mismatch — $stdout must have write method, Float given
# rubocop:enable Style/SpecialGlobalVars
