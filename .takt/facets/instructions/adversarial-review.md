Adversarially review the draft PR diff against the issue Acceptance.

**Band selection (orchestrator / this step's host):** not a unanimous three-way
vote. Pick **one** available band — Grok:max, Opus:high, or Fable:medium —
preferring carefulness that is not rate-limited. For advanced / high-risk
engine changes, use **Fable alone** or **Grok then Opus** (both must Approve).

For this tidy/engine follow-up class:
- Verify each Acceptance bullet is actually met in the diff.
- Look for process leftovers, wrong `Fixes` vs `Refs`, type-shaped comments, accidental scope creep.
- Prefer constructing a counterexample over trusting green CI alone when behavior is claimed.

Finish with exactly one of:
- "Approved"
- "Needs fix" (list findings as a checklist the next step can act on)
