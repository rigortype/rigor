# frozen_string_literal: true

# Issue #2196 — a project class whose superclass is a core class answers a method that class declares from that
# class, never from the private `Kernel` method of the same name. `Kernel#select` returns `Array[String]`, so reading
# `select { … }` on an `Array` subclass through it typed every element `String`. The engine cannot type `Array#select`
# on a subclass with no type arguments, so the call stays `Dynamic[top]`. Each comment gives what Ruby 4.0.5 answers.

# `FieldList.new([1, 2]).pick(1)` returns [1], and `first_ok(1)` [2] for elements whose `ok?` holds above 1.
class FieldList < Array
  def pick(n)
    assert_type("Dynamic[top]", select { |f| f == n })
  end

  def first_ok(n)
    fields = select { |f| f.ok?(n) }
    Array(fields.detect { |f| f.errors.size.zero? } || fields.first)
  end

  # A name only `Kernel` declares still resolves through it: `say` returns nil.
  def say = assert_type("nil", puts("x"))
end

# `FieldTable.new.merge!(a: 1).pick` returns {a: 1}.
class FieldTable < Hash
  def pick = assert_type("Dynamic[top]", select { |_k, v| v })
end
