# rubocop:disable Style/SpecialGlobalVars

# Issue #1367 — the writes that run after aliases.rb. A line marked FIRES-1367 quotes the error Ruby 4.0.5 raises.
def capture = ($stdout = 1) # QUIET-1367 — `$stdout` names `$captured_output`, so Ruby accepts it
def clear = ($! = nil) # QUIET-1367 — exempt on the old-name side too; Ruby still raises NameError here
def separator = ($/ = 1) # FIRES-1367 global.write-type-mismatch — value of $/ must be String
def status = ($? = nil) # FIRES-1367 global.readonly-write — $? is a read-only variable
# rubocop:enable Style/SpecialGlobalVars
