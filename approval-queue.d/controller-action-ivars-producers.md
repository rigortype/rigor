# Record the two ADR-125 visibility readers in producers.yml as reasoned producers

- **PR:** [#PR](https://github.com/rigortype/rigor/pull/PR)
- **Issue:** [#575](https://github.com/rigortype/rigor/issues/575)
- **Class:** gate-row
- **Precedent:** [#2061](https://github.com/rigortype/rigor/pull/2061)
- **Decided:** 2026-10-22

## Background

`spec/rigor/declaration_facts/producers_spec.rb` flags each new method that names a visibility symbol. The #575
carve-out adds two: `IvarWriteCollector#method_visibility` reads the enclosing def's visibility, and
`CheckRules#separate_invocations?` compares it with `:public`.

## Options and trade-offs

- **Route the read through `DeclarationWalk::Context`.** That context serves the declaration walk, and the collector
  runs after discovery. It would add a dependency for a value `Scope#discovered_method_visibility` already answers.
- **Record both methods with a reason.** Both read the recorded visibility through `Scope`, plus the fixed
  `:private` of `initialize` and the other lifecycle hooks. Neither derives a declaration context.

## Decision

Record both with reasons, as #2061 recorded the `CheckRules` visibility readers it added for #1984.

## To undo

Delete the two entries and move the visibility read onto `DeclarationWalk::Context`.
