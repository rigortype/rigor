Adversarially review the draft PR diff against the issue Acceptance.

This step is one pass of the **triple Approved gate**. The workflow runs:

1. Grok:max (`adversarial_review_grok`)
2. Opus:high (`adversarial_review_opus`)
3. Fable:medium (`adversarial_review_fable`)

For this tidy/engine follow-up class:
- Verify each Acceptance bullet is actually met in the diff.
- Look for process leftovers, wrong `Fixes` vs `Refs`, type-shaped comments, accidental scope creep.
- Prefer constructing a counterexample over trusting green CI alone when behavior is claimed.
- Do not rubber-stamp a prior pass's Approved; re-check independently.

Finish with exactly one of:
- "Approved"
- "Needs fix" (list findings as a checklist the next step can act on)
