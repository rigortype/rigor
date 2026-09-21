Adversarially review the draft PR diff against the issue Acceptance.

**Band selection:** default **Grok:max**. If the change is judged complex
(implementation-heavy / subtle contracts), also run **Opus:high** (both must
Approve). Reserve **Fable:medium** for complex design / architecture — do not
spend it on routine tidies. No live Claude usage poll.

For this tidy/engine follow-up class:
- Verify each Acceptance bullet is actually met in the diff.
- Look for process leftovers, wrong `Fixes` vs `Refs`, type-shaped comments, accidental scope creep.
- Prefer constructing a counterexample over trusting green CI alone when behavior is claimed.
- **Reality vs PR text:** compare the current PR body to the diff. On a final
  `Approved`, always emit a **PR body revision draft** and **suggested PR
  comment drafts** so claims match reality (orchestrator applies/posts them).
  Do not Approve while leaving misleading PR text unaddressed — either
  `Needs fix` or Approve with corrected drafts.

Finish with exactly one of:
- "Approved" (include PR body draft + comment drafts)
- "Needs fix" (list findings as a checklist the next step can act on)
