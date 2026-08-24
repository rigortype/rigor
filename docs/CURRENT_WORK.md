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

## Next session: the snapshot surface, then a release

**The report surface is done.** #439, #457, #429 and #436 are closed; #434 and #435 are open only for
their **snapshot-side** residue, which was deliberately scoped out of the three report PRs because it
touches a different artefact:

1. **#434's remaining two** — a regeneration event (a moved `config_digest:`) still prints the full
   `-symbol` diff instead of the regeneration line and the counts; and `unresolved:` arrays are half
   the snapshot's bytes (144,771 of 293,276 on redmine, lines up to 821 characters), which is
   simultaneously the half a reviewer cannot read and the half that churns on unrelated changes.
2. **#435 item 3** — drift rows carry no `file:line`, and `explain` covers the label lines but never
   an `exhaustive → not` transition, which is the drift row a reader is least equipped to interpret.

They are one PR: same file, same renderer, same specs. Close both issues with it.

**Then consider cutting v0.3.5** — see below; `[Unreleased]` is now well past the point where the
fixes are worth shipping.

**#460 is parked deliberately, not forgotten.** `Group.visible.find(id)` types `Dynamic`, which is why
redmine's write-recording `#update` figure is 3/27 rather than 27/27. It is an *inference-quality* item
— typing an AR relation touches `possible-nil-receiver`, this project's largest FP class — and the
session ruled that improving the effect numbers must not be the reason to spend that budget. v0.4.x.

Also open and independent: **#449** (`Date#to_time` overlay gap), **#427** (warm==cold gate blind on
gem-bump PRs), **#430** / **#431** (design calls).

**Landed since: #459, #461, #462, #464, #466, #467, #468, #470, #471** plus ADR-103 § WD17 and the
manual re-frame. The report went from 31,191 lines on redmine to **2,733** with nothing lost
(`--full --why` prints 34,680), gained `--label` / `--pure` / `--limit` / `--list-labels`, and a path
argument is now a view rather than a scope.
The 2026-08-24 grilling session settled four design calls in three rounds, all recorded: the
proven/declared binary **stands** (a plugin row is never judged — WD17); the **snapshot gate** is the
enforcement surface for plugin-sourced labels, which is what chapter 19 now says; a catalogue posture
**may** answer for a receiver the syntax names as a constant (#466 — redmine's IMAP/POP3 pollers prove
`io.net` again, for the connection this time); and a **bundled** plugin may declare the ancestry its own
gem introduces (#467 — mastodon `email.send` 39 → 68). One recommendation was wrong and was corrected
in flight: #463's named-constant posture **discharges** rather than keeping the `dynamic-receiver`
taint, because on a constant path there is no projection for the taint to be about.
 The last two came out of the user-story note's own issues and
both found the filed mechanism to be wrong, which is now three for three — **#455** was a union receiver,
not a `before_action` ivar; **#456** was not "the plugins attribute nothing" (rigor-actionmailer has
attributed `email.send` since #387) but three things stopping the rows matching: a plugin row could not
reach a class through an `include`, `ANCESTRY_CAP` silently truncated Rails concern lists, and an
`on_result:` row stopped one link short of the mailer. Corpus after #464: redmine 0 → 175 methods
declaring `email.send`, mastodon 0 → 737 declaring `job.enqueue`.

**The "declared lane goes quiet" family is closed.** #428 (cache hit), #441 (parallel runs), #446
(`super`), #452 (a class-level rbs-inline envelope, landed 2026-08-24 — upstream's writer emits a
*member's* annotations and a *declaration's* as nothing, so the cheapest bound in the feature bounded
nothing) — four mechanisms, all fixed. The rule they produced still binds new work here: **every path
by which a declared bound can fail to be read must end in a diagnostic, not in silence.** #459's
union-arm taint was the same rule applied to the collector.

`make verify` + `make docs-check` green on master at `fbbdf8f5`; full CI green on #459's tree, merged
at `9b6acc79` with master unmoved under it.

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
- **A correlation read off two corpus rows is not a mechanism.** #455 was filed as "a
  `before_action`-assigned ivar is untyped" because that was the visible difference between
  `GroupsController#create` and `#update`. Editing the `before_action` body to `@group = Group.new`
  changed nothing and killed the hypothesis in fifteen seconds — `find_group` is in that same class.
  **Perturb the suspected cause before filing**; the A/B that isolates a mechanism is the one where you
  change that cause and nothing else.
