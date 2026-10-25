# A derived ivar credit treats RBS-extended classes as overload-sensitive and accepts an empty `[]`/`{}` default

- **PR:** [#2375](https://github.com/rigortype/rigor/pull/2375)
- **Issue:** [#2321](https://github.com/rigortype/rigor/issues/2321)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-10-26

## Background

#2321 extends the class-ivar census's declared-parameter credit (#1154) from a bare read (`@x = x`) to an expression
over declared parameters (`@x = x.dup.freeze`). Review round 1 found that a parameter passed as a call argument takes
the first overload it matches: `a + b` under `(Integer a, Integer | Float b)` was credited `Integer` while Ruby holds
`2.5`. It also found that an optional parameter's default outside its declared type (`x = nil` under `?Integer x`)
reached derived values. The coordinator ruled that both cases decline: an argument whose declared type is a union, an
optional or a non-final class, and a default whose type is not within the declared type. Neither rule said what
"non-final" means or how to read an empty literal default, so the lane decided both.

## Options and trade-offs

Non-final class:

- A fixed allow-list of value classes (`Integer`, `String`, `Symbol`, …): predictable, but a list nobody maintains,
  and it would call `String` final although RBS declares subclasses of it.
- A class some loaded RBS class declaration names as its superclass, plus every module (`RbsLoader#superclass_names`,
  taken). This follows the environment and only ever declines more. Because RBS declares subclasses of `String` and
  `Array`, `Array(x)` over a `String` or `Array` parameter in argument position is no longer credited and keeps its
  previous reading. `Integer` is credited.

Empty literal default:

- Require `Acceptance` to answer `yes`. It answers only `maybe` for an empty `[]` against `Array[T]`, because the
  literal has no element type to compare. `RbsLoader#libraries` (`libraries: []`) and
  `AdditionalInitializer#methods`/`#block_methods` (`methods: []`) would then stay unrenderable.
- Treat an empty `[]` or `{}` default as within any `Array`/`Hash` member of the declared type (taken). This is sound
  in Ruby, since an empty Array is an `Array[T]` for every `T`. A default the census reads as a constant
  (`type_args = EMPTY_TYPE_ARGS`) is not an empty literal and still declines, so `Type::Nominal#type_args` stays
  unrenderable (`sig/rigor/type.rbs` pins at 175, not 174).

## Decision

Both choices taken. The extensibility rule takes the conservative direction ADR-5 and the false-positives-first rule
prefer: every case it changes is one where a credit is withheld, so it cannot add a report. The empty-literal
exception stays within the issue's own envelope, which declines only a default whose type may fall outside the
declaration, and an empty collection cannot.

## To undo

Extensibility: change `DerivedParamValue#overload_sensitive?` / `#leaf_class?` in
`lib/rigor/inference/scope_indexer/derived_param_value.rb`, and drop `RbsLoader#superclass_names` if nothing else
reads it. The credited `Array(x)` examples in `spec/rigor/inference/declared_param_ivar_census_spec.rb` use `Integer`
and would need a `String` twin. Empty default: delete `#empty_collection_within?`. The two empty-default examples then
fail, and the `RbsLoader#libraries` and `AdditionalInitializer` rows return to residue, so their pins and markers move
back.
