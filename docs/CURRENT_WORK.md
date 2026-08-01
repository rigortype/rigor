<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward — and verify it by the thing that decides, not by a
  proxy. This arc kept paying that rule: #260's cluster was only half blindness, #254's premise
  measured out to zero even on the favorable corpus, and #264's "jitter" would not reproduce on a
  quiet machine.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29). No version bump is due — releases wait for an explicit ask.
- **The whole Tier-2 measurement arc is closed** (2026-08-01/02, two sessions, six PRs merged —
  #261 #262 #265 #266 #267 plus the #253 seed PR before them — and #260 #263 #254 #264 all closed;
  every merge: audited diff + CI fully green + parent-re-run `make verify` exit 0; autonomous
  merges are user-authorised, recorded in memory):
  - The Tier-2 denominator, oracle knowledge, closure reach, Tier-1 over-claim annotation, and
    harness-error visibility are all landed and measured. The load-bearing documents are #260's
    amended decision and #254's two closing comments.
  - **`dependent-closure-kill-oracle` is presumptively NON-graduating**: textbringer (52 RBS
    files, dense fan-out — the predicted-favorable corpus) produced byte-identical OFF vs closure
    arms. Structural reason, verified: the Mutator never mutates `def` signatures, and callers
    read declarations when they exist — so body mutations are cross-file-invisible on RBS-typed
    code by construction, and the inferred-return channel is worth +2 kills on Rigor lib / 0 on
    redmine. Revival requires a signature-perturbing operator or an inferred-return-heavy corpus
    (recorded on #254 with the retirement-evidence pointer).
  - **#264's premise corrected at landing**: the ±3-site jitter was load-tied (six instrumented
    quiet runs, zero rescued exceptions, byte-identical pairs); the blanket-rescue invisibility
    was the real defect and is fixed (`harness_errors` bucket, ratio-excluded, JSON-unconditional,
    stderr warning at floor 3, exit semantics untouched).
  - Graduation numbers for `discovery-seeded-mutation-sites` (in #260's closing comments): Rigor
    `lib` 10,252/5,580/0.5443; redmine `app/models` 2,762/464/0.1680 (66.2% of ON survivors on
    project-class singletons). Tier-1 `lower_bound_typed` on `lib`: 2,223/12,056 (~18.4%).

- **2026-08-02 continuation, same audited-merge flow**: [#270](https://github.com/rigortype/rigor/pull/270)
  closed #134 (per-file mutation-result cache on the ADR-46 forward edge — **warm/cold 0.011**
  on `lib` (253.8s → 2.76s), leaf edit 3.05s, hub edit 21.5s; plus the `make check-mutation-cache`
  warm==cold CI gate, non-vacuous by construction). [#268](https://github.com/rigortype/rigor/pull/268)
  closed the #121 enumerated remainder (`Regexp.compile`, `Integer#rationalize` 0-arg,
  `Integer`/`Float#abs2`; the `rationalize(eps)` surface deliberately stays declined —
  catalog-import decision, not a fold tweak). Warm mutation runs REQUIRE a prior
  `rigor check --incremental` snapshot; no snapshot = reported-disabled, cold behaviour.
- **Filed**: [#269](https://github.com/rigortype/rigor/issues/269) (missing
  `non_empty_refinement_mutation_widening` snapshot — two sessions tripped on the stray),
  [#271](https://github.com/rigortype/rigor/issues/271) (engine FP: cross-file consumed factory
  return resolves a nested `Result` Data to the parent namespace's sibling — found wiring PR #270,
  worked around via `PluginFactFingerprint.key_digest`, root cause open, `area:engine`).

## Next session

- **[#271](https://github.com/rigortype/rigor/issues/271) is the sharpest open item** — an FP on
  our own lib, the class the project weighs heaviest. Diagnosis entry point is in the issue
  (revert the `key_digest` indirection locally, `rigor check lib`); the minimal repro attempt
  failed, so start from the real file pair.
- **The `ready-for-agent` pool**: #137 (dry-schema/validation ceiling slices), #147 (editor-mode
  throughput), #142 (LSP Ractor pool), #135 (self-mutation giant-file tier), #269 (small snapshot
  hygiene). #121 stays open as the P3 category — next slice starts by reconciling the stale
  Regexp doc rows (`escape`/`quote` marked 🔲 but implemented) against `RegexpFolding`.
- **`ready-for-human` items wanting a design pass**: #158 (inference budgets table — the spec's
  `budgets:` is still unwired per memory), #152 (`&&`/`||` polarity gate beyond Constant), #159
  (upstreaming staged ruby/rbs signature fixes — external publishing, needs the user's go).
- **The rbs-inline upstream report stays ON HOLD by user decision** (2026-08-01; do not file
  without a fresh ask). Evidence chain: ADR-32 WD12 + `annotation_parser.rb:323-326` → `753-764`
  → rescue at `617-621` → `annotations.rb:527-536`; plus the pending one-line ADR-32 correction
  (its "upstream docs" citation points at rbs-core's `RBS::InlineParser` doc, not the rbs-inline
  gem's).

## What this session learned that is not in a commit

- **The delegation pattern is now settled**: fixed design in the brief + repo contract verbatim +
  "report contradictions, do not silently redesign" + **"run every gate/measurement in the
  FOREGROUND with a generous timeout; never end a turn while anything is pending"** (three
  background-wait stalls on day 1, zero on day 2 once the rule moved into the brief). The
  escape hatch overturned a premise on four consecutive tasks — treat a subagent's contradiction
  report as the most valuable line in its output.
- **Do not let a measurement agent borrow the main tree's `exe/rigor` while another agent edits
  that tree** — a #264 diagnosis `warn` landed in `mutation_scanner.rb` mid-measurement of
  textbringer. It was provably benign (warn-only, zero firings, deterministic reruns), but the
  isolation was luck, not design: pin measurements to a clean checkout or sequence them.
- **A "deliberate" old comment and a filed issue premise are both claims**: the Tuple `first(n)`
  decline was stale, the #254 catch-in-callers example cannot exist under the body-only mutation
  contract, and #264's jitter was environmental. The verify-by-the-thing-that-decides rule from
  this header keeps being the highest-yield habit in the repo.
