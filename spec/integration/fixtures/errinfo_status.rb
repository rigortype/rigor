# rubocop:disable Style/SpecialGlobalVars, Lint/UselessAssignment, Style/RescueModifier, Lint/SuppressedException
require "rigor/testing"
require "timeout"
include Rigor::Testing

# Issue #1360 — `$!` is the exception being rescued and `$@` its backtrace: Ruby finds them through the nearest rescue
# frame of the running execution context, so they hold the exception inside a `rescue` clause and whatever they held
# before once the `begin` exits. `$?` is the status of the thread's last child process. Each case cites what Ruby
# 4.0.5 answers when the method is called on its own (from no rescue clause, in a thread that ran no subprocess).

class AppError < StandardError
  def detail = "detail"
end

class OtherError < StandardError; end

# A module whose own `===` lets `rescue` match exceptions that are not instances of it.
module AnyFailure
  def self.===(_exception) = true
end

# `rescue A, B` binds `$!` to `A | B`, as `rescue A, B => e` binds `e` (Ruby: the ArgumentError), and `$@` to the
# backtrace (Ruby: an Array of Strings).
def rescue_union
  Integer("x")
rescue ArgumentError, TypeError
  assert_type("ArgumentError | TypeError", $!)
  assert_type("Array[String]", $@)
end

# A bare `rescue` rescues a `StandardError` (Ruby: the ArgumentError).
def bare_rescue
  Integer("x")
rescue
  assert_type("StandardError", $!)
end

# A project class below `StandardError` binds as itself, and its own methods resolve (Ruby: "detail").
def project_class
  raise AppError
rescue AppError
  assert_type("AppError", $!)
  $!.detail
end

# A module with its own `===` matches exceptions that are not its instances (Ruby: the RuntimeError), so `$!` is not
# read as one.
def matcher_module
  raise "boom"
rescue AnyFailure
  assert_type("Dynamic[top]", $!)
end

# The rescue modifier's fallback rescues a `StandardError` (Ruby: the RuntimeError and its backtrace), and past it
# `$!` is what it was before (Ruby: nil).
def modifier
  error = ((raise "m") rescue $!)
  assert_type("StandardError", error)
  trace = (Integer("x") rescue $@)
  assert_type("Array[String] | Integer", trace)
  assert_type("Dynamic[top]", $!)
end

# Past the `begin`, `$!` and `$@` are what they were before it (Ruby: nil, nil). A method body starts unbound: it reads
# whatever its caller is rescuing (Ruby: nil here, the caller's exception when called from a rescue clause).
def after_begin
  assert_type("Dynamic[top]", $!)
  begin
    Integer("x")
  rescue ArgumentError
    assert_type("ArgumentError", $!)
  end
  assert_type("Dynamic[top]", $!)
  assert_type("Dynamic[top]", $@)
end

# A nested `begin` in a rescue clause: its own clause reads its own exception (Ruby: OtherError), its `else` and the
# code after it the outer one (Ruby: AppError, AppError), and its `ensure` either, since the clause runs after a raise
# too (Ruby: AppError here, the OtherError in flight in `nested_raise_ensure`).
def nested
  raise AppError
rescue AppError
  begin
    raise OtherError
  rescue OtherError
    assert_type("OtherError", $!)
  end
  assert_type("AppError", $!)
  begin
    :ok
  rescue OtherError
    :rescued
  else
    assert_type("AppError", $!)
  ensure
    assert_type("Dynamic[top]", $!)
  end
  assert_type("AppError", $!)
end

def nested_raise_ensure
  raise AppError
rescue AppError
  begin
    begin
      raise OtherError
    ensure
      assert_type("Dynamic[top]", $!)
    end
  rescue OtherError
  end
  assert_type("AppError", $!)
end

# A `break` out of an inner rescue clause leaves it (Ruby: AppError after the loop).
def break_out_of_rescue
  raise AppError
rescue AppError
  while true
    begin
      raise OtherError
    rescue OtherError
      break
    end
  end
  assert_type("AppError", $!)
end

# A `retry` enters the body again with `$!` as the `begin` found it (Ruby: nil on both attempts, and after).
def retried
  tries = 0
  begin
    tries += 1
    assert_type("Dynamic[top]", $!)
    raise AppError if tries < 2
  rescue AppError
    retry
  end
  assert_type("Dynamic[top]", $!)
end

# A block the clause runs reads the exception (Ruby: AppError). A thread's or fiber's root block runs in an execution
# context of its own (Ruby: nil, nil). A `define_method` body runs whenever the method is called (Ruby: nil once
# called from outside the clause), and so does a closure's body, which is read unbound wherever it is called (Ruby:
# AppError for the proc called inside the clause, nil for `rescued_lambda.call`).
def blocks_in_rescue
  begin
    raise AppError
  rescue AppError
    [1].each { assert_type("AppError", $!) }
    Thread.new { assert_type("Dynamic[top]", $!) }.join
    Fiber.new { assert_type("Dynamic[top]", $!) }.resume
    define_singleton_method(:later_error) { assert_type("Dynamic[top]", $!) }
    proc { assert_type("Dynamic[top]", $!) }.call
  end
  later_error
end

def rescued_lambda
  raise AppError
rescue AppError
  -> { assert_type("Dynamic[top]", $!) }
end

# A clause that guards `$!` by its class reads `$!` and `$@` unbound, as before #1360: a class guard does not narrow a
# global receiver yet (#1429), so a bound `StandardError` would report `key` against the guard (Ruby: :a in each, and
# exit status 3 in `guarded_exit_status`).
def guarded_is_a(h)
  h.fetch(:a)
rescue
  $!.key if $!.is_a?(KeyError) # QUIET-1360
end

def guarded_case(h)
  h.fetch(:a)
rescue
  case $!
  when KeyError then $!.key # QUIET-1360
  end
end

def guarded_case_equality(h)
  h.fetch(:a)
rescue
  $!.key if KeyError === $! # QUIET-1360
end

def guarded_kind_of(h)
  h.fetch(:a)
rescue
  return unless $!.kind_of?(KeyError)

  $!.key # QUIET-1360
end

def guarded_exit_status
  exit 3
rescue Exception
  exit($!.status) if $!.is_a?(SystemExit) # QUIET-1360
end

# A clause or fallback the analysis types without entering it (a rescue modifier's fallback, a `begin` or `do` block
# with a rescue clause in a value position) reads `$!` unbound, never the enclosing clause's ArgumentError (Ruby: :a,
# :a, the ENOENT's errno, :a, [:b], the OtherError, and the ArgumentError in the `ensure` reached normally).
def unentered_clauses(h, path, xs)
  raise ArgumentError
rescue ArgumentError
  h.fetch(:a) rescue $!.key # QUIET-1360
  k = (h.fetch(:a) rescue $!.key) # QUIET-1360
  File.read(path) rescue warn($!.errno.to_s) # QUIET-1360
  warn(begin
    h.fetch(:a)
  rescue KeyError
    $!.key # QUIET-1360
  end.inspect)
  warn(xs.map do |x|
    h.fetch(x)
  rescue KeyError
    $!.key # QUIET-1360
  end.inspect)
  assert_type("[Dynamic[top]]", [begin; raise OtherError; rescue OtherError; $!; end])
  assert_type("[1]", [begin; 1; ensure; assert_type("Dynamic[top]", $!); end])
  k
end

# A rescue modifier's fallback that guards `$!` by its class reads it unbound in the modifier's value too (Ruby: nil,
# the RuntimeError not being a KeyError).
def guarded_modifier
  found = ((raise "x") rescue ($!.is_a?(KeyError) ? $! : nil))
  assert_type("Dynamic[top]?", found)
end

# A class that gives itself a singleton `===` matches exceptions that are not its instances (Ruby: the RuntimeError).
class Matchy < StandardError
  def self.===(_exception) = true
end

def matchy_class
  raise "boom"
rescue Matchy
  assert_type("Dynamic[top]", $!)
end

# `set_backtrace(nil)` makes `$@` nil (Ruby: nil), so a clause that calls it reads `$@` unbound; `$!` is still the
# exception (Ruby: the AppError).
def reset_backtrace
  raise AppError
rescue AppError
  $!.set_backtrace(nil)
  assert_type("Dynamic[top]", $@)
  assert_type("AppError", $!)
end

# A copy of `$!` in a rescue clause is the exception, never nil.
def quiet_error_copy
  Integer("x")
rescue ArgumentError
  err = $!
  err.message # QUIET-1360
end

# `$?` after each subprocess that waits for its child (Ruby: a Process::Status after each). A method body starts
# unbound (Ruby: nil in a thread that ran no subprocess).
def status_setters
  assert_type("Dynamic[top]", $?)
  `true`
  assert_type("Process::Status", $?)
end

def status_percent_x
  %x(true)
  assert_type("Process::Status", $?)
end

def status_system
  system("true")
  assert_type("Process::Status", $?)
end

def status_kernel_system
  Kernel.system("true")
  assert_type("Process::Status", $?)
end

def status_wait
  Process.wait(spawn("true"))
  assert_type("Process::Status", $?)
end

def status_wait2
  Process.wait2(spawn("true"))
  assert_type("Process::Status", $?)
end

def status_waitpid
  Process.waitpid(spawn("true"))
  assert_type("Process::Status", $?)
end

def status_waitpid2
  Process.waitpid2(spawn("true"))
  assert_type("Process::Status", $?)
end

# A command whose output is read on (Ruby: a Process::Status), and one in a branch that may not run (Ruby: nil when
# `run` is false).
def status_receiver_chain
  head = `echo x`.strip
  assert_type("Process::Status", $?)
  head
end

def status_maybe(run)
  system("true") if run
  assert_type("Dynamic[top]", $?)
end

# A called method's subprocess sets its caller's `$?` too (Ruby: a Process::Status), but the analysis does not follow
# what a callee runs, so the read stays unbound.
def run_true = system("true")

def status_from_callee
  run_true
  assert_type("Dynamic[top]", $?)
end

# Once set, `$?` stays a Process::Status through later calls and blocks, and a fiber shares the thread's (Ruby: a
# Process::Status in each). A new thread has none (Ruby: nil), nor does a closure's body, which may run on one, nor a
# `define_method` body, which runs whenever the method is called.
def status_survives
  system("true")
  puts "ran"
  assert_type("Process::Status", $?)
  [1].each { assert_type("Process::Status", $?) }
  Fiber.new { assert_type("Process::Status", $?) }.resume
  Thread.new { assert_type("Dynamic[top]", $?) }.join
  -> { assert_type("Dynamic[top]", $?) }.call
  define_singleton_method(:later_status) { assert_type("Dynamic[top]", $?) }
  later_status
end

# An `ensure` clause may run after a raise that came before the subprocess (Ruby: a Process::Status here), and the
# code past a `begin` that finished after it (Ruby: a Process::Status).
def status_ensure
  begin
    system("true")
  ensure
    assert_type("Dynamic[top]", $?)
  end
  assert_type("Process::Status", $?)
end

# A backtick, `%x` or `system` sets `$?` to nil before it runs the child, so an exception raised while it waits
# (`Timeout::Error`, `Interrupt`, `Thread#raise`) leaves `$?` nil: a rescue clause reads it unbound (Ruby: nil), and so
# does the code past the `begin` and past a rescue modifier (Ruby: nil, nil).
def status_interrupted
  system("true")
  begin
    Timeout.timeout(0.3) { `sleep 2` }
  rescue Timeout::Error
    assert_type("Dynamic[top]", $?)
  end
  assert_type("Dynamic[top]", $?)
end

def status_interrupted_modifier
  system("true")
  out = (Timeout.timeout(0.3) { `sleep 2` } rescue nil)
  assert_type("Dynamic[top]", $?)
  out
end

# A body a `retry` re-enters runs again after such an exception (Ruby: a Process::Status on the first pass, nil on the
# second).
def status_retried
  system("true")
  tries = 0
  begin
    tries += 1
    assert_type("Dynamic[top]", $?)
    Timeout.timeout(0.3) { `sleep 2` } if tries == 1
  rescue Timeout::Error
    retry
  end
end

# A copy of `$?` after a subprocess is its status, never nil.
def quiet_status_copy
  system("true")
  st = $?
  st.success? # QUIET-1360
end
# rubocop:enable Style/SpecialGlobalVars, Lint/UselessAssignment, Style/RescueModifier, Lint/SuppressedException
