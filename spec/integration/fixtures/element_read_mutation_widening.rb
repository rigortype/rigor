require "rigor/testing"
include Rigor::Testing

# Issue #643 — a content mutator whose receiver is an ELEMENT READ
# (`c[0] << 5`, `b[0][0] << 1`) mutates an rvalue temp, so the receiver
# expression names no binding and the straight-line widening recorded
# nothing. The container kept the element's pin the mutation had just
# falsified: `c[0].last == 5` folded ALWAYS-FALSEY on a program that
# prints, and `b[0][0].first` answered `nil` on a program that holds an
# Integer.
#
# The element's pin is now widened one step INSIDE the container, at the
# position that was read, and the rebuilt container is written back to
# the local. The container's own arity survives — mutating an element
# cannot change how many elements the container has.

# --- The issue's own shape: a Union of literal containers as the
# element. Both members lose their arity; the outer Tuple keeps its. ---
def union_element_mutated(flag)
  c = [flag ? [1] : [2]]
  c[0] << 5
  assert_type("[Array[1 | Dynamic[top] | Integer] | Array[2 | Dynamic[top] | Integer]]", c)
  puts "hit" if c[0].last == 5
  c
end

# --- The nested plain-literal twin. Two index hops reach the innermost
# empty literal. ---
def nested_literal_mutated
  b = [[[]]]
  b[0][0] << 1
  assert_type("Array[Dynamic[top] | Integer]", b[0][0])
  b
end

# --- `first` / `last` name a position too, and so does `dig`. ---
def reader_forms_mutated
  xs = [[1], [2]]
  xs.first << 3
  xs.last << 4
  assert_type("[Array[1 | Dynamic[top] | Integer], Array[2 | Dynamic[top] | Integer]]", xs)

  ys = [[[5]]]
  ys.dig(0, 0) << 6
  assert_type("[[Array[5 | Dynamic[top] | Integer]]]", ys)
  ys
end

# --- A non-literal index cannot be attributed to one position, so every
# position widens. Under-approximating here would leave the FP in place
# for the position actually mutated. ---
def dynamic_index_mutated(i)
  zs = [[1], [2]]
  zs[i] << 3
  assert_type("[Array[1 | Dynamic[top] | Integer], Array[2 | Dynamic[top] | Integer]]", zs)
  zs
end

# --- A mutator reached through a METHOD CALL rather than a local has no
# binding to write back to; nothing changes. `parts` is a call, so the
# local `kept` below it is untouched by this statement. ---
def non_local_receiver_unchanged
  kept = [[1]]
  parts[0] << 5
  assert_type("[[1]]", kept)
  kept
end

def parts
  [[1]]
end

# --- The must-still-fire control. Nothing mutates this container, so the
# element's pin is still justified and the fold has to survive; without
# it the silence above could be a rule that stopped firing. ---
def unmutated_element_still_folds
  c = [[1]]
  puts "one" if c[0].last == 1 # GENUINE-TRUTHY
  c
end
