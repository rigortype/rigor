# Classes

[← Methods and blocks](05-methods-and-blocks.md) · Next: [RBS and `RBS::Extended` →](07-rbs-and-extended.md)

This chapter covers class-side typing — what `self` means in
different positions, how constants are resolved, and how
Rigor reads `attr_*` and `Data.define` declarations.

## Instance-side and class-side `self`

Inside an instance method body, `self` is a `Nominal[T]` of
the enclosing class:

```ruby
class User
  def name
    self      # Nominal[User]
  end
end
```

Inside a singleton method body (`def self.foo` or
`def User.foo`), `self` is a `Singleton[T]` — the class
object itself, not an instance:

```ruby
class User
  def self.find(id)
    self    # Singleton[User]
  end
end

User       # Singleton[User]
User.find(1)  # Nominal[User]  (declared by RBS)
User.new      # Nominal[User]
```

The distinction matters for method dispatch: instance methods
run on `Nominal[User]`, singleton methods run on
`Singleton[User]`. Rigor reads the right side of the colon in
RBS sigs (`def self.find: (Integer) -> User`) to know which
side a method lives on.

## Constants

Constant lookup walks four sources, in this order:

1. **Lexical scope.** If `Foo` is referenced inside
   `class A; module B; ...`, Rigor looks for `A::B::Foo`,
   `A::Foo`, `Foo`.
2. **RBS-core and bundled stdlib.** `String`, `Integer`,
   `Symbol`, `Array`, `Pathname`, `URI`, `OptParse`, `JSON`,
   `YAML`, etc.
3. **Project RBS.** `sig/` files in your project add to the
   lookup.
4. **In-source class discovery.** When no RBS exists, Rigor
   walks `class Foo`, `module Bar`, and constant assignments
   (`MAX = 100`).

```ruby
MAX = 100
class Counter
  def initial = MAX
end

Counter.new.initial   # Constant<100>  — the constant value
                      # propagates through the in-source
                      # class lookup
```

For constants whose right-hand side Rigor can fold, the
constant carries a `Constant<value>` type. For others, it
carries the wider RBS-erased form.

## `attr_reader`, `attr_writer`, `attr_accessor`

Rigor reads `attr_*` declarations and treats them as method
definitions. The reader's return type matches the
corresponding ivar's inferred type:

```ruby
class User
  attr_reader :name

  def initialize(name)
    @name = name
  end
end

u = User.new("Alice")
u.name    # Constant<"Alice">  — through in-source dispatch +
          # ivar tracking
```

`attr_writer` exposes the setter; `attr_accessor` exposes
both. The setter's argument type is whatever the call site
provides; Rigor does not yet check writes against a declared
ivar type (that would need the `def.ivar-write-mismatch` rule
queued for v0.1.x).

## Instance variables across methods

Rigor accumulates ivar facts across all methods in a class:

```ruby
class Counter
  def initialize
    @count = 0    # @count: Constant<0> after init
  end

  def bump
    @count += 1   # @count rebound to int<1, max>
  end

  def value
    @count        # int<0, max>  (union of seen writes)
  end
end
```

The ivar type at each read site is the union of every
statically-visible write — including writes from a different
method on the same class.

## `Data.define`

`Data.define` produces a small immutable struct. Rigor
recognises the declaration and surfaces the constructor
arity, the per-field accessors, and the resulting class
type:

```ruby
Point = Data.define(:x, :y)

p = Point.new(x: 3, y: 4)
assert_type(p, "Nominal[Point]")
assert_type(p.x, "Constant<3>")
assert_type(p.y, "Constant<4>")
```

The discovery walks `define_method`-style block bodies too,
so `Point = Data.define(:x, :y) do ... end` still works.
Override-aware initializer dispatch (where the block redefines
`#initialize`) is queued for v0.1.x — today the synthesized
keyword-argument constructor wins.

## `Struct.new`

`Struct.new(*Symbol)` produces a positional-arg constructor
plus the same accessors as `Data.define`. Rigor handles both
shapes:

```ruby
Coord = Struct.new(:x, :y)

c = Coord.new(10, 20)
assert_type(c.x, "Constant<10>")
assert_type(c.y, "Constant<20>")
```

`Struct` adds mutability (the accessors are also writers), so
ivar-style accumulation applies. `Data` is read-only.

## Inheritance and method resolution

When you call a method on `Nominal[Subclass]`, Rigor walks
the class hierarchy: subclass's RBS / in-source body first,
then each ancestor's RBS / body, then included modules in
their declaration order. The first one to define the method
wins.

The hierarchy is read from:

- RBS `class Foo < Bar` declarations.
- In-source `class Foo < Bar` lines.
- `include` / `prepend` / `extend` calls Rigor walked.

When the hierarchy is statically incomplete (a class
references a parent Rigor cannot locate), the receiver type
falls back to the deepest known ancestor — never to
`Dynamic[Top]` for a class Rigor saw the declaration of.

## `class` and `singleton(C)` types

Method signatures sometimes return "the class object itself":

```rbs
class Foo
  def self.factory: () -> Foo            # returns an instance
  def self.subclasses: () -> Array[singleton(Foo)]  # returns class objects
end
```

`singleton(Foo)` is the type of the class object `Foo`.
`Singleton[Foo]` (Rigor's internal carrier display form) is
the same idea. `Foo` (in `Array[Foo]`) means "an instance of
`Foo`" / `Nominal[Foo]`.

Calling an instance method on a `singleton(Foo)` is an error
unless `Foo` itself defines that singleton method — `String`
is `singleton(String)`, `String#upcase` is on instances, so
`String.upcase` flags `call.undefined-method`.

## Custom `case_eq` (`===`)

Rigor recognises `===` for `Class` / `Module` / `Range` /
`Regexp` — these are the standard `case x; when …` shapes.
Custom `case_eq` implementations on user classes are NOT
recognised:

```ruby
class IPv4
  def self.===(s)
    s.match?(/\A\d+\.\d+\.\d+\.\d+\z/)
  end
end

case some_input
when IPv4
  # Rigor does not narrow `some_input` here — IPv4.=== is a
  # user-defined case-equality, which the engine cannot prove
  # narrows a specific class.
  some_input
end
```

For these cases, write an explicit `is_a?` / `respond_to?`
guard, or use an `RBS::Extended` `predicate-if-true` directive
on the `===` method (see [Chapter 7](07-rbs-and-extended.md)).

## Constant-decl alias classes

Some Ruby idioms create a class alias by constant assignment:

```ruby
YAML = Psych
```

When the right-hand side is itself a class, Rigor follows the
alias for receiver typing — `YAML.load(...)` is treated as
`Psych.load(...)`. Method-existence checks deliberately stay
silent on the aliased name, however; the analyzer cannot
distinguish a deliberate alias from an accidental shadowing
without more context, so `YAML.unknown` does not fire
`call.undefined-method`. Use the canonical name when you need
the diagnostic.

## Modules

`module M; def foo; end; end` is structurally similar to a
class for typing purposes. Methods are looked up the same
way; `include M` adds `M`'s methods to the including class's
hierarchy.

`extend self`-style mixin patterns (`module_function` /
`extend self`) are recognised — both instance-side and
singleton-side surface the same methods.

## `protected` and `private`

Rigor reads visibility modifiers and respects them in the
limited context of `def.method-visibility-mismatch` rules
(future). Today, calling a private method on an external
receiver does not fire a diagnostic — visibility is more a
concern for `rubocop-style` linters than a type-system
question.

## What's next

Chapter 7 covers RBS and `RBS::Extended` — the external
signature surface that takes you beyond what inference alone
can prove.

[← Methods and blocks](05-methods-and-blocks.md) · Next: [RBS and `RBS::Extended` →](07-rbs-and-extended.md)
