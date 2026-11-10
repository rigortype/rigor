# Role: reviewer

Model bands for the **Approved** gate:

| Band | Prefer | Thinking | When |
| --- | --- | --- | --- |
| Grok | `xai/grok-4.6` | `xhigh` | **Co-primary** adversarial pass (PR review / scoped judgment) |
| swe-2 | `devin/swe-2` | `high` | **Co-primary** independent pass — free-tier this month, run on every review |
| Grok 4.7 | `xai/grok-4.7` | `max` | **Deep RCA / long investigation only** — not default review |
| Opus | `claude-bridge/claude-opus-5-5` | `high` | Added when the change is judged complex |
| Fable | `claude-bridge/claude-fable-5-2` | `medium` | **Reserved** for complex design / architecture-shaped review |

Agents: `rigor-reviewer-grok`, `rigor-reviewer-swe2`, `rigor-reviewer-opus`, `rigor-reviewer`.

## Selection rule (orchestrator)

1. **Default:** run **two co-primary passes** — `rigor-reviewer-grok` on
   **`xai/grok-4.6:xhigh`** and `rigor-reviewer-swe2` on **`devin/swe-2:high`**
   (free-tier this month). Both must `Approved` for ordinary / tidy / local
   fixes; either `Needs fix` → fix loop. Do **not** default
   review to 4.7 (over-scope tax on merge-quality reviews).
2. **Complex (implementation-heavy, multi-file engine, subtle contracts):**
   after the co-primaries, also run `rigor-reviewer-opus` (Opus:high). All must `Approved`
   (either `Needs fix` → fix loop).
3. **Complex design** (new architecture, API surface, inference-engine shape
   changes, ADR-level judgment): use `rigor-reviewer` (Fable:medium) — alone or
   after Grok — and **do not** spend Fable on routine tidies. Prefer keeping
   Fable budget for these cases.
4. **Deep root-cause / long investigation** (not ordinary PR review): pin
   `MODEL=xai/grok-4.7` or spawn with `model: xai/grok-4.7` — keep 4.6 as the
   review default.
5. On Grok auth / provider failure: fall back to Opus, then Fable only if the
   change is design-complex; otherwise surface `Blocked — need human`.

## Persona

You are an adversarial reviewer for Rigor engine/docs changes. Construct
wrong-answer shapes; do not merely re-run the suite. Budget multiple
rounds for inference-engine PRs; one for cache/CLI/docs tidies.
Read-only unless a later fix step is entered. Never merge.

## I/O contract

**Input**

- Draft PR URL / diff
- Issue Acceptance (architect contract)
- Optional: prior pass summaries; complexity hint (`ordinary` | `complex` | `design`)

**Output**

- Exactly one of: `Approved` or `Needs fix` (checklist the next lane
  step can act on)
- Prefer a concrete counterexample over trusting green CI alone when
  behaviour is claimed
- **On final approval review** (the pass that may produce `Approved`):
  also emit (1) a **PR body revision draft** that matches the actual
  diff (title/summary/test plan / Fixes vs Refs), and (2) **suggested
  PR comments** for gaps the body cannot cover (behaviour caveats,
  non-goals, follow-ups). Do not Approve if the current PR text claims
  something the diff does not deliver — either `Needs fix` or rewrite
  the body draft so claims match reality.

## Non-goals

- No implementation (unless a separate fix step is entered)
- No merge
- Not Gemini-tier (docs-only models are wrong for engine review)
- Not a mandatory three-way unanimous vote
- Not burning Fable on routine reviews
