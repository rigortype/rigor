<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Hard cap: 120 lines, enforced by spec/docs/agent_index_spec.rb. Compress, do not append.
- Verify a claim before carrying it forward, by the thing that decides rather than a proxy —
  including claims in THIS file. Last session's own "next unaudited sections" pointer was wrong.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Next session: build the manual and the user stories together

**This is the release blocker the owner named**, ahead of any version bump: work the effect system's
user-facing manual and its user experience as one task — draft the manual, build the user stories that
manual implies, and **feed what the stories expose back into the feature**. Author a SKILL where the
workflow needs one. The `rigor-docs-review` skill runs the five-layer review battery over
`docs/manual/` + `docs/handbook/` and is the right instrument once there is a draft to review.

Scope: the `rigor effects` chapters, the snapshot workflow (`effects update` / `check` / `diff` /
`explain`), envelopes and `%a{pure}`, `effects.tolerated:` / `attribution:` / `envelopes:`, and the
CLI-reference sections for `rigor effects` and `rigor unused`. The system shipped with 15 CHANGELOG
entries and no reader has walked it end to end.

## Where things stand

- `make verify` + `make docs-check` green on the integrated master at `c1d8dc64`. Released version is
  still **v0.3.3**; `[Unreleased]` carries 35 entries (Added + Fixed only — nothing breaking).
- **Merged this session**: #419 (catalogue extractor's `mutate` / `raises` facets — #417, #418) ·
  #421 (#321 suppression self-ack polarity) · #422 (#369 Solid Queue roots for `rigor unused`).
- **Open PR**: #423 — the WD13 effect-budget harness + advisory CI job. CI green.
- **#322 and #323 are still open and should be closed as no-change.** Both were already pinned by
  `7591f802` (2026-07-16), three weeks before they were filed; evidence is posted on each. #322's
  substantive half — `raise Object.new` is a missed diagnostic — is split out as **#420**.

## The release plan (owner ruling, 2026-08-19)

- **v0.3.4** — ships the opt-in effect system as it stands, plus the WD13 harness. Gated on the
  manual/UX work above, not on #409.
- **v0.3.5 → v0.3.9** — the optimisation window, **#424**: bring effect collection inside the WD13
  budget.
- **v0.4.0** — a **Go / No-Go** on effects-default-on, decided against the CI band.

## The measurement that reshaped this

**WD13's cost budget does not hold.** `rigor check` with `effects: {}` costs **+9.7 % wall on redmine
and +27.9 % on mastodon** against a `≤ ~5 %` bound; RSS is within noise. The mastodon arms do not
overlap, so the direction is certain and only the magnitude wants CI confirmation. Full record:
[`docs/notes/20260819-wd13-effect-budget-verification.md`](notes/20260819-wd13-effect-budget-verification.md).

Two corrections to how the bound was being read: the 5 % names **mastodon** specifically, and
**gitlab's bound is the closure** (`Propagator.propagate` ≤ 1 s), not the run — that half is still
unmeasured and is far cheaper than it looks. First lead for #424, **unverified**: `Effects::Scanner`
takes a second full AST walk per file rather than riding `ScopeIndexer`'s descent. Profile before
optimising.

#409's other four boxes are all owner decisions: the #410 waiver, #378, `effects.lsp` semantics, and
the flip itself.

## What this session learned that is not in a commit

- **Verify a backlog item's premise before implementing it.** Two of wave 2's three issues (#322, #323)
  were already fixed three weeks before they were filed — both came from differential runs against the
  rigor-rs port that verified the *behaviour* and never checked the suite, so "no spec pins this" was
  untrue on arrival. Cheap to check, and checking is what turned #321 from "add a spec" into the real
  finding: its existing example projected to the `suppression.*` subset, which cannot distinguish
  "the surveillance was acknowledged" from "the whole line got suppressed".
- **A cost measurement needs a zero-work guard more than it needs precision.** The budget script's
  first version wrote its variant configs to a tmpdir; relative `paths:` resolve against the config
  file's own directory, so it analysed nothing, finished in 0.18 s and reported a 33 % *improvement*.
  Both arms must analyse a positive and identical file count.
- **Interleave A/B reps, and carry the ranges, not just the median.** A `target/debug/xtask` at 99.7 %
  of a core invalidated a whole batch mid-run; the timestamps (round 1 ended 08:17:31, xtask started
  08:23:34, the data breaks exactly there) are what made the clean reps separable from the ruined
  ones. Non-overlapping ranges are what let a noisy measurement still support a direction.
- **Regenerate-and-diff beats a reimplemented probe.** The catalogue audit's hand-rolled body
  extractor included the C function's signature line, which `body.text` does not, and produced a
  contaminated 53-method list with a phantom `String#replace` regression. Confirming the generator was
  byte-reproducible against the checked-in files first made the real diff trustworthy.
- **My own published cause-analyses were wrong twice** (#418's mechanism, and the `String#replace`
  claim in the correction to it). Both were corrected in the issue, the note and this file. The
  measurement that decides is the one to run before writing the explanation down.
