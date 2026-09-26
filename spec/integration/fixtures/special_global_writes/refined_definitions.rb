# rubocop:disable Style/SpecialGlobalVars

# Issue #1367 — a refinement that adds `write` by `define_method` or `alias_method` rather than `def`. Ruby 4.0.5's
# `respond_to?(:write)` sees it where the `using` is in effect, so the stream setter accepts the literal there. A line
# marked FIRES-1367 quotes the error Ruby raises.
module ArrayWriter
  refine(Array) { define_method(:write) { |*texts| texts.sum(&:size) } }
end

module HashWriter
  refine(Hash) { alias_method :write, :store }
end

def before_using = ($stdout = []) # FIRES-1367 global.write-type-mismatch — $stdout must have write method, Array given

using ArrayWriter
using HashWriter

def array_stdout = ($stdout = []) # QUIET-1367
def hash_stdout = ($stdout = {}) # QUIET-1367
# rubocop:enable Style/SpecialGlobalVars
