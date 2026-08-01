<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward — and verify it by the thing that decides, not by a
  proxy. Read exit codes, diff structured output, and treat a subagent's summary as a claim to
  check, not a fact: this session caught one contradicting its own evidence and one citing a
  memory slug as a repo path.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **Merged this cycle** (2026-08-01, one session, all gates by exit code):
  - [#255](https://github.com/rigortype/rigor/pull/255) / #252 — the bleeding-edge overlay carries
    **behaviour features**: `Feature` has a `kind:`, call sites ask
    `Configuration#bleeding_edge_active?(id)` (raises on an unregistered id — deliberate; config
    stays inert), `GRADUATED` implements WD7. Plus a documented constraint: a behaviour feature
    must not change `check` analysis output unless its id enters the cache identity — severity is
    safe only because `SeverityStamp` resolves post-cache.
  - [#256](https://github.com/rigortype/rigor/pull/256) — CI gains the standalone
    `self-check-bleeding-edge` job (`check --bleeding-edge lib`, cold, required): WD2's "Rigor's
    own CI exercises the overlay", and graduation insurance. Deliberately NOT a matrix axis.
  - [#257](https://github.com/rigortype/rigor/pull/257) / #134 slice 1 — the Tier-2 mutation loop
    fork-maps; `--workers` finally reaches it. The larger find: **`ForkMap` never re-armed YJIT
    after fork** — the pool was a pessimization (67s at 8 workers vs 37s sequential) and Tier 1 +
    parameter-inference carried the same latent deficit. 8-worker Tier-2: 23.2s.
  - [#258](https://github.com/rigortype/rigor/pull/258) — `Jit.rearm_after_fork` carries the
    parent's *remaining* deadline (monotonic, grandchild-inheriting). 8-worker: 21.3s.
  - [#259](https://github.com/rigortype/rigor/pull/259) / #253 — Tier-2 site selection seeds
    Tier 1's cross-file discovery, behind the `discovery-seeded-mutation-sites` behaviour feature
    (off by default; the ratio `--threshold` pins would drop).
- **Measurement record**: [#253's comment](https://github.com/rigortype/rigor/issues/253#issuecomment-5149563175)
  (the seed's real effect), `docs/notes/20260801-tier1-protection-yjit-remeasure.md` (fresh
  Mastodon Tier-1 reference: 0w 18.2s / 4w 15.3s / 8w 12.8s quiet, RSS 813→354 MB, sites
  identical across worker counts).

## Next session

- **[#260](https://github.com/rigortype/rigor/issues/260) is the sharpest open item.** #253's
  measurement showed newly-admitted seeded sites are **structurally unkillable** (`lib`: +2,183
  sites → +2,187 survivors): the seed provides class identity but not the cross-file method
  table, so `Account.find` is measured and nothing can kill it. Two candidate fixes are in the
  issue (seed the oracle's def index vs admit only oracle-actionable sites); the decision rides
  *inside* the existing feature id while it is ungraduated. Settle it before quoting any
  graduation number.
- **Corrections to carry, not re-derive**: the #134 investigation's "+0.6% sites" was wrong by
  ~40× (real: +27% Rigor lib, **+92%** redmine app/models; ratio −48% rel) — its probe modelled
  only the constant-receiver arm and `param_inferred_types` contributes more. The ON arm is not a
  strict superset of OFF (a seed can legitimately resolve an anchor to a Dynamic drop).
- **[#254](https://github.com/rigortype/rigor/issues/254)** (project-wide kill oracle) is the
  remaining member of the graduation cluster; #134 slices 2-3 (the ADR-46 forward-edge result
  cache + the incremental==cold gate) are the remaining speed work, now cheaper to validate with
  the loop fork-mapped.
- **#134 / #135 / #137 (remaining slices)** are still the `ready-for-agent` pool; #121's
  enumerated remainder (Set projections, Tuple `first(n)`-family, `Regexp.compile`,
  `abs2`/`rationalize`) is unclaimed.
- **Unfiled upstream report** (small, external, needs maintainer sign-off): `rbs-inline` parses
  `# @rbs module-self: Foo` and discards it — the defect behind ADR-32 WD12.

## What this session learned that is not in a commit

- **Delegation pattern that worked**: fixed design decisions in the brief (marked "do not
  relitigate"), the binding repo contract restated verbatim, gates by exit code, and the parent
  re-running the gate independently before push. Two agents in parallel = one on the main tree +
  one in a worktree (worktree needs the `vendor` symlink + `.bundle/config` copy; never commit
  the symlink).
- **A perf measurement taken while other agents run `make verify` is garbage** — queue it. And
  when a load caveat is honest ("indicative, not clean"), the quiet re-run is cheap and upgrades
  the note: this session's showed the load penalty lands almost entirely on the *sequential* arm,
  flipping the apparent parallel ratio.
- **`fork` copies only the calling thread.** Any deferred work armed on a background thread —
  YJIT deadlines, timers — silently dies in every child. `PoolCoordinator` knew; `ForkMap`
  didn't; grep for `Thread.new` near any new fork site.
- **A required CI job asserting "clean under the queued overlay" must be preceded by proving the
  tree is clean under it** — it was (exit 0), which is what made #256 a one-PR change.
