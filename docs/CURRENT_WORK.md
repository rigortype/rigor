<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Hard cap: 120 lines, enforced by spec/docs/agent_index_spec.rb. Compress, do not append.
- Verify a claim before carrying it forward, by the thing that decides rather than a proxy —
  including claims in THIS file. Three sessions running, its own pointers have been wrong.
-->


# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones.
If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is the one that is wrong.

## State at 2026-11-18

- **The ADR-116 restructuring campaign is closed** at the pure moves (ADR-116 § "Landing point,
  2026-11-18"). `docs/agents/code-map.md` is the map to read before planning under `lib/rigor/`;
  `make verify-quick` is the between-edits gate; `spec/docs/lib_file_budgets.yml` holds file sizes.
  The redesign of the three large files is filed per file (#3344 `StatementEvaluator`, #3345
  `ExpressionTyper`, #3346 `ScopeIndexer`) and is taken up on its own, not as a queue to work down. #3289 (a time
  budget for the quick tier's directory mirror) is the one item still owed.
- **Typing Rigor's own source (#3315) is the active follow-on**, and it ends at two things: the
  self-check runs with `parameter_inference: true` (#3324), and a gate stops the share of Dynamic call
  sites from growing back. Measured before it started: 40.4% of `lib/` expressions and 50.2% of call
  sites are Dynamic, 57% of that rooted in untyped parameters.
  - Landed: #3328 (keyed reads on a union of shapes), #3329 (the provenance gate counts a
    parameter-only declaration apart from residue), #3330 (zero-start range reads).
  - #3324 turns the key on now (maintainer, 2026-11-19), with one inline suppression in
    `require_relative_closure.rb` for the row that needs both #3337 (PR #3341) and #3338 (PR #3339,
    which waits for #3340); `spec/rigor/self_check_suppressions_spec.rb` fails once the row is gone,
    and the suppression is deleted then. `make coverage` keeps the key off (`.rigor.coverage.yml`).
  - **The brake, ruled by the maintainer on 2026-11-18:** if another engine defect turns up behind
    those, stop chasing: turn the key on with an inline suppression that names the issue, and leave
    the defect to the backlog.
  - After #3324: declare the top call roots and hub parameters in `sig/` (#3335 adds the check of a
    declared parameter list against its `def`, which must land first), then add the ratchet.
- **Engine defects found on the way are filed, not owned by this work**: #3327 (ADR-67 WD6b holes),
  #3331–#3334, #3336, #3342, #3343.
- **Two approval-queue entries from the campaign await ratification**:
  `statement-evaluator-clusters.md` and `expression-typer-clusters.md`.

## Next

1. Land #3324; then #3340, #3339, #3341 (deleting the suppression) and #3335; then the `sig/`
   declarations and the ratchet.
2. Triage the current milestone (`gh issue list --milestone <name>`). Read
   `docs/agents/parallel-lanes.md` before fanning out.
