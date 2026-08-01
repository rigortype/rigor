<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward — and verify it by the thing that decides, not by a
  proxy. Read exit codes, diff structured output. A previous session shipped a "make verify green"
  claim read out of a grep that could not see "1 offense detected"; CI saw it.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **Merged since the last handoff:**
  - [#247](https://github.com/rigortype/rigor/pull/247) / #246 — the LSP publishes **whole-project**
    diagnostics to every open buffer on `didSave`, from an in-process `IncrementalSession` seeded
    from the snapshot and never written back. A dirty buffer is excluded except as itself. This was
    the "unfiled, needs a design call" item the previous handoff pointed at; the seven decisions are
    in `docs/design/20260517-language-server.md` § "Whole-project publishes on save".
  - [#248](https://github.com/rigortype/rigor/pull/248) / #137 — `SomeSchema.call(input).to_h`
    returns the schema's own `HashShape`. A `required` row becomes a required key and an `optional`
    row an optional one — the declaration's vocabulary, not `to_h`'s worst case, because typing every
    key as possibly-absent draws a nil error inside an `if result.success?` branch.
  - [#249](https://github.com/rigortype/rigor/pull/249) — an undeclared key on an **open** `HashShape`
    reads as `untyped` instead of `Constant[nil]`. The `extra_keys:` policy had only ever been
    consulted in `Inference::Acceptance`, never on the element-read path.
- **Open:** [#250](https://github.com/rigortype/rigor/pull/250) / #121 — `"widget".freeze` keeps its
  value. Corpus-measured: twenty projects, 9,548 diagnostics, byte-identical, fold fires 295 times.
- `make verify` and `make docs-check` green on `constant-self-returners` (checked by exit code).

## Next session

- **[#134](https://github.com/rigortype/rigor/issues/134) is rewritten and ready.** Its original
  premise was wrong — there is no whole-project cold re-scan per mutant, and ADR-46's `dependents`
  index answers a question the current oracle never asks. The investigation is
  [in the issue](https://github.com/rigortype/rigor/issues/134#issuecomment-5148902570) and the body
  now carries three slices. Slice 1 (fork-map the Tier-2 file loop; `--workers` is parsed but returns
  before `resolve_workers` on that path) is independent of the other two and the largest win per unit
  of effort. **Two findings were deliberately left out of #134 and are unfiled:** a project-wide kill
  oracle, and the Tier-2 site filter's bare `Scope.empty` where Tier 1 seeds `discovered_classes`.
  Both would move the reported effectiveness number that `--threshold` gates CI on, so both need a
  versioning decision rather than a perf PR.
- **#121 is now enumerated rather than open-ended.** A probe sweep (positive controls on every tier)
  found the self-returner family as the one gap with real-world weight — that is #250. The remainder,
  ranked: Set element projections (`min`/`max`/`first`/`sort`/`sum`/`to_set` leak `Dynamic[top]` on a
  carrier whose elements `to_a` already folds), `Tuple#first(n)`/`last(n)`/`sum(init)`/`count(obj)`
  (~15 lines; `take`/`drop`/`min(n)` already do it), `Regexp.compile` (one symbol next to `:new`),
  `abs2`/`rationalize` in the Integer/Float unary sets. **Predicate-shaped folds are disqualified** —
  a bool fold newly surfaces `flow.always-truthy-condition`, demonstrated live.
- **[#134](https://github.com/rigortype/rigor/issues/134) / [#135](https://github.com/rigortype/rigor/issues/135)**
  (self-testing) and the rest of **[#137](https://github.com/rigortype/rigor/issues/137)** (three
  dry-validation ceiling slices) are the `ready-for-agent` remainder.
- **Still deliberately not queued:** [#147](https://github.com/rigortype/rigor/issues/147) and
  [#142](https://github.com/rigortype/rigor/issues/142). Phase attribution says the remaining editor
  levers are small; do not start #147 on its stated estimate.
- **Unfiled upstream report** (small, external): `rbs-inline`'s parser accepts
  `# @rbs module-self: Foo` and its writer then discards it — the defect behind ADR-32 WD12. Needs
  maintainer sign-off because it is an external filing.

## What this session learned that is not in a commit

- **The coverage docs over-report, and now by name.** `20260522-stdlib-deterministic-module-coverage.md`
  carries no staleness warning and its 🔲 rows are wrong for every CGI escape/unescape function, all
  four URI `*_component` functions, and `Regexp.escape`/`quote` — all fold today. Math, CGI and
  Shellwords are **complete** and can be marked so. `20260522-type-method-coverage.md`'s 2026-07-31
  warning is scoped to §5 only; ~22 String rows above it are equally stale. Probe before implementing
  against any of these.
- **`rigor annotate` beats `type-of` for a coverage sweep** (one call types every line), and
  **`type-scan` is useless for it** — it reports whether a node got *a* type, never whether that type
  is precise.
- **A fold's blast radius is not the method you changed.** Value-pinning a constant is only
  interesting because of what becomes decidable downstream; the thing to measure is the *diagnostic*
  set, not the folded site. The corpus zero for #250 rests on a condition worth remembering: the pin
  does not survive a cross-file constant read (`Dynamic[top]` today). Same-file definition + predicate
  does draw the warning.
- **A subagent's confident summary can contradict its own evidence.** The #250 corpus report claimed
  `CONST = <literal>.freeze` was "extinct — 0 hits in all 20 projects" while citing `haml`'s
  `ID_KEY = 'id'.freeze` two sections earlier. The measurement was sound; the generalisation was not.
  Take the numbers, re-derive the story.
- **A PostToolUse formatter rubocop-autocorrects scratch fixtures written with the Write tool** —
  it deleted a probe's `pc3 = 2 + 3` outright as a useless assignment. Write probe fixtures with a
  Bash heredoc.
