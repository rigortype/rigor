# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
include Rigor::Testing

# Issue #1362 — the issue's example after `$VERBOSE = false`, and a `$stdout` this file binds to a `File`. Each
# method runs with whatever the command line or another file set last.

$VERBOSE = false

# Under `ruby -w`, or once another file sets `$VERBOSE = true`, the condition is true.
def warn_when_verbose
  warn "verbose" if $VERBOSE # QUIET-1362
  assert_type("bool?", $VERBOSE)
end

$stdout = File.open(File::NULL, "w")

# No narrower than the declared `IO`, and `$>` reads the same.
def out = assert_type("File | IO", $stdout)
def out_alias = assert_type("File | IO", $>)
# rubocop:enable Style/SpecialGlobalVars
