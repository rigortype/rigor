# Declare `OptimisticOrigin::BoundMark`'s members in `sig/` behind `# sig-gen gap: #1150` markers

- **PR:** [#2207](https://github.com/rigortype/rigor/pull/2207)
- **Issue:** [#1406](https://github.com/rigortype/rigor/issues/1406)
- **Class:** gate-row
- **Precedent:** [#1190](https://github.com/rigortype/rigor/pull/1190)
- **Decided:** 2026-10-20

## Background

With #1406 an ivar's RBS declaration types it when Rigor checks the code. `Scope`'s `optimistic_locals` / `optimistic_ivars` were declared `Hash[Symbol, Symbol | Data]`, so `OptimisticOrigin.bound_cause` kept `Data` in its else branch and `Scope#optimistic_local` / `#optimistic_ivar` reported `def.return-type-mismatch` against their declared `Symbol?`. Every writer of the two hashes stores a cause Symbol or a `BoundMark`, so the attributes now name `Inference::OptimisticOrigin::BoundMark`, which `sig/` had not declared.

## Options and trade-offs

- A member-less `class BoundMark < ::Data` declaration. It adds no residue row, and the self-check reads the members from the source `Data.define`. It is unlike every other `Data` class in `sig/`.
- Declaring the members (`cause`, `miss`, `self.new`, `self.[]`) with their real types, each behind a `# sig-gen gap: #1150` marker, since sig-gen proposes `untyped` for a `Data.define` member. This matches the other `< ::Data` declarations in `sig/` and adds four marked rows; marked rows do not count as residue, so the `inference/optimistic_origin.rbs` pin stays at 0.

## Decision

The second, by the precedent of #1190, which declared the `Effects::Registry` and plugin effect row `Data` classes the same way for the same gate and reason. `cause` is a `Symbol`, and `miss` is the recorded `true` / `false` / `nil` (`OptimisticOrigin.bound_mark` never stores `UNKNOWN_MISS` in a `BoundMark`).

## To undo

Replace the four members in `sig/rigor/inference/optimistic_origin.rbs` with a member-less `class BoundMark < ::Data` declaration, or drop the markers once #1150 lets sig-gen type `Data.define` members. The narrowed `optimistic_locals` / `optimistic_ivars` attributes need `BoundMark` declared either way.
