# rubocop:disable Style/SpecialGlobalVars

# Issue #1367 — a `pre_eval:` patch that aliases two specials. It is loaded ahead of lib/writes.rb, whose writes
# through the aliased names then reach other variables. The patch file is outside the analysed `paths:`.
alias $stdout $captured_output
alias $saved_error $!
# rubocop:enable Style/SpecialGlobalVars
