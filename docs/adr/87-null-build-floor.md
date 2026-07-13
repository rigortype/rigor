# ADR-87 — The null-build floor: stat-then-digest validation, zero-change snapshot skip, hit-path boot slimming

Status: **Accepted — WD1–WD5 implemented ([PR #85](https://github.com/rigortype/rigor/pull/85)).** Frames Rigor's warm paths
in build-system terms — the NULL build (zero files changed) and the single-edit
build — and removes the three measured floor components that are not intrinsic:
digest-everything validation, an unconditional snapshot rewrite, and a hit path
that boots the whole engine it never uses. Supersedes the
[ADR-54](54-cache-slimming.md) "mtime fast-path — Rejected" row on new evidence
and a stronger design; the digest remains the sole change AUTHORITY.

Grounding: [`20260714-nullbuild-recon.md`](../notes/20260714-nullbuild-recon.md)
(the phase-attribution matrix this ADR reads) +
[`20260713-corpus-perf-campaign.md`](../notes/20260713-corpus-perf-campaign.md).

## Context

Post-campaign (PRs #74–#82), the measured floors on `origin/master` (out-of-process
wall, the number users feel; RIGOR_DISABLE_YJIT=1):

| scenario | mail (111f) | rigor lib (326f) | gitlab app/models (1,225f + 10 plugins) |
|---|---:|---:|---:|
| A — null, default (ADR-45 HIT) | 0.357s | 0.360s | 1.678s |
| B — null, `--incremental` | 0.389s | 0.462s | 2.243s |
| C — 1-edit, `--incremental` | 0.825s | 0.790s | 11.6s (hub edit) |
| D — 1-edit, default (= full build) | 3.7s | 5.9s | ~21s |

Phase attribution localizes the non-intrinsic mass:

1. **Monorepo null is validation-bound.** A gitlab HIT re-SHA-256s **115 MB across
   52,739 files on every run** — the ADR-45 `fresh?` dependency set (32,827
   files / 74 MB) plus the ADR-60 plugin `watch:` globs (19,912 / 40 MB; the
   Rails plugins watch all of `app`+`lib`, dwarfing the analyzed set). Boot is
   287ms of the 1,678ms. **But the digest CPU is not the wall** — SHA-256 of
   115 MB is ~50ms; the mass is the plugin `#prepare` prepass logic + `Dir.glob`
   enumeration + Marshal that runs BEFORE the ADR-45 verdict on every hit
   (~0.8s), and the file READS the digest forces (cheap from the page cache but
   real cold). The stat tier removes the reads; skipping the prepass entirely on
   a hit removes the rest.
2. **Small/medium null is boot-bound.** Analysis is 6–55ms; the ~0.36s wall is
   ~245ms `bundle exec` bundler tax (absent for a gem-installed binary), ~90–150ms
   engine+rbs+prism requires, ~50ms VM start. The require census: on the `check`
   path ALL 145 requires load BEFORE the cache verdict and **zero files load
   after it on a HIT** — the engine is fully booted to do nothing; the RBS env
   is built on every HIT (39ms on gitlab) only to feed the cache KEY, which
   reads `gems`+`configs`, not the env itself.
3. **Zero-change `--incremental` rewrites its snapshot unconditionally**
   (`run_incremental` always `snapshot.save`: 209ms + 2.06 MB on gitlab).
4. What remains after 1–3 is intrinsic: closure re-analysis on an edit
   (leaf ≈ 0.25s, hub ≈ 4.3s — the ADR-46 conservative closure doing its job)
   and process/VM start.

## Decision

Three floor components are removed under one criterion: **the SHA-256 digest
remains the sole authority on whether a file's content changed; the stat tier
only decides whether the digest needs recomputing, and the hit path is served
without the machinery a hit never uses.** Concretely:

- Dependency validation becomes **stat-then-digest**: every validation-only file
  entry stores its digest AND a stat tuple `(size, mtime_ns, ctime_ns, inode)`;
  validation stats the file first and recomputes the digest only when the tuple
  moved (or the racy guard fires); a moved-stat-same-digest file (a `touch`) is
  still FRESH — strictly fewer false invalidations than today, never more.
  Trusting an unmoved tuple to skip rehashing is the git-index model with the
  guards git earned: nanosecond timestamps (APFS/ext4 both provide them),
  `ctime` in the tuple (not settable via `utimes` — defeating the tier requires
  root/clock manipulation, outside a local dev tool's threat model, and Rigor's
  own cache directory is equally writable to such an actor), inode identity, and
  a racy-window rehash (a file whose mtime is not strictly older than the entry's
  recording instant is always rehashed). An escape hatch pins the old behaviour:
  `cache.validation: digest` (config) / `RIGOR_STRICT_VALIDATION=1` (env; wins).
- The `check` **hit path is served before the engine loads**: a lightweight probe
  builds the ADR-45 run cache key from config alone, validates the stored
  dependency descriptor (stat-then-digest), and serves the cached diagnostics —
  never requiring the inference engine, the plugin gems, or the RBS environment.

This supersedes ADR-54's rejection row on its own terms: that row priced the
saving at ~50–150ms on Mastodon-scale and rejected a BARE mtime check that
would have replaced the digest as authority. The tuple design keeps digest
authority, and the measured saving is dominated not by the digest CPU (small)
but by what a stat-validated hit lets the probe SKIP (the whole engine + plugin
prepass): gitlab null 1.68s → **0.34s** on the measurement host.

## Working decisions

- **WD1 — `:stat` comparator on the existing `FileEntry` format.**
  `Cache::Descriptor::FileEntry` already carries `(path, comparator, value)`
  with a `VALID_COMPARATORS` registry (the seconds-resolution `:mtime`
  comparator is the precedent); `:stat` packs `digest + size + mtime_ns +
  ctime_ns + inode + recording_instant_ns` into the value string. The recording
  instant (captured once per run in `FileDigest.with_run`) drives the racy guard.
  `SCHEMA_VERSION` 4→5 for a clean one-shot rebuild (old entries read as misses
  — the #57 marker discipline). `Cache::FileDigest` (the single hashing choke
  point + per-run memo) gains `pack_stat` / `stat_fresh?` — the stat-first read
  path shared by `Descriptor#fresh?` / `file_entry_fresh?`. `:stat` entries ride
  ONLY validation-only descriptors (the runner run-dependency descriptor, the
  lazy `RbsDescriptor.build_run` files, plugin `IoBoundary` reads); every KEY
  descriptor keeps `:digest` (its value must be deterministic).
- **WD2 — the same tier under `GlobEntry`** (plugin `watch:` validation). The
  pre-ADR-87 `GlobEntry` value was a SHA-256 over per-file `"<path>\0<content-
  sha256>\n"` rows — it re-READ every file on every validation. WD2 keeps the
  identical **single-aggregate-hash** shape (small to Marshal, deterministic,
  composition-safe) but hashes STAT TUPLES: a SHA-256 over sorted
  `"<path>\0<size>\0<mtime_ns>\0<ctime_ns>\0<inode>\n"` rows. `fresh?` re-globs +
  re-stats and compares — reading **zero file-content bytes** on an unchanged
  tree (gitlab: 40 MB → 0 hashed). Strict mode restores the content-hash
  signature. This is what collapses the digest cost of the plugin prepass on the
  incremental / miss paths that still run it.

  > **Divergence from the draft (flagged):** the draft proposed a *per-file
  > stat-or-digest table* (one row per file, kept in the value) so only stat-
  > moved files re-hash. Implemented and measured, that regressed the gitlab
  > incremental null from 1.85s → **5.3s**: a 20k-file watched tree makes a
  > ~2.5 MB per-glob table whose `Marshal.dump`/`load` + parse dwarfs the
  > content-hash it saved. A watched dependency is all-or-nothing (one changed
  > file invalidates the producer's cache regardless), so per-file partial
  > re-hashing bought nothing but a heavy table. The aggregate stat signature is
  > the same one-hash shape as the old form — lean — and still reads 0 content
  > bytes on a null. Its only cost vs the old content signature is that a bare
  > `touch` invalidates the glob (rare, and only forces the recompute the old
  > form paid on EVERY run).
- **WD3 — zero-change snapshot save skip.** `run_incremental` skips
  `snapshot.save` when the recheck changed nothing (`Recheck#no_change?` —
  ΔF empty, no add/remove) — the snapshot on disk is already byte-equivalent.
  A cold baseline always saves; a real edit always re-saves.
- **WD4 — hit-path boot slimming.** `CheckCommand#run` parses options + resolves
  config WITHOUT the engine and consults a lightweight `Analysis::RunCacheProbe`
  before `load_check_dependencies`. The probe builds the run cache key through
  the shared `Analysis::RunCacheKey` (the same builder the runner uses — so the
  two can never drift out of key agreement), reading `RBS::VERSION` (via
  `require "rbs/version"`) + the config-derived library list
  (`Environment::DEFAULT_LIBRARIES + config.libraries`) WITHOUT building the RBS
  environment; on a fresh `Store#peek_validated` hit it serves the cached
  diagnostics (severity profile applied via the extracted `Analysis::SeverityStamp`)
  and returns. The engine cluster loads only on a miss / non-cacheable run
  (`--no-cache`, editor buffer, pool mode, `--coverage` / `--cache-stats` /
  `--incremental`, the `RIGOR_*_TRACE` dev probes — each declines the probe).
  Making the hit engine-free required decoupling two load-time engine pulls from
  the CLI: the rule-id constants moved to a light `check_rules/rule_ids.rb`
  (so `RuleCatalog` / `config_audit` no longer require the engine-heavy
  `check_rules.rb`), and `coverage_scan` / `check_runner_factory` became lazy
  requires. Pinned by a **subprocess** spec asserting a HIT run's
  `$LOADED_FEATURES` contains no `rigor/inference` (and no
  `rigor/analysis/runner` / `rigor/environment`) entry, with a MISS control that
  DOES load them. A project whose plugins synthesise virtual RBS produces a probe
  key that omits the `rbs.virtual_rbs` slot, so it simply misses and the full
  path takes over — never a wrong hit.
- **WD5 — staleness spec battery (the WD1/WD2 gate).** Manufactured cases, each
  asserting the diagnostic outcome: touch-only (stat moved, digest same → FRESH,
  no false invalidation); ordinary edit (stale); same-size edit (stale via
  mtime/ctime); same-size + mtime-backdated edit (stale via ctime); a racy entry
  (rehashed even when its tuple matches); `with_run(strict:)` / `RIGOR_STRICT_
  VALIDATION=1` forcing the digest path throughout; plus an end-to-end
  false-invalidation guard — a touch-only change between two cache-backed runs
  stays a HIT (served without re-running discovery, diagnostics byte-identical).

## Rejected / deferred alternatives

- **Bare mtime comparator as authority** — stays rejected (ADR-54's actual
  target); the digest remains the authority here.
- **Per-file stat-or-digest glob table** — implemented, measured a 2.9× gitlab
  incremental regression (Marshal-bound), reverted to the aggregate stat
  signature (WD2 divergence above).
- **FS-event invalidation / daemon** — stays on the ADR-86 WD4 ladder; this
  ADR is the ladder's first rung done properly (after it, the daemon's
  residual value on null builds is the ~0.2s boot floor only).
- **Incremental-by-default** — a real candidate after this ADR narrows the
  A/B gap, but it is an ADR-50 default-change with its own soak story;
  deliberately NOT bundled here.
- **Parallel stat sweep** — 52k `File::Stat` calls are ~50–100ms sequential;
  threads add nothing at this size. Revisit only if a profile shows stat
  dominating post-WD1.

## Consequences

Measured before → after (out-of-process wall on the measurement host,
RIGOR_DISABLE_YJIT=1; digest census = SHA-256 over file CONTENT):

| scenario | before | after | note |
|---|---:|---:|---|
| gitlab A (null HIT) | 1.41s | **0.34s** | WD4 skips the prepass + engine; 115 MB → **0 bytes** hashed |
| gitlab B (null `--incremental`) | 1.85s | **1.44s** | WD1/WD2 stat validation + WD3 skip-save; 67 MB → 3.45 MB (only ADR-46 change-detection reads; glob reads 0) |
| gitlab C (1-edit hub `--incremental`) | 8.65s | **8.55s** | neutral — closure-bound, not glob-bound (see below) |
| mail A / rigor-lib A (null HIT) | 0.37s / 0.38s | **0.22s / 0.22s** | WD4 engine-free hit; residual is bundler tax + VM |

- Positive: monorepo null ≈ 1.68s → ~0.34s and hashes 0 content bytes on a true
  null; small-project null ≈ 0.36s → ~0.22s; zero-change `--incremental` stops
  rewriting its snapshot; validation does strictly fewer false invalidations
  (touch-safe for `FileEntry`).
- **Honest note on gitlab C:** the recon expected ~5–6s, attributing ~5.4s of the
  11.6s to the plugin glob digest. Re-measured on the host, that attribution was
  wrong the same way the null-build attribution was: the glob's mass is
  `Dir.glob` enumeration + Marshal + plugin `#prepare` logic, NOT content hashing
  (which is page-cache-cheap). WD2 removes the content reads (0 bytes) but not the
  enumeration/Marshal, and C is dominated by the intrinsic hub-closure
  re-analysis — so C is **neutral**, not the projected 2×. The ADR is corrected
  to record this rather than claim an unearned win.
- Negative: stat tuples are machine-local (a copied cache re-digests once and
  re-records — same as today's behaviour on any miss); the boot split adds a
  require-ordering surface (pinned by the WD4 subprocess spec) and a second
  key-building call site (`RunCacheKey`, shared with the runner so it cannot
  drift); a project with synthesizer plugins forgoes the WD4 fast lane; one more
  comparator in the frozen cache vocabulary.
- The FP-discipline envelope: serving stale diagnostics now requires
  defeating `size+mtime_ns+ctime_ns+inode` simultaneously — root/clock
  manipulation — versus today's requirement of defeating SHA-256. The ADR
  records this as the deliberate, bounded trade; the strict flag restores the
  old envelope per-run.

## Relationship to other ADRs

[ADR-45](45-unchanged-project-fast-path.md) owns record-and-validate — its
digest authority is preserved, its validation cost is what WD1 removes and its
hit verdict is what WD4 serves engine-free;
[ADR-54](54-cache-slimming.md)'s rejection row is superseded (its premise is
re-measured and the design keeps digest authority); [ADR-60](60-pre-freeze-plugin-contract-consolidation.md)'s
`watch:` machinery hosts WD2; [ADR-46](46-incremental-dependency-graph.md)/[ADR-85](85-seed-bundles-and-lazy-def-node-handles.md)
own the incremental path WD3 trims; [ADR-86](86-partial-native-extensions.md)
WD4's non-native ladder is advanced one rung; [ADR-50](50-release-engineering-and-stability-strategy.md)
owns any future incremental-by-default flip and freezes the new `cache.validation`
config key + `:stat` comparator as public vocabulary at v1.0.
