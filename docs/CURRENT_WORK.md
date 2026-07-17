<!--
Maintainer note (stripped from an agent's context if imported; free to read here).

This file is a BOOKMARK, not a log. It answers one question: what should the next session do?

- Do not append a session narrative. What shipped is CHANGELOG.md's job; what was measured is a
  docs/notes/ note's; what was decided is an ADR's; what is queued is ROADMAP.md's. An arc that
  cites its own note (they all do) has already been recorded — writing it here too is the copy that
  goes stale, because nothing gates it.
- REPLACE the "Next session" section when you take work across the finish line. Do not add a
  "PREVIOUS" block under it.
- Verify a claim before carrying it forward. On 2026-07-17 this file's #1 item ("a live bug, do this
  first") was refuted by running its own repro — the guard had been in `lib/` since 2026-05-01.
-->

# Current Work — Resume Bookmark

Transient. The next session's entry point, plus engine-internal items not captured elsewhere.

Superseded by, in order: [`docs/ROADMAP.md`](ROADMAP.md) (backlog + release strategy),
[`CHANGELOG.md`](../CHANGELOG.md) (what shipped), [`docs/adr/`](adr/README.md) (decisions),
[`docs/notes/`](notes/README.md) (measurements). **If this file disagrees with one of them, it is the
one that is wrong.**

## Where things stand

- **v0.2.9 published 2026-07-11.** master accumulates toward **v0.3.0**, whose two mandatory pieces
  are both done: the hard-deprecation clearance ([#94](https://github.com/rigortype/rigor/pull/94))
  and the perf-baseline recalibration ([#95](https://github.com/rigortype/rigor/pull/95)). What else
  v0.3.0 carries is open — see ROADMAP § "The next cut — v0.3.0".
- The `0.2.x`/`0.3.x` line is **evaluation** (ADR-50): gather outside feedback and drive the planned
  feature set toward v1.0.0, the hard contract freeze. The protection ceiling is a **measured floor**,
  not a missing slice (ADR-67 WD2 was spiked and deferred; do not re-recommend it) — so the next
  direction is the evaluation line's purpose, not another engine-precision feature.
- `make verify` and `make docs-check` are clean.

## Next session

1. **`Regexp.last_match` match-success narrowing — [ADR-93](adr/93-default-rbs-inline-ingestion.md)
   WD1a.** herb gains 4 `call.possible-nil-receiver` under `--treat-all-as-inline-rbs`: the receiver
   is `Regexp.last_match(1)` after a successful `=~` whose group always participates
   (`/\n([ \t]+)\z/`), so nil is unreachable at runtime. A pre-existing engine imprecision that
   herb's `sig/`'s `-> untyped` had masked. FP-reducing on its own merits, and per the ADR-57
   protocol an artifact is fixed at root **before** the change that surfaces it lands — so this gates
   item 2.
2. **ADR-93's default flip + WD2 default-wiring — only after 1.** WD1's gate is landed and the mode
   is safe (four annotation-free corpora byte-identical); what remains is flipping the plugin default
   (`require_magic_comment:` is `true` today) and deciding WD2 (presence-gated default-wiring, a
   recorded partial reversal of the ADR-27/31 auto-load deferral). Note
   [ADR-94](adr/94-rbs-inline-reader-and-the-rbs-3x-floor.md): if the rbs 3.x floor ever moves, the
   whole reader migrates to `RBS::InlineParser` and WD2/WD3 evaporate — do not over-invest.
3. **Correct ADR-94 WD2 — its `UntypedFunction` "live bug" does not reproduce.** WD2 states that a
   `(?)` method type in a hand-written `.rbs` "crashes `rigor check` today" with `NoMethodError:
   undefined method 'required_positionals'`, and calls the fix a prerequisite of any reader
   migration. It is not: `CheckRules#arity_eligible?` and `#argument_check_eligible?` both guard the
   form — with comments naming this exact case — and both landed 2026-05-01 (`fc1da90e`, `ef0dd777`).
   Probed 2026-07-17 across seven shapes (arity, return use, singleton, in-block, with-block): the
   ADR's own repro runs clean. Either WD2 is stale, or the reproducing shape is not the one it
   documents; adjudicate, then correct the ADR rather than leaving a normative record asserting a bug
   that is not there (ADR-92's discipline, in the other direction).

**Also open:** the env-quarantine CI-visibility follow-up (turn the `signature_paths:` quarantine
`warn` into a diagnostic / non-zero exit) — needs a severity decision first, because a new rule id is
ADR-50 v1.0-frozen vocabulary. ADR-92's carry-overs: `void`'s remaining intent needs `static.*` plus a
`void_origins` side-table (ADR-75's pattern — provenance is metadata *about* a value, so `void → top`
plus an identity-keyed side-table reaches the intent without a carrier or a lattice fork);
`internal-spec`'s other documents were never swept; the prose-clause body stays ungated by design
(ADR-92 WD1), so the manual probe remains the only instrument there.

## Gotchas (load-bearing, learned the hard way)

- **A worktree isolates the ENGINE, never a PLUGIN.** `exe/rigor` unshifts its own tree's `lib/`, so
  `$worktree/exe/rigor` measures that worktree's engine — but `plugins/` still resolves from the main
  repo, so a worktree "before" run silently loads the *modified* plugin and the diff comes out empty.
  It presents as a **passing** gate. For a plugin change swap the directory instead:
  `git checkout origin/master -- plugins/rigor-<name>` (plus `rm` any file the change adds), run the
  before side, then `git checkout HEAD -- plugins/rigor-<name>`. Verify with `rigor plugins`, which
  prints each manifest's version.
- **`make verify` gates only `lib` + `plugins` — the external corpus still exposes false positives**
  from receivers Rigor mistypes. Never widen a union / nilable-receiver diagnostic on a clean
  `make verify` alone; diff a `rigor-survey` corpus first:
  `cd $proj; BUNDLE_GEMFILE=$rigor/Gemfile nix develop $rigor -c bundle exec $rigor/exe/rigor check --no-cache --no-baseline app`.
  Survey checkouts carry a `mise.toml` needing `mise trust`; `git stash push -- <tracked files>`
  (untracked paths error and stash nothing). Never run two `rigor` processes against one target —
  cache-lock contention corrupts the run.
- **Adjudicate against the framework's own source, not the symptom.** A GENUINE verdict on a hot
  production code path is presumptively-FP until confirmed against the library's source: two GitLab
  "bugs" overturned to FP that way, and the grape slice's whole plan description was written from the
  symptom and was wrong about the mechanism (the helper names come from a runtime table no static
  parser can enumerate). Read the target library before modelling it — and treat a stale "blocked on
  X" code comment as a hypothesis, not a fact (ADR-57 WD3's slice was sized off one and came in at a
  fraction of the estimate).
- **Un-inerting a big plugin on a big app surfaces a long tail of FP classes** — adjudicate every new
  firing against a `schema.rb` corpus (Mastodon) before shipping (the `structure.sql` slice found
  three).
- **Validate RBS core-class reopens against a project that loads the stdlib.** `ERB`/`CSV` are
  **classes** in rbs, not modules; a `module ERB` reopen raises `DuplicatedDeclarationError` that
  collapses the whole env to `RBS classes available: 0` — this repo does not load erb/csv, so
  self-check cannot catch it. Wrap nested classes in an explicit parent, and run the affected spec in
  isolation (binpacker masks order-dependent failures).
- **`dump_type`-via-`check` is the ground truth** — single-file `dump_type` probes are wrong for
  cross-file symbols. Analyze the whole directory.
- **Prove the path is exercised before trusting a green run.** A clean corpus result proves nothing
  until you instrument it (29 real `Void` translations in kramdown; 61 mail files matching
  `#:nodoc:`) — that is what separated a real no-op from a vacuous one, twice. The same failure in
  aggregate form: a `--depth 1` clone collapses every commit to one author/date, and "158 `nodoc`
  references" was 49 first-party + 128 vendored. ADR-82's group-dominant metric was lossy for exactly
  this reason.
- **rbs-inline** — the `# rbs_inline: enabled` magic comment is **mandatory** by default (ADR-32
  WD2): a test omitting it measures the plugin being *absent*. Upstream emits no declaration at all
  for a toplevel `def` (ADR-32 WD9). `Prism::Location#start_offset` counts **bytes** while
  `String#insert` indexes **characters** — use `start_character_offset`, or a rewrite lands mid-word
  on any multi-byte file (ASCII-only fixtures stay green through it).
- **ADR-46** — do NOT extract the `Runner#initialize` ivar pre-seeds (`@class_decl_paths_snapshot = {}`
  etc.) into a helper; moving them out of the constructor hides them from the engine's OWN flow
  analysis and `make check` self-flags `snapshot.size` as a nil-receiver FP. Keep them inline.
- **ADR-24** — a check-rules *reimplementation* of self-call resolution diverges from the engine's
  real one and produced 135 FPs (reverted). The landed route is the evaluation-time
  `SelfCallResolutionRecorder`: collect, don't recompute.
- **Perf measurement** — warm numbers are comparable only within one process model (an in-process
  cold-then-warm chain is ~186k allocs cheaper than a fresh-process warm, which manufactures a
  phantom regression). Self-check allocations require `vendor/bundle` present (~8M allocs of vendored
  sigs). A peak-RSS rise on a run over ~5s is the deadline **YJIT**, not a leak — A/B with
  `RIGOR_DISABLE_YJIT=1` before diagnosing. Details:
  [`20260713-corpus-perf-campaign.md`](notes/20260713-corpus-perf-campaign.md).
- **bench-perf** — the target is `bench-perf`, not `bench`. Both baselines (`bench/baseline.json`,
  `data/oss-sweep/mastodon-thresholds.json`) are exact-count / banded with little headroom, so a
  precision or allocation change flips them red **by design** until recalibrated. Recalibrate from
  the **CI-measured Linux** values: allocations is the deterministic signal, **`wall_s` is a
  rerunnable flake — `gh run rerun --failed` clears it, never recalibrate for wall alone**. Diff the
  OSS-sweep diagnostics for FPs before blessing a higher count (the v0.2.0 recalibration found 3
  `StringScanner#[]` FPs → fixed at root, not blessed in). `release-gate.yml` is **advisory** during
  the evaluation line; `ci.yml` is the required gate.
- **The formatter hook is destructive in `/Users/megurine/repo/ruby/rbs-inline`** — an `Edit` there
  triggers a rubocop autocorrect that rewrites the file, including rbs-inline's own `#:` annotations
  to `# :`, breaking its self-hosted `sig/`. Write via a script in that fork.

## Open engineering items

Engine-internal items worth seeing directly. The full demand-driven backlog is
[`docs/ROADMAP.md`](ROADMAP.md) § "Future cycles".

### ADR-24 — implicit-self method-call resolution, remaining

- **Slice 4's `call.self-undefined-method` rule ships `:off` and is NOT promotable**
  ([WD4 eval](notes/20260614-adr24-slice4-self-undefined-fp-eval.md)). The universal-base exclusion
  landed (287 corpus FPs); the **abstract / template-method base-class pattern** (167) is
  unaddressable under the current per-class gate. **Do NOT widen the standalone-only gate to
  superclass / include chains** until that is solved — the required shape is subclass-aware gating
  (record at the recorder whether the missed method is defined on a known subclass; suppress if so).
- **Non-`Bot` general adoption inside class bodies** — a resolved self-call return is adopted only
  when `Bot`. Unconditional adoption of precise returns regressed `rigor check lib` by 16 diagnostics
  (pre-existing callee-return imprecisions surfacing downstream); needs callee-return inference
  precise enough that adopting does not surface them.

### AR scope-body lambda `self`

`scope :x, -> { select(...).group(...) }` still needs the lambda's `self` rebound to the model class
(ADR-26 territory). v0.1.12 closed implicit-self class-side resolution for ordinary method bodies.
Empirical case: [`20260523-mastodon-v4.5-regression-sweep-v0.1.9.md`](notes/20260523-mastodon-v4.5-regression-sweep-v0.1.9.md)
§ "What is increasing" item 2.

### ADR-23 — `rigor triage` slice 4 plugin recognisers

Remaining: a `Plugin` hook letting plugins contribute their own recognisers (deferred).

### Inference budgets — spec table unwired

The spec's configurable `budgets:` table ([`inference-budgets.md`](type-specification/inference-budgets.md))
is normative-for-v1 but **not wired** — the only operative cutoffs are three hard-coded silent guards
(recursion re-entry ≈ depth 1, ancestor walk 100, HKT fuel 64) plus ADR-10 `budget_per_gem`. The
large-app cost cliff turned out **not** to be a budget (it was a 4.2M-retained-String leak in
`rigor-activerecord`, fixed v0.1.16; `union_size` was refuted as uncorrelated). Demand-deferred: no
corpus project shows a budget-shaped cost. If one does, re-run the distribution probe first
([ADR-41](adr/41-inference-budget-design.md) WD3). The `RIGOR_BUDGET_TRACE` / `RIGOR_HEAP_PROFILE` /
`RIGOR_HEAP_TRACE` probes are reusable.

### Stdlib RBS coverage gaps — and a staged upstream PR awaiting the user

When an upstream `ruby/rbs` gap is surfaced by a single internal call site, prefer an in-source
`# rigor:disable` + load the library; across multiple call sites or user-facing code, escalate to a
focused overlay under Rigor's own `sig/`, or an upstream fix. **The `references/rbs` branch
`widen-strscan-resolv-stdlib-sigs` (widens `StringScanner#[]`, `Resolv#initialize`) is staged — the
branch push and the `ruby/rbs` PR are the user's task.**

### Sig-gen (ADR-14) remaining gaps

`attr_reader` with ivars set from non-`initialize` sources (DB reads, config, side effects) still
produce `:untyped_return` → hand-written sig. Deep chains on untyped receivers → `rbs collection
install` / ADR-10 `source_inference:`. Dynamic methods (`define_method`, DSL macros) → project plugin.
`update_existing` does not collapse sibling parent/child class blocks (workaround: delete the target
sig + regenerate).
