require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1429 — a guard's narrowing of a global holds until code may run that rebinds the global. A method the project
# defines may (`reset_sep`, `helper_that_writes_stdout`), and so may a block such a method runs, a lambda, and an
# unresolved callee. A core or standard-library method does not, so the narrowing survives `$sep.strip`, `puts` and
# `$stdout.rewind`. Restoring reads the union of the pre-guard binding and the narrowed one (Ruby: the copy is nil
# after `reset_sep`, so the reported calls raise there).

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

# The issue's pair: a helper that may rewrite `$stdout` restores it to the union, which still has the guarded
# `StringIO` and keeps `.string` quiet; a core `rewind` keeps the narrowing (Ruby: the captured text under a
# `StringIO`, nil under `STDOUT`).
def with_helper
  $stdout.is_a?(StringIO) ? (helper_that_writes_stdout; assert_type("IO | StringIO", $stdout); $stdout.string) : nil # QUIET-1429
end

def with_rewind
  $stdout.is_a?(StringIO) ? ($stdout.rewind; assert_type("StringIO", $stdout); $stdout.string) : nil # QUIET-1429
end

# A constant's narrowing is restored the same way.
def constant_restored
  return unless STDOUT.is_a?(StringIO)

  assert_type("StringIO", STDOUT)
  reset_sep
  assert_type("IO | StringIO", STDOUT)
end
