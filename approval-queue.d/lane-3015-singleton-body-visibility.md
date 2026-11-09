# A class << self body with a visibility call in a concern block opens the includer's class side

- **PR:** [#3025](https://github.com/rigortype/rigor/pull/3025)
- **Issue:** [#3015](https://github.com/rigortype/rigor/issues/3015)
- **Class:** open-choice
- **Precedent:** [#2996](https://github.com/rigortype/rigor/pull/2996)
- **Decided:** 2026-11-09

## Background

Issue #3015 asks that a `class << self; def x` in an `included` block be filed on `Owner::<included>` as #3005 files
a `def self.x` there. That module records no visibility, so a `def` after `private` in the same `class << self`
body would be answered as a public class method. Ruby raises NoMethodError on `Kv.made` and answers
`Kv.send(:made)`. The issue did not cover this shape.

## Options and trade-offs

- File every `def` of the body. `Kv.made` would be answered where Ruby raises: a lost report, not a false one.
- File none of the body's `def`s. `Kv.send(:made)` and an implicit-self call in a class method would be reported
  as undefined, where Ruby answers: a false positive.
- File none of the body's `def`s and record the hook's open entry. Every class-side read on the includer
  declines, so nothing is reported, true or false, on its class side.

## Decision

The third option, as #2996 (#1592) opens the hook for a `class << self` body in a hook block that mixes in. False
positives outrank lost reports, and the shape is rare. A body with no statement-level visibility call is read.

## To undo

Remove the visibility branch of `ScopeIndexer#hook_block_singleton_defs` and decide the case again.
