# A rung module may not call `const_get`, whatever it names

- **PR:** [#3372](https://github.com/rigortype/rigor/pull/3372)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

The call ladder's port spec (`spec/rigor/inference/call_ladder/port_spec.rb`) holds a rung module to typing only through the typer it is given: it may not name `ExpressionTyper` or `StatementEvaluator`. #3371's second review round found that the check matched a typing class only as a constant node, so `Rigor::Inference.const_get(:ExpressionTyper)` and `Object.const_get("Rigor::Inference::ExpressionTyper")` passed. The coordinator's brief for this pull request gave two ways to close it and asked the lane to choose one and say why: count a `const_get` whose literal argument names a member of `TYPING_CLASSES`, or ban `const_get` in rung modules.

## Options and trade-offs

- **Count a `const_get` whose literal argument names a typing class.** It keeps a rung free to use `const_get` for anything else. It misses a name the module builds (`const_get(name)`, `const_get("Expression#{x}")`), a qualified string unless the reader splits its path, and a walk in two steps (`Inference.const_get(:Expression…)`), so it closes the two probes and not the hole.
- **Ban `const_get` in a rung module, whatever its argument.** It closes every spelling the reading can see: by name, through `send`, `method(:const_get)` or a `&:const_get` block, as the typing entries are already read. It costs a rung the call, which none of the four modules makes: a rung names the constants it uses, and a computed constant lookup has no place in typing a call.

## Decision

The ban: `CallLadderPort::CONSTANT_LOOKUPS = %i[const_get]`, read by `RungFile#typing_bypasses`, with the review's two probes and four other spellings as an example of the port spec, each mutation of the rule failing it. What the reading still cannot see (`eval`, `ObjectSpace`, a constant another module hands over) is in the spec's header.

The precedent is the amendment's rule that a rung calls only the names in `PORT` and types only through its typer, which S6's review round wrote as the typing-bypass check; the ban extends that check to the one way of naming a class it did not read.

## To undo

Empty `CONSTANT_LOOKUPS` (or drop it and `bypass`'s first branch) and delete the example; the two probes pass again. Replacing the ban with the literal check is a change to `bypass` alone.
