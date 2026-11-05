require "rigor/testing"
include Rigor::Testing

# Issue #1246 — a closure in a value position (a call argument, a receiver chain, a literal element, a `super`
# call's block) is never entered by the statement evaluator, so its body takes its scopes from the scope index's
# fallback walk, which threads none of the body's writes. A captured outer local the body rebinds therefore read
# at its pre-statement binding after the write, and a `def` or `class` body written inside such a closure read its
# own parameters and locals as the enclosing statement's locals of the same name. Every unmarked line is correct
# Ruby and MUST stay silent; the marked lines are genuine errors and MUST still fire.

def show(value) = value

# --- A captured local the body rebinds. ---
def captured_rebind_in_argument
  x = 1
  show([1].map { x = "s"; x.upcase })
end

def captured_rebind_with_parameter
  w = 1
  show([1].map { |v| w = "s"; w.upcase })
end

def captured_rebind_in_receiver_chain
  x = 1
  [1].map { x = "s"; x.upcase }.first
end

def captured_rebind_in_literal_element
  x = 1
  [[1].map { x = "s"; x.upcase }]
end

def captured_rebind_in_lambda_argument
  x = 1
  show(-> { x = "s"; x.upcase })
end

# The write sits in a closure nested in the body; it runs before the read on the second iteration.
def captured_rebind_in_nested_closure
  n = 1
  show([1].map { [2].each { n = "s" }; n.upcase })
end

def captured_rebind_in_class_new
  w = 1
  show(Class.new { w = "s"; w.upcase })
end

class CapturedRebindBase
  def run = yield(1)
end

class CapturedRebindSuper < CapturedRebindBase
  def run
    x = 1
    super { x = "s"; x.upcase }
  end
end

# --- A `def` / `class` body opens its own local table. ---
def def_in_class_new
  o = { x: 1 }
  show(Class.new { def call(o) = o + 1 })
end

def def_in_plain_block
  o = { x: 1 }
  show([1].each { def zz(o) = o + 1 })
end

def class_body_local_in_block
  o = { x: 1 }
  show([1].each { class CapturedRebindInner; o = 1; o + 1; end })
end

# --- Statement positions: the evaluator enters these already; the controls. ---
def statement_control
  x = 1
  [1].map { x = "s"; x.upcase }
end

# --- Must still fire. A statement-level block still types its parameter from the signature, and a captured local
# the value-position body only reads keeps its enclosing binding. ---
def statement_parameter_misuse
  [1].map { |o| o.upcase } # GENUINE-UNDEFINED
end

def captured_read_only
  r = 1
  show([1].map { r.upcase }) # GENUINE-UNDEFINED
end

# --- What the reads bind to. A rebound captured local reads `Dynamic[top]`: the walk does not thread the write.
# A read-only capture keeps the enclosing binding. ---
def rebound_capture_binding
  x = 1
  show([1].map { x = "s"; assert_type("Dynamic[top]", x) })
end

def read_only_capture_binding
  r = 1
  show([1].map { assert_type("1", r) })
end
