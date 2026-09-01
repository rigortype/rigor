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

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones.
If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is the one that is wrong.

## Where the cycle stands

The 2026-09-01 session ran the 25-target corpus opacity sweep, filed the mechanism backlog
(#518–#534, #539–#545, #553), and landed waves 0–3 of the fixes as **21 PRs** (one merged, twenty
green and waiting). Synthesis: [`docs/notes/20260901-corpus-opacity-attribution.md`](notes/20260901-corpus-opacity-attribution.md);
harness + per-target reports on branch `opacity-sweep-harness-20260901`.

## FIRST: twenty green PRs wait on merge (the classifier blocks `gh pr merge` for agents)

Every PR was verified standalone AND on a local all-in integration (all gates green; corpus below).
Merge order:

1. **[#536](https://github.com/rigortype/rigor/pull/536) #537 #545 #546 #547 #548 #549 #550 #551 #552 #554 #555 #556 #559 #561** — independent, any order.
2. Two stacks, same discipline — merge the base, `gh pr edit <top> --base master`, wait for CI,
   merge; do not let the auto-retarget race you (the stacked-PR trap):
   **[#538](https://github.com/rigortype/rigor/pull/538)** then **[#543](https://github.com/rigortype/rigor/pull/543)**;
   and **[#556](https://github.com/rigortype/rigor/pull/556)** then BOTH
   **[#557](https://github.com/rigortype/rigor/pull/557)** and **[#558](https://github.com/rigortype/rigor/pull/558)**
   (the check side and the overload-selector side of the same alias work — mutually independent,
   each retargets to master after #556; both corpus arms byte-identical to #556's).
3. Expect textual merge conflicts where several branches appended to the same spec-file tail and to
   `expression_typer.rb` / `scope_indexer_spec.rb` — every one resolves as "keep both sides", BY
   HAND (diff3 shows the base). A mechanical both-sides concatenation duplicated shared context and
   broke `expression_typer.rb` in this session's own integration check. Two conflicts are NOT
   keep-both: `try_user_method_inference` (#549's `method_name:` kwarg + #555's carrier gate — keep
   #549's signature with #555's gate line), and #537 vs #556 in `rbs_dispatch.rb` (keep #537's
   `join_candidate_returns` and thread #556's `alias_expander: environment.rbs_loader` into it as a
   kwarg it passes to the translator); and #537 vs #558 in `overload_selector.rb` (keep #537's
   array-valued passes, adopt #558's hash-bundle `run_selection_passes(overloads, shared)` signature
   with `alias_expander:` in the bundle). After all twenty: `make verify` on the integrated master
   and re-prime the diagnostics slot with a `check` run.
   Note #554 bumps the cache `SCHEMA_VERSION` (6 → 7), so the first post-merge run is cold.
   #556 costs ~+5.5% lib cold self-check wall (after its expansion-memo commit; rest is inherent).

**Integrated corpus (11 targets vs pre-session master, all adjudicated in the PR bodies): +39 / −70**
(re-collected after each late PR; byte-identical through #558, then #559 killed mail `chars.rb:240` —
the #553 phantom-Hash `.pack` FP — and #561 killed redmine `import.rb:274`, #560's live case).
The 39: **11 true-positive bug finds** (mastodon `quote_request.rb` nil-deref ×8 with the code's own
"TODO: raise if status is nil"; textbringer LSP `stderr` crash paths ×2; redmine `diff_table.rb:153`
`=` for `==`), 22 `def.return-type-mismatch` warnings against textbringer's own drifting sig (the
contradiction rule's job), 4 worst-case-sound `String?` reads, 2 FPs filed as #542, 1 borderline (#553's FP is FIXED by #559,
which closes that issue on merge).
The 70 removed are all false positives (39 of them undefined-method FPs the #554 extend fold clears).
Integrated `lib` precision, measured same-day paired: master 59.8% → **61.3%**
(`make coverage` gate re-pinned 0.57 → 0.58 in #535; #556 alone is +1.0pp of the gap); mastodon coverage +1.16pp from #551 alone,
protection +0.30pp from #548. Perf: #547 costs ~+12% cold-check wall on redmine (interleaved 3-rep),
~+5% mastodon — measured, disclosed in its PR with the memo-key optimization headroom.

## What the sweep's backlog still holds (all with verified repros)

- **[#527](https://github.com/rigortype/rigor/issues/527)** ancestor/include walk family
  (ready-for-human design pass) · **[#525](https://github.com/rigortype/rigor/issues/525)** Struct.new
  factories (block-def dispatch fixed by #555; in-body member reads + do-block `self` scoping remain,
  residuals on the issue) · **[#529](https://github.com/rigortype/rigor/issues/529)** RBS
  Alias/Intersection (CLOSED by #556-#558 — inference, check side, and overload selection all
  wired; the expansion memo landed in #556) ·
  **[#530](https://github.com/rigortype/rigor/issues/530)** WD9 under-claiming ·
  **[#534](https://github.com/rigortype/rigor/issues/534)** remaining Rails surfaces (the
  `Parameters#[]` half needs a rules-level decision — its non-nil typing folded five working
  controllers, analysis on the issue).
- Demoted with analysis on the issue: **[#531](https://github.com/rigortype/rigor/issues/531)**
  (`Array.new(n, fill)` — the naive fix trades ~500 corpus sites of `possible-nil-receiver` noise;
  needs in-bounds-index modeling or a rules decision) · **[#541](https://github.com/rigortype/rigor/issues/541)** /
  **[#542](https://github.com/rigortype/rigor/issues/542)** (attr_writer ivar surface, Hash.new
  default — both ready-for-human). #532/#533 keep small residuals listed on the issues
  (compound-write widening parity, conditional superclasses, the ragel loop-fixpoint analysis; the
  `Queue`/`SizedQueue` item died on verification — rbs core already ships the class aliases and the
  engine resolves them — and `Proc#[]` grew into a lambda-literal design note, both on #533); **[#553](https://github.com/rigortype/rigor/issues/553)**
  (the index-written-Array-param Hash-synthesis bug #554's gate unmasked) is FIXED by #559 ·
  **[#560](https://github.com/rigortype/rigor/issues/560)** filed at the close (stale element
  evidence under mutation): #561 lands the slot-rewriting half (+0/−1 corpus; its unscoped draft
  drew 8 haml FPs — the scoping to VALUE_REWRITING_MUTATORS is load-bearing); the ADDED-value join
  (`u.push(6); u.last == 6` still folds falsey) stays open on the issue.

## Findings worth more than the numbers

- **Corpus-gating precision levers keeps paying**: five latent wrong-type families surfaced only as
  precision rose (#539 Set#any? block fold, #540 mutated literal constants, #541 attr_writer-pinned
  ivars, #544 indexed-`||=` invention, the `class << self` def-sig mislookup fixed in #547) — each
  fixed or filed at its root, several deleting PRE-existing baseline FPs.
- **The integration run catches what no branch CI can**: #547's binder made #536's fixture stop
  exercising its decline path (fixed by pinning the fixture to a post-param shape), and mail's
  `always-falsey` fold needed #537+#544 together to die.
- Textbringer is the adjudication-heavy target: `def.return-type-mismatch` bursts there are usually
  its handwritten sig drifting, not a regression.

## Pitfalls that still bind

- The corpus baseline arms live in the session scratchpad; re-collect from a master-pinned worktree
  (`git worktree add --detach` + `.bundle/config` + vendor symlink) before gating the next engine
  change, and regenerate the two apps' `.rigor-ab.yml` (committed config minus `baseline:`) — a
  cleanup deleted them mid-session and one arm silently measured against the committed baseline
  (the tell: −787/−2306 with "silenced by baseline" in stderr).
- The sweep probe on the harness branch predates #535 — re-run post-merge before sizing new levers.
- Never compare post-#535 coverage ratios to older numbers; `rigor coverage` is plugin-aware now.
- Read a gate's exit code in its own call; PHASED A/B only for diagnostic sets, never timings.
