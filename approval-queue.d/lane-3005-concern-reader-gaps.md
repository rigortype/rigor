# A reopening's concern hook blocks are read under a gated hook, and a block's def self.x is filed on Owner::<included>

- **PR:** [#3014](https://github.com/rigortype/rigor/pull/3014)
- **Issue:** [#3005](https://github.com/rigortype/rigor/issues/3005)
- **Class:** open-choice
- **Precedent:** [#3003](https://github.com/rigortype/rigor/pull/3003)
- **Decided:** 2026-11-09

## Background

Issue #3005 asked for three concern-reader gaps to match Ruby:

- an `included` / `prepended` block in a reopening that does not repeat `extend ActiveSupport::Concern`, gated on
  the concern key the way #3003 gates a reopening's `class_methods` block;
- a `def self.x` in such a block, which Ruby defines on the includer's singleton class;
- `self.extend ActiveSupport::Concern` and its `send` spellings.

It did not say how the gate is represented, where a block's `def self.x` is filed, or what to do about load order.
Ruby runs a reopening's `included` block only for an `include` that runs after the reopening loads.

## Options and trade-offs

- Gate representation:
  - Record the reopening's entries under the gated hooks `:concern_included` / `:concern_prepended`, and map them
    to the plain hook in each reader only for a module whose bucket holds the concern entry. The entries of a body
    that runs the `extend` keep their current keys. Every reader that matches a hook name has to call the mapping:
    the singleton chain's hook plan, and `call.undefined-method`'s hook-block and hook-extend reads.
  - Add a marker element to every concern-block key. This changes the keys an existing body records, and the
    incremental class-mark diff.
- Where a block's `def self.x` goes:
  - File it as an instance method of a module named `Owner::<included>`, which no program can spell, and record a
    hook-extend entry for that name. The includer's singleton chain then holds the module where the hook's own
    extends go: after the includer's singleton class, ahead of the concern's `ClassMethods`, and behind a
    prepended concern's `ClassMethods`, which is where Ruby answers.
  - Mark the hook open. Every class-side read on the includer would decline, and no unknown name would be
    reported.
- Load order:
  - Read the reopening's block as running for every includer, as #3003 reads a reopening's `class_methods` block.
    A reopening that loads before the `extend` raises at load.
  - Decline every class-side read on such an includer. This loses the answer the issue asks for.

## Decision

Gated hooks, `Owner::<included>`, and read for every includer. #3003 is the precedent for the gate and for the
load-order reading. The `Owner::<included>` name follows #1592's `Owner::ClassMethods`: a module name the walk
files a block's `def`s under so that the singleton chain can place them. The PR body lists the load-order reading
as a known limit.

`IncrementalSession#mark_affected` also now fires `mixin:<owner>` when an owner's `<dynamic>` mark moves. This
follows #1661's reasoning for unpositioned edges.

## To undo

Remove these:

- `DiscoveryIndex::CONCERN_BLOCK_HOOKS` and `ResolutionChain.effective_hook`, together with their three callers;
- `ScopeIndexer#record_hook_block_singleton_defs` and the `receiver_side:` keyword;
- `dynamic_owners` in `IncrementalSession`.

Then restore `concern &&` on the hook-block branch of `record_concern_class_methods`.
