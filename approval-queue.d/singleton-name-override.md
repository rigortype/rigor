# The singleton typing read consults the visibility-contest census, recorded as an admission-census row

- **PR:** [#2348](https://github.com/rigortype/rigor/pull/2348)
- **Issue:** [#2284](https://github.com/rigortype/rigor/issues/2284)
- **Class:** gate-row
- **Precedent:** [#2307](https://github.com/rigortype/rigor/pull/2307)
- **Decided:** 2026-10-26

## Background

#2284 lets a project `def self.name` answer a call on the class object ahead of `Module#name`. Review found
that this let a superclass `def self.x` answer for a subclass that redefines `x` without a `def`
(`define_singleton_method(:x)`, `singleton_class.define_method(:x)`), producing an error-level false positive on
correct code. The fix makes `ExpressionTyper#resolve_singleton_def_with_owner` decline when a nearer entry on
the singleton chain has its visibility slot for the name contested in `discovered_method_visibilities`. That is
the census #1984 and #2013 already keep for those definers. The read is new for `expression_typer.rb`, so
`spec/rigor/declaration_facts/admission_census_spec.rb` stopped on an unrecorded reader.

## Options and trade-offs

- Record `lib/rigor/inference/expression_typer.rb` as a `consults_contested` reader of
  `discovered_method_visibilities`. This costs one row, and the read stays at the typing site that needs it.
- Move the read into a file the census already records, such as `definer_resolution.rb`. The census would not
  change, but the code would be shaped by the gate rather than by where the decision belongs.

## Decision

The row was recorded, with justification `consults_contested`. The read only makes the typer decline more,
which is the same shape as the existing `consults_contested` rows: `ivar_write_collector.rb`, added in #2307,
and `definer_resolution.rb`, added in #1602 (ADR-119 C1a).

An accepted conservative cost: the contest also comes from visibility-only calls. For example, a
`private_class_method :name` on a nearer subclass makes the farther `def self.name` read `Dynamic` instead of
its type. This loses precision but cannot produce a false positive.

A second accepted cost: a nearer `define_singleton_method` with a computed name contests that class's singleton
wildcard slot, so every inherited singleton `def` behind it reads `Dynamic`, including names it never defines.
`Sw.foo.upcase` therefore loses a true positive when `Sw`'s superclass has `def self.foo = nil`. The census cannot
say which names a computed definer reaches, so withholding all of them is the conservative reading.

## To undo

Remove the `expression_typer.rb` reads entry and its `justified` entry from `admission_census.yml`. Then
either delete `dynamic_singleton_definer_ahead?` and its call in `resolve_singleton_def_with_owner` (the
false positive returns), or route the same consult through an already-recorded reader. The examples in
`spec/integration/singleton_override_of_module_method_spec.rb` under "types the call Dynamic when a nearer
class defines the name without a def" and the cross-file `dyn.rb` row depend on it.
