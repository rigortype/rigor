<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward — and verify it by the thing that decides, not by a
  proxy. Every arc this week paid that rule: #260's cluster was only half blindness, #254's premise
  measured out to zero on its own favourable corpus, #264's "jitter" would not reproduce quiet, and
  #271's minimal repro was missing a third ingredient nobody had guessed.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **The Tier-2 measurement arc is closed** (#260 #263 #254 #264 #134, PRs #261 #262 #265 #266 #267
  #270). Load-bearing records live on the issues: #260's amended decision (only the
  `discovered_classes` half of the unkillable cluster was blindness; the `param_inferred_types`
  half is ADR-67 WD6b *by construction*), and #254's two closing comments
  (`dependent-closure-kill-oracle` is **presumptively non-graduating** — the Mutator never mutates
  `def` signatures and callers read declarations, so body mutations are cross-file-invisible on
  RBS-typed code; textbringer, the favourable corpus, gave byte-identical arms).
- **Graduation numbers** (in #260's closing comments): `discovery-seeded-mutation-sites` on Rigor
  `lib` 10,252/5,580/0.5443; redmine `app/models` 2,762/464/0.1680. Tier-1 `lower_bound_typed` on
  `lib`: 2,223/12,056 (~18.4%). Mutation cache: warm/cold **0.011** on `lib` (253.8s → 2.76s) —
  but the warm path REQUIRES a prior `rigor check --incremental` snapshot for those roots,
  otherwise the cache reports itself disabled and the run is simply cold.
- **Landed 2026-08-02 after that**: #271 (PR #275) — the engine FP where a nested
  `Const = Data.define(...)` never entered the cross-file `discovered_classes` table, so a
  consumer's lexical walk fell through to the parent namespace's same-named, RBS-declared (=closed)
  sibling and reported `call.undefined-method` on correct code. The trigger needs THREE ingredients
  at once (nested Data constant + same-named parent-namespace sibling + RBS for that sibling),
  which is why the first minimal repro stayed silent. #137 (PR #276) — all four dry-rb ceiling
  checkboxes, including the `dry-validation.rule-key-mismatch` `:error` behind two all-or-nothing
  FP gates (2 firing specs against 7 decline specs). #269 (PR #274) — the missing precision
  snapshot; the fixture had been running under a silent `skip`, not a vacuous pass.
- **Open follow-ups filed from that work**: [#277](https://github.com/rigortype/rigor/issues/277)
  (a self-recursive method narrows its inferred return, making a live condition read as
  always-truthy — same FP class as #271, worked around in PR #276 with a `nested:` flag).

## Next session

- **In flight when this was written** (three agents, results not yet audited): #277 (engine
  diagnosis, main tree), #142 (LSP pool dispatch — its brief starts with an empirical check that
  the "needs a persistent Environment" precondition may ALREADY be met), #135 checkbox 1 (the
  giant-file self-mutation tier, newly affordable thanks to #257 + #270). If they landed, the
  issues carry the records; if not, their branches are named in the PR list.
- **Remaining `ready-for-agent`**: #147 (CLI editor-mode throughput: snapshot cache, `--also`,
  multi-buffer — note it overlaps #142's buffer machinery, so sequence them rather than running
  both at once), #135's four remaining checkboxes, #121 as the ongoing P3 fold category (next
  slice starts by reconciling the stale Regexp doc rows — `escape`/`quote` marked 🔲 though
  implemented — against `RegexpFolding`).
- **`ready-for-human` wanting a design pass**: #158 (the spec's `budgets:` table is still unwired),
  #152 (`&&`/`||` polarity gate beyond Constant-only), #159 (upstreaming staged ruby/rbs signature
  fixes — external publishing, needs the user's go).
- **The rbs-inline upstream report stays ON HOLD by user decision** (2026-08-01; do not file
  without a fresh ask). Evidence chain: ADR-32 WD12 + `annotation_parser.rb:323-326` → `753-764`
  → rescue at `617-621` → `annotations.rb:527-536`; plus a pending one-line ADR-32 correction (its
  "upstream docs" citation points at rbs-core's `RBS::InlineParser` doc, not the rbs-inline gem's).

## What these sessions learned that is not in a commit

- **The delegation brief that works**: fixed design ("do not relitigate") + repo contract verbatim
  + gates by exit code + parent re-runs the gates independently + **"report contradictions, do not
  silently redesign"** + **"run every gate/measurement in the FOREGROUND; never end a turn while
  anything is pending"** (three background-wait stalls before that line was added; none after).
  The contradiction hatch overturned a premise on five separate tasks — it is the highest-value
  sentence in the brief.
- **For an engine FP, add "diagnose and report the root cause even if you also fix it; retreat
  rather than land a half-understood fix"** — that is what produced #271's three-ingredient
  finding instead of a plausible patch.
- **Two FPs on our own code were found by writing ordinary code, not by looking for FPs** (#271
  while wiring a cache key, #277 while writing a plugin walker). Dogfooding surfaces the class the
  project weighs heaviest; treat "I had to work around the checker" in any agent report as a
  finding to file, not an aside.
- **Do not let a measurement agent borrow the main tree's `exe/rigor` while another agent edits
  that tree** — a diagnostic `warn` landed mid-measurement during the textbringer run. Provably
  benign that time; the isolation was luck. Pin measurements to a clean checkout or sequence them.
- **Fixture lesson for oracle specs**: equalise the knowledge axis before comparing two oracles —
  #266's brute-force cross-check reported missing cross-file *knowledge* as a closure defect until
  both features were adopted in the fixture.
