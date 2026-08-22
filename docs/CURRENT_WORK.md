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

## Next session: the report's usability, then v0.3.5

Every silent-failure bug the walkthrough opened is fixed. What is left of that batch is the surface
a reader actually meets, and it is what the walkthrough said stops adopters cold:

1. **#439** — a path argument narrows the *analysis*, so the same method gets a weaker answer, unmarked.
   It is also the only tractability lever the report has, which is what makes it a trap. Do it **before
   or with** #434, whose fix is what removes the reason to reach for it.
2. **#434** — 31,191 lines on Redmine, 38.5 % of rows content-free, no summary, no `--limit`.
3. **#435** (four CLI affordance gaps) · **#429** (nothing lists the vocabulary) · **#436**'s remaining
   half (should a project whose plugins register a preset *default* `reach:` to it?).

**#434, #435, #429 and #436 all touch the same `rigor effects` output surface — give them to ONE agent**,
not four. #439 is a different mechanism and separates cleanly.

Also open and independent: **#452** (a class-level rbs-inline envelope is silently inert — the fourth
instance of the declared lane going quiet), **#449** (the ActiveSupport overlay omits `Date#to_time`, so
`date.to_time(:utc)` is a false positive without the plugin), **#427** (the warm==cold gate is blind on
gem-bump PRs), **#430** / **#431** (both need a design call, not a fix).

`make verify` + `make docs-check` green on integrated master at `fbbdf8f5`.

## Consider cutting v0.3.5

`[Unreleased]` carries **11 entries**, seven of them fixes for bugs users are hitting today: the
declared-bound check inert on every warm run (#428), every `documentation_url` 404ing (#438), `save`
reporting no database write (#440), the annotations notice silent on parallel runs (#441), `Date`
degrading to untyped (#437), `super` reported as effect-free (#446), and config mistakes arriving as
backtraces (#433). **No autonomous version bumps** — this needs an explicit ask.

## What shipped, and the one pattern worth carrying

Six PRs today (#443, #444, #445, #447, #448, #450, #451, #453). The engine fixes were all one shape:

- **#428** the declared-bound check was dropped by every cache hit; **#441** the annotations notice was
  dropped on every parallel or `--no-cache` run; **#446** a `super` call contributed nothing *and the
  row still claimed to be exhaustive*; **#452** (open) a class-level rbs-inline envelope is read by
  nobody. Four ways for a declared bound to go unchecked, none of which said so.
- **The rule that generalises: every path by which a declared bound can fail to be read must end in a
  diagnostic, not in silence.** ADR-103's promise is that an unresolved call taints rather than being
  guessed at; these were all cases where nothing was even reached, so nothing tainted.

#446's fix is the model for the rest: the ancestor walk starts **above** the class and does no
closed-world override join, because a subclass is never in `super`'s dispatch path — joining it would
prove a label no execution can produce. Corpus note: `docs/notes/20260823-effect-super-edge-corpus.md`.
`rigor check`'s diagnostic stream is byte-identical between arms on redmine and mastodon.

## The v0.4.0 graduation (#409)

Five of six preconditions resolved by ADR-103 WD16; #446 was the counterweight and is now cleared.
Left: the release-notes migration note (which needs **no** lane caveat and **no** "clear your cache
first" — both cache keys carry `Rigor::VERSION`) and the flip commit itself.

## What this session learned that is not in a commit

- **A CHANGELOG slip on master goes straight into other agents' CI.** I added a duplicate `### Fixed`
  to `[Unreleased]` and #451's run went red on it before I noticed. `make docs-check` does **not** cover
  `spec/docs/changelog_conformance_spec.rb` — run that spec after any changelog edit, every time.
- **Give parallel agents disjoint worktrees, disjoint survey targets, and no CHANGELOG.** The four-agent
  wave landed clean with the changelog written centrally afterwards (now in AGENTS.md § Release Cadence);
  the wave before it hand-resolved a conflict per PR.
- **Verify the agent's finding, not just its patch.** Two reports this session were accurate about the
  observation and wrong about the cause (#441's "lane" was the run mode; #433's manual mislink was
  already fixed). Two others handed over defects worth more than the fix — #449 and #452 — but only
  because their briefs asked what else the change touched.
