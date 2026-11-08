# Four helpers that read a mixin call or side's shape are listed in producers.yml as consumers, not producers

- **PR:** [#2993](https://github.com/rigortype/rigor/pull/2993)
- **Issue:** [#2991](https://github.com/rigortype/rigor/issues/2991)
- **Class:** gate-row
- **Precedent:** [#1735](https://github.com/rigortype/rigor/pull/1735)
- **Decided:** 2026-11-09

## Background

The fix records a second marker, `"?"`, beside the `"*"` taint on a mixin side, but only when the walk cannot name
the module. `spec/rigor/declaration_facts/producers_spec.rb` flags any method that spells a mixin side or kind
(`:include`, `%i[include prepend]`) as a possible declaration producer. Four methods now do that:

- `ScopeIndexer#instance_mixin_call?` and `#block_mixes_into_self?` are new.
- `MixinAccumulator#note` now passes `side == :include`.
- `ResolutionChain::Builder#extend_hook_taint` replaces `extend_hook_taint?` and reads the extended module's
  `:include` list.

## Options and trade-offs

- List each one with the reason it derives no declaration context. This is what the gate asks for, and it matches
  the neighbouring rows: `block_mixes_in?`, and `ResolutionChain.extend_reshapes_instance?` from #1735.
- Move them onto `DeclarationWalk::Context`. None of them resolves an owner or a context. Each reads a call's shape,
  or a list another walk already wrote, so a move would change the code's shape only to satisfy the gate.

## Decision

List them, each with its reason. #1735's rows for the same kind of consumer (a reader of the `unpositioned_mixins`
`:include` side) are the precedent.

## To undo

Delete the four rows in `spec/rigor/declaration_facts/producers.yml` together with the code they describe. Reverting
the #2991 change removes both.
