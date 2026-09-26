# rubocop:disable Style/SpecialGlobalVars

# Issue #1367 — `alias $new $old` makes `$new` name `$old`'s variable, setter included, so a file that aliases a
# special writes another variable through that name. Ruby 4.0.5 accepts both writes below. The rules exempt a
# special that an alias names on either side, whatever the file.
alias $stdout $captured_output
alias $! $last_failure

def capture = ($stdout = 1) # QUIET-1367
def fail_with = ($! = RuntimeError.new) # QUIET-1367

# An alias that names no special leaves every special's setter in place.
alias $out $captured_output

def stderr_integer = ($stderr = 1) # FIRES-1367 global.write-type-mismatch — $stderr must have write method, Integer given
# rubocop:enable Style/SpecialGlobalVars
