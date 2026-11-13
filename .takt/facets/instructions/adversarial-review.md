Adversarially review the draft PR diff against the issue Acceptance.

**Band selection:** default **Grok:xhigh**. If the change is judged complex
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

Report in the fixed shape of `.claude/skills/rigor-reviewer/SKILL.md` § Report: the parsed
`Severe N | Moderate N | Minor N | Nit N` line, the verdict line naming the head SHA you reviewed,
`Severe remaining`, and each finding with its severity, its failure scenario, introduced or
pre-existing, and its repro — the command, its output, and the output correct behaviour requires. A
suspicion that did not reproduce goes on the `Not reproduced` line, not in the findings. The step
after this one acts on the report without reviewing again, which it can only do if the findings carry
that much.

Then finish with exactly one of:
- "Approved" (only with `Severe remaining: no`; include PR body draft + comment drafts)
- "Needs fix"
