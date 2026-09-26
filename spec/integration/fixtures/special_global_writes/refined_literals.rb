# rubocop:disable Style/SpecialGlobalVars

# Issue #1367 — a refinement in effect where a literal is written. Ruby 4.0.5's `respond_to?(:write)` sees a refined
# `write`, on the literal's class or on an ancestor, so the stream setters accept the literal. The `to_str` / `to_int`
# conversions ignore refinements, so the other setters still raise. A line marked FIRES-1367 quotes the error.
module ArrayWriter
  refine(Array) { def write(*texts) = texts.sum(&:size) }
end

module NumericWriter
  refine(Numeric) { def write(*texts) = texts.sum(&:size) }
end

module SymbolText
  refine(Symbol) { def to_str = to_s }
end

module StringNumber
  refine(String) { def to_int = 1 }
end

def before_using = ($stdout = []) # FIRES-1367 global.write-type-mismatch — $stdout must have write method, Array given

using ArrayWriter
using NumericWriter
using SymbolText
using StringNumber

def array_stdout = ($stdout = []) # QUIET-1367
def integer_stderr = ($stderr = 1) # QUIET-1367 — Numeric's refined `write` reaches Integer
def hash_stdout = ($stdout = {}) # FIRES-1367 global.write-type-mismatch — $stdout must have write method, Hash given
def symbol_program_name = ($0 = :worker) # FIRES-1367 global.write-type-mismatch — no implicit conversion of Symbol into String
def string_line_number = ($. = "3") # FIRES-1367 global.write-type-mismatch — no implicit conversion of String into Integer
# rubocop:enable Style/SpecialGlobalVars
