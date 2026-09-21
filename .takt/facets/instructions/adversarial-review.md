Adversarially review the draft PR diff against the issue Acceptance.

For this tidy/engine follow-up class:
- Verify each Acceptance bullet is actually met in the diff.
- Look for process leftovers, wrong `Fixes` vs `Refs`, type-shaped comments, accidental scope creep.
- Prefer constructing a counterexample over trusting green CI alone when behavior is claimed.

Finish with exactly one of:
- "Approved"
- "Needs fix" (list findings as a checklist the next step can act on)
