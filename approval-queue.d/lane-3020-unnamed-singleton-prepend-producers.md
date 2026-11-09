# ResolutionChain#unnamed_extend_nodes is listed in producers.yml as a consumer

- **PR:** [#3026](https://github.com/rigortype/rigor/pull/3026)
- **Issue:** [#3020](https://github.com/rigortype/rigor/issues/3020)
- **Class:** gate-row
- **Precedent:** [#3011](https://github.com/rigortype/rigor/pull/3011)
- **Decided:** 2026-11-10

## Background

Fix round 1 withholds a class-side definer behind a class object whose singleton side lists `"?"` (`extend(*MODS)`).
The new reader `Scope::ResolutionChain#unnamed_extend_nodes` picks the chain's `:extend` marks that list `"?"`, and
`spec/rigor/declaration_facts/producers_spec.rb` flags any method that spells a mixin side, so it needs a row.

## Options and trade-offs

- List it as a consumer, as #3011 listed `Builder#lists_unnamed?`, which reads the same marker.
- Fold the read into another listed method or spell the side without the symbol. That moves code to dodge the gate.

## Decision

List it as a consumer. It reads the marks of a built chain and writes no table.

## To undo

Delete the row when the method goes.
