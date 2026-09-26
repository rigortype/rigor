require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1362 — the issue's example after `$VERBOSE = nil`, and a write to `$>`, which is `$stdout`. Each method
# runs with whatever the command line or another file set last.

$VERBOSE = nil

# Under `ruby -w`, or once another file sets `$VERBOSE = true`, the condition is true.
def warn_when_verbose
  warn "verbose" if $VERBOSE # QUIET-1362
  assert_type("bool?", $VERBOSE)
end

$> = StringIO.new

# A write to `$>` joins `$stdout`'s seed (Ruby: `$stdout.equal?($>)` is always true).
def out = assert_type("IO | StringIO", $stdout)
def captured_text = $stdout.string # QUIET-1362

def capture
  $> = StringIO.new
  assert_type("StringIO", $stdout)
end
