# rubocop:disable Style/SpecialGlobalVars
require "rigor/testing"
include Rigor::Testing

# Issue #1360 — the two program shapes in which `$@` and `$?` are not bound. Each case cites what Ruby 4.0.5 answers.

# A `wait` with the `WNOHANG` flag sets `$?` to nil when no child has exited (Ruby: `reap` returns nil and leaves
# `$?` nil while a child runs), and can run between any subprocess and a read of `$?`, so this file binds `$?` nowhere
# (Ruby: a Process::Status in `status_after_system`, nil once `reap` ran with a child still running).
def reap = Process.wait(-1, Process::WNOHANG)

def status_after_system
  system("true")
  assert_type("Dynamic[top]", $?)
end

# `$@` calls the exception's `backtrace`, which a program may define to return anything (Ruby: nil here), so `$@`
# stays unbound in a program that defines one; `$!` is still the rescued exception (Ruby: the QuietError).
class QuietError < StandardError
  def backtrace = nil
end

def trace_after_raise
  raise QuietError
rescue QuietError
  assert_type("QuietError", $!)
  assert_type("Dynamic[top]", $@)
end
# rubocop:enable Style/SpecialGlobalVars
