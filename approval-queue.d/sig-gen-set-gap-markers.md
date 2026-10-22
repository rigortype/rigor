# Close #1151 and #1152 as superseded and re-point their gap markers at #1154

- **PR:** [#2283](https://github.com/rigortype/rigor/pull/2283)
- **Issue:** [#1151](https://github.com/rigortype/rigor/issues/1151)
- **Class:** scope
- **Precedent:** [#2177](https://github.com/rigortype/rigor/issues/2177)
- **Decided:** 2026-10-22

## Background

#1151 and #1152 each pinned one `# sig-gen gap:` marker in `sig/rigor/scope.rbs`
(`Scope#published_constant_sourced` and `#published_constant_sourced?`) and described the cause as
Set element typing. A probe on master 4c182620c shows otherwise.

| Shape | Receiver the engine sees | sig-gen result |
|---|---|---|
| `@p = x` (keyword parameter, default an empty frozen Set) | untyped | reader and `include?` predicate skipped, `untyped-return` |
| `@r = Set.new.freeze` | `Set[]` | reader `Set[untyped]`, predicate `(false \| true)` |
| `LIT.include?([k.to_sym, n.to_sym])`, `LIT = Set[[:a, :b]].freeze` | `Set` constant | `(false \| true)` |

So `Set#include?` over a tuple key is already `bool` when the receiver is typed, and the real cause is
the untyped ivar assigned from an `initialize` parameter (#1154). A Set's element type stays
`Set[untyped]` in sig-gen by the #2177 ruling (a Set is mutable), and the cited `Set[[Symbol, Symbol]]`
could not be inferred from an empty seed in any case.

## Options and trade-offs

- Reverse #2177 for frozen Sets: unsound for mutated sets and still would not touch these rows. Rejected by
  the coordinator.
- Keep the markers: they cite two issues whose stated mechanism is wrong.
- Re-point both markers at #1154 and close #1151/#1152 (taken).

## Decision

Both markers cite #1154, the real mechanism, and the two allow-list rows are removed. #1151 and #1152 close as
superseded by #2177 and #1154. The `[Symbol, Symbol]` element of the reader remains an authored narrowing, noted
in the marker text.

## To undo

Reopen the issues, restore their rows in `spec/rigor/sig_gen/gap_issues.yml`, and point the two markers back.
