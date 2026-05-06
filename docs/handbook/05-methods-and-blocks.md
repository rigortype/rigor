# Methods and blocks

[← Tuples and hash shapes](04-tuples-and-shapes.md) · Next: [Classes →](06-classes.md)

This chapter covers what Rigor knows about method calls — the
receiver's type, the argument types, the inferred return
type, and the block parameters when a block is attached.

## Method dispatch — what Rigor sees at a call site

When Rigor encounters `receiver.method(args, &block)`, it
runs through a fixed sequence of dispatch tiers, taking the
first one that produces a result:

1. **Constant folding.** Every argument is a `Constant<...>`
   or a tuple of constants, the receiver is a known
   nominal class, and the method is in the per-class
   "pure" catalog. Rigor invokes the method at lint time
   and returns the result. `1 + 2` → `Constant<3>`,
   `[1, 2, 3].first` → `Constant<1>`.
2. **Shape dispatch.** The receiver carries a `Tuple` /
   `HashShape` / `IntegerRange` / refinement and the method
   has a per-shape rule. `Tuple[A, B, C].size` →
   `Constant<3>`; `int<0, max>.zero?` → `Constant<true> |
   Constant<false>`.
3. **RBS dispatch.** The class has an RBS sig for the method.
   Argument types are checked against the parameter contract
   (more on this below); the return type is read from the sig
   and may be tightened by `RBS::Extended` directives.
4. **In-source dispatch.** The class has no RBS but Rigor
   discovered a `def` (or `define_method`, `attr_*`) in the
   project. Parameter types are not checked (no contract);
   the return type is inferred from the method body.
5. **Fallback.** None of the above — the call returns
   `Dynamic[Top]` and stays silent.

The cascading "first match wins" structure is why a method
with a tight RBS sig + an `RBS::Extended` directive overrides
the in-source body's inferred return type. Tightening at the
sig level is the supported way to teach Rigor about a
domain-specific method whose return type is narrower than
RBS expresses.

## Argument typing — `call.argument-type-mismatch`

When the method has an RBS sig (or an `RBS::Extended`
parameter override), Rigor checks each positional / keyword
argument against the declared parameter type:

```rbs
class Slug
  %a{rigor:v1:param: id is non-empty-string}
  def normalise: (::String id) -> ::String
end
```

```ruby
Slug.new.normalise("hello")  # OK — Constant<"hello"> accepted
                             # by non-empty-string

Slug.new.normalise("")       # error: argument-type-mismatch
                             # ("" is the one value
                             # non-empty-string excludes)

Slug.new.normalise(some_str) # OK if Rigor cannot prove some_str
                             # is empty; Rigor stays silent on
                             # "could be either" cases.
```

`call.argument-type-mismatch` only fires when Rigor can
**prove** the argument cannot satisfy the parameter contract.
"Possibly empty" stays silent — the no-false-positives rule.

## Arity — `call.wrong-arity`

When the receiver class is statically known and the method is
discoverable (RBS sig or in-source `def`), Rigor checks the
number of arguments against the method's arity:

```ruby
[1, 2, 3].rotate(1, 2)
# error: wrong number of arguments to `rotate' on Array
#        (given 2, expected 0..1)
```

Arity checking respects optional positional, splat, keyword
arguments, and overload signatures. When the method is
overloaded, every overload that accepts the given arity is a
candidate — Rigor only flags arity when **no** overload
accepts.

## `call.undefined-method`

When the receiver class is statically known and the method is
not in any of (RBS sig, in-source `def`, in-source attr,
`Data.define` accessor), Rigor flags the call:

```ruby
"hello".no_such_method
# error: undefined method `no_such_method' for "hello"
```

The rule is **deliberately conservative**: a call only fires
when the receiver type is statically known and the method
catalogue is enumerable. `Dynamic[Top]` receivers, implicit-
self calls inside method bodies, and constant-decl alias
classes (`YAML` → `Psych`) are silenced.

## `call.possible-nil-receiver`

When the receiver's type is `T | nil` and the method called
on it is not defined on `NilClass`, Rigor flags it:

```ruby
def shout(name)
  name.upcase  # warning if name: String?
end
```

The fix is usually a guard:

```ruby
def shout(name)
  return "" if name.nil?
  name.upcase  # name: String now
end
```

This rule is one of the highest-value diagnostics Rigor ships
— it catches the entire family of `NoMethodError on nil`
crashes that pepper any non-trivial Ruby code base.

## Return-type inference for in-source methods

When you write a `def` without an RBS sig, Rigor infers the
return type from the method body. The inferred type is
whatever the last expression evaluates to:

```ruby
def double(n)
  n * 2
end

double(5)   # Constant<10>  — Rigor folds the call
```

When the body has multiple branches, the return type is the
union of every reachable terminal expression:

```ruby
def kind(x)
  if x.is_a?(Integer)
    :int
  elsif x.is_a?(String)
    :str
  end
end

kind(7)        # Constant<:int>
kind("hi")     # Constant<:str>
kind(:nope)    # Constant<nil>  — the implicit nil from
               # the if's missing else branch
```

`return` mid-body works as expected; explicit `raise` excludes
that branch from the union (a `bot` carrier internally).

## `def.return-type-mismatch`

When a method has both an RBS-declared return type and an
inferred one, Rigor checks that the inferred fits the
declared:

```rbs
class Slug
  def normalise: (::String) -> ::String
end
```

```ruby
class Slug
  def normalise(s)
    s.empty? ? nil : s.upcase   # warning:
                                # def.return-type-mismatch
                                # (declared String, inferred
                                # String | nil)
  end
end
```

The rule is the symmetric counterpart of
`call.argument-type-mismatch`: argument-side is "the caller
gave me a wrong type"; return-side is "I gave my caller a
wrong type."

## Block parameters

When a method takes a block, Rigor binds the block parameters
based on the receiver method's signature. Every block-using
method in the bundled catalog has a per-method rule:

```ruby
[1, 2, 3].each do |n|
  assert_type(n, "Constant<1> | Constant<2> | Constant<3>")
end

%w[a b c].each_with_index do |word, idx|
  assert_type(word, "Constant<\"a\"> | Constant<\"b\"> | Constant<\"c\">")
  assert_type(idx,  "non-negative-int")
end

{name: "Alice", age: 30}.each_pair do |key, value|
  assert_type(key,   "Constant<:name> | Constant<:age>")
  assert_type(value, "Constant<\"Alice\"> | Constant<30>")
end
```

Per-position binding works for tuples, hash shapes, and
ranges. When the receiver is widened (`Array[T]` instead of
`Tuple[…]`), the block parameter is the element type `T`.

When the receiving method does not have a per-method rule,
the block parameter falls back to `Dynamic[Top]`. Custom
block-using methods you write in your project's source are
seen by the in-source dispatch tier — Rigor walks the body to
infer the parameter type from `yield` calls — but that
analysis is more limited than the catalogued built-ins.

## Numbered parameters and `it`

`_1`, `_2`, ..., and Ruby 3.4's `it` are bound exactly like
explicit parameters:

```ruby
[1, 2, 3].each { _1.succ }
# _1: Constant<1> | Constant<2> | Constant<3>

[10, 20, 30].each { it.to_s }
# it: same as the explicit form
```

## Block-local declarations (`do |i; x|`)

The `;`-prefixed names introduce a fresh block-local
variable that shadows any outer local of the same name. Rigor
binds these locals to `Constant<nil>` at block entry — Ruby's
runtime semantics — and treats writes inside the block as
local to the block:

```ruby
x = 100
[1, 2, 3].each do |i; x|
  # x: Constant<nil>  at this point — the block-local shadow
  x = i * 2
  # x: Constant<2> | Constant<4> | Constant<6>
end

assert_type(x, "Constant<100>")  # outer x untouched
```

## Closure escape and captured locals

When a block captures an outer local, the block's writes to
that local affect the post-call view of the local. For known
non-escaping methods (`Array#each`, `tap`, …) the post-call
narrowing is preserved; for escaping methods (`Thread.new`,
`define_method`, …) the analyzer drops the narrowing on
captured locals because the block could fire arbitrarily
later.

This is the conservative call: better to widen too much than
to claim narrowed-after-escape facts that the runtime might
violate.

## What's next

Chapter 6 covers the class side: how Rigor types `self`,
constant lookup, `attr_*` declarations, and the
class-vs-instance method distinction.

[← Tuples and hash shapes](04-tuples-and-shapes.md) · Next: [Classes →](06-classes.md)
