# frozen_string_literal: true

# Issues #2196 and #2056 — an `&&` / `||` / `and` / `or`, an `if` / ternary or a `while` in a value position the
# evaluator does not enter (an array element, a hash value, a call argument, an interpolation, a multi-value `return`
# or multiple assignment) is read as its statement form reads it: the right operand under its left operand's edge, a
# write in either operand (in a block or a call argument too) from where it runs, and an instance variable a call in
# the right operand may set as the statement form reads it after that call. The narrowing ends with the right operand:
# an element or argument after the operator reads the scope the operator started in. Each comment gives what Ruby
# 4.0.5 answers.

def take(*args, **kwargs) = [args, kwargs]

# `statement(1)` returns 2, `statement(nil)` nil.
def statement(raw)
  c = raw ? 1 : nil
  c && (assert_type("1", c) + 1)
end

# `element(1)` returns [2], `element(nil)` [nil].
def element(raw)
  c = raw ? 1 : nil
  [c && (assert_type("1", c) + 1)]
end

# `nested(1)` returns [[2]].
def nested(raw)
  c = raw ? 1 : nil
  [[c && c + 1]]
end

# `hash_value(1)` returns {a: 2}.
def hash_value(raw)
  c = raw ? 1 : nil
  { a: c && c + 1 }
end

# `argument(1)` returns [[2], {}], `keyword_argument(1)` [[], {k: 2}].
def argument(raw)
  c = raw ? 1 : nil
  take(c && c + 1)
end

def keyword_argument(raw)
  c = raw ? 1 : nil
  take(k: c && c + 1)
end

# `interpolation(1)` returns "2".
def interpolation(raw)
  c = raw ? 1 : nil
  "#{c && c + 1}"
end

# `multi_return(1)` returns [1, 2], `multi_assign(1)` [1, 2].
def multi_return(raw)
  c = raw ? 1 : nil
  return c, c && c + 1
end

def multi_assign(raw)
  c = raw ? 1 : nil
  a, b = 1, (c && c + 1)
  [a, b]
end

# `or_operand(1)` returns [2], `or_operand(nil)` [true].
def or_operand(raw)
  c = raw ? 1 : nil
  [c.nil? || (assert_type("1", c) + 1)]
end

# `and_keyword(1)` returns [2], `or_keyword(1)` [2].
def and_keyword(raw)
  c = raw ? 1 : nil
  [(c and c + 1)]
end

def or_keyword(raw)
  c = raw ? 1 : nil
  [(c.nil? or c + 1)]
end

# The left operand of a chained `&&` narrows the operands after it: `chained(1)` returns [3].
def chained(raw)
  c = raw ? 1 : nil
  d = raw ? 2 : nil
  [c && d && c + d]
end

# The herb shape. `herb_shape(nil)` returns ["f", nil, nil].
def herb_shape(location)
  column = location&.start&.column
  ["f", location&.start&.line, column && (column + 1)]
end

# A local the left operand writes reads the written value in the right operand. `left_write(true, "1")` returns [2].
def left_write(raw, s)
  c = raw ? "a" : nil
  [(c = Integer(s, exception: false)) && assert_type("Integer", c) + 1]
end

# A write in the right operand is read from where it runs. Each runs without error for "s" and for nil:
# `right_write(true)` returns [false], `or_right_write(nil)` [true].
def right_write(raw)
  c = raw ? "s" : nil
  [c && (c = c.size; c.even?)]
end

def right_write_argument(raw)
  c = raw ? "s" : nil
  take(c && (c = c.size; c.even?))
end

def right_write_interpolation(raw)
  c = raw ? "s" : nil
  "#{c && (c = c.size; c.even?)}"
end

def or_right_write(raw)
  c = raw ? "s" : nil
  [c.nil? || (c = c.size; c.even?)]
end

def and_keyword_right_write(raw)
  c = raw ? "s" : nil
  [(c and (c = c.size; c.even?))]
end

def right_multi_write(raw)
  c = raw ? "s" : nil
  [c && (c, _d = c.size, 1; c.even?)]
end

def right_block_write(raw)
  c = raw ? "s" : nil
  [c && c.then { |v| c = v.size } && c.even?]
end

def block_read_after_write(raw)
  c = raw ? "s" : nil
  { k: c && (c = c.size).then { c.even? } }
end

# `||`'s right operand writes the local its left operand ruled out. `or_default(nil)` returns ["D"].
def or_default(raw)
  x = raw ? String(raw) : nil
  [x || (x = "d"; x.upcase)]
end

def nil_default(raw)
  x = raw ? String(raw) : nil
  [x.nil? && (x = "d"; x.upcase)]
end

# A write in a call argument of an earlier conjunct. `argument_write(nil)` returns ["D"].
def argument_write(raw)
  x = raw ? String(raw) : nil
  [x.nil? && take(x = "d") && x.upcase]
end

# A local the left operand writes and was bound to another type before. `rebound(1, "a")` returns ["A"].
def rebound(raw, s)
  x = raw ? 1 : 2
  [(x = String(s)) && x.upcase]
end

# An `if`, a ternary and a `while` in a value position. `if_right_write("s")` returns [false], `ternary_right_write("s")`
# [false], `while_write(nil)` [nil].
def if_right_write(raw)
  c = raw ? "s" : nil
  [if c then (c = c.size; c.even?) end]
end

def ternary_right_write(raw)
  c = raw ? "s" : nil
  [c ? (c = c.size; c.even?) : 0]
end

def while_write(raw)
  x = raw ? String(raw) : nil
  [while x.nil? do x = "d"; x.upcase end]
end

# A call in the right operand may set an instance variable its left operand narrowed; a condition may write one, or a
# global. `IvarHolder.new(nil).set_by_call` returns ["S"], `IvarHolder.new(true).reset_by_call` [2],
# `IvarHolder.new(nil).written("a")` ["A"], `global_written("a")` ["A"].
class IvarHolder
  def initialize(raw)
    @x = raw ? String(raw) : nil
    @y = raw ? "s" : 1
  end

  def set! = (@x = "s"; true)

  def reset! = (@y = 1)

  def set_by_call
    [@x || (set!; @x.upcase)]
  end

  def reset_by_call
    [@y.is_a?(String) && (reset!; 1 + @y)]
  end

  def written(s)
    [if (@x = s ? String(s) : nil).nil? then 0 else @x.upcase end]
  end
end

def global_written(s)
  [if ($and_or_global = s ? String(s) : nil).nil? then 0 else $and_or_global.upcase end]
end

# `unless` and `until` too. `unless_right_write("s")` returns [false], `until_right_write("s")` [false].
def unless_right_write(raw)
  c = raw ? "s" : nil
  [unless c.nil? then (c = c.size; c.even?) end]
end

def until_right_write(raw)
  c = raw ? "s" : nil
  [until c.nil?; c = c.size; break c.even?; end]
end

# A code body inside such a construct (a `def`, a `class` / `module` / `class << self` body, a `Class.new` /
# `Struct.new` / `Data.define` / `Module.new` block) resolves its constants and `self` in the class around it, as
# before #2196: `AND_OR_BAZ` is the nested `2`, not the top-level `nil`. With `ENV["X"]` set, `Holder::C1.new.m`
# returns 3 and `Holder.new.inner` 4; `Holder::C5.new.m` raises NoMethodError.
AND_OR_BAZ = nil

module AndOrNesting
  AND_OR_BAZ = 2

  class Holder
    def bar = 1

    C1 = ENV["X"] ? Class.new { def m = AND_OR_BAZ.succ } : nil
    C2 = (ENV["X"] && Struct.new(:a) { def m = AND_OR_BAZ.succ })
    C3 = ENV["X"] || Module.new { def self.m = AND_OR_BAZ.succ }
    C4 = [ENV["X"] && Data.define(:a) { def m = AND_OR_BAZ.succ }]
    C6 = [ENV["X"] && (class Inner; AND_OR_BAZ.succ; end)]
    C7 = [ENV["X"] && (module InnerM; AND_OR_BAZ.succ; end)]
    C9 = [ENV["X"] && (class << self; AND_OR_BAZ.succ; end)]
    C10 = [ENV["X"] && Class.new(StandardError) { def message = AND_OR_BAZ.succ.to_s }]
    C5 = ENV["X"] ? Class.new { def m = AND_OR_BAZ.succ.zork } : nil # GENUINE-UNDEFINED

    def defined_inside(c)
      [c && (def inner = self.bar.succ + AND_OR_BAZ)]
    end
  end
end

# `||`'s right operand writes `x` before it tests it, so the test always holds, in either form.
def or_write_then_test(raw)
  x = raw ? String(raw) : nil
  [x || (x = "d"; x ? 1 : 2)] # ALWAYS-TRUTHY
end

def or_write_then_test_statement(raw)
  x = raw ? String(raw) : nil
  x || (x = "d"; x ? 1 : 2) # ALWAYS-TRUTHY
end

# A write in a block of an earlier conjunct is read as the statement form reads it: the block may not run, so `x`
# may still be `nil`. Ruby runs this block once, so `block_write_conjunct(nil)` returns ["D"]; both forms report it.
def block_write_conjunct(raw)
  x = raw ? String(raw) : nil
  [x.nil? && [1].each { x = "d" } && x.upcase] # STATEMENT-FORM-NIL
end

def block_write_conjunct_statement(raw)
  x = raw ? String(raw) : nil
  x.nil? && [1].each { x = "d" } && x.upcase # STATEMENT-FORM-NIL
end

def block_write_condition(raw)
  x = raw ? String(raw) : nil
  [if x.nil? && [1].each { x = "d" } then x.upcase end] # STATEMENT-FORM-NIL
end

def block_write_condition_statement(raw)
  x = raw ? String(raw) : nil
  if x.nil? && [1].each { x = "d" } then x.upcase end # STATEMENT-FORM-NIL
end

# Positive controls: a write in the right operand is a write, and the left operand of a chained `&&` keeps its
# possible `nil`. `right_writes_nil(1)` and `chained_left(nil)` raise NoMethodError.
def right_writes_nil(raw)
  c = raw ? 1 : nil
  [c && (c = nil; c + 1)] # GENUINE-UNDEFINED
end

def left_writes_nil(raw)
  x = raw ? "s" : nil
  [(x = nil; true) && x.upcase] # GENUINE-UNDEFINED
end

def chained_left(raw)
  c = raw ? 1 : nil
  [c.zero? && c && 1] # GENUINE-NIL
end

# Positive controls: the narrowing does not outlive the right operand. `after_element(1)` returns [1, 2];
# `after_element(nil)` raises NoMethodError on the second element.
def after_element(raw)
  c = raw ? 1 : nil
  [c && 1, c + 1] # GENUINE-NIL
end

def after_argument(raw)
  c = raw ? 1 : nil
  take(c && 1, c + 1) # GENUINE-NIL
end

def after_hash_value(raw)
  c = raw ? 1 : nil
  { a: c && 1, b: c + 1 } # GENUINE-NIL
end

def after_interpolation(raw)
  c = raw ? 1 : nil
  "#{c && 1}#{c + 1}" # GENUINE-NIL
end

# `||`'s right operand runs on the falsey edge, where `c` is nil: `or_falsey(nil)` raises NoMethodError.
def or_falsey(raw)
  c = raw ? 1 : nil
  [c || c + 1] # GENUINE-UNDEFINED
end
