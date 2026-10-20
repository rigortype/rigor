# frozen_string_literal: true

# Issue #1924 — an `if` / `elsif` / `unless` / ternary in a value position the evaluator does not enter (an array
# element, a call argument, a hash value, an interpolation, a receiver) narrows its branches by its condition's edges,
# and a write the condition makes reaches them, so neither a local's old type nor a narrowing of it does. Since #2056
# the scope index evaluates such a conditional as the statement form does, so the written local reads its new value
# (#1924 first read it as `Dynamic[top]`). Each comment gives what Ruby 4.0.5 answers.

# `or_assign("a")` returns ["A"], `or_assign(nil)` ["D"].
def or_assign(raw)
  x = raw ? "a" : nil
  [if (x ||= "d").empty? then 0 else x.upcase end]
end

# `plain_write(true, "a")` returns ["A"].
def plain_write(raw, s)
  x = raw ? 1 : nil
  [if (x = s ? String(s) : nil).nil? then 0 else x.upcase end]
end

# `and_assign(1)` returns ["1"], `and_assign(nil)` [0].
def and_assign(raw)
  x = raw ? 1 : nil
  [if (x &&= String(x)).nil? then 0 else x.upcase end]
end

# `op_assign(true)` returns [false].
def op_assign(raw)
  x = raw ? 1 : 2
  [if (x += 0.5).zero? then 0 else x.nan? end]
end

# `multi_assign(true, "a")` returns ["A"].
def multi_assign(raw, s)
  x = raw ? 1 : nil
  [if ((x, _ = (s ? String(s) : nil), 1); x.nil?) then 0 else x.upcase end]
end

# The write is in the `elsif` condition only. `elsif_write(true, "a")` returns ["A"].
def elsif_write(raw, s)
  x = raw ? 1 : nil
  [if raw.nil? then 0 elsif (x = s ? String(s) : nil).nil? then 1 else x.upcase end]
end

# `nested(nil, true)` returns ["D"], `nested_element(nil)` [["D"]].
def nested(raw, t)
  x = raw ? "a" : nil
  [if t then (if (x ||= "d").empty? then 0 else x.upcase end) end]
end

def nested_element(raw)
  x = raw ? "a" : nil
  [[if (x ||= "d").empty? then 0 else x.upcase end]]
end

# The `then` and the `else` of an `unless`: `unless_write(nil)` returns ["D"], `unless_else(nil)` ["D"].
def unless_write(raw)
  x = raw ? "a" : nil
  [unless (x ||= "d").empty? then x.upcase end]
end

def unless_else(raw)
  x = raw ? "a" : nil
  [unless (x ||= "d").empty? then x.upcase else x.size end]
end

# `ternary_argument(nil)` returns ["D"].
def ternary_argument(raw)
  x = raw ? "a" : nil
  Array((x ||= "d").empty? ? 0 : x.upcase)
end

# A hash value, an interpolation and a receiver: with `raw = nil`, {k: "D"}, "D" and 1.
def hash_value(raw)
  x = raw ? "a" : nil
  { k: (if (x ||= "d").empty? then 0 else x.upcase end) }
end

def interpolation(raw)
  x = raw ? "a" : nil
  "#{if (x ||= "d").empty? then 0 else x.upcase end}"
end

def receiver(raw)
  x = raw ? "a" : nil
  (if (x ||= "d").empty? then "" else x.upcase end).size
end

# The written local reads the written value in the branch, whether it was bound before the condition or not.
# `widened(true, "a")` and `first_bound("a")` each return ["A"].
def widened(raw, s)
  x = raw ? 1 : nil
  [if (x = String(s)).empty? then 0 else assert_type("String", x).upcase end]
end

def first_bound(s)
  [if (z = String(s)).empty? then 0 else assert_type("String", z).upcase end]
end

# Nor does a later condition narrow it from one: `z.nil?` never holds, and `first_bound_elsif("a")` returns [1].
def first_bound_elsif(s)
  [if (z = String(s)).empty? then 0 elsif z.nil? then z.upcase else 1 end]
end

# Control: a condition that writes no local still narrows. `no_write("a")` returns ["A"].
def no_write(raw)
  x = raw ? String(raw) : nil
  [if x.nil? then 0 else assert_type("String", x).upcase end]
end

# Control: the write's own `nil` still reaches the branch, where Ruby raises NoMethodError.
def write_nil(raw)
  x = raw ? 1 : nil
  [if (x = nil).nil? then x.upcase end] # GENUINE-UNDEFINED
end

# Control: a branch the condition does not rule `nil` out of still reports the possible `nil` receiver. `unguarded("")`
# returns [0]; `unguarded(nil)` raises NoMethodError.
def unguarded(raw)
  x = raw ? String(raw) : nil
  [if x&.empty? then 0 else x.upcase end] # GENUINE-NIL
end
