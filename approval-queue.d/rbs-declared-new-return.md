# A project signature's `def self.new` on a core or stdlib class does not change what `.new` returns

- **PR:** [#2899](https://github.com/rigortype/rigor/pull/2899)
- **Issue:** [#2884](https://github.com/rigortype/rigor/issues/2884)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-11-06

## Background

#2884 makes `X.new` take its type from an explicit `def self.new` that a project, gem or collection signature
declares, instead of always answering `X`. The issue's settled rule already excluded declarations that Ruby's own core
and stdlib signatures make: core `Data.new: () -> bot`, `Ractor.new: … -> Ractor` and stdlib `Tempfile.new` would
otherwise reach every project subclass. Review found a gap the rule left open. A project signature can reopen a core
class and add `def self.new` to it (`class String; def self.new: () -> Integer; end`). That definition sits in a
project file, so attribution by buffer name honoured it, and both `String.new` and a `class MyStr < String` then typed
as `Integer`.

## Options and trade-offs

- **Honour it.** This follows "the project's signature is the contract" literally. But Ruby still returns the
  instance: a reopening that does not redefine `new` in Ruby leaves `String.new` a `String`. Any later call on the
  `Integer` the analyzer invented is a false positive on correct code, and the reopening reaches every subclass of the
  class.
- **Ignore a `new` carried by a class that core or stdlib declares** (`RbsLoader#core_or_stdlib_class?` on the
  declaring class), even when the definition comes from a project file. That loses a project's deliberate retyping of
  a core constructor, a shape that no corpus target was seen to use.

## Decision

The coordinator ruled for the second option during PR review, on ADR-5's false-positive discipline: a core class's
constructor answers its instance whatever a reopening signature claims. `DeclaredConstructor#honoured?` checks the
declaring class as well as every definition's buffer. `spec/rigor/inference/declared_singleton_new_spec.rb` pins
`String.new` and `MyStr.new` as `String` and `MyStr`.

## To undo

Drop the `core_or_stdlib_class?` conjunct in `DeclaredConstructor#honoured?`, and flip the spec row named above.
Nothing else depends on it.
