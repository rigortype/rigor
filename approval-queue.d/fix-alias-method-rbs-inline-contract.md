# Defer the alias_method contract half of #1934 to #2171

- **PR:** [#2172](https://github.com/rigortype/rigor/pull/2172)
- **Issue:** [#1934](https://github.com/rigortype/rigor/issues/1934)
- **Class:** scope
- **Precedent:** none — sets one
- **Decided:** 2026-10-20

## Background

#1934 expected no diagnostic, and "ideally" `title` reading `label`'s declared contract, as the `alias` keyword form does (`title("x")` reporting an argument-type mismatch against `Integer`). #2172 removes the diagnostic, but the alias resolves through the project's source, so the contract is not checked.

## Options and trade-offs

- **Defer to #2171 (taken).** The fix lands without risk to the class's definition build. The cost is that an `alias_method` call is not argument-checked until #2171 lands.
- **Emit an RBS `alias` from the plugin in this PR.** This gives the contract. But a duplicate of a declared name, a target RBS cannot resolve, and an alias in a branch that may not run would each fail `RBS::DefinitionBuilder` for the whole class, and every call on it would then read `Dynamic[top]`. Each shape needs its own guard and spec, which is a separate change.

## Decision

Defer. The issue's stated expectation is met. The contract half is an improvement in precision with failure modes of its own, and #2171 records those constraints and its gate.

## To undo

Land #2171, or fold its plugin change into a later PR. Nothing here depends on the deferral.
