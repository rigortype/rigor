require "rigor/testing"
include Rigor::Testing

# Issue #1429 — the paths other than a spelled call by which Ruby code runs between a guard on a global or constant
# and a read of it: the method a compound write or a `for` loop calls without spelling it, a loop's back edge, a
# rescue clause, a `retry`, the later operand of `&&`, a write to the other name of `$stdout`, and a constant rebound
# by `const_set` or written through another spelling. Each restores the narrowing. Ruby 4.0.5, with an argument given:
# every reported call raises NoMethodError on nil; the quiet ones return 1.

$sep = nil if ARGV.empty?
$sep = "," unless ARGV.empty?
SEP = ARGV.empty? ? nil : ","

class Resetter
  attr_writer :val

  def val
    $sep = nil
    1
  end

  def [](_index)
    $sep = nil
    1
  end

  def []=(_index, _value)
    $sep = nil
  end

  def +(_other)
    $sep = nil
    self
  end

  def each
    $sep = nil
    yield 1
  end

  def ==(_other)
    $sep = nil
    true
  end
end

def reset_sep
  $sep = nil
end

def reset_and_true
  $sep = nil
  true
end

def operator_write
  r = Resetter.new
  return unless $sep

  r += r
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

def attribute_operator_write
  r = Resetter.new
  return unless $sep

  r.val += 1
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

def attribute_or_write
  r = Resetter.new
  return unless $sep

  r.val ||= 1
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

def index_operator_write
  r = Resetter.new
  return unless $sep

  r[0] += 1
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

def index_or_write
  r = Resetter.new
  return unless $sep

  r[0] ||= 1
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

def ivar_operator_write
  @r = Resetter.new
  return unless $sep

  @r += @r
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

def for_loop
  r = Resetter.new
  return unless $sep

  for x in r do x end
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

# `!=` is `BasicObject`'s, and it calls the project's `==`.
def universal_delegate
  r = Resetter.new
  return unless $sep

  r != 1
  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

# The second iteration reads what the first one wrote.
def loop_back_edge_write
  return unless $sep

  i = 0
  while i < 2
    copy = $sep
    copy.length # FIRES-1429 call.possible-nil-receiver
    $sep = nil
    i += 1
  end
end

def loop_back_edge_call
  return unless $sep

  i = 0
  while i < 2
    copy = $sep
    copy.length # FIRES-1429 call.possible-nil-receiver
    reset_sep
    i += 1
  end
end

def rescue_clause
  return unless $sep

  begin
    reset_sep
    Integer("x")
  rescue ArgumentError
    copy = $sep
    copy.length # FIRES-1429 call.possible-nil-receiver
  end
end

def retried
  return unless $sep

  tries = 0
  begin
    copy = $sep
    copy.length # FIRES-1429 call.possible-nil-receiver
    tries += 1
    reset_sep
    raise "x" if tries < 2
  rescue RuntimeError
    retry
  end
end

def and_operand
  return unless $sep && reset_and_true

  copy = $sep
  copy.length # FIRES-1429 call.possible-nil-receiver
end

def const_set_call
  return unless SEP

  Object.const_set(:SEP, nil)
  copy = SEP
  copy.length # FIRES-1429 call.possible-nil-receiver
end

# A block given to `instance_eval` is read as any block: an empty one rebinds nothing.
def eval_block_kept
  return unless $sep

  [1].instance_eval { nil }
  copy = $sep
  copy.length # QUIET-1429
end

def control
  return unless $sep

  copy = $sep
  copy.length # QUIET-1429
end

module Prefs
  BAR = ARGV.empty? ? nil : ","
end

# `Prefs::BAR = nil` writes the constant `BAR` reads here (Ruby 4.0.5: NoMethodError on nil, after an
# already-initialized warning).
module Prefs
  if BAR
    Prefs::BAR = nil
    copy = BAR
    copy.length # FIRES-1429 call.possible-nil-receiver
  end
end
