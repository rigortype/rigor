# The literal-send rung moves with its sequence, a call's site is built above it, and `type_of` is the port's one public callback

- **PR:** [#3372](https://github.com/rigortype/rigor/pull/3372)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Slice S7 of ADR-116's WD12 amendment moves the `literal_send` rung (`try_literal_send`, `literal_send_arguments`, `own_send_type`, `LITERAL_SEND_SELECTORS`) into `CallLadder::LiteralSend`; the amendment lets it ride in S5's pull request. The rung writes the `send_target` entry's sequence, so that sequence moves into the module. Two things the amendment does not settle came up.

The entry is `try_call(site, typer)`, but `call_result_type_for` built the call's site only after the four rungs ahead of the dispatcher, and the literal-`send` rung is the first of them.

The rung calls back `type_of`, the typer's public entry, which can be neither a re-entry point nor marked `@api private`. The rule for it was accepted on #3371's review and recorded, unwritten in code, in `wd12-s6-user-method.md`: `PORT = [:scope, *PUBLIC_CALLBACKS, *REENTRY]`.

## Options and trade-offs

For the site:

- **Build a site for the literal-`send` rung alone**, where it is asked. A call that reaches the dispatcher then builds two contexts for the same fields, one more than today for nearly every call.
- **Build the call's site once, above the literal-`send` rung**, and hand it to that rung, the dispatcher and the rungs behind it. A call answered by one of the four rungs between them (the literal `send`, the top-level `def`, the receiver block folds, the overriding `def`) builds a site it did not build before; every other call builds the one it built. Over `lib` that is 2,471 more contexts than the base's 2,750,206, measured by counting `CallContext.build` in both engines. S8's two rungs, which sit between them, will take the same site.

For the callback, the rule is decided; what is left is how the port spec holds it. `CallLadder::PUBLIC_CALLBACKS` is a table beside `REENTRY`. The cut-off counts every name a rung calls on its typer except `scope` (`CallLadderPort.callbacks`), so a public callback counts; the marking example holds `scope` and `REENTRY` to `@api private` and not `PUBLIC_CALLBACKS`; the reentry spec reads `REENTRY` alone, as before.

## Decision

The site is built once, above the literal-`send` rung. The output is byte-identical at `--workers 0` and `2` on `lib/rigor/inference` and `spec/integration/fixtures`. The 2,471 contexts are inside the run-to-run noise of `tool/engine_alloc_ab.rb` (about 15,000 objects); the pull request's net allocation delta (−0.53%) is S5's dropped `kwargs` hash, one per ask of the project-singleton rung. `PUBLIC_CALLBACKS` is `%i[type_of]`, and the port spec's examples read it as above, with a reading example that a public callback counts toward the cut-off, and mutations of each part of the split in the PR.

The `send_target` entry's row names the module (`home: "CallLadder::LiteralSend"`, `written_in: %i[try_call]`), as the order pin's example "of a sequence that has moved into a rung module" already read; `own_send_type` stays ahead, and the entry's two drift rows (#3368, #3369) are unchanged.

The precedent is the amendment: "*`site` is the call.* It is built once per site with `CallContext.build`", and "a literal `send`'s target is a site of its own". The `PUBLIC_CALLBACKS` rule is the coordinator's ruling on #3371, recorded in `wd12-s6-user-method.md`, still in this queue.

## To undo

Move the site's build back below the overriding-`def` rung and give the literal-`send` rung its old `(node, receiver)` in the typer; delete `PUBLIC_CALLBACKS` and its examples, and point the `send_target` row back at the typer. The rung then calls `type_of` on itself and needs no port.
