# rubocop:disable Style/SpecialGlobalVars

# Issue #1367 — a refinement of `write` whose target is computed. The stream check does not follow which class a
# refinement refines: a refined `write` on any class declines every stream write where a `using` is in effect. Ruby
# 4.0.5 accepts the write after the `using`. A line marked FIRES-1367 quotes the error Ruby raises.
module ComputedWriter
  [Array].each { |target| refine(target) { def write(*texts) = texts.sum(&:size) } }
end

def before_using = ($stdout = []) # FIRES-1367 global.write-type-mismatch — $stdout must have write method, Array given

using ComputedWriter

def array_stdout = ($stdout = []) # QUIET-1367
# rubocop:enable Style/SpecialGlobalVars
