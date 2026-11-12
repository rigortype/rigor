# A block-form `select` with fields answers `Array[Elem]`, not `bot`

- **PR:** [#3165](https://github.com/rigortype/rigor/pull/3165)
- **Issue:** [#1408](https://github.com/rigortype/rigor/issues/1408)
- **Class:** open-choice
- **Precedent:** [#1327](https://github.com/rigortype/rigor/pull/1327)
- **Decided:** 2026-11-13

## Background

#1408 types `relation.select { … }` as `Array[Elem]` and keeps `select(:col)` as the relation. The
brief left the mixed form, `select(:col) { … }`, to be decided from the source. In activerecord
8.1.3.1 `QueryMethods#select` raises `ArgumentError` ("`select' with block doesn't take
arguments.") when it gets fields and a block. Rails 4.x ignored the fields and returned
`to_a.select { … }`, an Array.

## Options and trade-offs

- **`bot`.** Matches 8.1.3.1 exactly. Code after the call would read as unreachable, and a
  `select(*cols) { … }` whose splat is empty at run time returns the Array, so that reading would
  be wrong for it.
- **`self` (the relation).** What the call typed as before. Wrong on every Rails version.
- **`Array[Elem]` (taken).** True on Rails 4, and sound on 8.1 because the call never returns
  there. It is the wider sound type, and it leaves one overload for every block call.

## Decision

`def select: (*untyped) { (Elem) -> boolish } -> Array[Elem] | (*untyped) -> self`, and the
class-side `Model.select` answers the same way. #1327 made the same call for `find(ifnone) { … }`:
a rare argument-and-block form gets a wide answer rather than a precise one.

## To undo

Split the block overload into `() { … } -> Array[Elem]` and `(untyped, *untyped) { … } -> bot`
in `plugins/rigor-activerecord/sig/active_record/relation.rbs`, make
`Activerecord#class_select_return_type` answer `bot` when the call has arguments, and update the
"types fields next to a block as the Array" example. Nothing depends on it.
