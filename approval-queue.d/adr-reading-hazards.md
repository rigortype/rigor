# ADR-49 gains an advisory list of five reading hazards, borrowed as failure modes only

- **PR:** [#2707](https://github.com/rigortype/rigor/pull/2707)
- **Issue:** none
- **Class:** process
- **Precedent:** none — sets one
- **Decided:** 2026-11-03

## Background

The maintainer asked to manage ADR quality qualitatively, using three Japanese write-ups on ADR linting and authoring rules. ADR-49 already carries the quality rubric but names no recurring symptoms of an ADR that is hard to follow. One source, tokium_dev's ADR authoring guideline, is a rule set (32 MUST/SHOULD rules) whose several rules contradict ADR-49 axes 3 and 6: no line numbers, no progress in the body, no issue or PR numbers, no identifiers in the Decision. The corpus measured 77 of 128 ADRs citing issue or PR numbers and 40 carrying file:line anchors.

## Options and trade-offs

- Adopt the source's rules as norms: would put most of the corpus in violation and dock the exemplars ADR-49 calibrates on.
- Add nothing: leaves the recurring symptoms unnamed, which the source shows reviewers otherwise re-explain one PR at a time.
- Borrow the failure modes only, as a diagnostic table inside ADR-49, each mapped to an existing axis with a carve-out for what the corpus keeps fine.

## Decision

The third option, as the maintainer directed. It amends a living rubric that says "refine the axes when the corpus teaches us a new failure mode", reverses no Accepted decision, and adds no gate. No structural gate on ADR bodies was added; the regomark-style `deny`/`warn` split remains an open idea, not a decision.

## To undo

Delete the "Reading hazards" paragraph and table from ADR-49 § 3. Nothing links to it yet.
