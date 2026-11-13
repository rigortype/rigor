# An unattended loop gets no local-gate condition; a gate that answers per machine is the defect

- **PR:** [#3215](https://github.com/rigortype/rigor/pull/3215)
- **Issue:** none
- **Class:** process
- **Precedent:** [#3213](https://github.com/rigortype/rigor/pull/3213)
- **Decided:** 2026-11-14

## Background

#3212 landed a rule for an unattended loop that lands pull requests with no coordinator
(`contribution-flow.md` § "Landing a pull request" step 3), and its conditions route through step 6,
which reads CI. Hours later #3213 had to repair a gate that was **red on the author's clone and
green in CI**: a corpus globbed from the working tree took in `.pi/npm/node_modules/` pages that CI
never checks out. So the question the maintainer asked is fair — if CI can be green while a gate is
red, should the loop also run a local gate before it lands?

## Options and trade-offs

- **Add a local gate to the loop's conditions** (`make docs-check`, say). It would have caught that
  one commit. But it makes every unattended landing depend on the machine the loop runs on, which is
  the property that caused the incident, now load-bearing: a loop on a clone with a different set of
  installed artifacts would reach a different verdict, and the loop has no judgment to tell a real
  failure from its own environment. It also pays the gate twice on every PR.
- **Keep the conditions as they are and fix each divergence in the gate (taken).** CI is the full
  gate only because a gate's verdict does not depend on where it runs; a gate that breaks that is a
  defect in the gate. #3213 fixed the instance, #3214 holds the three corpora that still glob, and
  the rule now sits where gates are written (`AGENTS.md` § "Validation", with the failure mode in
  `measurement.md` § "Specs and gates that pass without checking").
- **Have the loop compare its own local run against CI** and park on disagreement. Catches the class
  rather than one gate, but it is a second gate's worth of wall-clock on every PR to detect
  something that should not exist, and a disagreement is exactly the case the loop may not judge.

## Decision

The second. The incident argues for environment-independent gates, not for a loop that double-checks
them: two sides that can disagree is the defect, and a condition that reads one of them does not
remove it.

Residual, accepted and named rather than fixed: a gate CI never runs cannot diverge but also cannot
help an unattended loop. The two `references/ruby` examples in `spec/docs/c_effects_raises_gate_spec.rb`
skip in every CI job (all of them check out with `submodules: false`) and run only on a clone that
has the submodule. That is deliberate and documented in the spec's own header; it is a reason to keep
such gates few, not a reason to give the loop a local run.

## To undo

Delete the second sentence of `AGENTS.md` § "Validation" and the `measurement.md` bullet it points
at, and add the condition to step 3's "When nobody is coordinating" paragraph. Nothing reads either
of them in code; `spec/docs/` has no gate on this rule, which is itself a consequence of the decision
— the rule is about how a gate is written, and the repository has no instrument that checks that.
