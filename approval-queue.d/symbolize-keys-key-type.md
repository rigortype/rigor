# The static symbolize_keys / to_options rows answer an untyped key, and a plugin hook maps the key members

- **PR:** [#2450](https://github.com/rigortype/rigor/pull/2450)
- **Issue:** [#2433](https://github.com/rigortype/rigor/issues/2433)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-27

## Background

ActiveSupport 8.1.4 implements `Hash#symbolize_keys` / `#to_options` as `transform_keys { |key| key.to_sym rescue key }`,
so `{1 => 2, "a" => 3}.symbolize_keys` is `{1 => 2, a: 3}`. The RBS rows said `Hash[Symbol, V]`, which reads an Integer key as a
Symbol and reports `undefined method '+' for Symbol` on `h.symbolize_keys.keys.first + 1`. No single RBS return type is right
for both a String-keyed and an Integer-keyed receiver.

## Options and trade-offs

- Keep `Hash[Symbol, V]`: precise for the common String-keyed hash, a false positive for any key without `to_sym`.
- `Hash[Symbol | K, V]`: rejected. Passing the common String-keyed result to a declared `Hash[Symbol, untyped]` parameter then
  reports `call.argument-type-mismatch`, a more frequent false positive than the one it removes.
- `Hash[untyped, V]` in the static rows, plus a `dynamic_return` hook in the plugin that maps each key member.

## Decision

The static non-bang rows (the plugin's `core_ext.rbs` and the overlay's twin) answer `Hash[untyped, V]`. The plugin hook maps
each key member: a String or Symbol (or a subclass, or a literal of either) becomes `Symbol`. Only the core value classes
that cannot meaningfully be subclassed stay as themselves (Integer, Float, Rational, Complex, NilClass, TrueClass,
FalseClass, with their literal and IntegerRange forms), and even those become `Dynamic[top]` when the project defines
`to_sym` on the class or an ancestor (Numeric, Comparable, Object, Kernel, BasicObject), read through
`Reflection.discovered_method?` so the negative dependency is recorded. Every other key, a project subclass, a delegator
or `Object` included, becomes `Dynamic[top]`, because bundled RBS cannot show that such a class has no `to_sym`
(review of the first revision: a project reopening of Integer, a `Path < Array` subclass and `SimpleDelegator` keys
reported `call.undefined-method` on correct code). A receiver union is mapped per `Hash` member with `nil` kept, so
`h&.symbolize_keys` keeps its `Symbol` key; a block is ignored as Ruby does; the hook declines a member that is neither
a `Hash[K, V]` nominal, a non-empty difference of one, a closed non-empty shape, nor `nil`. An open shape declines
(a `default_proc` can add keys). A String-keyed hash read through the overlay alone loses its `Symbol` key and goes
silent. The bang forms (`-> self`) are unchanged. The hook is the user's coordinator ruling; the narrowed key rule is
the coordinator's round-2 ruling.

## To undo

Restore `Hash[Symbol, V]` in the two `core_ext.rbs` rows and delete `SymbolizeKeys` and its `dynamic_return` in the plugin.
