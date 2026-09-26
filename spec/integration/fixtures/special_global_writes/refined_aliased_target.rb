# rubocop:disable Style/SpecialGlobalVars

# Issue #1367 — a refinement of `write` whose target is a constant alias. The stream check does not follow which class
# a refinement refines: a refined `write` on any class declines every stream write where a `using` is in effect. Ruby
# 4.0.5 accepts the write after the `using`. A line marked FIRES-1367 quotes the error Ruby raises.
Target = Array

module AliasedWriter
  refine(Target) { def write(*texts) = texts.sum(&:size) }
end

def before_using = ($stdout = []) # FIRES-1367 global.write-type-mismatch — $stdout must have write method, Array given

using AliasedWriter

def array_stdout = ($stdout = []) # QUIET-1367
# rubocop:enable Style/SpecialGlobalVars
