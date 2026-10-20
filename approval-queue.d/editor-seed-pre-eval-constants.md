# Record the editor seed's constant-table reads and copies in the admission census

- **PR:** [#2180](https://github.com/rigortype/rigor/pull/2180)
- **Issue:** [#2147](https://github.com/rigortype/rigor/issues/2147)
- **Class:** gate-row
- **Precedent:** [#2103](https://github.com/rigortype/rigor/pull/2103)
- **Decided:** 2026-10-20

## Background

ADR-124 seeds the editor publish's `prebuilt:` runner with the project's discovery tables. Under `pre_eval:` the runner still discarded the seed's literal constant table and could not retract a listed constant another file also assigns, because it read only its own (empty) tables. The fix reads `in_source_constants` and `constant_sources` from the seed when the run has none of its own, and makes the seed carry `constant_sources`. `spec/rigor/declaration_facts/admission_census_spec.rb` then requires four rows: `in_source_constants` read by `lib/rigor/analysis/runner.rb`, `constant_sources` read by `lib/rigor/protection/discovery_seed.rb`, and `constant_sources` copied by `discovery_seed.rb` and recorded against `lib/rigor/language_server/project_context.rb`, where the census matches the `constant_sources: true` keyword that asks the seed for the table rather than a copy of it.

## Options and trade-offs

- **Record the rows (taken).** The reads are of whole tables that the seed hands over intact, the shape the census exists to list.
- **Route the reads through a Scope reader.** A `discovery_seed:` is a plain Hash of tables before any Scope exists, so there is no Scope to read through. A reader would only wrap the same hash access.
- **Leave `pre_eval:` editor answers wrong.** That keeps a false positive (#663's retraction missing) in the editor.

## Decision

Record the rows. #2103 recorded the same kind of row in the same file: the seed-table copies of the coverage and protection paths, for the same reason (a path that runs no check takes the tables check seeds).

## To undo

Revert #2180's `Runner#literal_seed_constants` / `#constant_writer_sources` and the `constant_sources:` keyword of `DiscoverySeed.tables_for_buffer`, then regenerate the census with `RIGOR_REGENERATE_GATES=1`.
