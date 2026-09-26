# rubocop:disable Style/SpecialGlobalVars
require "stringio"
require "uri"

# Issue #1367 (ADR-117 WD2) — a write to a special global that the interpreter's setter rejects raises every time it
# runs. A line marked FIRES-1367 names the rule it reports, then quotes the error Ruby 4.0.5 raises for it. A line
# marked QUIET-1367 is a write Ruby accepts, or one the rules do not check. The writes sit in methods, so the file
# loads.

# A literal the setter rejects: TypeError.
def record_separator = ($/ = 1) # FIRES-1367 global.write-type-mismatch — value of $/ must be String
def record_separator_regexp = ($/ = /\n/) # FIRES-1367 global.write-type-mismatch — value of $/ must be String
def output_field_separator = ($, = 1) # FIRES-1367 global.write-type-mismatch — value of $, must be String
def output_record_separator = ($\ = :lf) # FIRES-1367 global.write-type-mismatch — value of $\ must be String
def field_separator = ($; = 1) # FIRES-1367 global.write-type-mismatch — value of $; must be String or Regexp
def last_match = ($~ = 1) # FIRES-1367 global.write-type-mismatch — wrong argument type Integer (expected MatchData)
def last_match_string = ($~ = "x#{1}") # FIRES-1367 global.write-type-mismatch — wrong argument type String (expected MatchData)
def program_name = ($0 = 1) # FIRES-1367 global.write-type-mismatch — no implicit conversion of Integer into String
def program_name_nil = ($PROGRAM_NAME = nil) # FIRES-1367 global.write-type-mismatch — no implicit conversion of nil into String
def program_name_rational = ($0 = 1r) # FIRES-1367 global.write-type-mismatch — no implicit conversion of Rational into String
def line_number = ($. = "3") # FIRES-1367 global.write-type-mismatch — no implicit conversion of String into Integer
def line_number_symbol = ($. = :"l#{1}") # FIRES-1367 global.write-type-mismatch — no implicit conversion of Symbol into Integer
def inplace_mode = ($-i = true) # FIRES-1367 global.write-type-mismatch — no implicit conversion of true into String
def stdout_integer = ($stdout = 1) # FIRES-1367 global.write-type-mismatch — $stdout must have write method, Integer given
def stdout_nil = ($stdout = nil) # FIRES-1367 global.write-type-mismatch — $stdout must have write method, NilClass given
def stdout_parenthesised = ($stdout = ((1.5))) # FIRES-1367 global.write-type-mismatch — $stdout must have write method, Float given
def stdout_words = ($stdout = %w[a b]) # FIRES-1367 global.write-type-mismatch — $stdout must have write method, Array given
def stderr_integer = ($stderr = 1) # FIRES-1367 global.write-type-mismatch — $stderr must have write method, Integer given
def stderr_hash = ($stderr = {}) # FIRES-1367 global.write-type-mismatch — $stderr must have write method, Hash given
def stdout_alias = ($> = [1]) # FIRES-1367 global.write-type-mismatch — $> must have write method, Array given

# A read-only special: NameError, whatever the value.
def error_info = ($! = RuntimeError.new) # FIRES-1367 global.readonly-write — $! is a read-only variable
def process_id = ($$ = 1) # FIRES-1367 global.readonly-write — $$ is a read-only variable
def child_status = ($? = nil) # FIRES-1367 global.readonly-write — $? is a read-only variable
def load_path = ($LOAD_PATH = []) # FIRES-1367 global.readonly-write — $LOAD_PATH is a read-only variable
def loaded_features = ($" += ["x.rb"]) # FIRES-1367 global.readonly-write — $" is a read-only variable

def argv_target
  first, $* = 1, 2 # FIRES-1367 global.readonly-write — $* is a read-only variable
  first
end

# A literal the setter accepts.
def separator_nil = ($/ = nil) # QUIET-1367
def separator_string = ($/ = "\r\n") # QUIET-1367
def field_separator_regexp = ($; = /,\s*/) # QUIET-1367
def last_match_nil = ($~ = nil) # QUIET-1367
def program_name_string = ($0 = "worker") # QUIET-1367
def line_number_float = ($. = 1.5) # QUIET-1367
def line_number_rational = ($. = 3r) # QUIET-1367 — Rational has `to_int`
def inplace_mode_off = ($-i = false) # QUIET-1367

# A value that is no literal is never reported, whatever its type.
def stdout_stringio = ($stdout = StringIO.new) # QUIET-1367
def stdout_constant = ($stdout = STDOUT) # QUIET-1367
def last_match_data = ($~ = "ab".match(/b/)) # QUIET-1367
def program_name_uri = ($0 = URI("https://x")) # QUIET-1367 — URI defines `alias to_str to_s` at run time
def dynamic_value(value) = ($stdout = value) # QUIET-1367
def conditional(flag) = ($/ = flag ? 1 : :lf) # QUIET-1367 — Ruby raises either way, but the value is no literal

# Writes the rules do not check.
def stdin_integer = ($stdin = 1) # QUIET-1367 — never checked (ADR-117 WD2); Ruby accepts it
def verbose = ($VERBOSE = 1) # QUIET-1367 — the setter takes any value
def load_path_or_write = ($LOAD_PATH ||= []) # QUIET-1367 — `$LOAD_PATH` is truthy, so this never writes
def load_path_append = ($LOAD_PATH << "lib") # QUIET-1367 — a method call, not a write
def separator_operator_write = ($/ += "x") # QUIET-1367 — an `op=` value is not type-checked
# rubocop:enable Style/SpecialGlobalVars
