# `DeclarationWalk::Rules`' interface pin compares the list both ways and reads its floor off the callers; `EMPTY_PREFIX` keeps the visibility it had; one caller is re-broken as a guard clause; the ratchet's 8 new `Dynamic` call sites are accepted until #3392

- **PR:** [#3390](https://github.com/rigortype/rigor/pull/3390)
- **Issue:** [#3346](https://github.com/rigortype/rigor/issues/3346)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-26

## Background

Slice R1 of ADR-116's amendment for #3346 moves the 44 declaration-context rules out of
`scope_indexer.rb` into `DeclarationWalk::Rules` and requalifies every caller. The amendment fixes
what moves, the names, the require's place and the gates. It left three things to the slice.

The amendment asks for a spec that "pins `Rules`' public functions and exported constants as a list
that may shrink and never grows", with a floor of 12. It does not say what the spec compares: a list
that only refuses additions lets an entry leave the module and stay on the list, where it could come
back unnoticed, and a floor written as twelve names in a spec is a number nobody checks.

It says `ScopeIndexer` "binds its own private names to the five" constants it still reads. Four of
the five were private in `ScopeIndexer` before the move. `EMPTY_PREFIX` was not: the
`private_constant` line under it names `EMPTY_NESTING` alone.

It says the moved bodies are Prism-identical and every caller is requalified, and says nothing of a
caller whose line no longer fits. `DeclarationWalk::Rules.` is 23 columns, and it pushed 23 call
sites past the 120-column limit.

It measured, on a scratch tree, that the move adds no `Dynamic` call site to the self-typing
ratchet. The slice measured 8 more (50,923 to 50,931, both arms from `git archive`; the review
reproduced the delta), with precision up 0.027 points rather than about 0.11. The cause is an engine
gap the scratch tree did not exercise: an Array or String constant read from another file types as
`Dynamic` ([#3392](https://github.com/rigortype/rigor/issues/3392)), and `ScopeIndexer` now reads
the eval lists it binds from `rules.rb`.

## Options and trade-offs

**What the pin compares.**

- *Additions only.* The amendment's words, read narrowly. A function that leaves the module stays
  listed, and re-adding it later needs no amendment.
- *The list both ways*, with a message for each direction: a function the list does not name is an
  amendment to ADR-116, and a name the module no longer exposes is deleted from the list. The floor
  is checked against the source: the functions the walk's two files call on the module are the six
  roots, and the functions the files outside the indexer call are the seven entries, each read by
  Prism with the producers gate's own rule for what names the module. A sixth outside file that
  starts calling an entry already on the list then fails the spec until its row is added, which is
  an edit to a spec and not to the ADR.

**`EMPTY_PREFIX`.**

- *Make it private*, as the amendment's sentence reads. No file in the repository reads
  `ScopeIndexer::EMPTY_PREFIX` from outside, so nothing here would break; an out-of-tree reader
  would. It is a change of visibility inside a slice whose other statements are a move.
- *Leave it as it was.* The slice changes the value each of the five names is bound to and nothing
  else about them.

**The call sites past 120 columns.**

- *Re-break each so that its Prism tree is the base's.* Possible for 22 of the 23: arguments on a
  second line, a hanging argument list, or a block `if` in place of a modifier `if` (the same
  `IfNode`).
- The 23rd, the last statement of `yield_singleton_side_constant`, is `yield <call> if rendered`
  at 131 columns. A block `if` there is `Style/GuardClause`'s offence, and a modifier `if` over two
  lines is `Style/MultilineIfModifier`'s. What is left is a guard clause (`return unless rendered`,
  then the `yield`), an inline `rubocop:disable`, or a local alias of the module, which the
  producers gate would not see as a call on it.

**The ratchet's 8 call sites.** Reading `DeclarationWalk::Rules::INSTANCE_EVAL_CALLS` at the nine
sites does not help: the direct cross-file read is `Dynamic` too (the review's two-file probe). A
literal copy in `ScopeIndexer` breaks "each list is one object" and the identity example in
`rules_spec.rb`. A `sig/` declaration of the three constants closes it (the review measured 17 fewer
`Dynamic` sites than base), but the amendment says R1 adds no `sig/` rows, and type-authoring prefers
surfacing an inference gap over hand-authoring around it. Accepting the 8 leaves both ratchet
figures above their pins.

## Decision

The 8 `Dynamic` call sites are accepted and the ratchet is not tightened on the precision rise;
#3392, labelled `known-limitation`, carries the fix, and a `sig/` declaration of the three constants
is the fallback if the engine fix does not come first.

The pin compares the list both ways and reads its floor off the callers. `EMPTY_PREFIX` keeps the
visibility it had; making it private is a one-line follow-up if the maintainer reads the amendment's
sentence as asking for it. `yield_singleton_side_constant` ends in a guard clause: both forms answer
nil for no rendered name and the block's value otherwise, and the pull request lists it as the one
caller whose tree differs from the base by more than the receivers.

The precedent is the amendment itself: "the same names, the same positional parameters, the bodies
Prism-identical" is the standard each choice is held to, and where the standard could not be met in
one statement the pull request says so instead of adding a suppression.

## To undo

For the pin, delete the second expectation of "exposes the pinned functions and no other" and the
two examples that read the callers in `spec/rigor/inference/declaration_walk/rules_spec.rb`. For the
constant, add `:EMPTY_PREFIX` to the `private_constant` line under it in `scope_indexer.rb`. For the
caller, restore the modifier form with a `# rubocop:disable Layout/LineLength` on its line. Nothing
depends on any of the three. For the ratchet, declare `INSTANCE_EVAL_CALLS`, `RECEIVER_EVAL_CALLS`
and `OBJECT_OWNER` of `DeclarationWalk::Rules` in `sig/`, or let #3392's fix recover the 8 sites.
