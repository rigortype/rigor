require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1362 — the issue's example after `$VERBOSE = nil`, and a write to `$>`. Each method runs with whatever the
# command line or another file set last.

$VERBOSE = nil

# Under `ruby -w`, or once another file sets `$VERBOSE = true`, the condition is true.
def warn_when_verbose
  warn "verbose" if $VERBOSE # QUIET-1362
  assert_type("bool?", $VERBOSE)
end

class Cap
  def self.flag(flag) = flag
end

# The `nil` this file writes is judged as a `nil` argument was before the join: the `bool` parameter of `Cap.flag`
# (this fixture's `sig/`) is not held against it, and the declared `true` / `false` add nothing (Ruby: nil, or true
# or false once another file set them).
def flag_direct = Cap.flag($VERBOSE) # QUIET-1362
def flag_conditional(flag) = Cap.flag(flag ? $VERBOSE : nil) # QUIET-1362

$> = StringIO.new

# `$>` keeps an entry of its own, joined with its own declaration (`$>: IO`), so a `StringIO`-only method on it
# stays quiet. Ruby answers `$stdout.equal?($>)` true, but the analysis does not unify the two names yet (#1366):
# `$stdout`, which this file never writes, stays unbound, as before.
def out_alias = assert_type("IO | StringIO", $>)
def captured_text = $>.string # QUIET-1362
def out = assert_type("Dynamic[top]", $stdout)

def capture
  $> = StringIO.new
  assert_type("StringIO", $>)
end
