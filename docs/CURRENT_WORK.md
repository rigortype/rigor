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

## State at 2026-11-19

Two pieces of work ended here; neither leaves a queue to work down.

- **The ADR-116 restructuring campaign is closed** at the pure moves (ADR-116 § "Landing point,
  2026-11-18"), and its last owed item landed (#3349: `make verify-quick` selects a mirror directory's
  specs by a time budget from `tool/spec_costs.tsv`). Read `docs/agents/code-map.md` before planning
  under `lib/rigor/`; `spec/docs/lib_file_budgets.yml` holds file sizes, and
  `inference/statement_evaluator.rb` sits one line under its budget, so new logic there goes into a
  module of its own. The redesign of the three large files is filed per file and taken up on its own:
  #3344 (`StatementEvaluator`), #3345 (`ExpressionTyper`), #3346 (`ScopeIndexer`).
- **Typing Rigor's own source (#3315) is closed** at its two end points.
  - The self-check runs with `parameter_inference: true` (`.rigor.dist.yml`) and no issue-bound
    suppression; `spec/rigor/self_check_suppressions_spec.rb` holds every `# rigor:disable` under `lib/`
    to a tabled reason and to still firing. `make coverage`, `check-incremental`, the memo audit and the
    `type_of` shadow keep the key off through `.rigor.gates.yml`
    (`spec/rigor/self_check_gates_config_spec.rb` pins the split; a new rigor-running step in
    an `acceptance-*` job must be put on one side).
  - `make coverage` holds expression precision and the share of Dynamic call sites to one-sided pins in
    `tool/coverage_ratchet.yml` (key off): 59.58% and 49.83% at #3356; with the key on, measured by
    hand, 64.75% and 43.89%. A gain is claimed by `make coverage-tighten`; moving a pin the worse way is
    an approval-queue entry. `docs/agents/measurement.md` § "The self-typing ratchet".
  - A hand-written parameter in `sig/` is checked for shape against its `def` (#3348) and counted apart
    from residue while its return stays unrenderable (#3329); `docs/agents/type-authoring.md`.
  - What is left is backlog, in order of yield: #3355 (four inference gaps behind the largest Dynamic
    roots — the memo-Hash read-back alone outweighs a batch of declarations), #3357 (declarations for
    the modules the moves created; #3354 is the worked example, about 265 call sites a batch), #3307.
- **Engine defects found on the way are filed, not owned by this work**: #3327 (ADR-67 WD6b holes),
  #3331–#3334, #3336, #3343 (loop content join), #3351 (known limitation: a non-empty fact stale after
  a mutation through an alias the engine does not link), #3352, #3342 and #3350 (tooling).
- **Approval-queue entries from this work await ratification**: `statement-evaluator-clusters.md`,
  `expression-typer-clusters.md` (the process, scope and non-empty-fact entries were ratified on
  2026-11-27).

## Next

1. Triage the current milestone (`gh issue list --milestone <name>`). Read
   `docs/agents/parallel-lanes.md` before fanning out.
2. If typing Rigor's own source is taken up again, start with #3355's gap A, not with more declarations.
