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

## Next session: two design calls, then the report's usability

The effect system's *bugs* are fixed and its *surface* is filed. What the corpus adjudication
(`docs/notes/20260823-effect-user-stories-corpus.md`, ten user stories run against redmine +
mastodon) added is that two of the ten failures are not surface at all:

1. **#454 — every label a Rails policy would name is unjudgeable.** Plugin rows go to the declared
   lane (`unit_scan.rb:296`) and `EnvelopeCheck` reads the proven lane only
   (`envelope_check.rb:14-20`); both are correct, and composed they mean **no bound can ever fire on
   a database access**. `io.db.*` is proven zero times in 11,702 corpus rows. The snapshot's `≤+`
   marker *does* gate it and nothing documents that. Needs an ADR-103 WD ruling — document-only, an
   opt-in `:info` rule, or a verified-plugin-row lane — before v0.4.0 promises anything about bounds.
2. **#455 — Rails effect visibility equals ivar receiver typing.** `GroupsController#create` records
   `io.db.write` (`@group = Group.new` in the method); `#update` records nothing (same `@group.save`,
   ivar from `before_action`). 0 of redmine's 27 `#update` actions record a write. ADR-58's per-class
   ivar index does not span the superclass-writes / subclass-reads flow. This is the highest-value
   engine lever for the whole feature and it is not an effects change.

Then the surface batch, unchanged from last session and still one agent's worth:

3. **#439** — a path argument narrows the *analysis*, so the same method gets a weaker answer,
   unmarked. Do it **before or with** #434, whose fix removes the reason to reach for it.
4. **#434** (31k-line report) · **#435** (four CLI affordance gaps) · **#429** (nothing lists the
   vocabulary) · **#436** (should a preset-registering project default `reach:`?) · **#457** (the
   report has no *query* surface — `--label`, `--pure`; distinct from #434's "make it smaller").
   **All five touch the same output surface — give them to ONE agent.**

Also open and independent: **#456** (`job.*` / `email.*` have zero producers on either app, though
`rigor-sidekiq` and `rigor-actionmailer` are loaded), **#458** (`Socket.gethostname` proves `io.net`,
so 5 % of redmine reads as networked on a Message-ID lookup), **#452** (class-level rbs-inline
envelope inert), **#449** (`Date#to_time` overlay gap), **#427** (warm==cold gate blind on gem-bump
PRs), **#430** / **#431** (design calls).

`make verify` + `make docs-check` green on master at `fbbdf8f5`; `make docs-check` green again at
`3bfa7ad2` (docs-only).

## Consider cutting v0.3.5

`[Unreleased]` carries **11 entries**, seven of them fixes for bugs users are hitting today: the
declared-bound check inert on every warm run (#428), every `documentation_url` 404ing (#438), `save`
reporting no database write (#440), the annotations notice silent on parallel runs (#441), `Date`
degrading to untyped (#437), `super` reported as effect-free (#446), and config mistakes arriving as
backtraces (#433). **No autonomous version bumps** — this needs an explicit ask.

## What the corpus adjudication is good for beyond its issues

The note is the first artefact that says what the feature is *worth*, with numbers, and four stories
do work end to end — the reviewer's drift story especially (`effects check` is ten lines and exit 1;
`explain` names the call chain unprompted). Both the v0.4.0 release notes and any talk or blog post
about effects should be written from it rather than from the ADR, which describes the model and not
the value. Two figures belong in the manual verbatim: `reach:` rows are exhaustive for **2.4 %**
(redmine) / **8.7 %** (mastodon) of entry points, so **absence proves nothing** — and the ` …?` hedge
sits on nine rows in ten, where it reads as wallpaper rather than as a warning.

## The v0.4.0 graduation (#409)

Five of six preconditions resolved by ADR-103 WD16; #446 was the counterweight and is cleared. Left:
the release-notes migration note (which needs **no** lane caveat and **no** "clear your cache first" —
both cache keys carry `Rigor::VERSION`) and the flip commit itself. **#454 is now worth deciding
first**: default-on ships a `check` surface whose bounds are structurally silent on the labels Rails
users will reach for, and the migration note is where that has to be said if the answer is
"document only".

## Pitfalls this session paid for

- **The snapshot omits `exhaustive:` when it is true** (`snapshot.rb:63`). A reader doing
  `v['exhaustive']` gets `nil` on every exhaustive row and reports 0 %. Use `.fetch(_, true)`. My
  headline number was that artefact for one round.
- **`explain` is the fastest way to check whether a label means what you think.** Redmine's 215
  `io.net` rows look like SMTP and are `Socket.gethostname`; one `explain --symbol` call showed it.
  Never read a label census without sampling its origins.
- **Nix + external cwd**: `nix develop --command` must be invoked with cwd inside the rigor repo;
  `cd <target> && nix develop …` fails with "not part of a flake". Chdir *inside* the `bash -c`.
