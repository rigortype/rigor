# Record the editor publish's parameter-inference table in the admission census

- **PR:** [#2187](https://github.com/rigortype/rigor/pull/2187)
- **Issue:** [#2147](https://github.com/rigortype/rigor/issues/2147)
- **Class:** gate-row
- **Precedent:** [#2103](https://github.com/rigortype/rigor/pull/2103)
- **Decided:** 2026-10-20

## Background

ADR-124's follow-up gives the editor publish the whole-project ADR-67 parameter-inference table, built once per generation by `ProjectContext#param_inferred_types` and handed to each publish's Runner. `spec/rigor/declaration_facts/admission_census_spec.rb` then requires four `param_inferred_types` rows: reads by `lib/rigor/language_server/diagnostic_publisher.rb` and `lib/rigor/language_server/project_context.rb`, and copies by `lib/rigor/analysis/runner/buffer_pool_dispatcher.rb` and `diagnostic_publisher.rb`.

## Options and trade-offs

- **Record the rows (taken).** The table is passed whole from the context to the runner, the shape the census lists.
- **Route it through a Scope reader.** There is no Scope at that point; the table is a runner input, as the incremental session's `param_inferred_types:` override already is.
- **Leave the editor collecting over the buffer alone.** The editor keeps typing cross-file-called parameters `Dynamic[top]` where `check` types them.

## Decision

Record the rows. #2103 recorded the same kind of row in the same file for the same reason: the coverage, protection and parameter-inference paths that run no check take the tables check seeds.

## To undo

Revert `ProjectContext#param_inferred_types` and the `param_inferred_types:` arguments in the publisher and the dispatcher, then regenerate the census with `RIGOR_REGENERATE_GATES=1`.
