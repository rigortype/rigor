# rubocop:disable Style/SpecialGlobalVars
require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1362 — a global still on its declared seed, or a local copied from one, passed where a signature (this
# fixture's `sig/`) requires the type the file writes: the declared members are not diagnostic fuel, so the call
# reports only when the file's writes themselves are rejected, as before the join. The same holds for a method whose
# body ends on such a read, and, without the declared members the file never writes, for a value that mixes such a
# global with something else. Each method runs once this file's writes ran.

class Cap
  def self.take(io) = io.string
  def self.file(file) = file.path
  def self.text(text) = text
  def self.count(number) = number
  def self.take_list(ios) = ios.map(&:string)
  def self.flag(flag) = flag
end

class Ret
  def out = $stdout # QUIET-1362
  def out_copy # QUIET-1362
    out = $stdout
    out
  end

  def separator = $/ # QUIET-1362
  def verbose = $VERBOSE # QUIET-1362
  def out_count = $stdout # FIRES-1362 def.return-type-mismatch
  def input = $stdin # FIRES-1362 def.return-type-mismatch
  def out_conditional(flag) = flag ? $stdout : StringIO.new # QUIET-1362
end

$stdout = StringIO.new
$stderr = File.open(File::NULL, "w")
$/ = "\n"
$VERBOSE = true
$stdin = STDIN

# Ruby: "" for each.
def take_direct = Cap.take($stdout) # QUIET-1362

def take_copy
  out = $stdout
  Cap.take(out) # QUIET-1362
end

# A copy of a copy, and a parenthesised read, count as the bare read (Ruby: "").
def take_copy_of_copy
  out = $stdout
  io = out
  Cap.take(io) # QUIET-1362
end

def take_parenthesised = Cap.take(($stdout)) # QUIET-1362

# Ruby: "/dev/null".
def file_direct = Cap.file($stderr) # QUIET-1362

def file_copy
  err = $stderr
  Cap.file(err) # QUIET-1362
end

# Ruby: "\n".
def text_direct = Cap.text($/) # QUIET-1362

def text_copy
  sep = $/
  Cap.text(sep) # QUIET-1362
end

# A value that mixes a seed with something else, judged without the declared `IO` the file never writes to
# `$stdout` (Ruby: "" or [""] for each; `$VERBOSE` holds `true` or `false`).
def take_conditional(flag) = Cap.take(flag ? $stdout : StringIO.new) # QUIET-1362

def take_default(flag)
  out = (flag ? StringIO.new : nil) || $stdout
  Cap.take(out) # QUIET-1362
end

def take_asymmetric(flag)
  out = StringIO.new
  out = $stdout if flag
  Cap.take(out) # QUIET-1362
end

def take_list = Cap.take_list([$stdout]) # QUIET-1362
def take_result = Cap.take($stdout.itself) # QUIET-1362
def flag_conditional(flag) = Cap.flag(flag ? $VERBOSE : false) # QUIET-1362
def flag_result = Cap.flag($VERBOSE.itself) # QUIET-1362

# Controls: the file's writes themselves are rejected, so the call still reports. `$stdin` holds `STDIN`, an `IO`,
# which `take` rejects, as it rejects the `"x"` arm (Ruby: `NoMethodError` for `string` in each).
def take_stdin = Cap.take($stdin) # FIRES-1362 call.argument-type-mismatch

def take_stdin_copy
  input = $stdin
  copy = input
  Cap.take(copy) # FIRES-1362 call.argument-type-mismatch
end

def take_stdin_parenthesised = Cap.take(($stdin)) # FIRES-1362 call.argument-type-mismatch

# A local two branches copy from different globals is judged by the writes to both, as is one a retried pass
# re-enters with a copy of another global.
def take_joined(flag)
  if flag then io = $stdout else io = $stdin end
  Cap.take(io) # FIRES-1362 call.argument-type-mismatch
end

def take_retried(flag)
  io = $stdout
  begin
    Cap.take(io) # FIRES-1362 call.argument-type-mismatch
    raise if flag
  rescue StandardError
    io = $stdin
    retry
  end
end

# A retried pass that re-enters with a copy of `$stdout`, which the entry's copy of `$stdin` does not accept, so the
# local is rebound; `$stdin` holds an `IO`.
def take_retried_rebound(flag)
  io = $stdin
  begin
    Cap.take(io) # FIRES-1362 call.argument-type-mismatch
    raise if flag
  rescue StandardError
    io = $stdout
    retry
  end
end

def take_mixed(flag) = Cap.take(flag ? $stdout : "x") # FIRES-1362 call.argument-type-mismatch

# Ruby: the method runs on a `StringIO`, which is no `Integer`.
def count_direct = Cap.count($stdout) # FIRES-1362 call.argument-type-mismatch

def count_copy
  out = $stdout
  Cap.count(out) # FIRES-1362 call.argument-type-mismatch
end
# rubocop:enable Style/SpecialGlobalVars
