# Record the visibility-slot producer of the incremental recheck as a declaration producer

- **PR:** [#2159](https://github.com/rigortype/rigor/pull/2159)
- **Issue:** [#2134](https://github.com/rigortype/rigor/issues/2134)
- **Class:** gate-row
- **Precedent:** [#2061](https://github.com/rigortype/rigor/pull/2061)
- **Decided:** 2026-10-20

## Background

Issue #2134 adds the ADR-46 key `visibility:<class>#<method>` so that `rigor check --incremental` re-checks a reader of a method's recorded visibility when another file adds or drops a `private :foo`. Its producer, `Incremental.changed_visibility_slots`, diffs each changed file's visibility entries and also fires `visibility:*#<method>` for an entry whose visibility is `:private`, because the singleton visibility rule first asks whether any class records the name private at all. Comparing a value with `:private` makes the method a declaration producer to `spec/rigor/declaration_facts/producers_spec.rb`, which fails until `producers.yml` lists it with a reason.

## Options and trade-offs

- **List it in `producers.yml`.** One row, saying it reads entries the indexer already wrote and derives no declaration context. Costs a gate row.
- **Fire `*#<method>` for every moved entry, whatever its visibility.** No `:private` literal and no row, but every file with a `Widget.new`-shaped singleton call would be re-checked whenever any class's `new` visibility entry moves, public ones included. `spec/rigor/analysis/external_hook_incremental_spec.rb` fails on exactly that over-recheck.
- **Move the comparison onto `DeclarationWalk::Context`.** That type is the walk's declaration context; a recheck-closure helper does not belong on it.

## Decision

List it. The row matches `CheckRules.private_recorded_names` (added by #2061), the same "set of names some class records `:private`" question the singleton gate asks, read from tables the indexer already wrote, and `IncrementalSession#singleton_rewritten_constants`, another recheck-closure reader listed with the same reason.

## To undo

Delete the `lib/rigor/analysis/incremental.rb` block from `spec/rigor/declaration_facts/producers.yml` and make `changed_visibility_slots` fire `*#<method>` for every moved entry; the external-hook precision example then has to be relaxed, so prefer keeping the row.
