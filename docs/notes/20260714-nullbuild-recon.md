> Grounds [ADR-87](../adr/87-null-build-floor.md) — the null-build & single-edit phase-attribution recon.

# Null-build & single-edit phase-attribution recon (2026-07-13)

Engine: worktree at `origin/master` = `92a275c3` (post ADR-84 return-memo, ADR-85
seed-bundles/lazy-handles, ADR-86). Rigor 0.2.9, Ruby 4.0.5 (+PRISM, arm64-darwin25),
`RIGOR_DISABLE_YJIT=1`, APFS. Measured via the worktree Gemfile + shared
`/Users/megurine/repo/ruby/rigor/vendor/bundle` inside the flake.

Targets: **mail** (`lib`, 111 files, 0 plugins) · **rigor-lib** (`lib`, 326 files, 0
plugins) · **gitlab** (`app/models`, 1225 files, 10 plugins via `.rigor.dist.yml`).
All runs `--no-baseline` to isolate the engine; wall = out-of-process (`time` around
`bundle exec exe/rigor`, INCLUDES boot); allocs = in-process CLI driver (boot excluded).

Instrumentation was 100% a scratchpad RUBYOPT preload (`phase_trace.rb`) — **zero
worktree source edits**. Diagnostic counts are identical across every scenario per
target (mail 26, rigor-lib 1, gitlab 210) = the tracer/harness did not perturb output.

---

## 1. The matrix — per target × per scenario

Wall = out-of-process median of N reps (N=5 mail/rigor warm, N=3 gitlab warm, N=1 for
the slow full builds), min in parens. Allocs = in-process `GC.stat(:total_allocated_objects)`,
one run per fresh process (the Store's in-process memo makes rep≥2 unrepresentative).

| Target · scenario | Wall median (min) | In-proc allocs | in-proc wall | GC ms |
|---|---|---|---|---|
| **mail** A null-default (ADR-45 HIT) | **0.357s** (0.350) | 185,532 | 0.147s | 11 |
| **mail** B null-incremental (warm 0-change) | **0.389s** (0.382) | 210,517 | 0.205s | 14 |
| **mail** C 1-edit incremental (warm) | **0.825s** (0.804) | 1,420,096 | 0.610s | 60 |
| **mail** D 1-edit default (= full build) | **3.719s** | 7,563,980 | 3.444s | 245 |
| **rigor-lib** A null-default HIT | **0.360s** (0.350) | 190,850 | 0.155s | 10 |
| **rigor-lib** B null-incremental | **0.462s** (0.447) | 306,456 | 0.268s | 17 |
| **rigor-lib** C 1-edit incremental | **0.790s** (0.786) | 1,117,244 | 0.541s | 49 |
| **rigor-lib** D 1-edit default (full) | **5.914s** | 12,605,322 | 5.646s | 415 |
| **gitlab** A null-default HIT | **1.678s** (1.659) | 1,458,720 | 1.491s | 101 |
| **gitlab** B null-incremental | **2.243s** (2.182) | 2,205,462 | 2.113s | 207 |
| **gitlab** C 1-edit incremental | **11.634s** | 26,437,308 | 10.687s | 841 |
| **gitlab** D 1-edit default (full) | **~21.04s** | 40,933,326 | 20.118s | 1456 |

Headlines:
- The two *null* scenarios (A, B) are cheap on small/medium projects (0.36–0.46s) but
  cost **1.7–2.2s on gitlab** — and that gitlab cost is **not** boot, it is cache
  re-validation (see §4).
- Incremental 1-edit (C) beats default 1-edit (D) by **4.5×** (mail), **7.5×**
  (rigor-lib), but only **~1.8×** (gitlab) — because the edited gitlab file (`label.rb`)
  is a hub model with a large dependent closure.
- **B is *slower* than A** on every target (incremental-null pays snapshot I/O +
  change-detection + a mandatory plugin-prepass; the ADR-45 HIT validates one entry).

---

## 2. Boot floor — micro-benchmarks (worktree bundle, median of 5)

| command | median | delta |
|---|---|---|
| `ruby -e exit` (bare nix Ruby, no bundler) | 0.051s | VM start |
| `bundle exec ruby -e exit` | 0.296s | **+0.245s = bundler setup** |
| `bundle exec ruby -e 'require "rigor/cli"'` | 0.326s | **+0.030s = rigor/cli require** |
| `bundle exec exe/rigor --version` | 0.236s | (CLI dispatch; sub-boot noise ±80ms) |

Reading: of a ~0.36s small-project warm wall, **~0.245s is `bundle exec` bundler setup —
an artifact of running from a dev bundle, NOT present for a `gem install`ed binary.**
The bare VM is ~50ms. `require "rigor/cli"` alone is only ~30ms because the analysis
engine is **deferred** — `rigor/cli.rb` loads the CLI dispatch layer; the runner /
inference / environment / rbs / prism / psych tree loads later, in
`CheckCommand#load_check_dependencies` (`lib/rigor/cli/check_command.rb:549`), at the
start of `check`.

So the *installed-binary* small-project warm floor ≈ VM(50) + engine-require(~90–150) +
cached-analysis(6–18ms) ≈ **~150–220ms**; the `bundle exec` runs add ~245ms of bundler
tax on top.

---

## 3. Require census & load-order (scenario A)

`require`-wrapper self-times are reliable for gem clusters; rigor-internal files load via
`require_relative` (which cannot be safely wrapped without breaking the worktree bundler)
so their per-cluster *time* is a `:script_compiled`-delta approximation (over-attributes)
— **counts and load-order are exact, internal sub-cluster ms is indicative only.**

**Gem cluster self-times (gitlab A, ms, reliable):** bundler 69 · rubygems 38 · prism 40
(native ext + reflection) · rbs 34 · psych 11 · stdlib ~76+38. **plugins 2.4ms total**
— the 10 plugin *gem requires* are cheap; their cost is `#prepare`/scan, not load (§4).

**Load-order marks (in-process t from tracer-load → run_analysis; reqs/scripts loaded):**

| target A | run_analysis-enter | cache-verdict | files compiled AFTER verdict |
|---|---|---|---|
| mail | t=232ms · 145 reqs / 575 scripts | t=239ms · 145 / 575 | **0** |
| rigor-lib | t=223ms · 145 / 575 | t=242ms · 145 / 575 | **0** |
| gitlab | t=287ms · 145 / 575 | t=328ms · **155 / 629** | **0** |

Answers to the load-order questions:
- **Is `load_check_dependencies` deferring the engine?** Yes for *non-check* commands
  (`--version` never loads the engine — 30ms). But for `check` it eagerly loads the
  **entire** engine (runner→inference→environment→rbs→prism→psych) before any cache
  decision: by `run_analysis-enter` all 145 requires / 575 scripts are already in, and
  **0 ruby files compile after the cache verdict on a HIT**. The rbs *gem* classes are
  unavoidable on the hit path (the cached env is a Marshal blob of RBS objects → its
  classes must be loaded to deserialize it).
- **What loads eagerly on the hit path that a redesign could defer?** On gitlab the 10
  plugin gems + 54 files load *between* `run_analysis` and `cache-verdict` (145→155 reqs,
  575→629 scripts) — i.e. during `run_project_pre_passes`, which runs unconditionally
  before the ADR-45 verdict. And the RBS **environment is built** (deserialized from
  cache, 39ms gitlab) on every HIT purely to hand `RbsDescriptor.build_run` the
  `rbs_loader` for the cache *key*'s `gems`+`configs` slots — even though the key only
  needs `RBS::VERSION` (a constant) + `loader.libraries` (config-derivable). Deferring
  the inference-engine require **and** the env build past the ADR-45 verdict is the
  standing opportunity: a HIT needs only the Store + Descriptor + config + the Diagnostic
  class to validate `fresh?` and unmarshal the cached diagnostics.

---

## 4. Digest census — the large-project floor lives here

### Scenario A (warm ADR-45 HIT) — `Cache::FileDigest.hexdigest` census

| target | hexdigest calls | MB hashed (SHA-256) | breakdown | stat-ish syscalls |
|---|---|---|---|---|
| mail | 135 | 2.71 | fresh?/dep-desc: 111 `.rb` (2.60) + 24 `.rbs` (0.12) | file? 200, dir? 677, glob 16, binread 1 |
| rigor-lib | 390 | 3.23 | fresh?: 326 `.rb` (3.03) + 64 `.rbs` (0.20) | — |
| **gitlab** | **52,739** | **115.01** | fresh?/dep-desc **32,827 (74.34)** + plugin-glob **19,912 (40.67)** | **file? 52,808**, dir? 1387, glob 21, stat 15, binread 5 |

gitlab by extension: 50,912 `.rb` (104.5 MB), 1,650 `.haml` (1.8 MB), 139 `.erb`, 26
`.rbs`, **3 `.sql` (8.46 MB — `structure.sql`)**, 9 `.yml`.

**This is the finding.** On a *warm HIT* gitlab re-SHA-256s **115 MB across 52,739
files** — every run. Two consumers:
1. **ADR-45 `Descriptor#fresh?`** (32,827 files, 74 MB): the run-diagnostics dependency
   descriptor. Far larger than the 1,225 analyzed models because the Rails plugins scan
   the whole `app`+`lib` during prepare (controllers, all models, views → 1,650 `.haml`,
   `structure.sql`), and every file they read becomes a recorded dependency re-digested
   on each `fresh?`.
2. **ADR-60 WD3 plugin `watch:`-glob validation** (`GlobEntry.digest_for`, 19,912 files,
   40 MB): each plugin producer's `#prepare` cache re-globs + re-digests its watched set.

Spans confirm the split (in-process ms, gitlab A): `run_analysis` 1341.8 =
`run_project_pre_passes` **1090.3** (plugin prepare/validate → `fetch_or_validate` ×5 =
932ms, the 40 MB glob digests) + `compute_run_diagnostics` **241.6** (ADR-45 `fresh?`,
the 74 MB) + env-build 39.3. Boot is only 287ms of the 1678ms wall. **gitlab's null
floor is I/O + SHA-256 bound, not boot-bound.**

Small projects: `fetch_or_validate` is 4.5ms (mail, 135 digests) / 10.5ms (rigor, 390) —
scales linearly with dependency-file count; dwarfed by boot at these sizes.

### Scenario B (incremental null, 0-change) — digest census

| target | hexdigest | MB | breakdown |
|---|---|---|---|
| mail | 111 | 2.60 | 111 `incr_digest_read` (change-detection); no ADR-45 `fresh?` |
| rigor-lib | 326 | 3.03 | 326 `incr_digest_read` |
| gitlab | 29,746 | 67.38 | plugin-glob 19,912 (40.67) + plugin `fresh?` 8,609 (23.40) + 1,225 `incr_digest_read` (3.31) |

Incremental *skips* the ADR-45 run-diagnostics `fresh?` (it excludes `run_result_cacheable?`)
but still pays the **full plugin-prepass** (glob-validate 40 MB on gitlab) + change-detection
(digest every analyzed file to find the zero changes) + snapshot I/O. `IncrementalSession#digest`
is a separate `Digest::SHA256.hexdigest(File.read(path))` per file.

### FS timestamp resolution (probed on this APFS host)

`stat` returns **full nanosecond** `mtime`/`ctime`/`birthtime` (e.g. two writes 3.98ms
apart → mtime_nsec 880402230 vs 884381970; inode present). So a
`(size, mtime_ns, inode, ctime_ns)` stat record is fully realizable here — and the
existing `:mtime` comparator throwing ns away (`File.mtime.to_i`, descriptor.rb:321) is a
self-inflicted coarsening.

---

## 5. Phase spans by scenario (in-process wall ms; spans nest)

**A (HIT):** mail `run_analysis` 6.5 = compute 5.9 (fetch_or_validate 4.5 + env 1.3) +
expand 0.6 · rigor 18.2 = compute 16.0 (fetch_or_validate 10.5 + env 5.5) + expand 2.0 ·
gitlab 1341.8 = pre_passes 1090.3 + compute 241.6 + env 39.3.

**B (incr null):** mail recheck 45.6 = run_analysis 40.5 + save 7.2 + load 3.5 +
discovery-fold 3.9 · rigor recheck 55.3 = **save 31.6 + load 21.1** (snapshot I/O = 53ms
DOMINATES) + discovery 11.4 · gitlab recheck 1417 = **pre_passes 1189** (plugin validate)
+ **save 209 + load 171** (snapshot I/O 380ms) + discovery 40.6; per-file analysis 0.0.

**C (incr 1-edit):** mail recheck 462.8 = analyze_files **411.1** (body.rb + its dependent
message.rb) + save 7.2 + load 3.7 + discovery 5.0 · rigor recheck 335.7 = analyze_files
**250** (reflection.rb closure) + save 34 + load 25 + discovery 14 · gitlab recheck 9907 =
**pre_passes 5361** (plugin validate, 57 MB) + analyze_files **4272** (label.rb hub
closure) + save 214 + load 184.

**D (full):** mail run_analysis 3366 = analyze_files 2782 + discovery 537 + dep-build 4 ·
rigor 5708 = analyze_files 5351 + discovery 282 · gitlab 19877 = analyze_files **13527** +
pre_passes **5416** (plugin build+validate, 58 MB) + discovery 660.

### Scenario C decomposition (change-DETECTION vs re-ANALYSIS vs snapshot-REWRITE)

| target C | change-detection (digest+load+discovery) | re-analysis (analyze_files) | snapshot rewrite | note |
|---|---|---|---|---|
| mail | ~15ms | 411ms (**89%**) | 7ms | body.rb pulls 2159-line message.rb |
| rigor-lib | ~45ms | 250ms (**74%**) | 34ms | reflection.rb moderate closure |
| gitlab | ~230ms + **plugin-prepass 5361ms** | 4272ms | 214ms | label.rb = hub; plugin-prepass co-dominates |

The split is **edited-file-connectivity-dependent**: a leaf edit → change-detection +
(on gitlab) the fixed plugin-prepass dominate; a hub edit → re-analysis dominates. On
gitlab the plugin-prepass (~5.4s of glob re-validation) is a **fixed tax on every
incremental recheck regardless of the edit**, and is the single biggest reason gitlab C
is 11.6s.

### Snapshot rewrite (deliverable #8): **YES, scenario B rewrites the snapshot every run.**

`IncrementalSession#run_incremental` calls `snapshot.save(...)` unconditionally (after any
warm recheck), even with zero changes. Observed byte-size change (cold→first-warm shrinks
as ADR-85 WD3 swaps live `Prism::DefNode`s for `DefHandle`s, then stable): mail
115,870→89,088 · gitlab 2,391,313→2,061,363. Rewrite cost: mail 7.2ms · rigor 32–34ms ·
gitlab 209–214ms (deflate + Marshal.dump of the 2 MB per-file cache/digests/bundles). The
matching `snapshot.load` (inflate+unmarshal) is 3.5 / 21 / 171–184ms. So the snapshot
round-trip is **~10ms / 53ms / 380ms** of pure I/O overhead the null incremental pays to
change nothing.

---

## 6. Stat-cache design surface (code-anchored)

Files (worktree paths):
- `lib/rigor/cache/file_digest.rb:42` — `FileDigest.hexdigest(path)` → `Digest::SHA256.file(path).hexdigest`
  (per-run thread-local memo). The single hashing choke point; called by `file_entry_fresh?`
  (`:digest`), `GlobEntry.digest_for`, `Runner#analyzed_file_entries`, `RbsDescriptor.file_entries`.
- `lib/rigor/cache/descriptor.rb:314` — `Descriptor#file_entry_fresh?(entry)`: `:digest`
  re-hashes (314-319); **`:mtime` already exists** (320-321) as
  `File.mtime(entry.path).to_i.to_s == entry.value` — **but SECONDS resolution, no size/inode.**
- `lib/rigor/cache/descriptor.rb:35` — `FileEntry`, `value_fields :path, :comparator, :value`;
  `VALID_COMPARATORS = %i[digest mtime exists]` (:38); `value` is a free-form frozen String (:52).
- `lib/rigor/cache/descriptor.rb:178` — `GlobEntry.digest_for(root:, pattern:)`: SHA-256 over
  sorted `"<path>\0<content-sha>\n"` rows. No comparator field (always content-hash).
- `lib/rigor/cache/descriptor.rb:226` — `Descriptor#fresh?` iterates `files.all?(&file_entry_fresh?)`
  + `globs.all?(&glob_entry_fresh?)`. Called on the *stored* dependency descriptor on every
  `Store#fetch_or_validate` hit (`store.rb:227-228`).
- `lib/rigor/cache/descriptor.rb:30` — `SCHEMA_VERSION = 4`; folded into the cache key
  (`cache_key_for`) and the `schema_version.txt` marker (`store.rb` `schema_marker_value`), so a
  bump clears the root on the next writable run.

**Can a `(size, mtime_ns, inode, ctime_ns)` record ride the existing formats without a
schema break?**

- **FileEntry: YES, no new struct field.** The record fits the existing
  `(path, comparator, value)` triple — add a `:stat` value to `VALID_COMPARATORS`
  (descriptor.rb:38) and pack the tuple into the `value` String (e.g.
  `"S<size>:M<mtime_ns>:C<ctime_ns>:I<ino>"`). `file_entry_fresh?` gains a `:stat` case:
  `File::Stat.new(path)` → pack → compare to `entry.value`. The existing `:mtime`
  comparator *is the proof* that a non-digest freshness signal already rides `value`; it
  is just coarse. The `comparator` participates in `to_canonical_hash`, but the ADR-45
  **cache KEY** (`run_key_descriptor`) is built from `gems`+`configs`, **not** the
  dependency `files`, so switching the dependency descriptor `:digest`→`:stat` does **not**
  change the key: old `:digest` entries keep validating via digest until a MISS rewrites
  them with `:stat` — a lazy soft-migration, no hard break. For a clean one-shot rebuild,
  bump `SCHEMA_VERSION 4→5` (descriptor.rb:30). Either is viable; the SCHEMA bump is cleaner.
- **GlobEntry: format-compatible, self-migrating.** No comparator field; change
  `digest_for` (descriptor.rb:178) to hash `"<path>\0<stat-tuple>\n"` rows instead of
  content-sha rows. Old glob entries then mismatch → recompute via the existing
  fault-tolerant path (`glob_entry_fresh?` rescue → false → rebuild). No field added;
  SCHEMA bump optional.

**Soundness caveat (why ADR-54 rejected the mtime fast-path, and how to reconcile).**
Stat records are **machine-local** — mtime/inode/ctime differ across machines and across
git checkouts, so a `:stat` entry must **not** be shared cross-machine (unlike a content
digest), and an mtime-preserving restore could theoretically miss a change. ADR-54 §WD
rejected a "`fresh?` mtime fast-path on soundness" for exactly this. The recon's
counter-evidence: the digest is now the *dominant warm floor* on a real Rails app (115 MB
/ 52,739 files / ~1.3s on every gitlab HIT). The reconciling redesign is **STAT-THEN-DIGEST**,
not stat-instead-of-digest:
- Store BOTH the stat tuple and the content digest per FileEntry (pack both into `value`, or
  add a parallel slot). On validation, `File::Stat.new(path)` first; if `(size, mtime_ns,
  ctime_ns)` matches the recorded stat → **skip the hash** (short-circuit fresh); only if the
  stat differs → fall back to `Digest::SHA256.file` against the recorded digest (a
  touched-but-identical file then still validates as fresh, and a genuinely-changed file
  digests exactly as today).
- On a *true null build* (nothing changed) this is 52,739 `File::Stat.new` calls
  (microseconds each, no byte reads) + **0 SHA-256 bytes**, versus today's 52,739 digests +
  **115 MB hashed** — an expected ~1.3s → ~50–100ms cut on the gitlab warm floor, with
  digest-authority preserved on any stat-changed file. `ctime_ns` catches metadata-only
  changes; `inode` catches atomic-replace swaps.
- Same lever applies to `GlobEntry` (stat each globbed file, only re-hash the changed ones)
  and to the ADR-60 plugin `watch:` validation (the other 40 MB).

---

## 7. Ranked read — where the null / 1-edit floor actually sits

1. **Large-project warm null (gitlab A/B): cache-validation / digest-bound.** ~1.3–2.0s of
   SHA-256 over 52,739 files / 115 MB (A) or 29,746 / 67 MB (B), split ADR-45 `fresh?`
   (74 MB) + ADR-60 plugin-glob (40 MB) + plugin `fresh?` (23 MB). Boot is a minor 287ms.
   **This is the highest-value target** and the direct motivation for the stat-then-digest
   redesign (§6). Secondary: the plugin `#prepare`/glob-validate prepass (~1.1s A / ~5.4s in
   the incremental & full paths) is a fixed tax paid before the ADR-45 verdict on every run.
2. **Small/medium warm null (mail, rigor-lib A/B): boot-bound.** Analysis is 6–55ms; the
   ~0.36–0.46s wall is ~245ms `bundle exec` bundler tax (artifact) + ~90–150ms engine+rbs+prism
   require (loaded eagerly in `load_check_dependencies` before the cache verdict) + ~50ms VM.
   The lever here is deferring the inference-engine require **and** the env build past the
   ADR-45 verdict (§3) — a HIT needs neither. Snapshot round-trip (B) adds 10–53ms of
   rewrite-nothing I/O.
3. **1-edit incremental (C): affected-closure + fixed plugin-prepass.** Cost = re-analysis of
   the edited file's dependent closure (leaf ≈ 0.25s, hub `label.rb` ≈ 4.3s) **plus** the
   fixed per-recheck plugin glob-validation (gitlab ~5.4s) **plus** snapshot round-trip. On
   gitlab the plugin-prepass alone makes even a trivial edit cost >5s — pushing plugin-cache
   validation onto the stat fast-path (§6) is the same lever as #1 and would cut it directly.
4. **1-edit default = full build (D): per-file inference-bound.** analyze_files 2.8s (mail) /
   5.3s (rigor) / 13.5s (gitlab) — the intrinsic typing cost, plus discovery pre-pass and (on
   gitlab) the 5.4s plugin build. This is the ADR-46/85 win case: incremental C avoids re-doing
   it for unchanged files (4.5–7.5× on leaf-ish edits).

**One-line synthesis.** Below ~300 files the null/near-null floor is *boot* (mostly a
`bundle exec` artifact + the eagerly-required engine); at monorepo scale it flips hard to
*cache re-validation* — re-hashing 100+ MB across 50k+ dependency files on every warm run —
which a machine-local **stat-then-digest** freshness tier (rideable on the existing
`FileEntry`/`GlobEntry` formats via a new `:stat` comparator, one `SCHEMA_VERSION` bump)
would collapse from ~1.3s to ~50–100ms while keeping digest soundness on any file whose
stat actually moved.
