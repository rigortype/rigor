# Truthiness and nil? guards narrow a reader chain only when the RBS declares the reader as an attribute

- **PR:** [#2690](https://github.com/rigortype/rigor/pull/2690)
- **Issue:** [#2685](https://github.com/rigortype/rigor/issues/2685)
- **Class:** open-choice
- **Precedent:** [#6](https://github.com/rigortype/rigor/pull/6)
- **Decided:** 2026-11-03

## Background

ADR-128 slice 2 had to remove 9 `call.argument-type-mismatch` false positives on
`scope.type_of(call_node.receiver)` right after `next nil unless call_node.receiver`. Its plan was to
declare Prism's node readers `%a{pure}` through a shipped overlay. The first lane found two problems
with that plan:

- No engine path reads `%a{pure}` to remember a call result. A project's own `%a{pure}` method
  still fired the same mismatch. This drift is filed as #2687.
- An overlay cannot re-declare a reader Prism's own RBS declares. Doing so raises
  `RBS::DuplicatedMethodDefinitionError` and degrades the class to `Dynamic[top]`.

The actual gap was in single-hop chain narrowing (`x.r` rooted at a local or instance variable). It
covered `is_a?`, `kind_of?`, `instance_of?` and `Class ===` guards with no purity gate, but had no
branch for truthiness or `nil?` guards. Whether to extend it, and with what gate, was undecided.

## Options and trade-offs

- **A — extend chain narrowing to truthiness and `nil?` with no gate**, as the `is_a?` chain
  already works. Smallest change, and it fixes the 9 sites. It would also narrow readers that answer
  a new value on each call (`queue.pop`, `io.gets`, `enum.next`), so a guard on one would wrongly
  carry to the next call.
- **B — gate on a purity declaration.** Needs a new consumer of `%a{pure}` from the built RBS
  environment, which runs into ADR-103 WD6's trust rule for gem RBS. It also needs a new way to
  attach purity to Prism's existing reader declarations, because re-declaring them collides. That
  is two new designs for one call shape.
- **C — gate on the RBS declaring the reader as an attribute** (`attr_reader` / `attr_accessor`),
  on the receiver's class or an RBS ancestor, with no project `def` able to answer the call. An
  attribute returns the instance variable it reads, so two reads with no write between them agree.
  Prism declares every node field this way, so no Prism-specific code is needed. It does not cover
  an `attr_reader` written only in project Ruby, and it trusts the RBS's `attr_reader` spelling.

## Decision

C, ruled by the coordinator on the `is_a?` chain precedent (shipped in 0.1.17, release PR #6). It
reuses that rule's address, lookup and invalidation (rebind of the root, any later call on the
root), and adds only the attribute gate. A truthiness or `nil?` guard says less than a class guard,
since it only says the reader answered non-nil once. So it is gated on the reader being a stored
field, where the `is_a?` rule is not gated at all. Only the edge that excludes `nil` is narrowed.

## To undo

Remove `Narrowing.analyse_attribute_chain_truthiness` / `analyse_attribute_chain_nil` and their two
call sites, `Inference::AttributeReaderChain`, and
`ExpressionTyper#instance_method_redefined_in_project?`. Then delete § "Guards on attribute readers"
from `control-flow-analysis.md` and revert ADR-128's slice 2 text. The 9 false positives return once
#2681 and #929 make the hook types live. Nothing else depends on the rule yet.
