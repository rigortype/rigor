# Move node_context.rbs's provenance residue pin from 0 to 1 for the find-family class-test narrowing

- **PR:** [#2918](https://github.com/rigortype/rigor/pull/2918)
- **Issue:** [#2719](https://github.com/rigortype/rigor/issues/2719)
- **Class:** gate-row
- **Precedent:** [#1189](https://github.com/rigortype/rigor/pull/1189)
- **Decided:** 2026-11-06

## Background

#2719 asked the engine to narrow `find` / `detect` / `rfind` through a single class-test block, and then to tighten `Rigor::Plugin::NodeContext#enclosing_def` (and two siblings) through `rigor sig-gen`. The engine part works: `enclosing_def`'s body now infers `Prism::DefNode?`. But sig-gen does not propose that return over the declared `::Prism::Node?`. Its union-lenience guard (`Generator#loses_declared_union_member?`) reads `Prism::Node` as a declared union member the inferred type drops. The row therefore turned from generated-equivalent into residue, and the ADR-107 provenance gate (`spec/rigor/sig_gen/provenance_spec.rb`) went red: `sig/rigor/plugin/node_context.rbs` 1, pinned 0.

## Options and trade-offs

- Move the pin to 1 with the reason at the pin. Cheap, honest about the residue, and the declaration stays the one sig-gen would accept.
- Hand-tighten the signature with a `# sig-gen gap:` marker. Gets the precise type now, but it is a hand-authored row, which the issue said must come from sig-gen.
- Fix sig-gen's guard in this PR. That widens the PR beyond #2719's engine part into sig-gen's tightening policy, which deserves its own review.
- Hold the engine change. That loses the narrowing every other `find` call site gains.

## Decision

Move the pin to 1, with a comment naming #2914, the issue filed for the sig-gen guard. The coordinator authorised it. #1189 is the precedent: it moved a residue pin up with the reason at the pin. The signature is not hand-tightened.

## To undo

When #2914 lets sig-gen propose `Prism::DefNode?`, apply the proposal and lower the pin back to 0. Reverting the engine change also returns the row to equivalent, and the pin then drops to 0 on its own.
