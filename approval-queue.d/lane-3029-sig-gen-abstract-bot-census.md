# The sig-gen bot guard's discovery-table reads are recorded in the admission census as existence and identity

- **PR:** [#3037](https://github.com/rigortype/rigor/pull/3037)
- **Issue:** [#3029](https://github.com/rigortype/rigor/issues/3029)
- **Class:** gate-row
- **Precedent:** [#2348](https://github.com/rigortype/rigor/pull/2348)
- **Decided:** 2026-11-10

## Background

`SigGen::BotProposalGuard` reads `discovered_def_nodes`, `discovered_singleton_def_nodes`,
`discovered_superclasses` and `discovered_includes` from the project's seed tables. It uses them to decide whether
a `-> bot` proposal is overridden, abstract or a template method. Those are new raw reads, so
`spec/rigor/declaration_facts/admission_census_spec.rb` stopped until they were recorded. The two def-node
members have `contested_*` siblings, so each recorded read also needs a `justified:` kind.

## Options and trade-offs

- Record `lib/rigor/sig_gen/bot_proposal_guard.rb` as a reader of the four members, justified as `existence` (is a
  method of this name defined on this class) and `identity` (the def node whose body is read). This costs four
  rows and two justifications.
- Also consult `contested_discovered_def_nodes` (`consults_contested`). A possible definition would then count as
  an override too, and more `bot` proposals would be skipped. But that is one more raw read, and the issue did not
  ask for it.
- Route the reads through `Scope` readers. Those take a scope and answer one class at a time, while the guard
  needs the whole table to find every override.

## Decision

Record the rows as `existence` / `identity`. A contested slot that the guard does not see only means a `bot`
proposal is kept, as master already does. The guard never reads a fact the census would let it get wrong in the
unsafe direction. #2348 recorded a new typing-site read the same way, with the justification naming what the read
does.

## To undo

Remove the four `lib/rigor/sig_gen/bot_proposal_guard.rb` rows and the two `justified:` entries from
`spec/rigor/declaration_facts/admission_census.yml`, together with the guard. To consult the contested sibling
instead, add the read and change the justification to `consults_contested`.
