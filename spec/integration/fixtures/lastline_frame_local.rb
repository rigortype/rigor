# rubocop:disable Style/SpecialGlobalVars, Style/GlobalStdStream, Lint/UselessAssignment
require "stringio"
require "rigor/testing"
include Rigor::Testing

# Issue #1359 — `$_`, the last line read, lives in the special-variable slot of the method, class, module or file
# body that runs the reader, beside `$~`. A write binds that body and its blocks only, a reader sets the caller's
# slot to the line it returns, and a condition on a reader narrows `$_` on both edges. Each case cites what Ruby
# 4.0.5 answers, keeping the read in the same frame as the reader.

# The issue's example. The top level is a frame of its own, and its write is the file's `$_` alone.
$_ = "top"
assert_type('"top"', $_)

# A method body starts with its own `$_` (Ruby: nil). It no longer reads the top level's write, and is unbound
# rather than typed nil until issue #1366's declared fallback.
def fresh = assert_type("Dynamic[top]", $_)

# The loop body runs only when `gets` returned a line, so `$_` is that line (Ruby: the line), and the loop exits
# when `gets` returns nil (Ruby: nil).
def lines
  while gets
    assert_type("String", $_)
  end
  assert_type("nil", $_)
end

# The block writes the method's slot (Ruby: "in block"). A block that may set `$_` rebinds the frame's slot, so
# the read after the call forgets rather than keeps what the method knew.
def blk
  [1].each { $_ = "in block" }
  assert_type("Dynamic[top]", $_)
end

# `if gets then $_ else $_ end` (Ruby: the line, then nil at end of input).
def branches
  if gets
    assert_type("String", $_)
  else
    assert_type("nil", $_)
  end
end

# A top-level `$~ = nil` no longer seeds method bodies: a method starts with its own `$~` (Ruby: nil), unbound here.
$~ = nil
def match_entry = assert_type("Dynamic[top]", $~)

# A reader in a called Ruby method sets that method's `$_`, never its caller's (Ruby: the caller's line).
def read_one(io) = io.gets

def callee_keeps(io)
  if gets
    read_one(io)
    assert_type("String", $_)
  end
end

# A thread's root block has a slot of its own: it reads `$_` unbound (Ruby: nil), and its reader leaves the
# creator's `$_` alone (Ruby: the creator's line). So does a fiber's.
def thread_entry
  if gets
    Thread.new { assert_type("Dynamic[top]", $_) }.join
    Thread.new { $stdin.gets }.join
    Fiber.new { $stdin.gets }.resume
    assert_type("String", $_)
  end
end

# The other conditions and receivers that narrow (Ruby: the line on each).
def or_break
  loop do
    gets or break
    assert_type("String", $_)
  end
end

def next_unless(items)
  items.each do
    next unless gets
    assert_type("String", $_)
  end
end

def assignment_condition
  while (line = gets)
    assert_type("String", line)
    assert_type("String", $_)
  end
end

def receivers(path)
  File.open(path) { |f| assert_type("String", $_) if f.gets }
  io = StringIO.new("a\n")
  assert_type("String", $_) if io.gets
  assert_type("String", $_) if $stdin.gets
  assert_type("String", $_) if STDIN.gets
  assert_type("String", $_) if ARGF.gets
  assert_type("String", $_) if Kernel.gets
  begin
    assert_type("String", $_) while $stdin.readline
  rescue EOFError
    nil
  end
end

# An untyped receiver's `gets` may be a Ruby method, which sets its own frame's `$_`, so it narrows nothing and
# leaves `$_` unbound (Ruby with a StringIO: the line; with a Ruby reader: the caller's earlier `$_`).
def untyped_receiver(io)
  assert_type("Dynamic[top]", $_) if io.gets
end

# A reader that is not a condition leaves `$_` unbound, not `String?` (Ruby: the line, or nil at end of input).
def statement_reader
  gets
  assert_type("Dynamic[top]", $_)
end

# Code that may set `$_` after a narrowing forgets it (Ruby: the later line, or nil at end of input, on each).
def block_reader(ios)
  if gets
    ios.each { |io| io.gets }
    assert_type("Dynamic[top]", $_)
  end
end

def operand_reader
  if gets
    line = gets.to_s
    assert_type("Dynamic[top]", $_)
  end
end

def symbol_proc_reader(ios)
  if gets
    ios.each(&:gets)
    assert_type("Dynamic[top]", $_)
  end
end

def sent_reader(io)
  if gets
    io.send(:gets)
    assert_type("Dynamic[top]", $_)
  end
end

def enumerator_reader
  if gets
    Enumerator.new { |y| $stdin.gets; y << 1 }.to_a
    assert_type("Dynamic[top]", $_)
  end
end

def and_right_operand(ios)
  if gets && ios.each { |io| io.gets }
    assert_type("Dynamic[top]", $_)
  end
end

# A lambda that reads a line can run at any later call (Ruby after `reread.call`: the later line).
def lambda_reader
  reread = -> { gets }
  if gets
    reread.call
    assert_type("Dynamic[top]", $_)
  end
end

def literal_reader
  if gets
    pair = [gets, 1]
    assert_type("Dynamic[top]", $_)
  end
end

def eval_reader
  if gets
    eval("gets", binding, __FILE__, __LINE__)
    assert_type("Dynamic[top]", $_)
  end
end

# A block kept by the method it is handed to runs at a later implicit-self call (Ruby after `emit_line`: the later
# line).
def on_line(&block) = (@kept = block)
def emit_line = @kept.call

def kept_block_reader
  on_line { $stdin.gets }
  if gets
    emit_line
    assert_type("Dynamic[top]", $_)
  end
end

# The call's receiver chain runs before its block, in the statement and in the pass that types the call's value
# (Ruby: the second line, or nil).
def receiver_reader
  if gets
    [gets].each { assert_type("Dynamic[top]", $_) }
  end
end

def receiver_reader_value
  if gets
    copies = [gets].map { $_ }
    assert_type("[Dynamic[top]]", copies)
  end
end

# A block that writes `$_` rebinds the frame's slot (Ruby: nil).
def block_writer(items)
  if gets
    items.each { $_ = nil }
    assert_type("Dynamic[top]", $_)
  end
end

# A block in a value position is not entered, and still reads `$_` forgotten when it may set it (Ruby on the second
# element at end of input: nil).
def unentered_block(items)
  if gets
    items.map { assert_type("Dynamic[top]", $_).tap { gets } }.size
  end
end

# A class method's implicit-self reader is `Kernel`'s too (Ruby: the line).
class LineSource
  def self.first
    assert_type("String", $_) if gets
  end
end

# A body that runs again reads what an earlier pass set (Ruby on the second pass at end of input: nil).
def loop_back_edge(ok)
  if gets
    while ok
      assert_type("Dynamic[top]", $_)
      gets
    end
  end
end

def for_back_edge(items)
  if gets
    for item in items
      assert_type("Dynamic[top]", $_)
      gets
    end
  end
end

def block_iteration(items)
  if gets
    items.map { assert_type("Dynamic[top]", $_).tap { gets } }
  end
end

# A block that cannot set `$_` shares the frame's narrowing (Ruby: the line).
def plain_block(items)
  if gets
    items.map { assert_type("String", $_) }
  end
end

# A retried body runs again after the rescue clause, and its reader rebinds `$_` for the retried pass (Ruby: the
# line read before the raise, or nil).
def retry_reader(tries)
  if gets
    begin
      assert_type("Dynamic[top]", $_)
      gets
      raise "again" if (tries -= 1).positive?
    rescue RuntimeError
      retry
    end
  end
end

# A rescue clause runs after any prefix of the body: `readline` sets `$_` to nil at end of input and then raises
# (Ruby: nil).
def rescue_arm
  if gets
    begin
      $stdin.readline
    rescue EOFError
      assert_type("Dynamic[top]", $_)
    end
  end
end

# A `define_method` body reads the definer's slot whenever the method is called, which the narrowing where it is
# written neither proves nor refutes.
def definer
  if gets
    define_singleton_method(:reread) { assert_type("Dynamic[top]", $_) }
  end
end

# Quiet controls: correct code that reads `$_` after a condition on the reader reports nothing.
def quiet_loop
  while gets
    line = $_
    line.chomp # QUIET-1359
  end
end

def quiet_if
  if gets
    line = $_
    line.chomp # QUIET-1359
  end
end

def quiet_or_break
  loop do
    gets or break
    line = $_
    line.chomp # QUIET-1359
  end
end

def quiet_next_unless(items)
  items.each do
    next unless gets
    line = $_
    line.chomp # QUIET-1359
  end
end

def quiet_assignment_condition
  while (line = gets)
    copy = $_
    copy.chomp # QUIET-1359
    line.chomp # QUIET-1359
  end
end

# A reader's value checked another way does not narrow `$_`, which stays unbound, so this reports nothing either.
def quiet_checked_elsewhere
  line = gets
  return unless line

  copy = $_
  copy.chomp # QUIET-1359
end
# rubocop:enable Style/SpecialGlobalVars, Style/GlobalStdStream, Lint/UselessAssignment
