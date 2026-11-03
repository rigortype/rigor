# Truthiness and nil? guards narrow a reader chain only when the RBS declares the reader as an attribute

- **PR:** [#2690](https://github.com/rigortype/rigor/pull/2690)
- **Issue:** [#2685](https://github.com/rigortype/rigor/issues/2685)
- **Class:** open-choice
- **Precedent:** none — sets one
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
branch for truthiness or `nil?` guards. That rule came in commit `a571c9ee7`, straight to `master`
with no pull request, and first shipped in v0.1.12. Whether to extend it, and with what gate, was
undecided. No ratified decision covers it, so this entry sets the precedent.

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
  on the receiver's class or an RBS ancestor, when the project cannot answer the call another way.
  Prism declares every node field this way, so no Prism-specific code is needed. It does not cover
  an `attr_reader` written only in project Ruby.

## Decision

C, ruled by the coordinator. The gate does not rely on an attribute returning its instance variable.
Some RBS attributes do not: `Net::HTTP#ipaddr` and `#proxy_*`, `OptionParser#version`, and Prism's
memoising `*_loc` readers. What it relies on is that the reader's nil-ness does not change between
two reads with no call on the receiver between them.

The rule reuses the `is_a?` chain's address, lookup and invalidation. Those invalidation holes now
apply to the far more common nil guard: a write through an alias of the root, or by a method the
root is passed to, is not seen. Three bounds keep that from becoming a finding on correct code:

- **A diagnostic firewall.** A fact from an attribute chain never makes
  `flow.always-truthy-condition` fire. A wrong narrowing can therefore only hide a `nil` report.
- **More invalidation, on this kind of fact only:**
  - a compound write (`x.r ||= v`), a multiple-assignment target, or a `for` target on the root;
  - a call whose block or lambda mentions the root;
  - a call that runs a closure (`clear.call`);
  - for an instance-variable root, any implicit-self call.
- **A wider override gate.** The rule declines for a name the project defines by any route other
  than `def`, anywhere: `define_method`, `attr_*`, an alias, or a top-level `def`. It also
  declines for a class that is refined, or whose method table is rewritten beyond the names it spells (a computed
  `define_method`, `define_singleton_method` in its body), and for a project `def` on the class, an
  ancestor or a descendant.

## To undo

- Remove `Narrowing.analyse_attribute_chain_truthiness` / `analyse_attribute_chain_nil` and their two
  call sites.
- Remove `Inference::AttributeReaderChain` and its call in `IndexedNarrowing.invalidate_chain_after_call`.
- Remove `CheckRules::AttributeChainGuard` and its check in `AlwaysTruthyConditionCollector`.
- Remove `ExpressionTyper#instance_method_redefined_in_project?`.
- Delete § "Guards on attribute readers" from `control-flow-analysis.md` and revert ADR-128's
  slice 2 text.

The chain drop in `StatementEvaluator#widen_attribute_write` can stay: it also stops an `is_a?` fact
outliving `x.r ||= v`. The 9 false positives return once #2681 and #929 make the hook types live.
Nothing else depends on the rule yet.
