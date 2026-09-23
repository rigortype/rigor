require "rigor/testing"
include Rigor::Testing

# A block or lambda parameter shadows the outer local of the same name, wherever the closure sits. The
# statement evaluator enters a statement-level call's block and a statement-level lambda's body, but not a
# closure in a value position (a call argument, a receiver chain, a literal element) nor a `super` call's
# block, so such a body keeps the enclosing statement's scope, and before the fix its parameters read as the
# outer local. Every unmarked line is correct Ruby and MUST stay silent; the marked lines are genuine errors
# and MUST still fire.

def show(value) = value

# --- Unentered closures: each parameter here shadows an outer local that has no `+` / `upcase`. ---
def call_argument
  o = { x: 1 }
  show([1, 2].map { |o| o + 1 })
end

def call_argument_same_receiver_name
  h = { x: 1, y: 2 }
  show(h.transform_values { |h| h + 1 })
end

def receiver_chain
  o = { x: 1 }
  [1, 2].map { |o| o + 1 }.sum
end

def receiver_chain_inside_a_block
  h = { x: 1, y: 2 }
  [5].map { |e| [e].map { |h| h + 1 }.first }
end

def nested_in_an_argument
  h = { x: 1, y: 2 }
  show([5].map { |e| [e].map { |h| h + 1 } })
end

def literal_element
  o = { x: 1 }
  [[1, 2].map { |o| o + 1 }]
end

def lambda_argument
  o = { x: 1 }
  show(->(o) { o + 1 })
end

def block_local
  o = { x: 1 }
  show([1, 2].map { |e; o| o = e; o + 1 })
end

def destructured_parameter
  o = { x: 1 }
  h = { x: 1, y: 2 }
  show([[1, 2]].map { |(o, h)| o + h })
end

# The implicit `it` is not in Prism's local table, but it is the inner block's own parameter.
def implicit_it
  [["a", "b"]].each { show(it.map { it.upcase }) }
end

class ShadowingBase
  def run = yield(1)
end

class ShadowingSuper < ShadowingBase
  def run
    o = { x: 1 }
    super { |o| o + 1 }
  end
end

# An entered lambda is recorded with the enclosing scope, so its parameter list needs the boundary too.
def lambda_parameter_default
  o = { x: 1 }
  f = ->(o, b = (o + 1)) { b }
  f
end

# --- Statement positions: the evaluator enters these blocks already; the controls. ---
def statement_control
  o = { x: 1 }
  [1, 2].map { |o| o + 1 }
end

def assignment_control
  o = { x: 1 }
  r = [1, 2].map { |o| o + 1 }
  r
end

# --- Must still fire. The first shows a statement-level block still types its parameter from the
# signature; the second shows a value-position block still reads a CAPTURED (unshadowed) outer local at
# its enclosing binding — only the names a block introduces are shadowed. ---
def statement_parameter_misuse
  [1].map { |o| o.upcase } # GENUINE-UNDEFINED
end

def captured_outer_read
  o = { x: 1 }
  show([1, 2].map { |e| o.upcase }) # GENUINE-UNDEFINED
end

# --- What the reads bind to. A shadowing parameter of a value-position block is the block's own
# variable, unknown here because the block's body is never evaluated; a captured read keeps the
# enclosing binding. ---
def shadowing_parameter_binding
  o = { x: 1 }
  show([1, 2].map { |o| assert_type("Dynamic[top]", o) })
end

def captured_read_binding
  o = { x: 1 }
  show([1, 2].map { |e| assert_type("{ x: 1 }", o) })
end
