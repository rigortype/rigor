# Record the rebinding-callee rule's raw def-table reads in the admission census as existence reads

- **PR:** [#2183](https://github.com/rigortype/rigor/pull/2183)
- **Issue:** [#1817](https://github.com/rigortype/rigor/issues/1817)
- **Class:** gate-row
- **Precedent:** [#1780](https://github.com/rigortype/rigor/pull/1780)
- **Decided:** 2026-10-20

## Background

The #1817 fix reads the project's def tables by method name: which classes have a `def` of the callee's name (`discovered_def_nodes`, `discovered_singleton_def_nodes`), which names have no `def` body (`discovered_methods`), and how many `def` rows the name has (`discovered_deferred_ranges`). The ADR-119 admission census (`spec/rigor/declaration_facts/admission_census.yml`) failed until those raw reads were recorded, and the two members with a `contested_*` sibling needed a `justified:` classification.

## Options and trade-offs

- **Record the four reads and justify the two contested members as `existence` (taken).** Each read asks only whether a key is there, or counts rows. The bodies themselves are read through `Scope#user_def_for` / `#singleton_def_for` / `#top_level_def_for`, which record their ADR-46 edges. A contested slot, where a possible definer may replace the body, is covered because the row count then exceeds the slots read and the rule declines.
- **Route every read through a new `Scope` reader.** This keeps the census unchanged, but it adds a by-name scan to `scope.rb`, a file Draft PR #1771 also rewrites. It would only move the same raw iteration into the table owner.

## Decision

Record the rows. #1780 recorded `ruby_deprecations.rb`'s raw reads of the same tables, a check rule asking whether the project defines a name, as `existence`, and `block_call_timing.rb`'s `project_defines_anywhere?` has the same classification. The new rows are the same kind of read in the same gate file.

## To undo

Delete the four `rebinding_block_callees.rb` lines under `reads:` and the two `justified:` entries, after removing or rerouting the reads they record; `RIGOR_REGENERATE_GATES=1 bundle exec rspec spec/rigor/declaration_facts/admission_census_spec.rb` rewrites the file.
