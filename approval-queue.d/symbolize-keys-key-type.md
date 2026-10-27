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
each key member: a String or Symbol (or a String subclass, or a literal of either) becomes `Symbol`; every other key, Integer,
Float, nil, true, false, Rational, Complex, an IntegerRange, a project class or a delegator included, becomes `Dynamic[top]`.
The coordinator ruled in round 3 that no key class is kept: round 2 kept the core value classes unless
`Reflection.discovered_method?` saw a project `to_sym`, but that misses a `to_sym` defined in another file under
`pre_eval`, added by `Integer.include(M)` / `prepend` / `Numeric.include`, or written as `class ::Integer`, and a kept key
then reports `call.undefined-method` on correct code. The accepted cost is that an Integer-keyed receiver reads
`Hash[Dynamic[top], V]`, so `Hash[Integer, Integer]#symbolize_keys` is silent on `+` but no longer typed. The hook answers
the `Hash` members of a receiver union and drops a `nil` member (`nil.symbolize_keys` raises; the engine adds `nil` back for
`&.`); an empty closed shape drops out of the union; a block is ignored as Ruby does. It declines a member that is neither a
`Hash[K, V]` nominal, a non-empty difference of one, a closed shape, nor `nil`, and an open shape (a `default_proc` can add
keys). A String-keyed hash read through the overlay alone loses its `Symbol` key and goes silent. The bang forms (`-> self`)
are unchanged. The hook is the user's coordinator ruling.

## To undo

Restore `Hash[Symbol, V]` in the two `core_ext.rbs` rows and delete `SymbolizeKeys` and its `dynamic_return` in the plugin.
