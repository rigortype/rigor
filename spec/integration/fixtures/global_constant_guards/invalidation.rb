require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1429 — a guard's narrowing of a global holds until code may run that rebinds the global. A method the project
# defines may (`reset_sep`, `helper_that_writes_stdout`), and so may a block such a method runs, a lambda, and an
# unresolved callee. A core or standard-library method does not, so the narrowing survives `$sep.strip`, `puts` and
# `$stdout.rewind`. Restoring reads the union of the pre-guard binding and the narrowed one.
#
# Each example puts only the call under test between the guard and the read: an `assert_type` is itself a call the
# scan cannot resolve, so it asserts after that call or in a method of its own. Ruby 4.0.5, with an argument given
# (`$sep` is ","): the reported calls raise NoMethodError on nil, the quiet ones return 1.

$stdout = STDOUT
$sep = nil if ARGV.empty?
$sep = "," unless ARGV.empty?

def reset_sep
  $sep = nil
end

def helper_that_writes_stdout
  $stdout = STDOUT
end

def with_retry = yield

def kept_across_core_calls
  return unless $sep

  $sep.strip
  puts $sep
  format("%s", $sep)
  copy = $sep
  copy.length # QUIET-1429
end

def kept_in_core_block
  return unless $sep

  [1, 2].each { puts "tick" }
  copy = $sep
  copy.length # QUIET-1429
end

def dropped_by_project_call
  return unless $sep

  reset_sep
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

def dropped_by_project_call_in_argument
  return unless $sep

  puts(reset_sep)
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

def dropped_by_block_that_rebinds
  return unless $sep

  [1, 2].each { reset_sep }
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

def dropped_in_project_helper_block
  return unless $sep

  with_retry do
    copy = $sep
    copy.length # FIRES-1429 call.possible-nil-receiver
  end
end

def dropped_in_lambda
  return unless $sep

  -> { assert_type('","?', $sep) }
end

def dropped_by_unresolved_callee(untyped)
  return unless $sep

  untyped.anything
  assert_type('","?', $sep)
end

# The issue's pair. A helper that may rewrite `$stdout` restores it to the union, whose gradual `StringIO` member
# keeps `.string` quiet; a core `rewind` keeps the narrowing. Ruby 4.0.5: the captured text under a `StringIO`, nil
# under `STDOUT`.
def with_helper
  $stdout.is_a?(StringIO) ? (helper_that_writes_stdout; assert_type("Dynamic[StringIO] | IO", $stdout); $stdout.string) : nil # QUIET-1429
end

def with_rewind
  $stdout.is_a?(StringIO) ? ($stdout.rewind; assert_type("Dynamic[StringIO]", $stdout); $stdout.string) : nil # QUIET-1429
end

# A constant's narrowing is restored the same way; the guard's own reading is asserted apart.
def constant_narrowed = (assert_type("Dynamic[StringIO]", STDOUT) if STDOUT.is_a?(StringIO))

def constant_restored
  return unless STDOUT.is_a?(StringIO)

  reset_sep
  assert_type("Dynamic[StringIO] | IO", STDOUT)
end

# `$>` is the variable `$stdout` names, so a write to it ends a guard's narrowing of `$stdout` (Ruby 4.0.5: `$stdout`
# is `STDOUT` after the write).
def alias_write
  return unless $stdout.is_a?(StringIO)

  $> = STDOUT
  assert_type("Dynamic[StringIO] | IO", $stdout)
end
