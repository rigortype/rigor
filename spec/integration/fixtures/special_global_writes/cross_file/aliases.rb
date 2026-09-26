# rubocop:disable Style/SpecialGlobalVars

# Issue #1367 — `alias $new $old` makes `$new` name `$old`'s variable, setter included, for every file that runs after
# it. writes.rb runs after this file. The `global.*` rules exempt a special that any file aliases, on either side.
alias $stdout $captured_output
alias $saved_error $!
# rubocop:enable Style/SpecialGlobalVars
