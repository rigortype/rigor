<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. Three items died of this in one week: a "live bug, do
  this first" refuted by its own repro (guarded since 2026-05-01), an "open" AR-lambda item fixed
  since 2026-05-28 (`fde760a2`), and ~40% of the old ROADMAP backlog already shipped.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is
the one that is wrong.

## Where things stand

- **v0.2.9 published 2026-07-11.** master accumulates toward **v0.3.0**; both mandatory pieces are
  done (deprecation clearance #94, perf recalibration #95). What else the cut carries is **not yet
  decided** — that is the next session's first job.
- The line is **evaluation** (ADR-50): outside feedback + completing the feature set toward the
  v1.0.0 freeze. The protection ceiling is a measured floor (ADR-67 WD2 spiked and deferred — do not
  re-recommend it); the next direction is the line's purpose, not another engine-precision feature.
- **Two arcs closed 2026-07-17.** The docs/flow re-org (ADR-97, ADR-98, #119): backlog → GitHub
  Issues, `docs/ROADMAP.md` deleted and gated against recreation, `CLAUDE.md` an `@AGENTS.md` shell,
  this file capped at 120 lines. The config surface (ADR-99, #170, #171): the JSON schema is a named
  source of truth, `rigor_rs:` is reserved for the Rust port, unknown top-level keys warn.
- `make verify` and `make docs-check` clean; master and `origin/master` agree.

## Next session — triage, then implement, then release

**1. Triage the backlog into the v0.3.0 cut.** 45 issues are open; **43 are unmilestoned** (17
`ready-for-agent`, 26 `ready-for-human`) and only #120 carries `v0.3.0`. They were migrated from the
old ROADMAP with a liveness adjudication, not a priority one — so nothing has yet decided what ships.
Deciding is milestone assignment: `gh issue edit <n> --milestone v0.3.0`. The `/triage` skill reads
`docs/agents/issue-tracker.md`; conventions and the label vocabulary are there and in
`docs/agents/triage-labels.md`. Area spread of the unmilestoned set: engine 19, plugins 8, editor 7,
perf 4, self-testing 3, docs 2, sig-gen 2.

**2. Implement what the triage picked.** A `ready-for-agent` issue is specified enough to start with
no human context — named injection point, constraint envelope, and the gate that proves it done. A
`ready-for-human` one needs a decision first; #120 (mature `--incremental` toward default-capable) is
the example, and its acceptance bar already exists: `--verify-incremental` (incremental == full
`--no-cache`, byte-identical), wired into CI.

**3. Release — and budget for the CHANGELOG.** `[Unreleased]` holds **55 bullets, 39 of them
multi-sentence**. Sealing them is the highest-value, most-skipped step of `rigor-release-prep`, it
needs cycle-wide context, and it is the one release step `make verify` cannot rescue. Measured
2026-07-17; plan for it rather than discovering it at the cut. **Version bumps and `rake release`
stay user-gated** — land entries, stop, and let the user drive the cut-over (AGENTS.md § Release
Cadence).

## Open, not milestoned — decide in step 1 whether these are v0.3.0

Carried from the rbs-inline arc; all three are specified:

- **`Regexp.last_match` match-success narrowing (ADR-93 WD1a).** herb gains 4
  `call.possible-nil-receiver` under `--treat-all-as-inline-rbs`: the receiver is
  `Regexp.last_match(1)` after a successful `=~` whose group always participates (`/\n([ \t]+)\z/`),
  so nil is unreachable. A pre-existing imprecision masked by herb's `-> untyped` sigs; FP-reducing
  on its own, and per the ADR-57 protocol it must land **before** ADR-93's default flip, which
  surfaces it.
- **ADR-93's `require_magic_comment:` default flip + the WD2 default-wiring decision.** Note ADR-94:
  if the rbs 3.x floor ever moves, the reader migrates to `RBS::InlineParser` and WD2/WD3 evaporate.
- **Correct ADR-94 WD2 — its `UntypedFunction` "live bug" does not reproduce.** `CheckRules` guards
  the form via `arity_eligible?` / `argument_check_eligible?` (both landed 2026-05-01, `fc1da90e` /
  `ef0dd777`); the ADR's own repro plus six variant shapes run clean (probed 2026-07-17). Adjudicate
  whether any reproducing shape exists, then fix the ADR text.

## Waiting on the user

- **Publish the staged `ruby/rbs` upstream fix** — branch `widen-strscan-resolv-stdlib-sigs` in
  `references/rbs` (widens `StringScanner#[]`, `Resolv#initialize`); push + upstream PR are the
  user's action. Tracked as #159.
- The upstream `rbs-inline` RDoc fix ([soutaro/rbs-inline#249](https://github.com/soutaro/rbs-inline/pull/249))
  is open under the user's fork; nothing to do repo-side until upstream responds.
- **rigor-rs:** the reserve pipeline (ADR-99) has its first reservation — `rigor_rs.ruby` is declared
  in our schema, so the port can implement against it and its vendored copy stops rejecting its own
  key on the next submodule bump.
