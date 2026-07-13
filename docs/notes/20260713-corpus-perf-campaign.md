# Corpus-wide cold/warm re-profile + perf-lever campaign — v0.3.0 opening (2026-07-13)

Status: profiling + landed-lever record. Taken against **v0.2.9 master `0a4adf48`**;
levers landed same-session through PRs #74 / #75 / #76 (+ follow-up `0e80d04e`),
with the warm-path slice open as PR #77 at writing time. Successor to
[`20260627-corpus-cold-warm-reprofile.md`](20260627-corpus-cold-warm-reprofile.md);
opens the v0.3.0 performance cycle (ROADMAP § "The next cut — v0.3.0").

## Method

Same in-process harness as `20260620`/`20260627` (driver: in-process `Rigor::CLI`,
`GC.stat(:total_allocated_objects)` as the deterministic metric, wall-mode +
object-mode StackProf from a throwaway GEM_HOME), with two corrections that
invalidate parts of the earlier notes' WARM columns:

1. **Warm-methodology artifact (P7).** The `20260627` warm numbers were measured
   cold-then-warm **chained in one Ruby process**; a fresh-process warm run is
   ~186k allocations more expensive purely from per-process VM warmup (regex /
   frozen-string ISeq caches), at EVERY commit. The apparent 0.2.7–0.2.9 "warm
   regressions" (kramdown +52.7%, mastodon-models 1.85×, redmine 1.32×) were
   entirely this cross-methodology comparison — a per-commit sweep with a
   self-consistent harness shows warm allocations flat across the whole window
   (+0.33% on kramdown). **Warm numbers are only comparable within one
   process-model.** This note's tables are all fresh-process.
2. **Vendor-bundle asymmetry.** Self-check (`check lib`) numbers are only
   comparable from a checkout whose bundle is installed: the RBS env ingests
   vendored-gem sigs, worth ~8M allocations on the rigor repo itself (29.33M
   with `vendor/bundle` vs 21.38M without). Worktree-based bench runs silently
   measure the smaller env. `bench/baseline.json` is CI-measured (vendor
   present) — recalibrate only from CI values, as the gotcha already says.

## Corpus shape at v0.2.9 (`0a4adf48`, pre-levers)

| target | cold s / allocs | warm s / allocs | YJIT cold (forced) |
|---|---|---|---|
| mastodon app+lib | 25.2 / 55.3M | 1.35 / 4.07M | 14.9s (**1.69×**) |
| gitlab app/models | 19.3 / 53.9M | 5.55 / 16.1M | 15.0s (1.29×) |
| redmine app/models | 8.6 / 13.7M | 0.50 / 1.00M | 5.5s (1.56×) |
| rigor lib (self) | 8.3 / 29.3M | 0.92 / 2.28M | 6.9s (1.21×) |
| mail lib | 4.9 / 21.0M | 0.93 / 5.36M | 4.2s (1.13×) |
| mastodon app/models | 4.0 / 10.1M | 0.61 / 1.18M | 5.0s (**0.80× — loss**) |
| kramdown lib | 1.7 / 4.15M | 0.25 / 0.52M | 2.55s (0.66× — loss) |
| dependabot (20 files) | 1.6 / 3.7M | 0.24 / 0.45M | 2.34s (0.68× — loss) |

Fixed cache-write cost: prime = cold + **~2.09M allocations, size-invariant**
across a 13× cold-alloc range (the env-blob + dependency-descriptor Marshal/SHA
surface). Once-per-change cost; recorded, deprioritized.

## Root causes found (architecture-confirmed) and what landed

1. **`compact_child_nodes` array churn — the cross-regime allocation source.**
   Every AST walk allocated a fresh Array per node (leaf classes allocate `[]`;
   43/152 Prism node classes are pure leaves). mail cold: **51.4% of ALL
   allocations**; Rails corpora ~10–12%; kramdown ~11%; rigor lib 20.5% self.
   → **Landed (PR #76 + `0e80d04e`)**: `Rigor::Source::NodeChildren` compiles a
   `#rigor_each_child` method onto every Prism node class from
   `Prism::Reflection` (field reads inlined, exact `compact_child_nodes`
   order/nil semantics, equivalence-spec-pinned); all 27 engine walkers migrated.
   The first iteration (central `send` dispatch) cut allocations but regressed
   wall (+5.6% mastodon app+lib under YJIT) and was upgraded to the node-method
   compile before shipping. Final A/B vs `0a4adf48`: mail −56.3% allocs / −9.8%
   wall; mastodon-models −15.2% / −7.2%; redmine-models −17.8% / −2.0%; kramdown
   −19.0% / −2.5%; liquid −9.8% / −2.8%; self-check allocs 29.3M → **15.2M**.
   Diagnostics byte-identical corpus-wide. Residual: `plugins/*/lib` private
   walkers still on `compact_child_nodes` (small; follow-up).
2. **YJIT was built into the toolchain and never enabled.** Wins ≥ ~5s runs
   (1.29–1.69× on Rails-scale), loses ≤ ~4s (compile cost unamortized).
   → **Landed (PR #75)**: `Rigor::Runtime::Jit.enable_after(5.0)` — a deadline
   thread armed at check/coverage start; a run finishing first never pays JIT
   compile, a long run JITs its dominant tail. `lsp`/`mcp` enable at boot.
   Calibrated: loss cases at parity, mastodon app+lib keeps ~100% of the 1.68×
   win, gitlab 84%. Opt-outs: `RIGOR_DISABLE_YJIT=1`, `RIGOR_YJIT_DEADLINE=n`.
   Residual: fork-pool workers fork before the deadline fires and never enable —
   arming the deadline per worker is a queued follow-up (default runs are
   sequential, so the headline path is covered).
3. **Uncached plugin prepare pass (gitlab regime).** `DryTypes::AliasScanner`
   re-Prism-parsed the whole tree in `#prepare` every run — 37.3% of gitlab
   warm wall (and the reason gitlab's warm/cold was 3.35× vs 13–19× elsewhere).
   → **Landed (PR #74)**: the scan rides ADR-60 WD3 `producer`/`watch:`
   record-and-validate. GitLab warm 6.28s → 3.81s (−40%); cross-process
   invalidation spec added. Audit: rails-routes / rails-i18n were already on the
   idiom; their residual warm cost is the sound freshness validation itself.
4. **Warm runs re-did whole-project work whose products a cache hit never
   consumes.** On a full ADR-45 hit the run still (a) parsed every file TWICE
   (the two independent pre-pass loops), (b) ran 6–8 seed walks per file,
   (c) SHA-256'd every `.rbs` file for a `RbsDescriptor.files` field only the
   miss path reads, and (d) re-digested overlapping file sets once per
   descriptor (run-diagnostics + each plugin watch glob).
   → **PR #77 (open at writing)**: the cross-file discovery passes move out of
   the eager pre-pass into a lazily-forced `ProjectPrePasses#discover` (a warm
   HIT never assembles, so never parses; recording / subset / incremental modes
   force it eagerly); a combined `discovered_project_index_for_paths` walks each
   file ONCE with both collectors over one tree (AST dropped per file — peak RSS
   flat); `RbsDescriptor.build_run` defers the RBS-tree SHA-256 the key never
   reads; a per-run `Cache::FileDigest` memo digests each path at most once
   across the dependency descriptor, `fresh?`, the RBS tree, and plugin watch
   globs. Consumer-map finding that shaped it: the plugin-registry /
   dependency-source / synthetic-method products feed `Environment.for_project`,
   which the cache KEY depends on — so only the discovery tables (which the key
   never reads) defer; env inputs stay eager. Measured (vs merged master,
   `RIGOR_DISABLE_YJIT=1` both arms): warm rigor-lib −67.9% wall / −80.4%
   allocs, gitlab app/models −31.1% / −13.2%, textbringer −38.8% / −49.5%,
   net-ssh −31.8% / −44.5%, herb −28.3% / −38.6%; cold neutral-to-better
   (allocs −0.7..−2.3%). Byte-identical cold+warm on all five gate targets;
   `make check-incremental` green.
5. **The 0.2.6→0.2.9 self-check allocation growth (+9.6M) is fully attributed
   and is NOT a diffuse engine regression.** Per-commit sweep on a fixed
   plugin-less corpus (mail): flat across the window except **one step,
   +2.05M (+10.8%) at PR #62** (module-singleton cross-file seed, ADR-57 WD3).
   Object-profile diff: the seed itself is flat — the cost is module-constant
   calls that used to short-circuit to `Dynamic[top]` now doing real dispatch
   (callee body evaluation → `join_bindings` → union normalization →
   `sort_by { describe(:short) }`). That is the feature working as designed
   (GitLab lib +2,812 protected sites); the rest of the self-check delta is
   rigor's own lib growth + the vendored-RBS env surface (§ Method 2).

## Integrated master after the session's merges (no #77)

Spot-check on the merged master (`0e80d04e`), fresh caches, default settings:
mail cold 21.03M → **9.20M allocs** (wall 4.92 → 4.59s), warm 5.36M → **1.13M**;
mastodon app/models cold 10.09M → 8.56M, warm 1.18M → **0.67M**. No
cross-lever interaction regressions; PR #77 stacks its warm wins on top.

## Non-targets (measured; do not re-chase)

- **Union-normalization churn is irreducible by cheap local means — now
  triple-confirmed.** 6/20 measured `.uniq` and `equal?` fast-paths neutral;
  this session probed memoizing the `describe(:short)` sort key
  (thread-local Hash keyed by carrier): allocs −1..−3% but mail wall **+3.4%
  reproducible** — the structural `hash` of a carrier allocates and recurses,
  costing more than the string it saves. Reverted. The only remaining lever is
  global carrier interning/hash-consing (large, FP/identity risk, still not
  recommended).
- **ADR-82 provenance side-tables**: 0.18% of object samples — the "perf-neutral"
  claim held on every profile.
- **redmine `DidYouMean::Jaro`** (~6% self): intrinsic per the 6/27 adjudication;
  reconfirmed present, unchanged.
- **Per-dispatch `CallContext`/`Data#initialize`**: ADR-44 adjudication stands.
- **Cache-write fixed ~2.1M**: once-per-change; not worth complexity now.

## Queued levers (evidence-ranked, not implemented)

1. **Scope-safe run-scoped return memo** — the structural cold lever for
   module/procedural-heavy code, third time surfaced (ADR-57 +12% cold, ADR-24
   WD5 deferral, PR #62's +10.8% being per-call-site callee re-evaluation).
   Constraints already on record: naive per-call-node caching is unsound
   (ADR-52 WD5 — results depend on call-site scope/narrowing); ADR-55's
   fixpoint summaries are per-call-stack transient, not cross-site. Needs a
   design (what a summary may depend on / when it invalidates) — the ROADMAP
   already names it for v0.3.0. Recommended next deliberative ADR.
2. **Per-file seed cache + demand-parsed def bodies (pre-pass
   incrementalization)** — after Wave 2, the remaining pre-pass cost is the
   MISS path on big projects (11k-file gitlab re-parses everything to re-check
   one edit; `--incremental`'s subset analysis still pays the full pre-pass).
   Feasibility verified: every cross-file discovery table is plain data except
   the def-node tables (Marshal-able but each dump drags the file's source; the
   lazy alternative is (path, node_id) refs resolved through a per-run parse
   memo — object identity only needs run-local stability). `declared_types`
   (identity-keyed) is per-file-only and outside the pre-pass, so it does not
   block. This is the ADR-46-completion arc.
3. **Pool-worker YJIT arming** (fork children currently never JIT).
4. **`plugins/*/lib` walker migration** to `rigor_each_child` (small).

## Gate / discipline notes for the next profiler

- Adjudicate with allocations; wall only via interleaved same-machine pairs.
- Warm comparisons: fresh-process only, never against in-process-chained numbers.
- bench-perf self-check numbers require `vendor/bundle` present (CI values bind).
- A worktree isolates the ENGINE, not plugins (re-bitten this session — P4's
  gitlab gate had to stash-swap the plugin dir).
- YJIT does not change allocations (≤ +0.007% = the deadline thread), so the
  deterministic gates survive PR #75; wall baselines recalibrate at the next cut.

## Closing re-profile (2026-07-14) — the cycle's measured total and the ③/④ verdicts

Swept on master `3424840b` (all nine PRs #74–#82 merged), same harness, caches
cleared per target, diagnostics **10/10 exact** vs the reference (zero drift).
Allocations — the deterministic metric — improved on **all 22 cold+warm cells**:

| aggregate | cold | warm |
|---|---|---|
| allocations | mean −27.0% / median −20.6% (11/11 ↓) | mean −68.2% / median −75.4% (11/11 ↓) |
| wall | mean −5.2% (noisy host; see below) | gitlab −73%, mail −81%; 4 noise-suspect ↑ flagged |

Headlines: mastodon app+lib cold 25.2s/55.3M → 15.0s/32.8M (−40%/−41%);
mail warm allocs −96.5%; rigor-lib warm −91.4%; gitlab-models warm −90.9%
(and warm-incremental 16.7M → 2.06M, 8.1×, from ADR-85). Wall on this shared
host is noise-dominated — the PROFILED gitlab cold run (StackProf overhead
added) measured 21% faster than the plain run nine minutes earlier; the four
flagged warm-wall upticks (mastodon-models +0.59s, kramdown +0.11s,
redmine-models +0.22s, applib +0.31s) all pair with large allocation DROPS, so
they are noise-suspect — re-verify with N≥3 on a quiet host before treating as
real.

**③ Carrier interning / hash-consing — REJECTED for this cycle, now on closing
evidence.** Type-equality/union-normalization frames are **5.0% (kramdown) /
2.0% (mastodon-models) of residual allocation samples** — a real but minor
cost, far below the campaign's landed levers. The residual cold allocation
profile is dominated by parse-class work that the warm path already
cache-covers (RBS signature parse 26.6% of kramdown's cold samples; Prism 12%
+ rigor-rails-i18n's Psych/YAML 11.5% on mastodon-models — all first-run/CI
costs, absent on producer-cached warm runs). Equality churn does remain
kramdown's top *CPU* self-cost (15.8% wall self), so interning stays what the
6/20 note called it — a large, identity-risky change for one regime's CPU —
with the triple-negative probe history (6/20 ×2, P9) still standing.

**④ Daemon / watch mode — deferred as a product decision, with the measured
shape recorded.** The warm floor is TWO different bottlenecks by scale:
small/medium projects spend **~61–73% of the floor in `require`**
(process-bootstrap — the textbook daemon win, mail 0.17s floor), while
monorepo-scale spends **~55% in glob + digest cache revalidation**
(`Cache::FileDigest` / `GlobEntry` re-validating watched trees, gitlab 1.48s
floor) — a daemon only flattens that half with FS-event invalidation, its
genuinely hard part. `rigor lsp` already serves the editor loop with prebuilt
state; a CLI daemon/watch surface is demand-gated product work (ADR-27
territory), not an engine lever.

Cycle verdict: the profile-driven levers are spent — the residual is
parse-once costs, the sound cache-validation floor, flat dispatch, and a 2–5%
equality tail. The next perf movement at this maturity is either the daemon
product decision or workload-level (parallel-by-default), both decisions, not
profiles.
