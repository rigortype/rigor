# frozen_string_literal: true

# Issue #2196 — an `&&` / `||` / `and` / `or` in a value position the evaluator does not enter (an array element, a
# hash value, a call argument, an interpolation, a multi-value `return` or multiple assignment) evaluates its right
# operand under its left operand's edge, as the statement form does. The narrowing ends with the right operand: an
# element or argument after the operator reads the scope the operator started in. Each comment gives what Ruby 4.0.5
# answers.

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

# A bound local the left operand writes reads `Dynamic[top]` in the right operand, as the walk of an unentered `if`
# reads it: the walk applies no write. `left_write(true)` returns [2].
def left_write(raw)
  c = raw ? 1 : nil
  [(c = Integer("1", exception: false) if raw) && assert_type("Dynamic[top]", c) + 1]
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
