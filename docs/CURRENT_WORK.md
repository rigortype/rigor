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

## Next session: build the effect manual and the user stories together

**Still the release blocker the owner named.** Draft the manual, build the user stories that manual
implies, and **feed what the stories expose back into the feature**. Author a SKILL where the
workflow needs one. `rigor-docs-review` runs the five-layer battery once there is a draft.

Scope: the `rigor effects` chapters, the snapshot workflow (`effects update` / `check` / `diff` /
`explain`), envelopes and `%a{pure}`, `effects.tolerated:` / `attribution:` / `envelopes:`, and the
CLI-reference sections for `rigor effects` and `rigor unused`. There is **no narrative chapter** in
either `docs/manual/` or `docs/handbook/` today — only reference sections in 02/03/16. The system
shipped in v0.3.4 and no reader has walked it end to end.

**Write it default-on-shaped** (owner ruling, 2026-08-22): the chapter's narrative assumes v0.4.0's default,
with the opt-in stated plainly where it bites — "v0.3.x needs an `effects:` block; from v0.4.0 it is
the default". Writing it opt-in-shaped means a full rewrite at the flip.

## Where things stand

- **v0.3.4 released** (tag `v0.3.4`, 2026-08-21); `[Unreleased]` carries one entry.
- `make verify` + `make docs-check` green on `design/effects-graduation-rulings`.
- **Open PR**: the WD16 decision record (this branch). Dependabot: #413 (rack) and #412 (rbs 4.1.3)
  are CI-green — **audit the rbs marshal patch before merging #412**; #343 (rubocop 1.89.0) fails
  Lint and needs the offences fixed; #86 stays held on the `Style/ArrayIntersect` autocorrect bug.

## The v0.4.0 graduation is nearly unblocked (ADR-103 WD16, 2026-08-22)

Five of #409's six preconditions are resolved. Two of WD15's premises were written from the design
rather than the code and did not survive contact:

- **Non-fork backends** — there is no thread backend, and the Ractor one cannot analyse a file under
  rbs 4.x (upstream `RBS::Namespace` interning). Replaced by the sequential degrade, which is sound.
  **#410 and #414 are closed.**
- **Vocabulary** — read against Steins on 2026-08-22: the `mutate` spellings already agree, `io.db.*`
  is ours and evolution-safe, and the application-meaning roots diverge *architecturally* (Steins
  keeps ecosystem labels out of its builtin set entirely). Rigor keeps them; the spec's "shared /
  MUST" claim was the thing that was wrong. Vocabulary 1 ships as it stands. #378 stays open as the
  upstream conversation, not as a gate.
- **WD13 budget** — the advisory CI `effect-budget` job is the sole arbiter. The gitlab closure
  (`Propagator.propagate` 1.34 s vs 1 s) is #424's target for v0.3.5-v0.3.9, not a gate.
- **`effects.lsp`** — editor mode stays effect-free, spelled as a key defaulting to `false`.

What is left: the **migration note** (written at the release) and the flip commit itself —
`Configuration::DEFAULTS["effects"]`, `effects-on-by-default` `FEATURES` → `GRADUATED`, the
`effects.lsp` key, manual / schema, CHANGELOG migration entry.

## Other decisions taken this session

- **#370** (`rigor unused`: a data-file mention does not rescue a declaration from the test-only
  section) — option 1: report it as its own category, "reachable from tests; also named in
  configuration". The normative tier text lands with the behaviour, not before it.

## Queue, in the order it consumes cleanly

1. #413, then #412 (rbs marshal audit first), then #343's Lint offences.
2. The manual + user stories above — the largest item, and the one the release waits on.
3. #370, #420 (`raise Object.new` polarity, on corpus evidence), #391 (`sig-gen` writes `%a{pure}`).
4. #424's propagation work in the v0.3.5-v0.3.9 window; #392 → #393 → #394 for the view slices.

## What this session learned that is not in a commit

- **Read the other repository before writing an alignment issue.** #378 asked for a three-item
  conversation with Steins; fetching `steins/docs/type-specification/effects.md` took one call and
  showed item 3 already agreed, item 1 accurately documented, and item 2 a different *kind* of
  divergence than the issue described — architectural, not lexical. It also surfaced a whole label
  family (`failure.*`) our "verbatim" claim had gone stale against.
- **A precondition can name something that does not exist.** WD15 required "the Ractor **and
  thread** backends" to carry the side-table. `pool_backend` has three arms and none of them is a
  thread pool. The issue built on it (#410) then inherited the phantom and scoped itself as "just a
  message channel". Check the premise against the code before sizing the work — the same lesson the
  last session recorded about #322 / #323, arriving from a different direction.
