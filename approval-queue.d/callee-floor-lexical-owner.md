# The callee floor resolves hand-off constants under the def's recorded nesting and still floors inherited defs

- **PR:** [#2570](https://github.com/rigortype/rigor/pull/2570)
- **Issue:** [#2555](https://github.com/rigortype/rigor/issues/2555)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-01

## Background

PR #2516 left two conservative readings in the callee mutation floor, both recorded in the entry
`callee-floor-inherited-no-walk.md`, which this entry replaces. First, a def reached through an inherited lookup is
floored without being walked (`FLOOR_ALL`). The user chose that after three review rounds of order-dependent answers
("推奨で進めて"). Second, a bare hand-off constant is resolved under every prefix of the defining class's name plus the
top level, unioned with the receiver typed under each truncation of the nested-spelling nesting ("Always union"). The
typed half was memoised per class, side and spelling, and bypassed under constant narrowings ("Fix the memo key").
Lever L1 of #2555 found the def's nesting already recorded per def node (`discovered_def_nestings`, seeded
project-wide and rehydrated for bundle-served defs), so the second reading can be made exact with no cache change.

## Options and trade-offs

- Resolve the hand-off receiver once, under the nesting recorded for the def node, and keep the union only where
  that nesting is not exact: none recorded, or a receiverless def run on the class object that is not in its cref's
  instance table (a `class << self` def, whose cref is the singleton class). This regains the true positives #2522
  describes, and no answer depends on the caller.
- Also walk inherited defs (#2521). Tried in this PR and withdrawn in review round 2: walking exposes every blind spot
  of the own-def census (`h.merge!`, a write through a local alias, `tap`, `[h].each`, a write through another
  object or an ivar, `instance_variable_set`; #2336), which `FLOOR_ALL` masks, each a false positive on correct code.
- Resolve instance self-calls through the ancestors (`Scope#user_def_through_ancestors`) instead of the class's own
  table. An inherited target reaches `FLOOR_ALL`, so this only adds floors. It fixes a v0.4.6 false positive: a
  literal passed to an inherited mutator kept its shape.
- Count a parameter handed to `super` (zsuper, `super(...)`, a positional or keyword rest passed on whole) as
  mutated, and read a project `method_missing` as floor-all for a call no def answers. Both only add floors, and
  both apply to every self-call, since the evaluator does not know which context it runs in.

## Decision

The first, third and fourth options. The inherited no-walk reading the user chose in #2516 stands, and its memo and
narrowing rules carry over: the union path is memoised per class, side, spelling and name, and every memo is
bypassed under constant narrowings. Walking inherited defs waits until the census covers its blind spots (#2336).

## To undo

Route `hand_off_receiver_callees` to `unrecorded_hand_off_callees` unconditionally to restore the union, restore
`Scope#user_def_for` in `resolve_self_callees`, and drop `super_forwarded_parameters` and `method_missing_callees`.
To lift #2521 instead, make `walked_owner` return the owner for an inherited def once #2336 is done. The specs in
`spec/integration/callee_floor_lexical_owner_spec.rb` pin each part.
