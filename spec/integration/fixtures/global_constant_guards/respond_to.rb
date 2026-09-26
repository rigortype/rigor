require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1429 — `respond_to?(:m)` admits `m` on its truthy edge: a member whose class RBS knows to lack `m` is dropped,
# and a receiver none of whose members may respond reads `Dynamic[top]` when a member is a `Nominal`, so the guarded
# call does not report (Ruby 4.0.5: "" and 1 under `STDOUT`).

$stdout = STDOUT

class Holder
  def initialize
    @io = STDOUT
  end

  def captured = (@io.respond_to?(:string) ? @io.string : "") # QUIET-1429
end

def local_admits
  io = STDOUT
  io.respond_to?(:string) ? io.string : "" # QUIET-1429
end

def constant_admits = (STDOUT.respond_to?(:string) ? STDOUT.string : "") # QUIET-1429

def members(flag)
  value = flag ? 1 : "one"
  assert_type('"one"', value) if value.respond_to?(:upcase)
  assert_type('"one" | 1', value) unless value.respond_to?(:upcase)
end

# A literal carrier that lacks the method reads `bot`: it never gains the method (Ruby 4.0.5: 1).
def literal_receiver
  number = 1
  number.respond_to?(:upcase) ? assert_type("bot", number) : number
end

# Control: without the guard the call still reports.
def unguarded
  io = STDOUT
  io.string # FIRES-1429 call.undefined-method
end
