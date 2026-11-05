# frozen_string_literal: true

require "rigor/testing"
include Rigor::Testing

# Issue #2855 — a `Class` or `Module` nominal against a `singleton(X)`
# parameter is a class object whose identity inference lost, not a wrong
# value kind, so `call.argument-type-mismatch` withholds it. `Object`,
# `BasicObject` and `Kernel` mean any value, so they still report.

# The issue's shapes: a `const_get` result kept by `is_a?(Class)`, and an
# `is_a?(Module)` guard on an untyped value.
SHAPES = Object.constants.filter_map { |n| c = Object.const_get(n); c if c.is_a?(Class) && c < Shape }

def each_shape_fields = SHAPES.each { |klass| Registry.fields_for(klass) }

def module_guarded(x) = (x.is_a?(Module) ? Registry.fields_for(x) : nil)

# Each of the two, read from a declared return.
def declared_class_and_module
  assert_type("Array[Symbol]", Registry.fields_for(Registry.a_class))
  Registry.fields_for(Registry.a_module)
end

# A parameter whose union admits class objects (`singleton(Shape)?`).
def optional_parameter = Registry.optional_fields_for(Registry.a_class)

# The multi-overload path admitted a `Class` before the fix and still does.
def overloaded_class_argument = assert_type("Symbol", Registry.lookup(Registry.a_class))

# Controls: an instance of an unrelated class, and an unrelated class object.
def unrelated_instances
  Registry.fields_for(1) # GENUINE-MISMATCH
  Registry.fields_for("s") # GENUINE-MISMATCH
  Registry.fields_for(Registry.an_integer) # GENUINE-MISMATCH
  Registry.fields_for(String) # GENUINE-MISMATCH
end

# Controls: the any-value nominals are not class objects.
def any_values
  Registry.fields_for(Object.new) # GENUINE-MISMATCH
  Registry.fields_for(BasicObject.new) # GENUINE-MISMATCH
  Registry.fields_for(Registry.an_object) # GENUINE-MISMATCH
  Registry.fields_for(Registry.a_basic_object) # GENUINE-MISMATCH
  Registry.fields_for(Registry.a_kernel) # GENUINE-MISMATCH
  Registry.name_or_shape(Registry.an_object) # GENUINE-MISMATCH
end

# The rest of a union is still judged: its `Integer` member is rejected.
def class_or_integer = Registry.fields_for(Registry.class_or_integer) # GENUINE-MISMATCH

def related_class_object = Registry.fields_for(Circle)
