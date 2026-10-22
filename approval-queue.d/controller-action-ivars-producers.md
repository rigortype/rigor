# Record the two ADR-125 visibility readers in producers.yml and admission_census.yml

- **PR:** [#2307](https://github.com/rigortype/rigor/pull/2307)
- **Issue:** [#575](https://github.com/rigortype/rigor/issues/575)
- **Class:** gate-row
- **Precedent:** [#2061](https://github.com/rigortype/rigor/pull/2061)
- **Decided:** 2026-10-22

## Background

`spec/rigor/declaration_facts/producers_spec.rb` flags each new method that names a visibility symbol. The #575
carve-out adds two: `IvarWriteCollector#method_visibility` reads the enclosing def's visibility, and
`CheckRules#separate_invocations?` compares it with `:public`. `spec/rigor/declaration_facts/admission_census_spec.rb` also flags the collector's read of the contested mark on `discovered_method_visibilities`.

## Options and trade-offs

- **Route the read through `DeclarationWalk::Context`.** That context serves the declaration walk, and the collector
  runs after discovery. It would add a dependency for a value `Scope#discovered_method_visibility` already answers.
- **Record both methods with a reason.** Both read the recorded visibility through `Scope`, plus the fixed
  `:private` of `initialize` and the other lifecycle hooks. Neither derives a declaration context.

## Decision

Record both with reasons, as #2061 recorded the `CheckRules` visibility readers it added for #1984. In the census, `ivar_write_collector.rb` is a read of `discovered_method_visibilities` justified as `consults_contested`, the class #1617 gave `definer_resolution.rb` for the same contested check.

## To undo

Delete the two producers.yml entries and the census rows, and move the visibility read onto `DeclarationWalk::Context`.
