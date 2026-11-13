# An unattended loop gets no local-gate condition; a gate that answers per machine is the defect

- **PR:** [#3215](https://github.com/rigortype/rigor/pull/3215)
- **Issue:** none
- **Class:** process
- **Precedent:** [ADR-123](../docs/adr/123-merge-queue-and-post-hoc-approval.md)
- **Decided:** 2026-11-14

## Background

#3212 landed a rule for an unattended loop that lands pull requests with no coordinator
(`contribution-flow.md` § "Landing a pull request" step 3), and its conditions route through step 6,
which reads CI. Hours later #3213 had to repair a gate that was **red on the author's clone and
green in CI**: a corpus globbed from the working tree took in `.pi/npm/node_modules/` pages that CI
never checks out. So the question the maintainer asked is fair — if CI can be green while a gate is
red, should the loop also run a local gate before it lands?

## Options and trade-offs

- **Add a local gate to the loop's conditions** (`make docs-check`, say). This is a *third* run of a
  gate the flow already requires twice: `bin/verify-changed` runs `rspec spec/docs/` unconditionally
  before step 1, and the `docs-check` job runs it in CI. The flow's problem on #3212 was not a
  missing run — the author's run was red — so a fourth place to run it adds no information. It also
  makes every unattended landing depend on the machine the loop runs on, which is the property that
  caused the incident, now load-bearing: a loop on a clone with another set of installed artifacts
  reaches another verdict, and the loop has no judgment to tell a real failure from its own
  environment.
- **Keep the conditions as they are and fix each divergence in the gate (taken).** CI is the full
  gate only because a gate's verdict does not depend on where it runs; a gate that breaks that is a
  defect in the gate. #3213 fixed the instance, #3214 holds the corpora where the choice between
  "only tracked" and "not ignored" is still open, and the rule now sits where gates are written
  (`AGENTS.md` § "Validation", with the failure mode in `measurement.md` § "Specs and gates that
  pass without checking"). The rule is deliberately narrow: it is about where a gate's *corpus*
  comes from in a tree that holds ignored artifacts, not about reading the working tree, which most
  gates here do and should — `make lint`, `check`, `coverage` and a dozen `spec/docs/` corpora walk
  directories, and `bin/verify-changed` checks whitespace on untracked files on purpose.
- **Have the loop compare its own local run against CI** and park on disagreement. Catches the class
  rather than one gate, but it is a second gate's worth of wall-clock on every PR to detect
  something that should not exist, and a disagreement is exactly the case the loop may not judge.

## Decision

The second. The incident argues for environment-independent gates, not for a loop that double-checks
them: two sides that can disagree is the defect, and a condition that reads one of them does not
remove it.

The precedent fits at the premise rather than the subject. ADR-123 put landing behind the merge
queue and post-hoc approval precisely because CI, run on the merged result, is the authority that
decides a landing; this decision declines to add a second authority next to it. No merged PR carries
a ratified decision on this question — #3213 repaired one gate and explicitly filed the open half as
#3214 rather than deciding it — so on the question itself this entry sets the precedent.

Residuals, accepted and named rather than fixed: a gate CI never runs cannot diverge, but cannot help
an unattended loop either.

- The two `references/ruby` examples in `spec/docs/c_effects_raises_gate_spec.rb` skip wherever the
  submodule is absent, which is every CI job (none checks it out), and run only on a clone that has
  it. Deliberate, and documented in that spec's own header as "the honest state".
- The Nix devShell is never exercised in CI. `nix-package` builds and smoke-tests the package, not
  `nix develop`, which AGENTS.md § "Development Environment" makes mandatory for every contributor
  command. § "Validation" already answers this with a local `make verify` for a Flake-environment
  change.
- No `shellcheck` runs on either side, and `ci.yml`'s `skip_re` excludes `.sh` from code detection,
  as it does `tool/steep/` and `tool/sorbet/`.

Each is a reason to keep such gates few, not a reason to give the loop a local run.

## To undo

Delete both sentences this PR adds to `AGENTS.md` § "Validation" — the corpus-from-the-index one and
the "the gate is the defect" one, which is the sentence that forbids the condition an undo would be
re-adding and also holds the pointer to the `measurement.md` bullets — and those three bullets, then
add the condition to step 3's "When nobody is coordinating" paragraph. Nothing reads any of it in
code; `spec/docs/` has no gate on this rule, which is itself a consequence of the decision — the rule
is about how a gate is written, and the repository has no instrument that checks that.
